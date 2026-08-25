import Foundation
import NSpaceContracts

// 节点契约（NodeEvent/NodeContext/OperationNode/ConflictArbiter）在 NSpaceContracts 词汇表；
// 本内核只做通用机制：排队/调度/取消/进度切面/Run 状态机原子提交（BG-3 零业务分支）。

// MARK: - 内核（唯一 Commit Owner：Run 状态机的原子提交，BG-5）

public actor OperationKernel {
    private struct Run {
        let id: UUID
        let spec: OperationSpec
        var state: RunState = .pending
        var filesDone = 0
        var filesTotal = 0
        var bytesDone: Int64 = 0
        var bytesTotal: Int64 = 0
        var currentPath: String?
        var task: Task<Void, Never>?
        let startedAt = Date()
    }

    private var nodes: [OperationSpec.Kind: any OperationNode] = [:]
    private var arbiter: (any ConflictArbiter)?
    private var runs: [UUID: Run] = [:]
    /// 成功终态的节点凭证留存（createdURLs / trashedItems 供 UI 选中/撤销读取；纯派生存档，非状态机分支）
    private var receipts: [UUID: OperationReceipt] = [:]
    private var order: [UUID] = []
    private var observers: [UUID: AsyncStream<OperationProjection>.Continuation] = [:]
    /// 串行执行：磁盘 I/O 可预测；并行度留作后续配置
    private var executing = false
    private var waiting: [UUID] = []

    public init() {}

    // MARK: 编排配置（What 由 App 启动时声明式注入，BG-2）

    public func register(_ node: any OperationNode, for kinds: [OperationSpec.Kind]) {
        for k in kinds { nodes[k] = node }
    }

    public func setArbiter(_ a: any ConflictArbiter) { arbiter = a }

    // MARK: Command 面（展示层唯一入口，BG-1）

    @discardableResult
    public func submit(_ spec: OperationSpec) -> UUID {
        let id = UUID()
        runs[id] = Run(id: id, spec: spec)
        order.append(id)
        publish(id)
        waiting.append(id)
        pump()
        return id
    }

    public func cancel(_ id: UUID) {
        guard var run = runs[id], !run.state.isTerminal else { return }
        if let task = run.task {
            task.cancel()
        } else {
            waiting.removeAll { $0 == id }
            run.state = .cancelled
            runs[id] = run
            publish(id)
        }
    }

    // MARK: Query / Subscribe 面（只读投影）

    public func projections() -> AsyncStream<OperationProjection> {
        let key = UUID()
        return AsyncStream { continuation in
            observers[key] = continuation
            for id in order { if let p = projection(id) { continuation.yield(p) } }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeObserver(key) }
            }
        }
    }

    public func projection(_ id: UUID) -> OperationProjection? {
        guard let r = runs[id] else { return nil }
        return OperationProjection(id: r.id, kind: r.spec.kind, state: r.state,
                                   filesDone: r.filesDone, filesTotal: r.filesTotal,
                                   bytesDone: r.bytesDone, bytesTotal: r.bytesTotal,
                                   currentPath: r.currentPath)
    }

    /// 成功终态凭证（createdURLs / trashedItems）；未完成或非成功返回 nil
    public func receipt(_ id: UUID) -> OperationReceipt? { receipts[id] }

    // MARK: 内部：调度与状态提交

    private func removeObserver(_ key: UUID) { observers[key] = nil }

    private func pump() {
        guard !executing, !waiting.isEmpty else { return }
        let id = waiting.removeFirst()
        guard var run = runs[id], run.state == .pending else { pump(); return }
        guard let node = nodes[run.spec.kind] else {
            run.state = .failed(message: "no node registered for \(run.spec.kind.rawValue)", errorClass: .logic)
            runs[id] = run; publish(id); pump(); return
        }
        executing = true
        run.state = .scanning
        let spec = run.spec
        run.task = Task { [weak self] in
            await self?.drive(id: id, node: node, spec: spec)
        }
        runs[id] = run
        publish(id)
    }

    private func drive(id: UUID, node: any OperationNode, spec: OperationSpec) async {
        let context = NodeContext(
            operationID: id,
            report: { [weak self] event in
                Task { await self?.apply(event, to: id) }
            },
            resolveConflicts: { [weak self] conflicts in
                await self?.arbitrateConflicts(id: id, conflicts: conflicts) ?? nil
            }
        )
        do {
            let receipt = try await node.execute(spec, context: context)
            receipts[id] = receipt
            commit(id) { run in
                run.filesDone = receipt.filesDone
                run.bytesDone = receipt.bytesDone
                run.state = .completed
            }
        } catch is CancellationError {
            commit(id) { $0.state = .cancelled }
        } catch let error as any ClassifiedError {
            commit(id) { $0.state = .failed(message: error.localizedDescription, errorClass: error.errorClass) }
        } catch {
            commit(id) { $0.state = .failed(message: error.localizedDescription, errorClass: .transient) }
        }
        executing = false
        pump()
    }

    private func arbitrateConflicts(id: UUID, conflicts: [FileConflict]) async -> [URL: ConflictDecision]? {
        guard let arbiter else { return [:] }  // 无裁决者=无冲突策略,默认跳过全部由节点处理
        commit(id) { $0.state = .awaitingConflict }
        let decisions = await arbiter.arbitrate(operation: id, conflicts: conflicts)
        commit(id) { if !$0.state.isTerminal { $0.state = .running } }
        return decisions
    }

    private func apply(_ event: NodeEvent, to id: UUID) {
        commit(id) { run in
            switch event {
            case let .scanTotals(files, bytes):
                run.filesTotal = files
                run.bytesTotal = bytes
                if run.state == .scanning { run.state = .running }
            case let .progress(filesDone, bytesDone, currentPath):
                run.filesDone = filesDone
                run.bytesDone = bytesDone
                run.currentPath = currentPath
            }
        }
    }

    /// 唯一状态提交点：终态不可再转移（spec 3.1）
    private func commit(_ id: UUID, _ mutate: (inout Run) -> Void) {
        guard var run = runs[id] else { return }
        let wasTerminal = run.state.isTerminal
        mutate(&run)
        if wasTerminal { return }
        runs[id] = run
        publish(id)
    }

    private func publish(_ id: UUID) {
        guard let p = projection(id) else { return }
        for c in observers.values { c.yield(p) }
    }
}

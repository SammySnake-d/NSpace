import Foundation
import NSpaceContracts

/// 永久删除节点（`.delete`）。构造零参注入（Axiom 2：无全局可变状态）。
///
/// 语义：逐项容错（照 v0.19.18 修好的 trash 口径——已经真删掉的那部分必须被如实回报，
/// 不许随首个错误一起丢），一件都没删成才 throw。
/// 删除**不可撤销**，所以回执里没有 trashedItems，只有 filesDone 与 failures。
public struct EraserNode: OperationNode {
    public init() {}

    public func execute(_ spec: OperationSpec, context: NodeContext) async throws -> OperationReceipt {
        let started = Date()
        guard spec.kind == .delete else {
            throw EraserError(.logic, "EraserNode 不处理 \(spec.kind.rawValue)")
        }
        guard !spec.sources.isEmpty else {
            throw EraserError(.logic, "delete 需要至少一个源")
        }
        // 围栏必须显式给出：没有围栏的永久删除请求一律拒绝，不猜、不放行
        guard let fence = spec.destination else {
            throw EraserError(.logic, "delete 必须带 destination 作为围栏根（爆炸半径守卫）")
        }
        let outside = spec.sources.filter { !EraserLimits.isFenced($0, by: fence) }
        guard outside.isEmpty else {
            throw EraserError(.logic,
                "拒绝删除围栏之外的项（\(outside.count) 项，首个：\(outside[0].lastPathComponent)）")
        }

        let fm = FileManager.default
        context.report(.scanTotals(files: spec.sources.count, bytes: 0))
        var done = 0
        var failures: [OperationFailure] = []
        for src in spec.sources {
            if Task.isCancelled { throw CancellationError() }
            do {
                try fm.removeItem(at: src)
                done += 1
                context.report(.progress(filesDone: done, bytesDone: 0, currentPath: src.path))
            } catch {
                failures.append(OperationFailure(url: src, errorClass: .external,
                                                 message: "永久删除失败: \(error.localizedDescription)"))
            }
        }
        // 一件都没删成 = 真正的失败
        if done == 0, let first = failures.first {
            throw EraserError(first.errorClass, first.message)
        }
        return OperationReceipt(id: context.operationID, filesDone: done, bytesDone: 0,
                                duration: Date().timeIntervalSince(started), failures: failures)
    }
}

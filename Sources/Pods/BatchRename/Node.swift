import Foundation
import NSpaceContracts

/// 原子批量重命名节点（两阶段临时中转，天然支持互换与链式重命名并可在任一失败时完整回滚）
public struct BatchRenameNode: OperationNode {
    struct EntryIdentity: Hashable, Sendable {
        let dev: dev_t
        let ino: ino_t
    }

    public init() {}

    static func entryIdentity(_ url: URL) -> EntryIdentity? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        return EntryIdentity(dev: st.st_dev, ino: st.st_ino)
    }

    public func execute(_ spec: OperationSpec, context: NodeContext) async throws -> OperationReceipt {
        guard spec.kind == .batchRename else {
            throw BatchRenameError(.logic, "BatchRenameNode 仅支持 batchRename")
        }
        guard let pairs = spec.renamePairs, !pairs.isEmpty else {
            throw BatchRenameError(.logic, "batchRename 需要至少一条重命名配对")
        }

        let started = Date()
        let fm = FileManager.default
        let activePairs = pairs.filter { $0.source.lastPathComponent != $0.newName }
        if activePairs.isEmpty {
            return OperationReceipt(
                id: context.operationID,
                filesDone: 0,
                bytesDone: 0,
                duration: Date().timeIntervalSince(started),
                createdURLs: pairs.map(\.source)
            )
        }

        // 1. 预检全部源、非法名、批内重名与外部碰撞
        var sourceIDs: Set<EntryIdentity> = []
        for pair in activePairs {
            guard let eid = Self.entryIdentity(pair.source) else {
                throw BatchRenameError(.external, "源不存在: \(pair.source.lastPathComponent)", path: pair.source.path)
            }
            guard !pair.newName.isEmpty, !pair.newName.contains("/"),
                  pair.newName != ".", pair.newName != ".." else {
                throw BatchRenameError(.logic, "非法文件名: \(pair.newName)")
            }
            sourceIDs.insert(eid)
        }

        var seenTargets: Set<String> = []
        var plans: [(source: URL, temp: URL, destination: URL)] = []
        let batchToken = UUID().uuidString.prefix(8)

        for (index, pair) in activePairs.enumerated() {
            let parent = pair.source.deletingLastPathComponent()
            let dst = parent.appendingPathComponent(pair.newName)
            let collisionKey = "\(parent.path)/\(pair.newName.lowercased())"
            if !seenTargets.insert(collisionKey).inserted {
                throw BatchRenameError(.external, "批次内存在重名目标: \(pair.newName)", path: dst.path)
            }
            if let dstID = Self.entryIdentity(dst), !sourceIDs.contains(dstID) {
                throw BatchRenameError(.external, "已存在同名项: \(pair.newName)", path: dst.path)
            }
            let hopName = ".nspace-batch-\(batchToken)-\(index)-\(UUID().uuidString.prefix(6))"
            let hop = parent.appendingPathComponent(hopName)
            plans.append((pair.source, hop, dst))
        }

        context.report(.scanTotals(files: plans.count, bytes: 0))

        // 2. 第一阶段：全部源移入同级隐藏临时位，规避互换/链式循环碰撞
        var staged: [(source: URL, temp: URL, destination: URL)] = []
        do {
            for item in plans {
                try Task.checkCancellation()
                try fm.moveItem(at: item.source, to: item.temp)
                staged.append(item)
            }
        } catch {
            for done in staged.reversed() {
                try? fm.moveItem(at: done.temp, to: done.source)
            }
            if error is CancellationError { throw error }
            throw BatchRenameError(.external, "批量重命名暂存失败: \(error.localizedDescription)")
        }

        // 3. 第二阶段：临时位落位至最终目标名
        var landed: [(source: URL, temp: URL, destination: URL)] = []
        do {
            for (idx, item) in staged.enumerated() {
                try fm.moveItem(at: item.temp, to: item.destination)
                landed.append(item)
                context.report(.progress(filesDone: idx + 1, bytesDone: 0, currentPath: item.destination.path))
            }
        } catch {
            // 完整回滚：已落位退回临时位 -> 全部临时位退回原始 URL
            for done in landed.reversed() {
                try? fm.moveItem(at: done.destination, to: done.temp)
            }
            for item in staged.reversed() {
                try? fm.moveItem(at: item.temp, to: item.source)
            }
            throw BatchRenameError(.external, "批量重命名失败: \(error.localizedDescription)")
        }

        let created = landed.map(\.destination)
        let renamedItems = landed.map { RenamedItem(original: $0.source, renamed: $0.destination) }
        return OperationReceipt(
            id: context.operationID,
            filesDone: landed.count,
            bytesDone: 0,
            duration: Date().timeIntervalSince(started),
            createdURLs: created,
            renamedItems: renamedItems
        )
    }
}

import Foundation
import NSpaceContracts

// 私有关注点：四种本地操作的物理实现（真实 FileManager 副作用；错误就地三分类）

extension LocalOpsNode {

    // MARK: 重命名（同目录 moveItem 改名；FG-6 失败由 UI 侧原子回滚）

    func renameEntry(_ spec: OperationSpec, context: NodeContext, started: Date) throws -> OperationReceipt {
        let fm = FileManager.default
        guard spec.sources.count == 1, let src = spec.sources.first else {
            throw LocalOpsError(.logic, "rename 需要恰好一个源")
        }
        guard let newName = spec.newName, !newName.isEmpty else {
            throw LocalOpsError(.logic, "rename 需要非空新名")
        }
        guard !newName.contains("/"), newName != ".", newName != ".." else {
            throw LocalOpsError(.logic, "非法文件名: \(newName)")
        }
        guard fm.fileExists(atPath: src.path) else {
            throw LocalOpsError(.external, "源不存在: \(src.lastPathComponent)", path: src.path)
        }
        let dst = src.deletingLastPathComponent().appendingPathComponent(newName)
        // 同名（仅大小写变化除外）视为无操作，避免 moveItem 自我覆盖报错
        if dst.path == src.path {
            return OperationReceipt(id: context.operationID, filesDone: 0, bytesDone: 0,
                                    duration: Date().timeIntervalSince(started), createdURLs: [src])
        }
        if fm.fileExists(atPath: dst.path) {
            throw LocalOpsError(.external, "已存在同名项: \(newName)", path: dst.path)
        }
        context.report(.scanTotals(files: 1, bytes: 0))
        do {
            try fm.moveItem(at: src, to: dst)
        } catch {
            throw LocalOpsError(.external, "重命名失败: \(error.localizedDescription)", path: src.path)
        }
        context.report(.progress(filesDone: 1, bytesDone: 0, currentPath: dst.path))
        return OperationReceipt(id: context.operationID, filesDone: 1, bytesDone: 0,
                                duration: Date().timeIntervalSince(started), createdURLs: [dst])
    }

    // MARK: 新建文件夹 / 新建文件（重名自动追加序号；结果 URL 回传供选中+重命名）

    func createEntry(_ spec: OperationSpec, context: NodeContext, isDirectory: Bool,
                     defaultBase: String, started: Date) throws -> OperationReceipt {
        let fm = FileManager.default
        guard let dir = spec.destination else {
            throw LocalOpsError(.logic, "新建需要 destination 目录")
        }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            throw LocalOpsError(.external, "目标目录不可用: \(dir.lastPathComponent)", path: dir.path)
        }
        let base = (spec.newName?.isEmpty == false) ? spec.newName! : defaultBase
        let name = uniqueName(base: base, ext: "", in: dir)
        let url = dir.appendingPathComponent(name)
        context.report(.scanTotals(files: 1, bytes: 0))
        do {
            if isDirectory {
                try fm.createDirectory(at: url, withIntermediateDirectories: false)
            } else {
                guard fm.createFile(atPath: url.path, contents: Data()) else {
                    throw LocalOpsError(.external, "无法创建文件: \(name)", path: url.path)
                }
            }
        } catch let e as LocalOpsError {
            throw e
        } catch {
            throw LocalOpsError(.external, "新建失败: \(error.localizedDescription)", path: url.path)
        }
        context.report(.progress(filesDone: 1, bytesDone: 0, currentPath: url.path))
        return OperationReceipt(id: context.operationID, filesDone: 1, bytesDone: 0,
                                duration: Date().timeIntervalSince(started), createdURLs: [url])
    }

    // MARK: 移到废纸篓（记录 原URL→回收站URL 对供撤销）

    func trashEntries(_ spec: OperationSpec, context: NodeContext, started: Date) throws -> OperationReceipt {
        let fm = FileManager.default
        guard !spec.sources.isEmpty else {
            throw LocalOpsError(.logic, "trash 需要至少一个源")
        }
        context.report(.scanTotals(files: spec.sources.count, bytes: 0))
        var pairs: [TrashedItem] = []
        var done = 0
        for src in spec.sources {
            guard fm.fileExists(atPath: src.path) else {
                throw LocalOpsError(.external, "源不存在: \(src.lastPathComponent)", path: src.path)
            }
            var resulting: NSURL?
            do {
                try fm.trashItem(at: src, resultingItemURL: &resulting)
            } catch {
                throw LocalOpsError(.external, "移到废纸篓失败: \(error.localizedDescription)", path: src.path)
            }
            // 回收站落点未知时以原名兜底（撤销仍可按原路径尝试）
            let trashed = (resulting as URL?) ?? src
            pairs.append(TrashedItem(original: src, trashed: trashed))
            done += 1
            context.report(.progress(filesDone: done, bytesDone: 0, currentPath: src.path))
        }
        return OperationReceipt(id: context.operationID, filesDone: done, bytesDone: 0,
                                duration: Date().timeIntervalSince(started), trashedItems: pairs)
    }
}

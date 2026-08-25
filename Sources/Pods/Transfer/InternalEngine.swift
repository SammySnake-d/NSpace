import Foundation
import NSpaceContracts
import Darwin

// 私有关注点：物理传输引擎 —— copyfile(3) 字节级进度 + 协作式取消 + 同卷 rename 快路径

/// 协作式取消旗标：withTaskCancellationHandler 置位，copyfile 回调轮询（跨线程安全）
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// 进度聚合器：copyfile 回调在 I/O 线程触发，加锁聚合并节流上报（≥512KB 或文件边界才发）
final class ProgressAggregator: @unchecked Sendable {
    private let lock = NSLock()
    private var filesDone = 0
    private var bytesCompleted: Int64 = 0     // 已完成文件的字节
    private var currentFileBytes: Int64 = 0   // 当前文件已拷字节
    private var lastReported: Int64 = 0
    private let report: @Sendable (NodeEvent) -> Void

    init(report: @escaping @Sendable (NodeEvent) -> Void) { self.report = report }

    func currentFile(bytes: Int64, path: String) {
        lock.lock()
        currentFileBytes = bytes
        let total = bytesCompleted + currentFileBytes
        let shouldReport = total - lastReported >= 512 * 1024
        if shouldReport { lastReported = total }
        let files = filesDone
        lock.unlock()
        if shouldReport { report(.progress(filesDone: files, bytesDone: total, currentPath: path)) }
    }

    func fileFinished(bytes: Int64, path: String) {
        lock.lock()
        filesDone += 1
        bytesCompleted += bytes
        currentFileBytes = 0
        lastReported = bytesCompleted
        let files = filesDone, total = bytesCompleted
        lock.unlock()
        report(.progress(filesDone: files, bytesDone: total, currentPath: path))
    }

    /// 同卷 move 快路径：整棵树瞬时完成
    func addCompleted(files: Int, bytes: Int64, path: String) {
        lock.lock()
        filesDone += files
        bytesCompleted += bytes
        lastReported = bytesCompleted
        let f = filesDone, total = bytesCompleted
        lock.unlock()
        report(.progress(filesDone: f, bytesDone: total, currentPath: path))
    }

    func snapshotFiles() -> Int { lock.lock(); defer { lock.unlock() }; return filesDone }
    func snapshotBytes() -> Int64 { lock.lock(); defer { lock.unlock() }; return bytesCompleted }
}

/// 专用 I/O 队列：copyfile 阻塞调用不占用 Swift 并发协作线程池
private let ioQueue = DispatchQueue(label: "com.nspace.transfer.io", qos: .userInitiated)

extension TransferNode {
    func transferEntry(_ entry: TransferPlan.Entry, mode: TransferPlan.Mode,
                       flag: CancelFlag, progress: ProgressAggregator,
                       entryTotals: ScanTotals) async throws {
        if flag.isSet { throw CancellationError() }
        let fm = FileManager.default

        if mode == .move, sameVolume(entry.source, entry.destination.deletingLastPathComponent()) {
            // 同卷移动 = 原子 rename，瞬时
            do { try fm.moveItem(at: entry.source, to: entry.destination) } catch {
                throw TransferError(.external, "移动失败: \(error.localizedDescription)", path: entry.source.path)
            }
            progress.addCompleted(files: entryTotals.files, bytes: entryTotals.bytes,
                                  path: entry.destination.path)
            return
        }

        // 复制（或跨卷移动的复制阶段）
        try await copyRecursive(from: entry.source, to: entry.destination,
                                merge: entry.merge, flag: flag, progress: progress)

        if mode == .move {
            do { try fm.removeItem(at: entry.source) } catch {
                throw TransferError(.external, "跨卷移动清理源失败: \(error.localizedDescription)",
                                    path: entry.source.path)
            }
        }
    }

    private func copyRecursive(from src: URL, to dst: URL, merge: Bool,
                               flag: CancelFlag, progress: ProgressAggregator) async throws {
        if flag.isSet { throw CancellationError() }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: src.path, isDirectory: &isDir) else {
            throw TransferError(.external, "源不存在: \(src.lastPathComponent)", path: src.path)
        }

        if isDir.boolValue, !isPackageTreatedAsFile(src) {
            if !fm.fileExists(atPath: dst.path) {
                do { try fm.createDirectory(at: dst, withIntermediateDirectories: true) } catch {
                    throw TransferError(.external, "创建目录失败: \(error.localizedDescription)", path: dst.path)
                }
            }
            let children = (try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [])) ?? []
            for child in children {
                let childDst = dst.appendingPathComponent(child.lastPathComponent)
                if merge, fm.fileExists(atPath: childDst.path) {
                    var childDstDir: ObjCBool = false
                    var childSrcDir: ObjCBool = false
                    _ = fm.fileExists(atPath: childDst.path, isDirectory: &childDstDir)
                    _ = fm.fileExists(atPath: child.path, isDirectory: &childSrcDir)
                    if !(childDstDir.boolValue && childSrcDir.boolValue) {
                        // 合并语义：同名子文件源覆盖目标（契约文档化承诺）
                        try? fm.removeItem(at: childDst)
                    }
                }
                try await copyRecursive(from: child, to: childDst, merge: merge,
                                        flag: flag, progress: progress)
            }
        } else {
            try await copyOneFile(from: src, to: dst, flag: flag, progress: progress)
        }
    }

    /// 单文件 copyfile：字节级进度回调 + COPYFILE_QUIT 取消 + 半成品清理
    private func copyOneFile(from src: URL, to dst: URL,
                             flag: CancelFlag, progress: ProgressAggregator) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            ioQueue.async {
                do {
                    try copyOneFileSync(from: src, to: dst, flag: flag, progress: progress)
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let ka: Set<URLResourceKey> = [.volumeIdentifierKey]
        guard let va = try? a.resourceValues(forKeys: ka).volumeIdentifier,
              let vb = try? b.resourceValues(forKeys: ka).volumeIdentifier else { return false }
        return va.isEqual(vb)
    }

    /// .app 等包：整体视作文件级复制单位仍走目录递归即可；此处仅决定进度粒度，返回 false 走递归
    private func isPackageTreatedAsFile(_ url: URL) -> Bool { false }
}

/// copyfile 回调上下文盒（经 STATUS_CTX 透传进 C 回调）
private final class CopyContext {
    let flag: CancelFlag
    let progress: ProgressAggregator
    let dstPath: String
    init(flag: CancelFlag, progress: ProgressAggregator, dstPath: String) {
        self.flag = flag; self.progress = progress; self.dstPath = dstPath
    }
}

private func copyOneFileSync(from src: URL, to dst: URL,
                             flag: CancelFlag, progress: ProgressAggregator) throws {
    if flag.isSet { throw CancellationError() }
    let state = copyfile_state_alloc()
    defer { copyfile_state_free(state) }

    let box = CopyContext(flag: flag, progress: progress, dstPath: dst.path)
    let ctx = Unmanaged.passRetained(box)
    defer { ctx.release() }

    let callback: copyfile_callback_t = { what, stage, state, _, _, ctxPtr in
        guard let ctxPtr else { return Int32(COPYFILE_CONTINUE) }
        let box = Unmanaged<CopyContext>.fromOpaque(ctxPtr).takeUnretainedValue()
        if box.flag.isSet { return Int32(COPYFILE_QUIT) }
        if what == COPYFILE_COPY_DATA, stage == COPYFILE_PROGRESS {
            var copied: off_t = 0
            copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied)
            box.progress.currentFile(bytes: Int64(copied), path: box.dstPath)
        }
        return Int32(COPYFILE_CONTINUE)
    }

    copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), ctx.toOpaque())
    copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB),
                       unsafeBitCast(callback, to: UnsafeRawPointer.self))

    // COPYFILE_CLONE：同卷 APFS 瞬时克隆；跨卷自动退化为真实拷贝
    let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_CLONE | COPYFILE_NOFOLLOW)
    let rc = copyfile(src.path, dst.path, state, flags)

    if rc < 0 {
        // 半成品清理：取消或出错都不留残缺目标
        try? FileManager.default.removeItem(at: dst)
        if flag.isSet || errno == ECANCELED { throw CancellationError() }
        let msg = String(cString: strerror(errno))
        throw TransferError(.external, "复制失败: \(msg)", path: src.path)
    }

    var size: off_t = 0
    copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &size)
    if size == 0 {
        // APFS 克隆路径不搬字节（COPIED=0）：按目标实际大小入账，进度语义=逻辑传输量
        let attrs = try? FileManager.default.attributesOfItem(atPath: dst.path)
        size = off_t((attrs?[.size] as? Int64) ?? 0)
    }
    progress.fileFinished(bytes: Int64(size), path: dst.path)
}

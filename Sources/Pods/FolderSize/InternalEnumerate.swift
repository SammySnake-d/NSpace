import Foundation
import NSpaceContracts

// 私有关注点：递归占用字节求和 + 承接 detached 任务句柄的线程安全盒子。

private let sizeKeys: Set<URLResourceKey> = [
    .isRegularFileKey, .isDirectoryKey,
    .totalFileAllocatedSizeKey, .fileSizeKey,
]

/// 递归求和：目录深枚举所有常规文件占用；单个文件直接返回其占用。
/// 每步查 Task.isCancelled 支持协作式取消（取消抛 CancellationError）。
func directoryAllocatedSize(_ url: URL) throws -> Int64 {
    let fm = FileManager.default

    let rv: URLResourceValues
    do {
        rv = try url.resourceValues(forKeys: sizeKeys)
    } catch let e as NSError {
        let cls: ErrorClass = (e.domain == NSCocoaErrorDomain &&
            (e.code == NSFileReadNoPermissionError || e.code == NSFileReadNoSuchFileError))
            ? .external : .transient
        throw FolderSizeError(cls, e.localizedDescription, underlying: e)
    }

    if rv.isRegularFile == true {
        return fileBytes(rv)
    }
    guard rv.isDirectory == true else { return 0 }   // 符号链接/特殊文件不计

    guard let enumerator = fm.enumerator(
        at: url,
        includingPropertiesForKeys: Array(sizeKeys),
        options: [],
        errorHandler: nil) else {
        throw FolderSizeError(.external, "无法枚举目录：\(url.path)")
    }

    var total: Int64 = 0
    for case let child as URL in enumerator {
        try Task.checkCancellation()   // 协作式取消检查点
        guard let crv = try? child.resourceValues(forKeys: sizeKeys),
              crv.isRegularFile == true else { continue }
        total += fileBytes(crv)
    }
    return total
}

// 优先 totalFileAllocatedSize（含元数据/块对齐的真实占用），回退 fileSize（逻辑字节）。
private func fileBytes(_ rv: URLResourceValues) -> Int64 {
    Int64(rv.totalFileAllocatedSize ?? rv.fileSize ?? 0)
}

/// 承接 detached 任务句柄，供取消转发；锁保证 set/cancel 无竞争。
final class TaskHandleBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var cancelled = false

    func set(_ task: Task<Void, Never>) {
        lock.lock(); defer { lock.unlock() }
        if cancelled { task.cancel() } else { self.task = task }
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        task?.cancel()
    }
}

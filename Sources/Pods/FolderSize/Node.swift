import Foundation
import NSpaceContracts

/// 构造工厂 + 入口（Axiom 2：无全局状态，缓存为实例私有）。
public actor FolderSize: FolderSizing {
    // 派生缓存（非权威状态，可随时丢弃）：路径 → 已算字节数。
    private var cache: [URL: Int64] = [:]

    // 深枚举并发限界：同时最多 maxConcurrent 个，其余以续体排队（FIFO）。
    // 深枚举本体在 detached task 上跑，不阻塞 actor 执行器，故并发有意义。
    private let maxConcurrent = 2
    private var activeScans = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func size(of url: URL) async throws -> Int64 {
        if let cached = cache[url] { return cached }

        await acquireSlot()
        defer { releaseSlot() }

        try Task.checkCancellation()   // 排队等待期间若已取消，尽早退出
        let total = try await runEnumeration(url)
        cache[url] = total
        return total
    }

    public func invalidate(_ url: URL) {
        cache[url] = nil
    }

    // MARK: - 并发闸（计数 + 续体队列；交接时计数不动，保持严格 maxConcurrent 上限）

    private func acquireSlot() async {
        if activeScans < maxConcurrent {
            activeScans += 1
            return
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            waiters.append(c)
        }
        // 被 releaseSlot 唤醒即持有名额（名额由上一持有者交接，activeScans 未变）
    }

    private func releaseSlot() {
        if waiters.isEmpty {
            activeScans -= 1
        } else {
            waiters.removeFirst().resume()   // 交接名额给队首
        }
    }

    // MARK: - 深枚举（detached 至后台，取消经句柄转发）

    private func runEnumeration(_ url: URL) async throws -> Int64 {
        let handle = TaskHandleBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int64, any Error>) in
                let work = Task.detached(priority: .utility) {
                    do { cont.resume(returning: try directoryAllocatedSize(url)) }
                    catch { cont.resume(throwing: error) }
                }
                handle.set(work)
            }
        } onCancel: {
            handle.cancel()   // 转发取消 → detached task 内 Task.isCancelled 置真 → 枚举循环抛错
        }
    }
}

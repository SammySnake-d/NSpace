import Foundation
import CoreServices
import NSpaceContracts

// 私有关注点：FSEventStream 生命周期 + C 回调 trampoline。
// 全部可变状态由 lock 串行化，故对外以 @unchecked Sendable 呈现（锁保证数据竞争自由）。

final class WatchPump: @unchecked Sendable {
    private let lock = NSLock()
    private let path: String
    private let continuation: AsyncStream<Void>.Continuation
    // 专用队列承接 FSEvents 回调，绝不占用主线程（后台零功耗律）。
    private let queue = DispatchQueue(label: "com.nspace.directorywatch", qos: .utility)

    private var stream: FSEventStreamRef?
    private var running = false
    private var stopped = false
    private(set) var startupError: DirectoryWatchError?

    init(path: URL, continuation: AsyncStream<Void>.Continuation) {
        self.path = path.path
        self.continuation = continuation
    }

    /// 回调线程调用：向信号流投递一次变化（stopped 后丢弃）。
    func emit() {
        lock.lock(); let dead = stopped; lock.unlock()
        guard !dead else { return }
        continuation.yield(())
    }

    func start() {
        lock.lock(); defer { lock.unlock() }
        guard stream == nil, !stopped else { return }

        // info 传 unretained self：WatchPump 生命周期覆盖 stream（stop/deinit 必先拆流），无悬垂。
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)

        let flags = UInt32(kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagNoDefer)   // NoDefer: 首个变化即刻上报，其后才按 latency 合并

        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault, watchCallback, &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3, flags) else {
            startupError = DirectoryWatchError(.transient, "FSEventStream 创建失败：\(path)")
            continuation.finish()
            return
        }

        FSEventStreamSetDispatchQueue(s, queue)
        if FSEventStreamStart(s) {
            stream = s
            running = true
        } else {
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            startupError = DirectoryWatchError(.transient, "FSEventStream 启动失败：\(path)")
            continuation.finish()
        }
    }

    func suspend() {
        lock.lock(); defer { lock.unlock() }
        guard let s = stream, running, !stopped else { return }
        FSEventStreamStop(s)
        running = false
    }

    func resume() {
        lock.lock(); defer { lock.unlock() }
        guard let s = stream, !running, !stopped else { return }
        if FSEventStreamStart(s) { running = true }
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }
        stopped = true
        if let s = stream {
            if running { FSEventStreamStop(s) }
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
            running = false
        }
        continuation.finish()
    }
}

// C 回调 trampoline：经 info 指针取回 WatchPump（unretained），投递一次信号。
// 单次回调可能聚合多路径事件；对"整目录重载"语义无需逐条解析，一次 emit 即可。
private func watchCallback(
    _ streamRef: ConstFSEventStreamRef,
    _ info: UnsafeMutableRawPointer?,
    _ numEvents: Int,
    _ eventPaths: UnsafeMutableRawPointer,
    _ eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    _ eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let info else { return }
    Unmanaged<WatchPump>.fromOpaque(info).takeUnretainedValue().emit()
}

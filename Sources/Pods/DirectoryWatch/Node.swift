import Foundation
import NSpaceContracts

/// 构造工厂（Axiom 2：无全局状态，句柄经构造产出）。
public struct DirectoryWatch: DirectoryWatching {
    public init() {}

    public func watch(_ path: URL) -> DirectoryWatcher {
        DirectoryWatcher(path: path)
    }
}

/// FSEvents 监听句柄：暴露 `signals` 信号流与挂起/恢复/停止控制。
///
/// 后台窗格挂起是产品北极星：`suspend()` 真停 FSEventStream（零回调、零功耗），
/// `resume()` 再启动；`stop()` / deinit 彻底拆流并收尾信号流。
public final class DirectoryWatcher: Sendable {
    /// 目录变化信号流（0.3s latency 合并突发事件；bufferingNewest(1) 把多次变化坍缩成一次待重载）。
    public let signals: AsyncStream<Void>
    /// FSEventStream 创建失败时非 nil（transient）；调用方据此降级为手动刷新（⌘R），不崩。
    public var startupError: DirectoryWatchError? { pump.startupError }

    private let pump: WatchPump

    init(path: URL) {
        let (stream, continuation) = AsyncStream.makeStream(
            of: Void.self, bufferingPolicy: .bufferingNewest(1))
        self.signals = stream
        self.pump = WatchPump(path: path, continuation: continuation)
        pump.start()
    }

    /// 挂起监听：停止 FSEventStream（不再产生回调），但保留句柄可后续 resume。
    public func suspend() { pump.suspend() }

    /// 恢复监听：重启 FSEventStream，只收到恢复之后发生的变化。
    public func resume() { pump.resume() }

    /// 停止并拆除监听，收尾信号流（幂等）。
    public func stop() { pump.stop() }

    deinit { pump.stop() }
}

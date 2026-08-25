import Foundation
import NSpaceContracts

// DirectoryWatch 胶囊唯一对外契约面（Axiom 3）：目录 URL → 变化信号流 + 挂起/恢复/停止句柄。
// 每次目录变化产一个 Void 信号，调用方收到即整目录重载（不做增量 diff，交由 DirectoryReader 出新快照）。

public struct DirectoryWatchError: ClassifiedError {
    public let errorClass: ErrorClass
    public let localizedDescription: String

    init(_ cls: ErrorClass, _ message: String) {
        self.errorClass = cls
        self.localizedDescription = message
    }
}

/// 监听工厂：产出一个已启动的 DirectoryWatcher 句柄。
public protocol DirectoryWatching: Sendable {
    /// 返回的句柄立即开始监听；持有它以维持监听，释放即自动停止（deinit 收流）。
    func watch(_ path: URL) -> DirectoryWatcher
}

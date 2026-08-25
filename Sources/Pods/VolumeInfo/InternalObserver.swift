import Foundation

/// 私有关注点：非 Sendable 的 NotificationCenter 观察者令牌盒
/// removeObserver 线程安全（Foundation 保证），故 @unchecked Sendable 成立
final class ObserverBox: @unchecked Sendable {
    private let center: NotificationCenter
    private let lock = NSLock()
    private var tokens: [any NSObjectProtocol]

    init(center: NotificationCenter, tokens: [any NSObjectProtocol]) {
        self.center = center
        self.tokens = tokens
    }

    func removeAll() {
        lock.lock()
        let toRemove = tokens
        tokens = []
        lock.unlock()
        for t in toRemove { center.removeObserver(t) }
    }

    deinit { removeAll() }
}

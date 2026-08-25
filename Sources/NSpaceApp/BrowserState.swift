import Foundation

/// 每标签浏览状态：当前位置 + 前进/后退历史栈（spec 数据契约 session 结构的运行态）
@MainActor
final class BrowserState {
    private(set) var current: URL
    private var backStack: [URL] = []
    private var forwardStack: [URL] = []

    init(url: URL) {
        self.current = url
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { current.standardizedFileURL.path != "/" }

    /// 新导航：清空前进栈（浏览器语义）
    func navigate(to url: URL) {
        guard url != current else { return }
        backStack.append(current)
        forwardStack.removeAll()
        current = url
    }

    func goBack() -> URL? {
        guard let prev = backStack.popLast() else { return nil }
        forwardStack.append(current)
        current = prev
        return prev
    }

    func goForward() -> URL? {
        guard let next = forwardStack.popLast() else { return nil }
        backStack.append(current)
        current = next
        return next
    }

    func goUp() -> URL? {
        guard canGoUp else { return nil }
        let parent = current.deletingLastPathComponent().standardizedFileURL
        navigate(to: parent)
        return parent
    }
}

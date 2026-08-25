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

    /// 后退/前进历史（最近的在前，供导航长按历史菜单展示；§3）
    var backHistory: [URL] { backStack.reversed() }
    var forwardHistory: [URL] { forwardStack.reversed() }

    /// 跳到后退历史第 index 项（0=最近）：回退 index+1 步，路径逐一进前进栈（浏览器语义）
    @discardableResult
    func jumpBack(to index: Int) -> URL? {
        guard index >= 0, index < backStack.count else { return nil }
        var last: URL?
        for _ in 0...index { last = goBack() }
        return last
    }

    /// 跳到前进历史第 index 项（0=最近）：前进 index+1 步
    @discardableResult
    func jumpForward(to index: Int) -> URL? {
        guard index >= 0, index < forwardStack.count else { return nil }
        var last: URL?
        for _ in 0...index { last = goForward() }
        return last
    }

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

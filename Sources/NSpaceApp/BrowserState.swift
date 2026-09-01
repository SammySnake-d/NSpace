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
        // 同一目录的不同写法不得重复压进后退栈：`/a/b` 与 `/a/b/`、含 `.`/`..` 的形式
        // URL 原样比一律不相等（absoluteString 不同），于是同一个目录被压进历史，
        // 用户按 ⌘[ 看起来"原地不动"。地址栏粘贴带尾斜杠的路径是最容易撞上的入口。
        // 只做 standardizedFileURL（纯字符串）比较、**不**解析符号链接——那要 stat，
        // 失效的网络卷上会把导航热路径拖住（同 PathEditorField 把解析挪到后台的理由）。
        guard url.standardizedFileURL.path != current.standardizedFileURL.path else { return }
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

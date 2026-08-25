import AppKit
import NSpaceKernel

/// 主窗口：M2 单窗格列表；M3+ 挂窗格网格/侧栏/地址栏/状态栏
@MainActor
final class MainWindowController: NSWindowController {
    let kernel: OperationKernel
    private let listVC: FileListViewController

    init(kernel: OperationKernel, initialDirectory: URL, select: URL? = nil) {
        self.kernel = kernel
        let model = DirectoryViewModel(directory: initialDirectory)
        self.listVC = FileListViewController(model: model)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.minSize = NSSize(width: 600, height: 400)
        window.center()
        window.setFrameAutosaveName("NSpaceMainWindow")
        super.init(window: window)

        window.contentViewController = listVC
        listVC.onNavigate = { [weak self] url in self?.navigate(to: url) }
        updateTitle(for: initialDirectory)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建 UI，无 xib") }

    func navigate(to url: URL) {
        listVC.model.navigate(to: url)
        updateTitle(for: url)
    }

    private func updateTitle(for url: URL) {
        window?.title = url.lastPathComponent
        window?.representedURL = url  // 标题栏图标可 ⌘点击 显示路径链（Finder 惯例）
    }

    // MARK: 前往菜单

    @objc func goHome(_ sender: Any?) {
        navigate(to: FileManager.default.homeDirectoryForCurrentUser)
    }

    @objc func goUpFolder(_ sender: Any?) {
        let parent = listVC.model.directory.deletingLastPathComponent()
        guard parent != listVC.model.directory else { return }
        navigate(to: parent)
    }
}

import AppKit
import NSpaceKernel

/// 主窗口：M3 单窗格（地址栏+列表+历史）；M4 起换 PaneGrid 多窗格
@MainActor
final class MainWindowController: NSWindowController {
    let kernel: OperationKernel
    let pane: PaneViewController

    init(kernel: OperationKernel, initialDirectory: URL, select: URL? = nil) {
        self.kernel = kernel
        self.pane = PaneViewController(directory: initialDirectory)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.minSize = NSSize(width: 600, height: 400)
        window.center()
        window.setFrameAutosaveName("NSpaceMainWindow")
        super.init(window: window)

        window.contentViewController = pane
        pane.onLocationChange = { [weak self] url in self?.updateTitle(for: url) }
        updateTitle(for: initialDirectory)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建 UI，无 xib") }

    func navigate(to url: URL) {
        pane.navigate(to: url)
    }

    private func updateTitle(for url: URL) {
        window?.title = url.lastPathComponent
        window?.representedURL = url  // 标题栏图标可 ⌘点击 显示路径链（Finder 惯例）
    }
}

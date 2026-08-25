import AppKit
import NSpaceKernel

/// 主窗口：M0 为可走骨架（空内容 + 标题）；M2 起挂窗格网格/侧栏/状态栏
@MainActor
final class MainWindowController: NSWindowController {
    let kernel: OperationKernel
    let initialDirectory: URL
    let initialSelection: URL?

    init(kernel: OperationKernel, initialDirectory: URL, select: URL? = nil) {
        self.kernel = kernel
        self.initialDirectory = initialDirectory
        self.initialSelection = select

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = initialDirectory.lastPathComponent
        window.minSize = NSSize(width: 600, height: 400)
        window.center()
        window.setFrameAutosaveName("NSpaceMainWindow")
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建 UI，无 xib") }
}

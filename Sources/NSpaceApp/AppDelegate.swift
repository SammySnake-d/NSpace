import AppKit
import NSpaceKernel

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let kernel = OperationKernel()
    private var windowControllers: [MainWindowController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        openWindow(at: FileManager.default.homeDirectoryForCurrentUser)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// open-URL 路由：目录 → 开窗定位；文件 → 父目录 + 选中该文件（替代 Finder 的入口）
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                openWindow(at: url)
            } else {
                openWindow(at: url.deletingLastPathComponent(), selecting: url)
            }
        }
    }

    @discardableResult
    func openWindow(at directory: URL, selecting: URL? = nil) -> MainWindowController {
        let wc = MainWindowController(kernel: kernel, initialDirectory: directory, select: selecting)
        windowControllers.append(wc)
        wc.window?.delegate = self
        wc.showWindow(nil)
        return wc
    }

    @objc func newWindow(_ sender: Any?) {
        openWindow(at: FileManager.default.homeDirectoryForCurrentUser)
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        windowControllers.removeAll { $0.window === window }
    }
}

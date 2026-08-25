import AppKit
import NSpaceKernel
import Transfer
import LocalOps
import SessionStore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let kernel = OperationKernel()
    /// 冲突裁决面板（内核唯一 arbiter）——强持有，内核只存弱语义引用
    private let conflictSheet = ConflictSheet()
    private var windowControllers: [MainWindowController] = []
    /// 会话快照唯一 Commit Owner（M11）
    let sessionStore = SessionStore(
        directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NSpace"))
    /// 恢复完成前的状态变化不落盘（防启动过程把半成品覆盖上次会话）
    private var sessionReady = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        // 组合根（BG-2）：声明式注入 What —— 胶囊节点 + 冲突裁决者 + 进度订阅
        Task { @MainActor in
            await kernel.register(TransferNode(), for: [.copy, .move, .duplicate])
            await kernel.register(LocalOpsNode(), for: [.rename, .newFolder, .newFile, .trash])
            await kernel.setArbiter(conflictSheet)
            ProgressWindowController.shared.start(kernel: kernel)
            // 性能自证入口（北极星验收用，非产品路径）：NSPACE_PERF_DIRS=a:b:c:d → 四宫格各导航一目录
            if let spec = ProcessInfo.processInfo.environment["NSPACE_PERF_DIRS"], !spec.isEmpty {
                let dirs = spec.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
                let wc = openWindow(at: dirs[0])
                wc.grid.apply(layout: .quad)
                for (i, dir) in dirs.dropFirst().enumerated() where i + 1 < wc.grid.visiblePanes.count {
                    wc.grid.visiblePanes[i + 1].navigate(to: dir)
                }
            } else {
                await restoreSessionOrDefault()
            }
            sessionReady = true
            NSApp.activate()
            if UISelfTest.isEnabled { UISelfTest.run(delegate: self) }
        }
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
    func openWindow(at directory: URL, selecting: URL? = nil, orderFront: Bool = true) -> MainWindowController {
        let wc = MainWindowController(kernel: kernel, initialDirectory: directory, select: selecting)
        windowControllers.append(wc)
        wc.window?.delegate = self
        if orderFront { wc.showWindow(nil) }
        return wc
    }

    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.showWindow(sender)
    }

    @objc func newWindow(_ sender: Any?) {
        openWindow(at: FileManager.default.homeDirectoryForCurrentUser)
    }

    // MARK: 会话恢复与保存（M11：重开即回到工作状态）

    private func restoreSessionOrDefault() async {
        guard let snapshot = await sessionStore.load(), !snapshot.windows.isEmpty else {
            openWindow(at: FileManager.default.homeDirectoryForCurrentUser)
            return
        }
        // 保存的每个"窗口"= 一个工作区标签：首个成窗，其余并入其标签组（M13 语义）
        var first: MainWindowController?
        for w in snapshot.windows {
            let dir = URL(fileURLWithPath: w.panes.first?.tabs.first?.path ?? NSHomeDirectory())
            let wc = openWindow(at: dir, orderFront: first == nil)
            wc.grid.restoreSession(w)
            if let firstWindow = first?.window, let newWindow = wc.window {
                firstWindow.addTabbedWindow(newWindow, ordered: .above)
            }
            if first == nil { first = wc }
        }
        first?.window?.makeKeyAndOrderFront(nil)
    }

    /// 状态变化落盘请求（位置/布局/标签变化处调用；SessionStore 内部 1s 防抖合并）
    func noteStateChanged() {
        guard sessionReady else { return }
        let snapshot = SessionSnapshot(windows: windowControllers.compactMap { wc in
            wc.window != nil ? wc.grid.sessionWindow() : nil
        })
        guard !snapshot.windows.isEmpty else { return }
        Task { await sessionStore.save(snapshot) }
    }

    /// 退出前强制落盘（同步等待 ≤1s；防抖中的快照不丢）
    func applicationWillTerminate(_ notification: Notification) {
        let snapshot = SessionSnapshot(windows: windowControllers.compactMap { wc in
            wc.window != nil ? wc.grid.sessionWindow() : nil
        })
        let store = sessionStore
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            if !snapshot.windows.isEmpty { await store.save(snapshot) }
            await store.flush()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 1)
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if let wc = windowControllers.first(where: { $0.window === window }) {
            wc.teardown()
        }
        windowControllers.removeAll { $0.window === window }
        noteStateChanged()
    }

    /// ⌘Z 路由到该窗口的文件操作撤销栈（撤销废纸篓等）
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        windowControllers.first(where: { $0.window === window })?.coordinator.undoManager
    }
}

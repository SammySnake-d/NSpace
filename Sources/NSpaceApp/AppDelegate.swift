import AppKit
import NSpaceKernel
import NSpaceContracts
import Transfer
import LocalOps
import ArchiveEngine
import SessionStore
import Frecency

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let kernel = OperationKernel()
    /// 冲突裁决面板（内核唯一 arbiter）——强持有，内核只存弱语义引用
    private let conflictSheet = ConflictSheet()
    private var windowControllers: [MainWindowController] = []
    /// 会话快照唯一 Commit Owner（M11）
    let sessionStore = SessionStore(directory: AppDelegate.supportDirectory)
    /// 使用习惯学习（M28）：全应用打开/进入记账 → 聚焦搜索按 frecency 排序。单一实例，注入到各窗口 coordinator 与搜索面板。
    let frecencyStore = FrecencyStore(directory: AppDelegate.supportDirectory)

    /// 应用支持目录：UITEST 走隔离临时目录，绝不把测试夹具路径/记账污染进用户真实会话与搜索排序
    /// （测试沙箱铁律，同 I-46 windowFrame 隔离；I-47 后 sessionStore 亦经此，因导航即落盘会写 session）。
    /// 产品走 Application Support/NSpace。
    static var supportDirectory: URL {
        let real = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NSpace")
        return ProcessInfo.processInfo.environment["NSPACE_UITEST"] != nil
            ? FileManager.default.temporaryDirectory.appendingPathComponent("nspace-uitest-support")
            : real
    }
    /// 恢复完成前的状态变化不落盘（防启动过程把半成品覆盖上次会话）
    private var sessionReady = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        Theme.applyAppearance()   // 外观：启动即套明暗模式（跟随系统/浅色/深色）
        // M28：使用习惯学习排序——搜索面板共享同一 frecencyStore（全应用记账在各窗口 coordinator）
        SearchPanelController.shared.frecencyStore = frecencyStore
        // I-25 反向直达：Finder 右键"服务 → 用 NSpace 打开"（默认程序被 macOS 27 锁死后的正道）
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        // M24：全局呼出/隐藏热键（Carbon，无需 AX；偏好外部化，设置-通用可录制）
        GlobalHotkey.apply()
        // 组合根（BG-2）：声明式注入 What —— 胶囊节点 + 冲突裁决者 + 进度订阅
        Task { @MainActor in
            await kernel.register(TransferNode(), for: [.copy, .move, .duplicate])
            await kernel.register(LocalOpsNode(), for: [.rename, .newFolder, .newFile, .trash])
            await kernel.register(ArchiveEngineNode(), for: [.compress, .extract])
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
            if UISelfTest.isEnabled {
                UISelfTest.run(delegate: self)
            } else if ProcessInfo.processInfo.environment["NSPACE_CONFLICT_PREVIEW"] != nil {
                // 冲突面板真机预览（非产品路径，仅供人眼终审截图）：造夹具冲突并弹真 sheet
                presentConflictPreview()
            } else if ProcessInfo.processInfo.environment["NSPACE_GROUPING_PREVIEW"] != nil {
                // 图标视图分组真机预览（非产品路径，仅供人眼终审截图）：造跨年月夹具 + 图标视图 + 分组
                presentGroupingPreview()
            } else if ProcessInfo.processInfo.environment["NSPACE_PERF_DIRS"] == nil {
                // 权限引导：未授权且未勾"不再提示" → 主窗口就绪后弹一次 sheet（自测/性能跑不打扰）
                promptFullDiskAccessIfNeeded()
                // 热更新：后台自动检查（autoCheckUpdates 开且距上次 >20 小时；失败静默不打扰）
                UpdateController.shared.autoCheckIfDue()
            }
        }
    }

    /// 冲突面板真机预览（NSPACE_CONFLICT_PREVIEW）：在自建夹具里造 3 条冲突弹真 sheet 供截图。
    /// 沙箱铁律：只动 temporaryDirectory 下的自建夹具，绝不碰用户真实文件。
    private func presentConflictPreview() {
        guard let win = NSApp.windows.first(where: { $0.windowController is MainWindowController }) else { return }
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("nspace-conflict-preview")
        let srcDir = base.appendingPathComponent("src")
        let dstDir = base.appendingPathComponent("dst")
        try? fm.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: dstDir, withIntermediateDirectories: true)
        let names = ["报告.pdf", "预算表.xlsx", "封面.png"]
        var conflicts: [FileConflict] = []
        for n in names {
            let s = srcDir.appendingPathComponent(n)
            let d = dstDir.appendingPathComponent(n)
            try? Data("src".utf8).write(to: s)
            try? Data("dst".utf8).write(to: d)
            conflicts.append(FileConflict(source: s, existing: d, bothDirectories: false))
        }
        // 再加一个目录冲突（让「合并」按钮可用，预览三按钮全态）
        let sSub = srcDir.appendingPathComponent("素材")
        let dSub = dstDir.appendingPathComponent("素材")
        try? fm.createDirectory(at: sSub, withIntermediateDirectories: true)
        try? fm.createDirectory(at: dSub, withIntermediateDirectories: true)
        conflicts.insert(FileConflict(source: sSub, existing: dSub, bothDirectories: true), at: 0)
        win.makeKeyAndOrderFront(nil)
        Task { @MainActor in _ = await conflictSheet.arbitrate(operation: UUID(), conflicts: conflicts) }
    }

    /// 图标视图分组真机预览（NSPACE_GROUPING_PREVIEW）：跨年月夹具 + 图标视图 + 分组，供人眼终审截图。
    /// 沙箱铁律：只动 temporaryDirectory 下的自建夹具。
    private func presentGroupingPreview() {
        guard let wc = NSApp.windows.compactMap({ $0.windowController as? MainWindowController }).first else { return }
        let fm = FileManager.default
        let box = fm.temporaryDirectory.appendingPathComponent("nspace-grouping-preview", isDirectory: true)
        try? fm.createDirectory(at: box, withIntermediateDirectories: true)
        let cal = Calendar.current
        for (mi, (y, m)) in [(2026, 8), (2026, 5), (2025, 12)].enumerated() {
            guard let date = cal.date(from: DateComponents(year: y, month: m, day: 15, hour: 12)) else { continue }
            for k in 0..<3 {
                let f = box.appendingPathComponent("文件-\(mi)-\(k).txt")
                try? Data("x".utf8).write(to: f)
                try? fm.setAttributes([.modificationDate: date], ofItemAtPath: f.path)
            }
        }
        Preferences.listGrouping = true
        let pane = wc.grid.activePane
        pane.setViewMode(.icons)
        pane.navigate(to: box)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            pane.activeTab.model.sort = SortSpec(key: .dateModified, ascending: false)
            pane.activeTab.model.reload()
            wc.window?.makeKeyAndOrderFront(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Dock 点击/重新激活且无可见窗口 → 开新窗（I-21：⌘W 关掉最后一个窗口后必须能回来）
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            openWindow(at: FileManager.default.homeDirectoryForCurrentUser)
        }
        return true
    }

    /// ⌘W 分层关闭（I-21 用户语义）：目标 = key 窗口，无 key 时取 z 序最顶的可见窗口
    /// （"位于软件上层的窗口"）。浮层（设置/任务/搜索等）→ 只关它；
    /// 主窗口 → 关当前工作区标签（最后一个则关窗，可经 Dock 重开）
    @objc func closeTopmost(_ sender: Any?) {
        guard let target = NSApp.keyWindow ?? NSApp.orderedWindows.first(where: { $0.isVisible }) else { return }
        if let wc = target.windowController as? MainWindowController {
            wc.closeActiveWorkspace(sender)
        } else if target.styleMask.contains(.closable) {
            target.performClose(sender)
        } else {
            target.orderOut(sender)
        }
    }

    /// open-URL 路由：目录 → 开窗定位；文件 → 父目录 + 选中该文件（替代 Finder 的入口）。
    /// 打开模式（externalOpenTarget）：activePane 且已有窗口 → 复用活动窗格新建窗格标签定位。
    func application(_ application: NSApplication, open urls: [URL]) {
        var fileURLs: [URL] = []
        for url in urls {
            // nspace:// 方案（I-25 第三方集成）：nspace://open?path=… / nspace://reveal?path=…
            if url.scheme == "nspace" {
                if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
                   let path = comps.queryItems?.first(where: { $0.name == "path" })?.value {
                    fileURLs.append(URL(fileURLWithPath: path))
                }
                continue
            }
            fileURLs.append(url)
        }
        openFileURLs(fileURLs)
    }

    /// 服务菜单入口（Finder 右键 → 服务 → 用 NSpace 打开；I-25）
    @objc func openInNSpace(_ pboard: NSPasteboard, userData: String, error: NSErrorPointer) {
        let urls = (pboard.readObjects(forClasses: [NSURL.self]) as? [URL]) ?? []
        openFileURLs(urls)
        NSApp.activate()
    }

    private func openFileURLs(_ urls: [URL]) {
        // 外部打开审计面包屑（I-28 NSFileViewer 链路诊断；单键覆盖写，量恒小）
        if let first = urls.first {
            UserDefaults.standard.set("\(Date().timeIntervalSince1970)|\(first.path)", forKey: "debug.lastExternalOpen")
        }
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            let directory = isDir.boolValue ? url : url.deletingLastPathComponent()
            let selecting: URL? = isDir.boolValue ? nil : url
            if Preferences.externalOpenTarget != "newWindow", let wc = activeMainWindowController() {
                // 现有窗口新标签（默认，用户点名）：复用活动窗口的活动窗格，新建窗格标签定位（文件则显露选中）。
                // 非 "newWindow"（含默认 newTab 与旧值 activePane）皆复用；无现有窗口时自然落到下方开新窗。
                let pane = wc.grid.activePane
                pane.openNewTab(at: directory)
                if let selecting { pane.reveal(selecting) }
                wc.window?.makeKeyAndOrderFront(nil)
                NSApp.activate()
            } else if isDir.boolValue {
                openWindow(at: url)
            } else {
                openWindow(at: url.deletingLastPathComponent(), selecting: url)
            }
        }
    }

    /// 活动主窗口（打开模式=activePane 的落点）：优先 keyWindow，其次 mainWindow，再退回任一存活窗口
    private func activeMainWindowController() -> MainWindowController? {
        if let key = NSApp.keyWindow?.windowController as? MainWindowController { return key }
        if let main = NSApp.mainWindow?.windowController as? MainWindowController { return main }
        // 兜底取**最前**的可见主窗（orderedWindows 是前→后序），而不是"最后创建的那一个"——
        // 后者在用户关掉新窗或多窗切换之后会指向背后、甚至已不可见的窗口，外部打开就落到看不见的地方。
        if let front = NSApp.orderedWindows.first(where: {
            $0.isVisible && $0.windowController is MainWindowController
        })?.windowController as? MainWindowController {
            return front
        }
        return windowControllers.last { $0.window != nil }
    }

    /// 是否还有主窗口存活。**不能用 NSApp.windows 的 isVisible 判断**：unhide 是异步的，
    /// 刚 NSApp.unhide(nil) 完窗口 isVisible 仍是 false，据此会误判"没有主窗"而多开一个空窗
    /// （用户按全局热键呼出 NSpace 时冒出多余窗口）。窗口台账在 windowWillClose 里同步维护，可信。
    var hasLiveMainWindow: Bool { windowControllers.contains { $0.window != nil } }

    /// 最前的主窗口（全局热键呼出用）。不用 NSApp.windows.first —— 已 close() 但尚未析构的窗口
    /// 仍留在里面，makeKeyAndOrderFront 会把它"复活"成用户以为早就关掉的僵尸窗。
    var frontmostMainWindow: NSWindow? {
        if let key = NSApp.keyWindow, key.windowController is MainWindowController { return key }
        if let main = NSApp.mainWindow, main.windowController is MainWindowController { return main }
        return windowControllers.last { $0.window != nil }?.window
    }

    @discardableResult
    func openWindow(at directory: URL, selecting: URL? = nil, orderFront: Bool = true) -> MainWindowController {
        let wc = MainWindowController(kernel: kernel, frecencyStore: frecencyStore,
                                     initialDirectory: directory, select: selecting)
        windowControllers.append(wc)
        wc.window?.delegate = self
        if orderFront { wc.showWindow(nil) }
        return wc
    }

    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.showWindow(sender)
    }

    /// 完全磁盘访问自动引导：未授权且未勾"不再提示" → 在主窗口上弹一次说明 sheet。
    /// 三钮：去授权（开系统设置）/ 稍后（本次略过，下次再问）/ 不再提示（落 Preferences 标志）。
    private func promptFullDiskAccessIfNeeded() {
        guard !Preferences.fdaPromptDismissed, !FinderIntegration.hasFullDiskAccess(),
              let window = windowControllers.first(where: { $0.window != nil })?.window else { return }
        let alert = NSAlert()
        alert.messageText = L10n.t("fda.prompt.title")
        alert.informativeText = L10n.t("fda.prompt.body")
        alert.addButton(withTitle: L10n.t("fda.prompt.grant"))
        alert.addButton(withTitle: L10n.t("fda.prompt.later"))
        alert.addButton(withTitle: L10n.t("fda.prompt.never"))
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                switch response {
                case .alertFirstButtonReturn: FinderIntegration.openFullDiskAccessSettings()
                case .alertThirdButtonReturn: Preferences.fdaPromptDismissed = true
                default: break  // 稍后
                }
            }
        }
    }

    @objc func newWindow(_ sender: Any?) {
        openWindow(at: FileManager.default.homeDirectoryForCurrentUser)
    }

    // MARK: 会话恢复与保存（M11：重开即回到工作状态）

    private func restoreSessionOrDefault() async {
        // UITEST 隔离：自测断言依赖确定性初态（单工作区默认布局），不吃真实用户会话；
        // frame 持久化场景（SETFRAME/EXPECTFRAME）走独立的 windowFrame 键，不受此影响
        if ProcessInfo.processInfo.environment["NSPACE_UITEST"] != nil {
            openWindow(at: FileManager.default.homeDirectoryForCurrentUser)
            return
        }
        guard let snapshot = await sessionStore.load(), !snapshot.windows.isEmpty else {
            openWindow(at: FileManager.default.homeDirectoryForCurrentUser)
            return
        }
        // 每个保存的"窗口"= 一组工作区（M17）：各成独立 OS 窗口，工作区数组自管恢复
        var first: MainWindowController?
        for ws in snapshot.windows {
            let firstPane = ws.workspaces.first(where: { !$0.panes.isEmpty })
            let dir = URL(fileURLWithPath: firstPane?.panes.first?.tabs.first?.path ?? NSHomeDirectory())
            let wc = openWindow(at: dir, orderFront: first == nil)
            wc.restoreWorkspaces(ws)
            if first == nil { first = wc }
        }
        first?.window?.makeKeyAndOrderFront(nil)
    }

    /// 状态变化落盘请求（位置/布局/工作区变化处调用；SessionStore 内部 1s 防抖合并）
    func noteStateChanged() {
        guard sessionReady else { return }
        let snapshot = SessionSnapshot(windows: windowControllers.compactMap { wc in
            wc.window != nil ? wc.workspaceSnapshot() : nil
        })
        guard !snapshot.windows.isEmpty else { return }
        Task { await sessionStore.save(snapshot) }
    }

    /// 退出前强制落盘（同步等待 ≤1s；防抖中的快照不丢）
    func applicationWillTerminate(_ notification: Notification) {
        let snapshot = SessionSnapshot(windows: windowControllers.compactMap { wc in
            wc.window != nil ? wc.workspaceSnapshot() : nil
        })
        let store = sessionStore
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            if !snapshot.windows.isEmpty { await store.save(snapshot) }
            await store.flush()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 1)
        // 强制刷偏好落盘：更新流程 openApplication+terminate 会尽快杀本进程，
        // 保证窗口尺寸/侧栏宽/列显隐等最后写入在被杀前已持久（cfprefsd 未及异步落盘的兜底）
        UserDefaults.standard.synchronize()
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

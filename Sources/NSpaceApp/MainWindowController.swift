import AppKit
import NSpaceKernel
import BookmarkStore
import StashStore

/// 主窗口：工具栏（侧边栏开关+布局切换）+ [侧边栏 | 窗格网格]；Tab 键循环窗格焦点
@MainActor
final class MainWindowController: NSWindowController {
    let kernel: OperationKernel
    let grid: PaneGridController
    let coordinator: FileOpsCoordinator
    let sidebar: SidebarViewController
    /// 暂存架控制器（M7）：内容经 StashStore 胶囊持久化，行呈现在侧边栏
    let stashShelf: StashShelfController
    private let splitVC = NSSplitViewController()
    private var keyMonitor: Any?
    private let layoutControl = NSSegmentedControl()

    init(kernel: OperationKernel, initialDirectory: URL, select: URL? = nil) {
        self.kernel = kernel
        self.grid = PaneGridController(initialDirectory: initialDirectory)
        self.coordinator = FileOpsCoordinator(kernel: kernel, grid: grid)
        let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NSpace")
        let model = SidebarModel(bookmarkStore: BookmarkStore(directory: supportDir))
        self.sidebar = SidebarViewController(model: model)
        self.stashShelf = StashShelfController(store: StashStore(directory: supportDir))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.minSize = NSSize(width: 600, height: 400)
        window.center()
        window.setFrameAutosaveName("NSpaceMainWindow")
        // M13：窗口级工作区标签（QSpace 语义——标签对象=整个分屏布局）
        window.tabbingMode = .automatic
        window.tabbingIdentifier = "NSpaceMain"
        super.init(window: window)

        grid.coordinator = coordinator
        // 暂存架接线：批量复制/移动经 coordinator 提交，"当前窗格"落点来自 grid
        stashShelf.coordinator = coordinator
        stashShelf.grid = grid
        sidebar.model.stash = stashShelf

        // 侧边栏 item：系统 sidebar 材质 + 折叠动画 + toggleSidebar 联动
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 160
        sidebarItem.maximumThickness = 320
        sidebarItem.canCollapse = true
        let contentItem = NSSplitViewItem(viewController: grid)
        splitVC.addSplitViewItem(sidebarItem)
        splitVC.addSplitViewItem(contentItem)
        splitVC.splitView.autosaveName = "NSpaceSidebarSplit"  // 折叠/宽度状态自动记忆
        window.contentViewController = splitVC

        sidebar.onNavigate = { [weak self] url in self?.grid.activePane.navigate(to: url) }
        grid.onActiveLocationChange = { [weak self] url in self?.updateTitle(for: url) }
        updateTitle(for: initialDirectory)
        setupToolbar()
        installTabKeyMonitor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建 UI，无 xib") }

    func navigate(to url: URL) {
        grid.activePane.navigate(to: url)
    }

    /// 窗口关闭时由 AppDelegate 调用（事件监视器必须显式拆除）
    func teardown() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        sidebar.model.stop()
    }

    private func updateTitle(for url: URL) {
        // QSpace 式标签标题：活动目录 | 其他可见窗格目录
        let name: (URL) -> String = { $0.path == "/" ? "/" : $0.lastPathComponent }
        var parts = [name(url)]
        for pane in grid.visiblePanes where pane !== grid.activePane {
            parts.append(name(pane.activeTab.browser.current))
        }
        window?.title = parts.joined(separator: " | ")
        window?.representedURL = url
        (NSApp.delegate as? AppDelegate)?.noteStateChanged()
    }

    // MARK: 工作区标签（⌘T / 标签栏"+"按钮都走这里）

    @objc func newWorkspaceTab(_ sender: Any?) {
        guard let delegate = NSApp.delegate as? AppDelegate, let current = window else { return }
        let dir = grid.activePane.activeTab.browser.current
        let wc = delegate.openWindow(at: dir, orderFront: false)
        if let newWindow = wc.window {
            current.addTabbedWindow(newWindow, ordered: .above)
            newWindow.makeKeyAndOrderFront(nil)
        }
    }

    /// AppKit 约定入口：标签栏 "+" 按钮
    @objc override func newWindowForTab(_ sender: Any?) {
        newWorkspaceTab(sender)
    }

    @objc func togglePaneTabBar(_ sender: Any?) {
        PaneViewController.paneTabBarVisible.toggle()
        // 广播到全部窗口（每个工作区标签是独立窗口控制器）
        for case let wc as MainWindowController in NSApp.windows.compactMap(\.windowController) {
            wc.grid.setPaneTabBarsVisible(PaneViewController.paneTabBarVisible)
        }
    }

    // MARK: Tab 键循环窗格焦点（文本编辑中放行）

    private func installTabKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window, event.keyCode == 48,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  !(self.window?.firstResponder is NSTextView) else { return event }
            self.grid.cycleFocus(backward: event.modifierFlags.contains(.shift))
            return nil
        }
    }

    // MARK: 工具栏

    private func setupToolbar() {
        let toolbar = NSToolbar(identifier: "NSpaceToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window?.toolbar = toolbar
        window?.toolbarStyle = .unified
        syncLayoutControl()
    }

    private func syncLayoutControl() {
        layoutControl.selectedSegment = PaneLayout.allCases.firstIndex(of: grid.layout) ?? 0
    }

    @objc private func layoutSegmentChanged(_ sender: NSSegmentedControl) {
        let layouts = PaneLayout.allCases
        guard sender.selectedSegment >= 0, sender.selectedSegment < layouts.count else { return }
        grid.apply(layout: layouts[sender.selectedSegment])
    }

    /// 菜单布局切换后同步工具栏选中态
    @objc func applyLayout(_ sender: NSMenuItem) {
        grid.applyLayout(sender)
        syncLayoutControl()
        (NSApp.delegate as? AppDelegate)?.noteStateChanged()
    }

    // MARK: 聚焦搜索（⌘F 当前文件夹 / ⌥⌘F 全局）

    @objc func showSearchHere(_ sender: Any?) { showSearch(scopeGlobal: false) }
    @objc func showSearchGlobal(_ sender: Any?) { showSearch(scopeGlobal: true) }

    private func showSearch(scopeGlobal: Bool) {
        let dir = grid.activePane.activeTab.browser.current
        SearchPanelController.shared.show(scopeGlobal: scopeGlobal, currentDirectory: dir,
                                          attachedTo: window) { [weak self] url in
            self?.revealSearchHit(url)
        }
    }

    /// 回车定位：目录（非包）直接进入；文件/包进父目录并选中（复用 prepareReveal 显露链）
    private func revealSearchHit(_ url: URL) {
        let pane = grid.activePane
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        let isPackage = (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false
        if exists, isDir.boolValue, !isPackage {
            pane.navigate(to: url)
        } else {
            pane.navigate(to: url.deletingLastPathComponent())
            pane.activeTab.listVC.prepareReveal(url, rename: false)
        }
        window?.makeKeyAndOrderFront(nil)
    }
}

extension MainWindowController: @preconcurrency NSToolbarDelegate {
    private static let layoutItemID = NSToolbarItem.Identifier("layout")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, Self.layoutItemID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard itemIdentifier == Self.layoutItemID else { return nil }
        let layouts = PaneLayout.allCases
        layoutControl.segmentCount = layouts.count
        layoutControl.trackingMode = .selectOne
        layoutControl.segmentStyle = .separated
        for (i, layout) in layouts.enumerated() {
            layoutControl.setImage(NSImage(systemSymbolName: layout.symbolName,
                                           accessibilityDescription: layout.localizedName), forSegment: i)
            layoutControl.setToolTip(layout.localizedName, forSegment: i)
            layoutControl.setWidth(30, forSegment: i)
        }
        layoutControl.target = self
        layoutControl.action = #selector(layoutSegmentChanged(_:))
        syncLayoutControl()

        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.view = layoutControl
        item.label = L10n.t("toolbar.layout")
        item.paletteLabel = L10n.t("toolbar.layout")
        return item
    }
}

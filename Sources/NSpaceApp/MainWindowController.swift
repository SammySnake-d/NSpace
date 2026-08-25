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
    /// 手工 NSSplitView（弃 NSSplitViewController：其恢复/调宽会在 splitView 上留必需
    /// 等式约束，布局扰动时反推窗口坍缩——UI 探针实锤 W==320/W==220/H==52 泄漏）
    private let mainSplit = NSSplitView()
    private let sidebarWrap = NSVisualEffectView()
    private var savedSidebarWidth: CGFloat = 200
    private var keyMonitor: Any?
    private let layoutControl = NSSegmentedControl()
    private let viewModeControl = NSSegmentedControl()

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
        // M13：窗口级工作区标签（QSpace 语义——标签对象=整个分屏布局）
        window.tabbingMode = .automatic
        window.tabbingIdentifier = "NSpaceMain"
        super.init(window: window)
        // AppKit 经典坑:控制器默认级联窗口会屏蔽 setFrameAutosaveName 的恢复——必须显式关闭
        shouldCascadeWindows = false

        grid.coordinator = coordinator
        // 暂存架接线：批量复制/移动经 coordinator 提交，"当前窗格"落点来自 grid
        stashShelf.coordinator = coordinator
        stashShelf.grid = grid
        sidebar.model.stash = stashShelf

        // 手工分栏：sidebar 材质用 NSVisualEffectView 包裹；宽度/折叠自管持久化
        mainSplit.isVertical = true
        mainSplit.dividerStyle = .thin
        mainSplit.delegate = self
        sidebarWrap.material = .sidebar
        sidebarWrap.blendingMode = .behindWindow
        let sv = sidebar.view
        sv.translatesAutoresizingMaskIntoConstraints = false
        sidebarWrap.addSubview(sv)
        NSLayoutConstraint.activate([
            sv.topAnchor.constraint(equalTo: sidebarWrap.topAnchor),
            sv.bottomAnchor.constraint(equalTo: sidebarWrap.bottomAnchor),
            sv.leadingAnchor.constraint(equalTo: sidebarWrap.leadingAnchor),
            sv.trailingAnchor.constraint(equalTo: sidebarWrap.trailingAnchor),
        ])
        for pane in [sidebarWrap, grid.view] {
            pane.translatesAutoresizingMaskIntoConstraints = true
            pane.autoresizingMask = [.width, .height]
            mainSplit.addArrangedSubview(pane)
        }
        let host = NSViewController()
        host.view = NSView()
        host.addChild(sidebar)
        host.addChild(grid)
        mainSplit.translatesAutoresizingMaskIntoConstraints = false
        host.view.addSubview(mainSplit)
        NSLayoutConstraint.activate([
            mainSplit.topAnchor.constraint(equalTo: host.view.topAnchor),
            mainSplit.bottomAnchor.constraint(equalTo: host.view.bottomAnchor),
            mainSplit.leadingAnchor.constraint(equalTo: host.view.leadingAnchor),
            mainSplit.trailingAnchor.constraint(equalTo: host.view.trailingAnchor),
        ])
        window.contentViewController = host
        // 自管 frame 持久化恢复——必须在 contentViewController 赋值【之后】：
        // 该赋值会把窗口压回内容适配尺寸(600×400 钳制)，先恢复会被盖掉
        // （用户"尺寸没有持久化"的完整根因；弃 autosave 因其携带系统平铺 tilingState）
        if let saved = UserDefaults.standard.string(forKey: "windowFrame") {
            let r = NSRectFromString(saved)
            if r.width >= 600, r.height >= 400 { window.setFrame(r, display: false) }
        }
        // 外部化默认布局（新窗口/新工作区标签生效；会话恢复会覆盖）
        if let l = PaneLayout(rawValue: Preferences.defaultLayoutRaw), l != grid.layout {
            grid.apply(layout: l)
        }
        savedSidebarWidth = {
            let w = UserDefaults.standard.double(forKey: "sidebarWidth")
            return w > 0 ? min(max(w, 160), 320) : 200
        }()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let collapsed = UserDefaults.standard.bool(forKey: "sidebarCollapsed")
            self.mainSplit.setPosition(collapsed ? 0 : self.savedSidebarWidth, ofDividerAt: 0)
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(splitDidResize(_:)),
            name: NSSplitView.didResizeSubviewsNotification, object: mainSplit)
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowFrameChanged(_:)),
            name: NSWindow.didEndLiveResizeNotification, object: window)
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowFrameChanged(_:)),
            name: NSWindow.didMoveNotification, object: window)

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
        NotificationCenter.default.removeObserver(self)
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        sidebar.model.stop()
    }

    // MARK: 侧栏宽度自管持久化（替代 NSSplitView.autosaveName）

    /// frame 持久化落盘（拖拽结束/移动/关窗时调；全屏态不записыв）
    func persistFrameNow() {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: "windowFrame")
    }

    @objc private func splitDidResize(_ note: Notification) {
        let w = sidebarWrap.frame.width
        if w >= 160 {
            savedSidebarWidth = w
            UserDefaults.standard.set(w, forKey: "sidebarWidth")
            UserDefaults.standard.set(false, forKey: "sidebarCollapsed")
        }
    }

    @objc private func windowFrameChanged(_ note: Notification) {
        persistFrameNow()
    }

    /// 自实现侧栏折叠（⌘⌥S / 工具栏钮）：宽度 0 ⟷ 记忆宽度
    @objc func toggleSidebar(_ sender: Any?) {
        let collapsed = sidebarWrap.frame.width < 1
        mainSplit.setPosition(collapsed ? savedSidebarWidth : 0, ofDividerAt: 0)
        UserDefaults.standard.set(!collapsed, forKey: "sidebarCollapsed")
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
        syncViewModeControl()
        (NSApp.delegate as? AppDelegate)?.noteStateChanged()
    }

    // MARK: 书签（右键"添加到书签"经响应链到此；选中目录逐个入册）

    @objc func addSelectionToBookmarks(_ sender: Any?) {
        let dirs = grid.activePane.activeTab.listVC.selectedItems
            .filter { $0.isDirectory && !$0.isPackage }
        guard !dirs.isEmpty else { NSSound.beep(); return }
        let store = sidebar.model.bookmarkStore
        Task { [weak self] in
            for dir in dirs { try? await store.add(dir.url) }
            self?.sidebar.model.rebuild()
            Toast.show(String(format: L10n.t("toast.bookmarkAdded"), dirs.count),
                       in: self?.window)
        }
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

    @objc private func navSegmentClicked(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 0 { grid.activePane.goBack(nil) }
        else { grid.activePane.goForward(nil) }
    }

    @objc private func viewModeSegmentClicked(_ sender: NSSegmentedControl) {
        guard let mode = PaneViewMode(rawValue: sender.selectedSegment) else { return }
        grid.activePane.setViewMode(mode)
    }

    /// 活动窗格/标签变化时同步视图切换器选中态
    func syncViewModeControl() {
        viewModeControl.selectedSegment = grid.activePane.activeTab.viewMode.rawValue
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
    private static let sidebarItemID = NSToolbarItem.Identifier("sidebarToggle")
    private static let navItemID = NSToolbarItem.Identifier("nav")
    private static let viewModeItemID = NSToolbarItem.Identifier("viewMode")
    private static let airdropItemID = NSToolbarItem.Identifier("airdrop")
    private static let terminalItemID = NSToolbarItem.Identifier("terminal")
    private static let tasksItemID = NSToolbarItem.Identifier("tasks")
    private static let trashItemID = NSToolbarItem.Identifier("trashSel")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // QSpace 式图标组（隐性语义：图标+tooltip，零文字）
        [Self.navItemID, .flexibleSpace,
         Self.viewModeItemID, .space,
         Self.airdropItemID, Self.terminalItemID, Self.tasksItemID, Self.trashItemID, .space,
         Self.layoutItemID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    /// 纯图标工具项工厂（隐性语义 + 微 tooltip；action 走响应链到活动窗格）
    private func iconItem(_ id: NSToolbarItem.Identifier, symbol: String, labelKey: String,
                          action: Selector, target: AnyObject? = nil) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: L10n.t(labelKey))
        item.label = L10n.t(labelKey)
        item.paletteLabel = L10n.t(labelKey)
        item.toolTip = L10n.t(labelKey)
        item.isBordered = true
        item.action = action
        item.target = target
        item.autovalidates = true
        return item
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.sidebarItemID:
            return iconItem(itemIdentifier, symbol: "sidebar.left", labelKey: "menu.toggleSidebar",
                            action: #selector(toggleSidebar(_:)), target: self)
        case Self.navItemID:
            // 返回/前进合体分段（Finder 惯例）
            let control = NSSegmentedControl()
            control.segmentCount = 2
            control.trackingMode = .momentary
            control.segmentStyle = .separated
            control.setImage(NSImage(systemSymbolName: "chevron.left",
                                     accessibilityDescription: L10n.t("menu.back")), forSegment: 0)
            control.setImage(NSImage(systemSymbolName: "chevron.right",
                                     accessibilityDescription: L10n.t("menu.forward")), forSegment: 1)
            control.setToolTip(L10n.t("menu.back"), forSegment: 0)
            control.setToolTip(L10n.t("menu.forward"), forSegment: 1)
            control.target = self
            control.action = #selector(navSegmentClicked(_:))
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = control
            item.label = L10n.t("toolbar.nav")
            item.paletteLabel = L10n.t("toolbar.nav")
            return item
        case Self.viewModeItemID:
            let control = viewModeControl
            control.segmentCount = 3
            control.trackingMode = .selectOne
            let symbols = [("square.grid.2x2", "menu.asIcons"), ("list.bullet", "menu.asList"),
                           ("rectangle.split.3x1", "menu.asColumns")]
            for (i, pair) in symbols.enumerated() {
                control.setImage(NSImage(systemSymbolName: pair.0,
                                         accessibilityDescription: L10n.t(pair.1)), forSegment: i)
                control.setToolTip(L10n.t(pair.1), forSegment: i)
                control.setWidth(28, forSegment: i)
            }
            control.target = self
            control.action = #selector(viewModeSegmentClicked(_:))
            syncViewModeControl()
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = control
            item.label = L10n.t("toolbar.viewMode")
            item.paletteLabel = L10n.t("toolbar.viewMode")
            return item
        case Self.airdropItemID:
            return iconItem(itemIdentifier, symbol: "dot.radiowaves.left.and.right",
                            labelKey: "toolbar.airdrop",
                            action: #selector(FileListViewController.airdropSelected(_:)))
        case Self.terminalItemID:
            return iconItem(itemIdentifier, symbol: "terminal",
                            labelKey: "toolbar.terminal",
                            action: #selector(FileListViewController.openInTerminal(_:)))
        case Self.tasksItemID:
            return iconItem(itemIdentifier, symbol: "arrow.up.arrow.down.circle",
                            labelKey: "toolbar.tasks",
                            action: #selector(ProgressWindowController.toggleVisible(_:)),
                            target: ProgressWindowController.shared)
        case Self.trashItemID:
            return iconItem(itemIdentifier, symbol: "trash",
                            labelKey: "menu.moveToTrash",
                            action: #selector(FileListViewController.moveToTrash(_:)))
        case Self.layoutItemID:
            break
        default:
            return nil
        }
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


// MARK: - 手工分栏约束（min160/max320，可折叠到 0）

extension MainWindowController: @preconcurrency NSSplitViewDelegate {
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat { 160 }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat { 320 }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        subview === sidebarWrap
    }

    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        // 窗口缩放时侧栏保持宽度、内容区吃增量（Finder 语义）
        let sidebarW = sidebarWrap.frame.width < 1 ? 0 : min(max(sidebarWrap.frame.width, 160), 320)
        let divider = splitView.dividerThickness
        sidebarWrap.frame = NSRect(x: 0, y: 0, width: sidebarW, height: splitView.bounds.height)
        grid.view.frame = NSRect(x: sidebarW + (sidebarW > 0 ? divider : 0), y: 0,
                                 width: splitView.bounds.width - sidebarW - (sidebarW > 0 ? divider : 0),
                                 height: splitView.bounds.height)
    }
}

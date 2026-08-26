import AppKit
import NSpaceKernel
import BookmarkStore
import StashStore
import SessionStore

/// 主窗口（M17 自绘甲板）：两列贯通结构——
/// 左列 sidebarColumn（.sidebar 材质全高：红绿灯行 + 暂存架 + 书签），
/// 右列 contentColumn（TopDeckView 甲板 + PaneGrid 窗格矩阵 + 各窗格状态栏）。
/// 工作区标签自管（WorkspaceManager，弃原生 NSWindow tabbing）；Tab 键循环窗格焦点。
@MainActor
final class MainWindowController: NSWindowController, @preconcurrency NSMenuItemValidation {
    let kernel: OperationKernel
    let grid: PaneGridController
    let coordinator: FileOpsCoordinator
    let sidebar: SidebarViewController
    /// 暂存架控制器（M7）：内容经 StashStore 胶囊持久化，行呈现在侧边栏
    let stashShelf: StashShelfController
    /// 自绘顶部甲板（M17）：标签条 28 + 图标工具条 36
    let deck = TopDeckView()
    /// 工作区管理器（M17）：窗口内 [SessionWindow] + activeIndex，切换=快照当前→恢复目标
    private(set) var workspaces: WorkspaceManager!

    /// 手工 NSSplitView（弃 NSSplitViewController：其恢复/调宽会在 splitView 上留必需
    /// 等式约束，布局扰动时反推窗口坍缩——UI 探针实锤 W==320/W==220/H==52 泄漏）
    private let mainSplit = NSSplitView()
    let sidebarWrap = NSVisualEffectView()   // internal：UISelfTest I-22 断言需度量可见性
    /// 右列容器：甲板压顶 + 窗格矩阵铺底（唯一垂直分割线由此列与左列共界）
    private let contentColumn = NSView()
    private var savedSidebarWidth: CGFloat = 200
    /// I-22：折叠状态完全自管。绝不走 NSSplitView 的 collapse 机制——它把折叠记在私有状态里，
    /// isHidden 会被后续布局重新盖回（实测宽度已恢复 202 仍 hidden=true），展开永远失败。
    private var sidebarCollapsedState = false
    private var keyMonitor: Any?

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
        // M17：弃原生窗口标签（横跨全窗与贯通布局冲突）——工作区改自管 WorkspaceManager
        window.tabbingMode = .disallowed
        // 自绘甲板：标题隐藏 + 标题栏透明 + 无 NSToolbar（I-10 追踪分隔线体系随之消亡）
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbar = nil
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

        // 右列 = 甲板压顶 + 窗格矩阵铺底
        deck.deckDelegate = self
        let gridView = grid.view
        gridView.translatesAutoresizingMaskIntoConstraints = false
        contentColumn.addSubview(deck)
        contentColumn.addSubview(gridView)
        NSLayoutConstraint.activate([
            deck.topAnchor.constraint(equalTo: contentColumn.topAnchor),
            deck.leadingAnchor.constraint(equalTo: contentColumn.leadingAnchor),
            deck.trailingAnchor.constraint(equalTo: contentColumn.trailingAnchor),
            gridView.topAnchor.constraint(equalTo: deck.bottomAnchor),
            gridView.leadingAnchor.constraint(equalTo: contentColumn.leadingAnchor),
            gridView.trailingAnchor.constraint(equalTo: contentColumn.trailingAnchor),
            gridView.bottomAnchor.constraint(equalTo: contentColumn.bottomAnchor),
        ])

        for pane in [sidebarWrap, contentColumn] {
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
        // 外部化默认布局（新窗口/新工作区生效；会话恢复会覆盖）
        if let l = PaneLayout(rawValue: Preferences.defaultLayoutRaw), l != grid.layout {
            grid.apply(layout: l)
        }
        savedSidebarWidth = {
            let w = UserDefaults.standard.double(forKey: "sidebarWidth")
            return w > 0 ? min(max(w, 160), 320) : 200
        }()
        let startCollapsed = UserDefaults.standard.bool(forKey: "sidebarCollapsed")
        sidebarCollapsedState = startCollapsed
        deck.setSidebarCollapsed(startCollapsed)
        DispatchQueue.main.async { [weak self] in
            self?.applyColumnFrames()
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
        grid.onActiveStatusChange = { [weak self] in
            guard let self else { return }
            self.deck.validateActions(hasSelection: self.grid.activePane.currentSelectionCount > 0)
        }

        // 工作区管理器：以当前 grid 快照播种单工作区（grid.view 已 loadView，窗格池就位）
        workspaces = WorkspaceManager(initial: grid.sessionWindow())
        updateTitle(for: initialDirectory)
        refreshWorkspaceTabs()
        // 新窗口同步当前已知的更新态（更新在别窗被发现后再开的窗口也带"↑"）
        deck.versionBadge.setUpdateAvailable(UpdateController.shared.available != nil,
                                             latestVersion: UpdateController.shared.available?.version)
        installKeyMonitor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建 UI，无 xib") }

    func navigate(to url: URL) {
        grid.activePane.navigate(to: url)
    }

    // MARK: UISelfTest 度量入口（M17 §5：分割线全高 / 折叠不漂移）
    var sidebarColumnFrame: NSRect { sidebarWrap.frame }
    var contentColumnFrame: NSRect { contentColumn.frame }
    var workspaceCount: Int { workspaces.count }

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

    /// frame 持久化落盘（拖拽结束/移动/关窗时调；全屏态不写）
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
            deck.setSidebarCollapsed(false)
        } else if w < 1 {
            // 折叠视觉（甲板让位红绿灯）；折叠态持久化只由 toggleSidebar 落——
            // 启动瞬时 0 宽的 didResize 绝不可写 collapsed=true（否则下次启动误折叠）
            deck.setSidebarCollapsed(true)
        }
    }

    @objc private func windowFrameChanged(_ note: Notification) {
        persistFrameNow()
    }

    /// 自实现侧栏折叠（⌘⌥S / 甲板钮）：宽度 0 ⟷ 记忆宽度；折叠时甲板 leading 让位红绿灯
    @objc func toggleSidebar(_ sender: Any?) {
        setSidebar(collapsed: !sidebarCollapsedState)
    }

    /// 确定性折叠/展开（甲板钮/菜单经 toggle 走此；UISelfTest 直接指定目标态）。
    /// 自管宽度直铺 frame（见 sidebarCollapsedState 注释），子视图永不 isHidden。
    func setSidebar(collapsed: Bool) {
        sidebarCollapsedState = collapsed
        sidebarWrap.isHidden = false
        applyColumnFrames()
        UserDefaults.standard.set(collapsed, forKey: "sidebarCollapsed")
        deck.setSidebarCollapsed(collapsed)
    }

    /// 两列 frame 直铺（delegate resize 与折叠切换共用；折叠=宽 0，展开=夹紧后的记忆宽）
    private func applyColumnFrames() {
        let divider = mainSplit.dividerThickness
        let w: CGFloat = sidebarCollapsedState ? 0 : min(max(savedSidebarWidth, 160), 320)
        sidebarWrap.frame = NSRect(x: 0, y: 0, width: w, height: mainSplit.bounds.height)
        contentColumn.frame = NSRect(x: w + (w > 0 ? divider : 0), y: 0,
                                     width: mainSplit.bounds.width - w - (w > 0 ? divider : 0),
                                     height: mainSplit.bounds.height)
        mainSplit.needsDisplay = true
        contentColumn.layoutSubtreeIfNeeded()
    }

    private func updateTitle(for url: URL) {
        // QSpace 式标题：活动目录 | 其他可见窗格目录
        let name: (URL) -> String = { $0.path == "/" ? "/" : $0.lastPathComponent }
        var parts = [name(url)]
        for pane in grid.visiblePanes where pane !== grid.activePane {
            parts.append(name(pane.activeTab.browser.current))
        }
        window?.title = parts.joined(separator: " | ")
        window?.representedURL = url
        syncDeck()
        refreshWorkspaceTabs()
        (NSApp.delegate as? AppDelegate)?.noteStateChanged()
    }

    /// 甲板控件同步（活动窗格/位置/布局/选中变化后回灌）
    private func syncDeck() {
        let pane = grid.activePane
        let b = pane.activeTab.browser
        deck.syncViewMode(pane.activeTab.viewMode.rawValue)
        deck.syncLayout(grid.layout)
        deck.syncNav(canBack: b.canGoBack, canForward: b.canGoForward, canUp: b.canGoUp)
        deck.validateActions(hasSelection: pane.currentSelectionCount > 0)
    }

    /// 活动窗格/标签变化时同步视图切换器选中态（旧调用点保留）
    func syncViewModeControl() {
        deck.syncViewMode(grid.activePane.activeTab.viewMode.rawValue)
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

    // MARK: 工作区标签（M17：自管 WorkspaceManager；⌘T/⌘W/循环 + 标签条钮都走这里）

    /// 切换前把 grid 实时快照回灌活动槽（否则切走的工作区丢失未落盘编辑）
    private func snapshotIntoActive() {
        workspaces.syncActive(grid.sessionWindow())
    }

    private func refreshWorkspaceTabs() {
        snapshotIntoActive()
        deck.updateWorkspaces(titles: workspaces.titles(), active: workspaces.activeIndex)
    }

    private func focusActivePane() {
        window?.makeFirstResponder(grid.activePane.focusTarget)
    }

    @objc func newWorkspaceTab(_ sender: Any?) {
        snapshotIntoActive()
        let dir = grid.activePane.activeTab.browser.current
        let fresh = SessionWindow(
            layoutRaw: Preferences.defaultLayoutRaw,
            panes: [SessionPane(tabs: [SessionTab(path: dir.path,
                                                  sortKey: Preferences.defaultSortKey,
                                                  sortAscending: Preferences.defaultSortAscending,
                                                  includeHidden: Preferences.showHiddenByDefault,
                                                  viewMode: Preferences.defaultViewModeRaw)],
                                activeTabIndex: 0)],
            activePaneIndex: 0)
        workspaces.append(fresh, limit: Preferences.workspaceTabLimit)
        grid.restoreSession(workspaces.activeState)
        refreshWorkspaceTabs()
        focusActivePane()
        syncDeck()
        (NSApp.delegate as? AppDelegate)?.noteStateChanged()
    }

    func switchWorkspace(to index: Int) {
        guard index != workspaces.activeIndex else { return }
        snapshotIntoActive()
        workspaces.switchTo(index)
        grid.restoreSession(workspaces.activeState)
        refreshWorkspaceTabs()
        focusActivePane()
        syncDeck()
        (NSApp.delegate as? AppDelegate)?.noteStateChanged()
    }

    func closeWorkspace(at index: Int) {
        snapshotIntoActive()
        let wasActive = index == workspaces.activeIndex
        if workspaces.close(at: index) {
            if wasActive { grid.restoreSession(workspaces.activeState) }
            refreshWorkspaceTabs()
            focusActivePane()
            syncDeck()
            (NSApp.delegate as? AppDelegate)?.noteStateChanged()
        } else {
            // 最后一个工作区 → 关窗（⌘W 语义）
            window?.performClose(nil)
        }
    }

    @objc func closeActiveWorkspace(_ sender: Any?) {
        closeWorkspace(at: workspaces.activeIndex)
    }

    /// ⌘1..9 数字直达（I-13）：菜单项 tag = 工作区下标；越界由 switchTo 守卫忽略
    @objc func switchWorkspaceByNumber(_ sender: NSMenuItem) {
        switchWorkspace(to: sender.tag)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(switchWorkspaceByNumber(_:)) {
            item.state = item.tag == workspaces.activeIndex ? .on : .off
            return item.tag < workspaces.count
        }
        return true
    }

    @objc func nextWorkspace(_ sender: Any?) { cycleWorkspace(backward: false) }
    @objc func previousWorkspace(_ sender: Any?) { cycleWorkspace(backward: true) }

    private func cycleWorkspace(backward: Bool) {
        guard workspaces.count > 1 else { return }
        snapshotIntoActive()
        workspaces.cycle(backward: backward)
        grid.restoreSession(workspaces.activeState)
        refreshWorkspaceTabs()
        focusActivePane()
        syncDeck()
        (NSApp.delegate as? AppDelegate)?.noteStateChanged()
    }

    /// AppDelegate 会话恢复入口：用工作区数组重建本窗口
    func restoreWorkspaces(_ ws: SessionWorkspaces) {
        guard !ws.workspaces.isEmpty else { return }
        workspaces = WorkspaceManager(states: ws.workspaces, activeIndex: ws.activeWorkspace)
        grid.restoreSession(workspaces.activeState)
        deck.updateWorkspaces(titles: workspaces.titles(), active: workspaces.activeIndex)
        syncDeck()
    }

    /// AppDelegate 会话保存入口：先回灌活动槽再交出全体工作区
    func workspaceSnapshot() -> SessionWorkspaces {
        snapshotIntoActive()
        return SessionWorkspaces(workspaces: workspaces.states, activeWorkspace: workspaces.activeIndex)
    }

    @objc func togglePaneTabBar(_ sender: Any?) {
        PaneViewController.paneTabBarVisible.toggle()
        // 广播到全部窗口
        for case let wc as MainWindowController in NSApp.windows.compactMap(\.windowController) {
            wc.grid.setPaneTabBarsVisible(PaneViewController.paneTabBarVisible)
        }
    }

    // MARK: Tab 键循环窗格焦点 + ⌃⇥ 循环工作区（文本编辑中放行）

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window, event.keyCode == 48 else { return event }
            let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
            // 工作区循环修饰键走 KeyBindings 注册表（cycleWorkspace/Back），不再硬编码 ⌃/⌃⇧
            let fwd = KeyBindings.binding("cycleWorkspace")
            let back = KeyBindings.binding("cycleWorkspaceBack")
            if fwd.key == "\t", mods == fwd.mods { self.cycleWorkspace(backward: false); return nil }
            if back.key == "\t", mods == back.mods { self.cycleWorkspace(backward: true); return nil }
            if mods.isEmpty, !(self.window?.firstResponder is NSTextView) {
                self.grid.cycleFocus(backward: false)
                return nil
            }
            return event
        }
    }

    // MARK: 布局菜单命令（甲板分段/菜单共用；同步甲板选中态）

    /// 菜单布局切换后同步甲板选中态
    @objc func applyLayout(_ sender: NSMenuItem) {
        grid.applyLayout(sender)
        deck.syncLayout(grid.layout)
        (NSApp.delegate as? AppDelegate)?.noteStateChanged()
    }

    // MARK: 聚焦搜索（⌘F 当前文件夹 / ⌥⌘F 全局）

    @objc func showSearchHere(_ sender: Any?) { showSearch(scopeGlobal: false) }
    @objc func showSearchGlobal(_ sender: Any?) { showSearch(scopeGlobal: true) }

    private func showSearch(scopeGlobal: Bool) {
        let dir = grid.activePane.activeTab.browser.current
        SearchPanelController.shared.show(scopeGlobal: scopeGlobal, currentDirectory: dir,
                                          attachedTo: window, onReveal: { [weak self] url in
            self?.revealSearchHit(url)
        }, onStash: { [weak self] urls in
            self?.stashShelf.add(urls)
        })
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

// MARK: - 甲板动作出口（带选中态/校验的控件）

extension MainWindowController: TopDeckDelegate {
    func deckToggleSidebar() { toggleSidebar(nil) }
    func deckGoBack() { grid.activePane.goBack(nil) }
    func deckGoForward() { grid.activePane.goForward(nil) }
    func deckGoUp() { grid.activePane.goUpFolder(nil) }
    func deckSetViewMode(_ mode: PaneViewMode) { grid.activePane.setViewMode(mode) }
    func deckSetLayout(_ layout: PaneLayout) {
        grid.apply(layout: layout)
        deck.syncLayout(grid.layout)
        (NSApp.delegate as? AppDelegate)?.noteStateChanged()
    }
    func deckNewWorkspace() { newWorkspaceTab(nil) }
    func deckSelectWorkspace(_ index: Int) { switchWorkspace(to: index) }
    func deckCloseWorkspace(_ index: Int) { closeWorkspace(at: index) }

    func deckHistory(forward: Bool) -> [URL] {
        let b = grid.activePane.activeTab.browser
        return forward ? b.forwardHistory : b.backHistory
    }

    func deckJumpHistory(forward: Bool, index: Int) {
        if forward { grid.activePane.jumpForwardHistory(to: index) }
        else { grid.activePane.jumpBackHistory(to: index) }
    }

    func deckVersionBadgeClicked() {
        UpdateController.shared.startUpdateFlow(from: window)
    }
}

// MARK: - 手工分栏约束（min160/max320，可折叠到 0）

extension MainWindowController: @preconcurrency NSSplitViewDelegate {
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat { 160 }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat { 320 }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        false   // I-22：折叠自管（sidebarCollapsedState 直铺 frame），禁用 AppKit 私有折叠机制
    }

    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        // 窗口缩放时侧栏保持宽度、内容区吃增量（Finder 语义）；折叠态由自管状态决定
        applyColumnFrames()
    }
}

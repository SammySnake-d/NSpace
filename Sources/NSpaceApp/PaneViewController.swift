import AppKit
import NSpaceContracts
import SessionStore

/// 窗格内容视图模式（M9：每窗格每标签独立；⌘1 图标 / ⌘2 列表 / ⌘3 分栏）
enum PaneViewMode: Int {
    case icons, list, columns
}

/// 窗格：标签栏 + 地址栏（面包屑⟷编辑器）+ 内容视图；每标签独立浏览器与历史。
/// 多实例由 PaneGridController 编排；活动窗格高亮由 setActive 驱动
@MainActor
final class PaneViewController: NSViewController {
    /// 一个标签 = 独立浏览状态 + 独立目录模型 + 独立内容视图（隐藏标签零后台工作）。
    /// class 语义（M9）：viewMode 可变；图标/分栏视图懒创建——不切换就不付构造成本。
    /// 三视图共享同一 DirectoryViewModel（onUpdate 多播）；分栏的列加载自管（局部 DirectoryReader）
    final class Tab {
        let browser: BrowserState
        let model: DirectoryViewModel
        let listVC: FileListViewController
        var viewMode: PaneViewMode = .list
        var iconVC: FileIconGridViewController?
        var columnVC: FileColumnViewController?

        init(browser: BrowserState, model: DirectoryViewModel, listVC: FileListViewController) {
            self.browser = browser
            self.model = model
            self.listVC = listVC
        }
    }

    private(set) var tabs: [Tab] = []
    private(set) var activeTabIndex = 0
    var activeTab: Tab { tabs[activeTabIndex] }

    /// 位置变化上抛（窗口标题）
    var onLocationChange: ((URL) -> Void)?
    /// 用户在本窗格交互 → 请求成为活动窗格
    var onRequestFocus: (() -> Void)?

    /// 文件操作桥：下传每个标签的内容视图（右键菜单/快捷键经此发 OperationSpec）
    var coordinator: FileOpsCoordinator? {
        didSet {
            for tab in tabs {
                tab.listVC.coordinator = coordinator
                tab.iconVC?.coordinator = coordinator
                tab.columnVC?.coordinator = coordinator
            }
        }
    }

    private let tabBar = TabBarView()
    private var tabBarHeight: NSLayoutConstraint?
    /// 窗格标签栏默认隐藏（M13：主标签在窗口级；QSpace 同款可选项）
    static var paneTabBarVisible: Bool {
        get { UserDefaults.standard.bool(forKey: "showPaneTabBar") }
        set { UserDefaults.standard.set(newValue, forKey: "showPaneTabBar") }
    }
    private let breadcrumb = BreadcrumbBar()
    private let pathEditor = PathEditorField()
    private let addressArea = NSView()
    private let contentContainer = NSView()
    private let statusBar = StatusBarView()
    private(set) var isActivePane = false
    /// 窗格级挂起（布局切走时置位）：置位期间标签切换不恢复 watcher——北极星零后台功耗
    private(set) var isPaneSuspended = false

    init(directory: URL) {
        super.init(nibName: nil, bundle: nil)
        appendTab(at: directory)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建 UI，无 xib") }

    override func loadView() {
        tabBar.onSelect = { [weak self] i in self?.switchTab(to: i) }
        tabBar.onClose = { [weak self] i in self?.closeTab(at: i) }
        tabBar.onNew = { [weak self] in self?.openNewTab() }

        breadcrumb.onNavigate = { [weak self] url in self?.navigate(to: url) }
        breadcrumb.onBeginEditing = { [weak self] in self?.beginPathEditing() }
        breadcrumb.onDropFiles = { [weak self] urls, target, forceCopy in
            // 拖文件到面包屑分段 = 投进该祖先目录（语义同列表投放，经 coordinator 判卷提交）
            self?.coordinator?.dropTransfer(urls: urls, into: target, forceCopy: forceCopy)
        }
        pathEditor.onCommit = { [weak self] url in
            self?.endPathEditing()
            self?.navigate(to: url)
        }
        pathEditor.onCancel = { [weak self] in self?.endPathEditing() }
        pathEditor.isHidden = true

        addressArea.wantsLayer = true
        for sub in [breadcrumb, pathEditor] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            addressArea.addSubview(sub)
            NSLayoutConstraint.activate([
                sub.topAnchor.constraint(equalTo: addressArea.topAnchor, constant: 2),
                sub.bottomAnchor.constraint(equalTo: addressArea.bottomAnchor, constant: -2),
                sub.leadingAnchor.constraint(equalTo: addressArea.leadingAnchor, constant: 4),
                sub.trailingAnchor.constraint(equalTo: addressArea.trailingAnchor, constant: -4),
            ])
        }

        let separator = NSBox()
        separator.boxType = .separator

        let root = NSView()
        root.wantsLayer = true
        for sub in [tabBar, addressArea, separator, contentContainer, statusBar] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(sub)
        }
        let tabHeight = tabBar.heightAnchor.constraint(
            equalToConstant: Self.paneTabBarVisible ? 22 : 0)
        tabBarHeight = tabHeight
        tabBar.isHidden = !Self.paneTabBarVisible
        NSLayoutConstraint.activate([
            tabHeight,
            // fullSizeContentView 下内容延伸到标题栏底下：标签栏必须锚 safeArea 顶，否则被工具栏遮住
            tabBar.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            addressArea.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            addressArea.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            addressArea.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            addressArea.heightAnchor.constraint(equalToConstant: 26),
            separator.topAnchor.constraint(equalTo: addressArea.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: separator.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        mountActiveTab()
        refreshChrome()
    }

    // MARK: 标签管理

    @discardableResult
    private func appendTab(at url: URL) -> Tab {
        let browser = BrowserState(url: url)
        let model = DirectoryViewModel(directory: url)
        // 外部化默认偏好：新标签按设置初始化（隐藏文件/文件夹置顶/视图模式）
        model.includeHidden = Preferences.showHiddenByDefault
        model.sort = SortSpec(key: model.sort.key, ascending: model.sort.ascending,
                              foldersFirst: Preferences.foldersFirst)
        let listVC = FileListViewController(model: model)
        listVC.coordinator = coordinator
        listVC.onNavigate = { [weak self] target in self?.navigate(to: target) }
        listVC.onInteract = { [weak self] in self?.onRequestFocus?() }
        // 状态栏数据源：快照应用/选中变化 → 仅当该标签仍是活动标签时刷新计数
        listVC.onContentChange = { [weak self, weak listVC] in
            guard let self, self.activeTab.listVC === listVC else { return }
            self.updateStatusCounts()
        }
        listVC.onSelectionChange = { [weak self, weak listVC] in
            guard let self, self.activeTab.listVC === listVC else { return }
            self.updateStatusCounts()
        }
        let tab = Tab(browser: browser, model: model, listVC: listVC)
        tab.viewMode = PaneViewMode(rawValue: Preferences.defaultViewModeRaw) ?? .list
        tabs.append(tab)
        return tab
    }

    /// 懒创建图标网格视图（共享同一 model；回调语义与列表一致）
    private func ensureIconVC(for tab: Tab) -> FileIconGridViewController {
        if let vc = tab.iconVC { return vc }
        let vc = FileIconGridViewController(model: tab.model)
        vc.coordinator = coordinator
        vc.onNavigate = { [weak self] target in self?.navigate(to: target) }
        vc.onInteract = { [weak self] in self?.onRequestFocus?() }
        vc.onContentChange = { [weak self, weak tab] in
            guard let self, let tab, tabs.contains(where: { $0 === tab }), self.activeTab === tab else { return }
            self.updateStatusCounts()
        }
        vc.onSelectionChange = { [weak self, weak tab] in
            guard let self, let tab, self.tabs.contains(where: { $0 === tab }), self.activeTab === tab else { return }
            self.updateStatusCounts()
        }
        tab.iconVC = vc
        return vc
    }

    /// 懒创建分栏视图（列加载自管：局部 DirectoryReader；下钻经 onNavigate 回本窗格同步地址栏）
    private func ensureColumnVC(for tab: Tab) -> FileColumnViewController {
        if let vc = tab.columnVC { return vc }
        let vc = FileColumnViewController(model: tab.model)
        vc.coordinator = coordinator
        vc.onNavigate = { [weak self] target in self?.navigate(to: target) }
        vc.onInteract = { [weak self] in self?.onRequestFocus?() }
        vc.onSelectionChange = { [weak self, weak tab] in
            guard let self, let tab, self.tabs.contains(where: { $0 === tab }), self.activeTab === tab else { return }
            self.updateStatusCounts()
        }
        tab.columnVC = vc
        return vc
    }

    /// 当前模式对应的内容视图控制器（图标/分栏首用才创建）
    private func contentVC(for tab: Tab) -> NSViewController {
        switch tab.viewMode {
        case .list: return tab.listVC
        case .icons: return ensureIconVC(for: tab)
        case .columns: return ensureColumnVC(for: tab)
        }
    }

    func openNewTab(at url: URL? = nil) {
        appendTab(at: url ?? activeTab.browser.current)
        switchTab(to: tabs.count - 1)
        onRequestFocus?()
    }

    func closeTab(at index: Int) {
        guard tabs.count > 1, tabs.indices.contains(index) else { return }
        let tab = tabs.remove(at: index)
        tab.model.stopWatching()          // 关标签：彻底拆流，不留任何后台监听
        quiesceContent(of: tab)           // 三视图在飞任务全取消
        let vcs: [NSViewController?] = [tab.listVC, tab.iconVC, tab.columnVC]
        for vc in vcs.compactMap({ $0 }) {
            vc.view.removeFromSuperview()
            vc.removeFromParent()
        }
        if activeTabIndex >= tabs.count { activeTabIndex = tabs.count - 1 }
        else if index <= activeTabIndex, activeTabIndex > 0 { activeTabIndex -= 1 }
        mountActiveTab()
        refreshChrome()
    }

    func switchTab(to index: Int) {
        guard tabs.indices.contains(index), index != activeTabIndex else {
            refreshChrome(); return
        }
        activeTabIndex = index
        mountActiveTab()
        refreshChrome()
        onRequestFocus?()
    }

    private func mountActiveTab() {
        contentContainer.subviews.forEach { $0.removeFromSuperview() }
        // 北极星：隐藏标签全部挂起（watcher 真停 + 在飞装饰/列加载取消），只有活动标签活着
        for (i, tab) in tabs.enumerated() where i != activeTabIndex {
            tab.model.suspend()
            quiesceContent(of: tab)
        }
        // 活动标签的非当前模式视图同样静默（切走的视图不留任何在飞任务）
        quiesceContent(of: activeTab, keep: activeTab.viewMode)
        let vc = contentVC(for: activeTab)
        if vc.parent !== self { addChild(vc) }
        let v = vc.view
        v.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(v)
        // 999 优先级:内容视图(分栏/网格)自身的尺寸诉求绝不外推改变窗口尺寸(用户报告的 bug)
        let edges = [
            v.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            v.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            v.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
        ]
        for c in edges { c.priority = .init(999) }
        NSLayoutConstraint.activate(edges)
        // 窗格本身被布局切走时不恢复（由 resumePane 统一恢复）
        if !isPaneSuspended {
            activeTab.model.resume()
            wakeActiveContent()
        }
    }

    /// 停一个标签各内容视图的派生工作（装饰请求/列加载）；keep 指定的活动模式视图不停
    private func quiesceContent(of tab: Tab, keep: PaneViewMode? = nil) {
        if keep != .list { tab.listVC.cancelDecorationWork() }
        if keep != .icons { tab.iconVC?.cancelDecorationWork() }
        if keep != .columns { tab.columnVC?.suspend() }
    }

    /// 唤醒活动标签当前模式的内容视图（各模式的恢复语义）
    private func wakeActiveContent() {
        let tab = activeTab
        switch tab.viewMode {
        case .list: tab.listVC.refreshVisibleDecorations()
        case .icons: tab.iconVC?.refreshVisibleDecorations()
        case .columns: tab.columnVC?.wake(at: tab.browser.current)
        }
    }

    // MARK: 窗格级挂起/恢复（PaneGridController 布局切换时调用——北极星零后台功耗）

    /// 布局切走本窗格：所有标签挂起（活动标签也挂），装饰/列加载请求全取消
    func suspendPane() {
        guard !isPaneSuspended else { return }
        isPaneSuspended = true
        for tab in tabs {
            tab.model.suspend()
            quiesceContent(of: tab)
        }
    }

    /// 布局切回本窗格：只恢复活动标签（其余标签保持挂起，等切换时再恢复）
    func resumePane() {
        guard isPaneSuspended else { return }
        isPaneSuspended = false
        activeTab.model.resume()
        wakeActiveContent()
    }

    private func refreshChrome() {
        tabBar.update(titles: tabs.map { displayName($0.browser.current) }, active: activeTabIndex)
        breadcrumb.setURL(activeTab.browser.current)
        onLocationChange?(activeTab.browser.current)
        applyActiveTint()
        // 状态栏：计数即时刷；卷容量只在目录变化/标签切换时读一次（statfs 只读，不轮询）
        updateStatusCounts()
        statusBar.updateVolume(for: activeTab.browser.current)
    }

    private func updateStatusCounts() {
        var items = activeTab.model.items.count
        var selected = 0
        switch activeTab.viewMode {
        case .list:
            selected = activeTab.listVC.selectedItems.count
        case .icons:
            selected = activeTab.iconVC?.selectedItems.count ?? 0
        case .columns:
            // 分栏语义：计焦点列（列自管加载，与 model 无关）
            if let counts = activeTab.columnVC?.statusCounts {
                items = counts.items
                selected = counts.selected
            }
        }
        statusBar.update(itemCount: items, selectedCount: selected)
    }

    private func displayName(_ url: URL) -> String {
        url.path == "/" ? "/" : url.lastPathComponent
    }

    // MARK: 导航（唯一入口：历史/地址栏/内容/标签标题四方同步）

    func navigate(to url: URL) {
        activeTab.browser.navigate(to: url)
        applyLocation()
    }

    private func applyLocation() {
        activeTab.model.navigate(to: activeTab.browser.current)
        // 分栏模式：列链联动（沿当前链下钻原地扩列，跳转则重建列链）
        if activeTab.viewMode == .columns {
            activeTab.columnVC?.showDirectory(activeTab.browser.current)
        }
        refreshChrome()
    }

    /// 窗格标签栏显隐（菜单"显示窗格标签栏"驱动全部窗格）
    func setTabBarVisible(_ visible: Bool) {
        tabBar.isHidden = !visible
        tabBarHeight?.constant = visible ? 22 : 0
    }

    // MARK: 视图模式切换（M9：⌘1 图标 / ⌘2 列表 / ⌘3 分栏；选中按 URL 集迁移）

    func setViewMode(_ mode: PaneViewMode) {
        guard activeTab.viewMode != mode else { return }
        let carried = currentSelectionURLs()
        activeTab.viewMode = mode
        mountActiveTab()
        restoreSelection(carried)
        view.window?.makeFirstResponder(focusTarget)
        updateStatusCounts()
    }

    private func currentSelectionURLs() -> [URL] {
        switch activeTab.viewMode {
        case .list: return activeTab.listVC.selectedURLs
        case .icons: return activeTab.iconVC?.selectedURLs ?? []
        case .columns: return activeTab.columnVC?.selectedURLs ?? []
        }
    }

    private func restoreSelection(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        switch activeTab.viewMode {
        case .list: activeTab.listVC.select(urls: urls)
        case .icons: activeTab.iconVC?.select(urls: urls)
        case .columns: activeTab.columnVC?.select(urls: urls)
        }
    }

    // MARK: 会话快照/恢复（M11；SessionStore 契约）

    func sessionPane() -> SessionPane {
        let sessionTabs = tabs.map { tab in
            SessionTab(path: tab.browser.current.path,
                       sortKey: tab.model.sort.key.rawValue,
                       sortAscending: tab.model.sort.ascending,
                       includeHidden: tab.model.includeHidden,
                       viewMode: tab.viewMode.rawValue)
        }
        return SessionPane(tabs: sessionTabs, activeTabIndex: activeTabIndex)
    }

    /// 按快照重建标签（丢弃 init 占位标签；路径已消失回退个人目录——容错矩阵）
    func restoreSession(_ pane: SessionPane) {
        guard !pane.tabs.isEmpty else { return }
        for tab in tabs { tab.model.stopWatching() }
        tabs.removeAll()
        let fm = FileManager.default
        for st in pane.tabs {
            var isDir: ObjCBool = false
            let url = (fm.fileExists(atPath: st.path, isDirectory: &isDir) && isDir.boolValue)
                ? URL(fileURLWithPath: st.path)
                : fm.homeDirectoryForCurrentUser
            let tab = appendTab(at: url)
            if let key = SortSpec.Key(rawValue: st.sortKey) {
                tab.model.sort = SortSpec(key: key, ascending: st.sortAscending,
                                          foldersFirst: tab.model.sort.foldersFirst)
            }
            tab.model.includeHidden = st.includeHidden
            if let raw = st.viewMode, let vm = PaneViewMode(rawValue: raw) {
                tab.viewMode = vm
            }
        }
        activeTabIndex = min(max(0, pane.activeTabIndex), tabs.count - 1)
        if isViewLoaded {
            mountActiveTab()
            refreshChrome()
        }
    }

    // MARK: 活动窗格高亮

    func setActive(_ active: Bool) {
        isActivePane = active
        applyActiveTint()
    }

    private func applyActiveTint() {
        addressArea.layer?.backgroundColor = isActivePane
            ? NSColor.controlAccentColor.withAlphaComponent(0.10).cgColor
            : NSColor.clear.cgColor
    }

    /// 焦点落点（PaneGrid 激活窗格时把键盘焦点交给内容视图）
    var focusTarget: NSView {
        switch activeTab.viewMode {
        case .list: return activeTab.listVC.focusTarget
        case .icons: return ensureIconVC(for: activeTab).focusTarget
        case .columns: return ensureColumnVC(for: activeTab).focusTarget
        }
    }

    /// 操作后重读活动内容（真实 FS 投影刷新；分栏另刷自管列链）
    func reloadActiveList() {
        activeTab.model.reload()
        if activeTab.viewMode == .columns { activeTab.columnVC?.reloadAllColumns() }
    }

    /// 仅重绘活动内容（剪切灰显变化，无需重新读盘）
    func redrawActiveList() {
        switch activeTab.viewMode {
        case .list: activeTab.listVC.redraw()
        case .icons: activeTab.iconVC?.redraw()
        case .columns: activeTab.columnVC?.redraw()
        }
    }

    // MARK: 地址栏编辑

    func beginPathEditing() {
        onRequestFocus?()
        pathEditor.isHidden = false
        breadcrumb.isHidden = true
        pathEditor.beginEditing(with: activeTab.browser.current.path)
    }

    private func endPathEditing() {
        pathEditor.isHidden = true
        breadcrumb.isHidden = false
        view.window?.makeFirstResponder(focusTarget)
    }

    // MARK: 菜单命令（响应链，只在活动窗格生效）

    @objc func goBack(_ sender: Any?) {
        if activeTab.browser.goBack() != nil { applyLocation() }
    }

    @objc func goForward(_ sender: Any?) {
        if activeTab.browser.goForward() != nil { applyLocation() }
    }

    @objc func goUpFolder(_ sender: Any?) {
        if activeTab.browser.goUp() != nil { applyLocation() }
    }

    @objc func editPath(_ sender: Any?) {
        beginPathEditing()
    }

    @objc func goHome(_ sender: Any?) {
        navigate(to: FileManager.default.homeDirectoryForCurrentUser)
    }

    @objc func newTab(_ sender: Any?) {
        openNewTab()
    }

    @objc func closeActiveTab(_ sender: Any?) {
        if tabs.count > 1 {
            closeTab(at: activeTabIndex)
        } else {
            view.window?.performClose(sender)
        }
    }

    // 视图模式菜单（显示 > 为图标/为列表/为分栏）
    @objc func viewAsIcons(_ sender: Any?) { setViewMode(.icons) }
    @objc func viewAsList(_ sender: Any?) { setViewMode(.list) }
    @objc func viewAsColumns(_ sender: Any?) { setViewMode(.columns) }
}

extension PaneViewController: @preconcurrency NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(goBack(_:)): return activeTab.browser.canGoBack
        case #selector(goForward(_:)): return activeTab.browser.canGoForward
        case #selector(goUpFolder(_:)): return activeTab.browser.canGoUp
        case #selector(viewAsIcons(_:)):
            menuItem.state = activeTab.viewMode == .icons ? .on : .off
            return true
        case #selector(viewAsList(_:)):
            menuItem.state = activeTab.viewMode == .list ? .on : .off
            return true
        case #selector(viewAsColumns(_:)):
            menuItem.state = activeTab.viewMode == .columns ? .on : .off
            return true
        default: return true
        }
    }
}

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
    /// 计数/选中变化上抛（甲板据此重验动作按钮 enabled；M17）
    var onStatusChange: (() -> Void)?

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
    private let addressArea = AddressBarBacking()
    /// 地址栏内联错误提示（路径不存在/无权限）：红字贴右端、1.5s 后淡出——不弹窗（spec 做工不变量）
    private let pathHint = NSTextField(labelWithString: "")
    private var pathHintFadeWorkItem: DispatchWorkItem?
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
        pathEditor.onRevealFile = { [weak self] url in
            self?.endPathEditing()
            self?.revealFile(url)
        }
        pathEditor.onCancel = { [weak self] in self?.endPathEditing() }
        // 失焦复位：不夺焦（焦点已在用户刚点的地方），只把编辑框收掉让面包屑回显
        pathEditor.onReset = { [weak self] in self?.endPathEditing(takeFocus: false) }
        // 相对路径（"Downloads"、"./x"）按当前浏览目录解析——进程 CWD 对文件管理器没有意义
        pathEditor.baseDirectory = { [weak self] in
            self?.activeTab.browser.current ?? FileManager.default.homeDirectoryForCurrentUser
        }
        pathEditor.onInvalid = { [weak self] message in self?.flashPathHint(message) }
        pathEditor.isHidden = true

        // 窗口级 key 迁移不发 didEndEditing（见 windowDidResignKey 注释），只能靠通知补这条缝。
        // object: nil + 回调内比对 view.window —— 窗格会随布局重建/会话恢复换窗，绑死 object 会失联。
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidResignKey(_:)),
            name: NSWindow.didResignKeyNotification, object: nil)

        pathHint.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        pathHint.textColor = .systemRed
        pathHint.alignment = .right
        pathHint.lineBreakMode = .byTruncatingHead
        pathHint.drawsBackground = true                 // 盖住底下的路径文本，短提示才读得清
        pathHint.backgroundColor = .controlBackgroundColor
        pathHint.isHidden = true

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

        // 内联错误提示浮在地址栏右端（最后添加=盖在编辑框之上），不改行高、不挤压面包屑
        pathHint.translatesAutoresizingMaskIntoConstraints = false
        addressArea.addSubview(pathHint)
        NSLayoutConstraint.activate([
            pathHint.centerYAnchor.constraint(equalTo: addressArea.centerYAnchor),
            pathHint.trailingAnchor.constraint(equalTo: addressArea.trailingAnchor, constant: -8),
            pathHint.leadingAnchor.constraint(greaterThanOrEqualTo: addressArea.leadingAnchor, constant: 8),
        ])

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
            addressArea.heightAnchor.constraint(equalToConstant: 24),
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
        // 外部化默认偏好：新标签按设置初始化（隐藏文件/默认排序键与升降序/文件夹置顶/视图模式）
        model.includeHidden = Preferences.showHiddenByDefault
        let defaultSortKey = SortSpec.Key(rawValue: Preferences.defaultSortKey) ?? .name
        model.sort = SortSpec(key: defaultSortKey, ascending: Preferences.defaultSortAscending,
                              foldersFirst: Preferences.foldersFirst)
        let listVC = FileListViewController(model: model)
        listVC.coordinator = coordinator
        listVC.onNavigate = { [weak self] target in self?.navigate(to: target) }
        listVC.onNavigateBack = { [weak self] in self?.goBack(nil) }
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
        let target = url ?? activeTab.browser.current
        // 窗格标签上限（QSpace 语义）：>0 且已达上限 → 先覆盖最老（移除 index 0）再追加
        let limit = Preferences.paneTabLimit
        if limit > 0, tabs.count >= limit { closeTab(at: 0) }
        appendTab(at: target)
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
        // 任何导航/标签切换都退出地址栏编辑态：面包屑随即回显当前目录。
        // 修用户报的"刷新/退回上级再重进地址栏不恢复、删空后一直空白"——这些路径不经失焦，
        // 仅靠 controlTextDidEndEditing 的失焦复位覆盖不到，必须在位置同步处强制收编辑态。
        // isViewLoaded 守卫不可省：endPathEditing 会摸 self.view，而 refreshChrome 会在
        // 视图尚未装载时被 applyLocation 调到（新窗口 initialDirectory / 外部打开 reveal 都走这条），
        // 此时 pathEditor.isHidden 还是 NSView 默认的 false，会误判成"正在编辑"并把 loadView 提前逼出来，
        // 扰乱新窗口的建窗与焦点时序（I-52 外部打开落错窗即由此确定性复现）。同 restore(from:) 的既有守卫。
        if isViewLoaded, !pathEditor.isHidden { endPathEditing() }
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
        var bytes: Int64 = 0
        switch activeTab.viewMode {
        case .list:
            let sel = activeTab.listVC.selectedItems
            selected = sel.count
            bytes = sel.reduce(0) { $0 + ($1.size ?? 0) }
        case .icons:
            let sel = activeTab.iconVC?.selectedItems ?? []
            selected = sel.count
            bytes = sel.reduce(0) { $0 + ($1.size ?? 0) }
        case .columns:
            // 分栏语义：计焦点列（列自管加载，与 model 无关）
            if let vc = activeTab.columnVC {
                let counts = vc.statusCounts
                items = counts.items
                selected = counts.selected
                bytes = vc.selectedItems.reduce(0) { $0 + ($1.size ?? 0) }
            }
        }
        statusBar.update(itemCount: items, selectedCount: selected, selectedBytes: bytes)
        onStatusChange?()
    }

    /// 当前活动内容视图的选中数（甲板动作按钮校验用）
    var currentSelectionCount: Int {
        switch activeTab.viewMode {
        case .list: return activeTab.listVC.selectedItems.count
        case .icons: return activeTab.iconVC?.selectedItems.count ?? 0
        case .columns: return activeTab.columnVC.map { $0.statusCounts.selected } ?? 0
        }
    }

    /// UISelfTest（M21）：list 模式选中前 n 项并刷计数，回状态栏选中药丸是否可见
    func uiTestSelectFirstItemsAndPillVisible(_ n: Int) -> Bool {
        let urls = Array(activeTab.model.items.prefix(n)).map(\.url)
        activeTab.listVC.select(urls: urls)
        updateStatusCounts()
        return statusBar.selectionPillVisible
    }

    /// UISelfTest（I-30）：程序化进入路径编辑，暴露编辑框以驱动首键探针
    var uiTestPathEditor: PathEditorField { pathEditor }
    /// UISelfTest（I-37）：暴露面包屑地址栏以驱动截断/折叠/宽度自适应断言
    var uiTestBreadcrumb: BreadcrumbBar { breadcrumb }
    /// I-30 探针：以指定种子进入编辑（走真实 begin 链，仅替换种子文本便于净首键断言）
    func uiTestBeginPathEditing(seed: String) {
        onRequestFocus?()
        pathEditor.isHidden = false
        breadcrumb.isHidden = true
        pathEditor.beginEditing(with: seed)
    }

    /// UISelfTest（I-30 编排收尾）：退出路径编辑恢复面包屑（场景不得把编辑态泄漏给后续截图）
    func uiTestEndPathEditing() { endPathEditing() }

    /// UISelfTest（I-53）：当前是否处于路径编辑态（失焦复位断言用）
    var uiTestIsPathEditing: Bool { !pathEditor.isHidden }

    /// UISelfTest（I-53）：模拟「点击他处失焦」——直接转移 firstResponder（不经 onCancel）
    func uiTestBlurPathEditor() {
        view.window?.makeFirstResponder(focusTarget)
    }

    /// UISelfTest（I-53）：当前目录（地址栏应反映的）
    var uiTestCurrentURL: URL { activeTab.browser.current }

    /// UISelfTest（I-53）：地址栏编辑器的当前文本
    var uiTestPathEditorText: String { pathEditor.stringValue }

    /// UISelfTest（I-54）：内联错误提示是否正在显示 / 显示的文字
    var uiTestPathHintVisible: Bool { !pathHint.isHidden && pathHint.alphaValue > 0 }
    var uiTestPathHintText: String { pathHint.stringValue }

    /// UISelfTest（I-54）：⌘R 刷新走的真实入口（响应链在地址栏获焦时先到本控制器）
    func uiTestRefresh() { refresh(nil) }

    /// UISelfTest（I-55）：当前标签是否在显示隐藏文件（验证 reveal 隐藏文件时自动打开）
    var uiTestIncludeHidden: Bool { activeTab.model.includeHidden }

    /// UISelfTest（I-55）：设置当前标签的"显示隐藏文件"（场景收尾复原用，不泄漏给后续场景）
    func uiTestSetIncludeHidden(_ on: Bool) { activeTab.model.includeHidden = on }

    /// UISelfTest（I-58）：列头排序指示器当前显示的 (键, 升序)。
    /// 「排序状态丢失」的真相是指示器没跟上 model.sort——数据排对了、箭头停在"名称"上，
    /// 所以必须把指示器和模型分开断言，只验 model.sort 会漏掉这个 bug。
    var uiTestSortIndicator: (key: String, ascending: Bool)? {
        guard let d = activeTab.listVC.tableView.sortDescriptors.first, let k = d.key else { return nil }
        return (k, d.ascending)
    }

    /// UISelfTest（I-58）：直接改模型排序（模拟会话恢复那条路——restore 就是这样写的，不经列头）
    func uiTestSetSort(key: String, ascending: Bool) {
        guard let k = SortSpec.Key(rawValue: key) else { return }
        activeTab.model.sort = SortSpec(key: k, ascending: ascending,
                                        foldersFirst: activeTab.model.sort.foldersFirst)
    }

    /// UISelfTest（I-58）：模型侧的排序（对照组）
    var uiTestModelSort: (key: String, ascending: Bool) {
        (activeTab.model.sort.key.rawValue, activeTab.model.sort.ascending)
    }

    /// UISelfTest（I-57）：面包屑当前显示的目录 / 是否可见。
    /// 「面包屑回显」必须验内容——只验 !isHidden 的断言把 breadcrumb.isHidden=false 删掉照样绿。
    var uiTestBreadcrumbURL: URL { breadcrumb.url }
    var uiTestBreadcrumbVisible: Bool { !breadcrumb.isHidden }

    /// UISelfTest（I-57）：地址栏是否仍持有 field editor（退出编辑后必须已释放；
    /// 「isHidden=true 但 field editor 还在」这个状态是可达的，光验 isHidden 盖不住）
    var uiTestPathEditorHasFocus: Bool { pathEditor.currentEditor() != nil }

    /// UISelfTest（I-32）：刷新状态栏计数并回选中药丸是否可见（删除后选中清空 → 应无"已选"药丸）
    func uiTestRefreshAndSelectionPillVisible() -> Bool {
        updateStatusCounts()
        return statusBar.selectionPillVisible
    }

    private func displayName(_ url: URL) -> String {
        url.path == "/" ? "/" : url.lastPathComponent
    }

    // MARK: 导航（唯一入口：历史/地址栏/内容/标签标题四方同步）

    func navigate(to url: URL) {
        coordinator?.recordAccess(url)   // M28：进入文件夹 = 一次使用记账（搜索按习惯排序用）
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
        // 读盘途中切视图模式：待定位目标还挂在旧视图上，不搬过去就永久丢失，
        // 而且会在旧视图里留成日后突然"幽灵跳选"并抢焦点的定时炸弹。先取走，挂到新视图上。
        let carriedReveal = takePendingReveal()
        activeTab.viewMode = mode
        mountActiveTab()
        restoreSelection(carried)
        if let carriedReveal { revealAfterLoad(carriedReveal.url, rename: carriedReveal.rename) }
        view.window?.makeFirstResponder(focusTarget)
        updateStatusCounts()
    }

    /// 取走当前视图上的待定位目标（切视图模式搬家用）
    private func takePendingReveal() -> (url: URL, rename: Bool)? {
        switch activeTab.viewMode {
        case .list:  return activeTab.listVC.takePendingReveal()
        case .icons: return activeTab.iconVC?.takePendingReveal()
        case .columns:
            guard let url = activeTab.columnVC?.takePendingReveal() else { return nil }
            return (url, false)   // 分栏无行内重命名语义
        }
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

    // MARK: 活动窗格高亮 / 非活动窗格暗化

    /// 非活动窗格内容暗化覆盖层（懒建；alpha=偏好值，0 或活动时隐藏）
    private var dimOverlay: NSView?

    func setActive(_ active: Bool, dimmed: Bool = false) {
        isActivePane = active
        applyActiveTint()
        // 非活动窗格暗化（QSpace 外观项）：盖半透明黑覆盖 contentContainer；
        // dimmed 由 grid 传入（仅多窗格的非活动窗格为真），单窗格恒不暗化
        let alpha = Preferences.inactivePaneDimming
        if dimmed, alpha > 0 {
            let overlay = ensureDimOverlay()
            overlay.frame = contentContainer.bounds
            overlay.layer?.opacity = Float(alpha)
            overlay.isHidden = false
            contentContainer.addSubview(overlay)   // 置于内容之上（mountActiveTab 清空后重挂）
        } else {
            dimOverlay?.isHidden = true
        }
    }

    /// 懒建暗化覆盖层（autoresizing 随 contentContainer 缩放；不用约束以便随内容视图重挂存活）
    private func ensureDimOverlay() -> NSView {
        if let overlay = dimOverlay { return overlay }
        let overlay = NSView()
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.black.cgColor
        overlay.frame = contentContainer.bounds
        overlay.autoresizingMask = [.width, .height]
        dimOverlay = overlay
        return overlay
    }

    private func applyActiveTint() {
        // 高亮开关（偏好）关时不描色；强调色走 Theme.accent（可自定义主题色）。
        // 底色解析交给 AddressBarBacking.updateLayer（外观感知、明暗切换自动重解析）。
        addressArea.highlighted = isActivePane && Preferences.activePaneHighlight
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
        hidePathHint()
        pathEditor.beginEditing(with: activeTab.browser.current.path)
    }

    private func endPathEditing(takeFocus: Bool = true) {
        pathEditor.isHidden = true
        breadcrumb.isHidden = false
        hidePathHint()
        // 失焦复位这条路上 takeFocus=false：焦点此刻已经在别处（可能是另一个窗格、侧边栏、工具栏），
        // 再 makeFirstResponder 就是把用户刚点过去的焦点抢回来——用户点隔壁窗格却发现光标跳回这边。
        if takeFocus { view.window?.makeFirstResponder(focusTarget) }
    }

    /// 无效路径就地反馈：地址栏右端红字，1.5s 后淡出（不弹窗——spec 做工不变量）
    private func flashPathHint(_ message: String) {        pathHintFadeWorkItem?.cancel()
        pathHint.stringValue = message
        pathHint.alphaValue = 1
        pathHint.isHidden = false
        // VoiceOver 播报：否则视障用户只听得到一声 beep，完全不知道错在哪
        NSAccessibility.post(element: pathHint, notification: .announcementRequested,
                             userInfo: [.announcement: message,
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
        let fade = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                self.pathHint.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                self?.pathHint.isHidden = true
            }
        }
        pathHintFadeWorkItem = fade
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: fade)
    }

    private func hidePathHint() {
        pathHintFadeWorkItem?.cancel()
        pathHintFadeWorkItem = nil
        pathHint.isHidden = true
    }

    /// 窗口失去 key（另开设置窗 / ⌘F 搜索面板 / ⌘Tab 切到别的 App）时，**AppKit 不发**
    /// `controlTextDidEndEditing`——独立探针实测：resignKey 之后 field editor 仍在、
    /// pathEditor.isHidden 仍是 false。于是失焦复位这条路对它完全无感知，用户把地址栏删空后
    /// 去开个设置窗，回头看主窗就是一个空白输入框盖在面包屑上。
    ///
    /// **只在文本为空时才收**：⌘L 全选后切到 Finder/终端复制一段路径、再切回来 ⌘V 粘贴，
    /// 正是本轮要服务的头号用例。无条件复位会把编辑框关掉、焦点交回文件列表，那记 ⌘V 就命中
    /// 列表的 pasteItems，变成「往当前目录粘贴文件」——一个纯浏览动作被升级成写盘操作。
    /// 空文本意味着用户没有任何待粘贴内容可丢，收掉是纯收益。
    @objc private func windowDidResignKey(_ note: Notification) {
        guard isViewLoaded, (note.object as? NSWindow) === view.window,
              !pathEditor.isHidden,
              pathEditor.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        endPathEditing(takeFocus: false)   // 窗口正在失去 key，别去抢焦点
    }

    /// 粘贴文件路径（.apk 等）或包路径（.app）：进入其父目录并选中该项（Finder 语义）
    private func revealFile(_ fileURL: URL) {
        // 目标是隐藏文件、而当前又没在显示隐藏文件：用户是**明确点名**要这个文件的，
        // 不打开显示就只会跳到父目录、什么都不选中，在用户眼里就是"回车了没反应"。
        // 为该标签打开显示隐藏（每标签独立，⌘⇧. 随时可关掉），让用户真看得到自己要的东西。
        if Self.isHiddenItem(fileURL), !activeTab.model.includeHidden {
            activeTab.model.includeHidden = true
        }
        let parent = fileURL.deletingLastPathComponent()
        navigate(to: parent)
        revealAfterLoad(fileURL)
    }

    /// 是否为隐藏项：点开头，或带 macOS 隐藏标志（后者是 UF_HIDDEN，点前缀盖不住）
    private static func isHiddenItem(_ url: URL) -> Bool {
        if url.lastPathComponent.hasPrefix(".") { return true }
        return (try? url.resourceValues(forKeys: [.isHiddenKey]))?.isHidden ?? false
    }

    // MARK: 菜单命令（响应链，只在活动窗格生效）

    @objc func goBack(_ sender: Any?) {
        if activeTab.browser.goBack() != nil { applyLocation() }
    }

    @objc func goForward(_ sender: Any?) {
        if activeTab.browser.goForward() != nil { applyLocation() }
    }

    /// I-39：⌘↑ 上层后自动选中来源子目录（Finder/QSpace 语义）——与 ⌘↓ 互逆闭环的前半
    @objc func goUpFolder(_ sender: Any?) {
        let child = activeTab.browser.current
        if activeTab.browser.goUp() != nil {
            applyLocation()
            revealAfterLoad(child)
        }
    }

    /// I-39：⌘↓ 下层——单选文件夹在窗格内进入；有选中交视图打开逻辑（文件默认程序）；
    /// 无选中时回退最近历史的直接子级（刚 ⌘↑ 上来的情形，历史不膨胀）
    @objc func goDownFolder(_ sender: Any?) {
        let items = currentSelectedItems()
        if items.count == 1, let only = items.first, only.isDirectory, !only.isPackage {
            navigate(to: only.url)
            return
        }
        if !items.isEmpty {
            switch activeTab.viewMode {
            case .list: activeTab.listVC.openSelected(nil)
            case .icons: activeTab.iconVC?.openSelected(nil)
            case .columns: activeTab.columnVC?.openSelected(nil)
            }
            return
        }
        if canDescendIntoHistory, activeTab.browser.goBack() != nil { applyLocation() }
    }

    /// 最近后退历史是否为当前目录的直接子级（⌘↓ 无选中兜底 + 菜单校验共用）
    private var canDescendIntoHistory: Bool {
        guard let recent = activeTab.browser.backHistory.first else { return false }
        return recent.deletingLastPathComponent().standardizedFileURL.path
            == activeTab.browser.current.standardizedFileURL.path
    }

    private func currentSelectedItems() -> [FileItem] {
        switch activeTab.viewMode {
        case .list: return activeTab.listVC.selectedItems
        case .icons: return activeTab.iconVC?.selectedItems ?? []
        case .columns: return activeTab.columnVC?.selectedItems ?? []
        }
    }

    /// 导航落位后选中指定条目（各视图自带"加载完成再选"机制，避开异步读目录竞态）
    private func revealAfterLoad(_ url: URL, rename: Bool = false) {
        switch activeTab.viewMode {
        case .list: activeTab.listVC.prepareReveal(url, rename: rename)
        case .icons: activeTab.iconVC?.prepareReveal(url, rename: rename)
        case .columns: activeTab.columnVC?.select(urls: [url])
        }
    }

    /// 视图模式感知的对外定位入口（外部 reveal / open-in-NSpace / 搜索定位 / 打开新窗选中 共用）：
    /// 先设目录再调本方法即可——各视图的 pending 机制会在异步读目录完成后落选中（I-44）。
    func reveal(_ url: URL) { revealAfterLoad(url) }

    /// 导航历史（长按历史菜单用）：最近的在前
    var backHistory: [URL] { activeTab.browser.backHistory }
    var forwardHistory: [URL] { activeTab.browser.forwardHistory }

    /// 跳到后退/前进历史第 index 项（0=最近）
    func jumpBackHistory(to index: Int) {
        if activeTab.browser.jumpBack(to: index) != nil { applyLocation() }
    }

    func jumpForwardHistory(to index: Int) {
        if activeTab.browser.jumpForward(to: index) != nil { applyLocation() }
    }

    @objc func editPath(_ sender: Any?) {
        beginPathEditing()
    }

    /// ⌘R 刷新：地址栏获焦时响应链先到本控制器（内容区获焦时由各视图 VC 自己的 refresh 处理）。
    /// 用户报"删空地址栏后刷新也不恢复"——刷新既不经失焦、也不经导航，两条既有复位路径都盖不到，
    /// 必须在这里显式收编辑态，否则空白编辑框会一直盖在面包屑上。
    @objc func refresh(_ sender: Any?) {
        if isViewLoaded, !pathEditor.isHidden { endPathEditing() }
        reloadActiveList()
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

/// 地址栏底衬（外观感知）：常态不透明 controlBackgroundColor 基色，活动窗格叠 accent 0.10。
/// 关键：用 updateLayer 而非一次性 cgColor —— 系统明暗切换与 .nspaceThemeChanged 都会自动重解析，
/// 杜绝深色下非活动窗格地址栏渲染成白块 / 缓存陈旧（原一次性 cgColor 在浅色时取值、深色下不刷新）。
private final class AddressBarBacking: NSView {
    var highlighted = false { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建 UI，无 xib") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let base = NSColor.controlBackgroundColor
            let bg = highlighted ? (base.blended(withFraction: 0.10, of: Theme.accent) ?? base) : base
            layer?.backgroundColor = bg.cgColor
        }
    }
}

extension PaneViewController: @preconcurrency NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(goBack(_:)): return activeTab.browser.canGoBack
        case #selector(goForward(_:)): return activeTab.browser.canGoForward
        case #selector(goUpFolder(_:)): return activeTab.browser.canGoUp
        case #selector(goDownFolder(_:)): return currentSelectionCount > 0 || canDescendIntoHistory
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

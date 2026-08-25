import AppKit
import NSpaceContracts

/// 窗格：标签栏 + 地址栏（面包屑⟷编辑器）+ 内容视图；每标签独立浏览器与历史。
/// 多实例由 PaneGridController 编排；活动窗格高亮由 setActive 驱动
@MainActor
final class PaneViewController: NSViewController {
    /// 一个标签 = 独立浏览状态 + 独立目录模型 + 独立列表视图（隐藏标签零后台工作）
    struct Tab {
        let browser: BrowserState
        let model: DirectoryViewModel
        let listVC: FileListViewController
    }

    private(set) var tabs: [Tab] = []
    private(set) var activeTabIndex = 0
    var activeTab: Tab { tabs[activeTabIndex] }

    /// 位置变化上抛（窗口标题）
    var onLocationChange: ((URL) -> Void)?
    /// 用户在本窗格交互 → 请求成为活动窗格
    var onRequestFocus: (() -> Void)?

    /// 文件操作桥：下传每个标签的列表视图（右键菜单/快捷键经此发 OperationSpec）
    var coordinator: FileOpsCoordinator? {
        didSet { tabs.forEach { $0.listVC.coordinator = coordinator } }
    }

    private let tabBar = TabBarView()
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
        NSLayoutConstraint.activate([
            // fullSizeContentView 下内容延伸到标题栏底下：标签栏必须锚 safeArea 顶，否则被工具栏遮住
            tabBar.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: 22),
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
        tabs.append(tab)
        return tab
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
        tab.listVC.cancelDecorationWork()
        tab.listVC.view.removeFromSuperview()
        tab.listVC.removeFromParent()
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
        // 北极星：隐藏标签全部挂起（watcher 真停 + 在飞装饰请求取消），只有活动标签活着
        for (i, tab) in tabs.enumerated() where i != activeTabIndex {
            tab.model.suspend()
            tab.listVC.cancelDecorationWork()
        }
        let listVC = activeTab.listVC
        if listVC.parent !== self { addChild(listVC) }
        let v = listVC.view
        v.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            v.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            v.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
        ])
        // 窗格本身被布局切走时不恢复（由 resumePane 统一恢复）
        if !isPaneSuspended {
            activeTab.model.resume()
            activeTab.listVC.refreshVisibleDecorations()
        }
    }

    // MARK: 窗格级挂起/恢复（PaneGridController 布局切换时调用——北极星零后台功耗）

    /// 布局切走本窗格：所有标签挂起（活动标签也挂），装饰请求全取消
    func suspendPane() {
        guard !isPaneSuspended else { return }
        isPaneSuspended = true
        for tab in tabs {
            tab.model.suspend()
            tab.listVC.cancelDecorationWork()
        }
    }

    /// 布局切回本窗格：只恢复活动标签（其余标签保持挂起，等切换时再恢复）
    func resumePane() {
        guard isPaneSuspended else { return }
        isPaneSuspended = false
        activeTab.model.resume()
        activeTab.listVC.refreshVisibleDecorations()
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
        statusBar.update(itemCount: activeTab.model.items.count,
                         selectedCount: activeTab.listVC.selectedItems.count)
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
        refreshChrome()
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
    var focusTarget: NSView { activeTab.listVC.focusTarget }

    /// 操作后重读活动列表（真实 FS 投影刷新）
    func reloadActiveList() { activeTab.model.reload() }

    /// 仅重绘活动列表（剪切灰显变化，无需重新读盘）
    func redrawActiveList() { activeTab.listVC.redraw() }

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
}

extension PaneViewController: @preconcurrency NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(goBack(_:)): activeTab.browser.canGoBack
        case #selector(goForward(_:)): activeTab.browser.canGoForward
        case #selector(goUpFolder(_:)): activeTab.browser.canGoUp
        default: true
        }
    }
}

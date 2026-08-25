import AppKit

// 方向契约（direction contract）—— 照抄 docs/design/M17-deck-spec.md 开头（唯一权威）
// THESIS: 原生 macOS 专业工具标准做到极致——Finder 的材质语言 × QSpace 的密度与拓扑；
//        特色走结构与做工，不走色彩（用户否决一切"web 花哨配色"，seed f8a2afe5 的骰子结果被用户的 canon 出口取代）。
// OWN-WORLD: 现有主题系统（Theme.accent / appearanceMode / accentColorHex）+ 系统材质
//        （NSVisualEffectView .titlebar/.sidebar）+ SF Symbols + 发丝分隔线 + 4pt 网格。去掉全部内容后
//        仍可辨识的是拓扑：一条贯通全高的分割线，左列暂存牌堆压顶，右列三层甲板。
// STORY: 打开即是四件事同屏可扫——哪个窗格有焦点、路径在哪、暂存架里有什么、任务跑到哪。
// FIRST VIEWPORT: 左列 = 红绿灯行(28) + 暂存架(148) + 书签/iCloud/位置；右列 = 工作区标签条(28)
//        + 图标工具条(36) + 窗格矩阵(每窗格自带地址栏) + 状态栏(22)。
// FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review,
//        the verdict, and DESIGN.md.

/// 甲板动作出口（MainWindowController 实现）：需带选中态/校验的控件走此协议，
/// 纯响应链动作（AirDrop/终端/废纸篓）由甲板直接 target=nil 上抛第一响应者。
@MainActor
protocol TopDeckDelegate: AnyObject {
    func deckToggleSidebar()
    func deckGoBack()
    func deckGoForward()
    func deckGoUp()
    func deckSetViewMode(_ mode: PaneViewMode)
    func deckSetLayout(_ layout: PaneLayout)
    func deckNewWorkspace()
    func deckSelectWorkspace(_ index: Int)
    func deckCloseWorkspace(_ index: Int)
    /// 导航历史（长按后退/前进段弹出；最近的在前）
    func deckHistory(forward: Bool) -> [URL]
    func deckJumpHistory(forward: Bool, index: Int)
}

/// 自绘顶部甲板（M17 §1/§3/§6.2）：NSVisualEffectView(.titlebar) 内两行——
/// 工作区标签条(28) + 发丝线 + 图标工具条(36) + 发丝线。密度对齐 QSpace（钮 24×24 / SF13 / 间距 4）。
/// 工具条 A1 左右分野：左=侧栏│导航│视图三段（就近内容），弹性留白兼窗口拖动把手，右=动作│布局五段。
/// 甲板空白处可拖动窗口，双击按系统 AppleActionOnDoubleClick 缩放/最小化。零新配色（Theme.accent/系统语义色/材质）。
@MainActor
final class TopDeckView: NSVisualEffectView {
    static let tabRowHeight: CGFloat = 28
    static let toolbarRowHeight: CGFloat = 36
    /// 侧栏折叠时红绿灯落在甲板左上，标签行让位（仅折叠态；§1，收敛 4pt 阶梯 = 80）
    static let trafficLightInset: CGFloat = 80

    weak var deckDelegate: TopDeckDelegate?

    /// 工作区标签条（复用/泛化现 TabBarView 语法；§2）
    let workspaceTabBar = TabBarView()
    /// 两行容器（UISelfTest 度量高度 28/36 用；§5）
    let tabRow = NSView()
    let toolbarRow = NSView()

    private let navControl = NSSegmentedControl()
    private let viewModeControl = NSSegmentedControl()
    private let layoutControl = NSSegmentedControl()
    private let sidebarButton = NSButton()
    private let airdropButton = NSButton()
    private let terminalButton = NSButton()
    private let tasksButton = NSButton()
    private let trashButton = NSButton()
    private var tabRowLeading: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        material = .titlebar
        blendingMode = .behindWindow
        state = .followsWindowActiveState
        translatesAutoresizingMaskIntoConstraints = false
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建 UI，无 xib") }

    // MARK: 构建

    private func build() {
        // ── 行1：工作区标签条 ───────────────────────────────────────────
        workspaceTabBar.translatesAutoresizingMaskIntoConstraints = false
        workspaceTabBar.useTransparentBackground()
        workspaceTabBar.onSelect = { [weak self] i in self?.deckDelegate?.deckSelectWorkspace(i) }
        workspaceTabBar.onClose = { [weak self] i in self?.deckDelegate?.deckCloseWorkspace(i) }
        workspaceTabBar.onNew = { [weak self] in self?.deckDelegate?.deckNewWorkspace() }
        tabRow.translatesAutoresizingMaskIntoConstraints = false
        tabRow.addSubview(workspaceTabBar)

        // ── 行2：图标工具条（§6.1 官方 SF Symbols；§6.2 A1 左右分野）──────
        // 左簇：侧栏开关（sidebar.leading）
        buildIconButton(sidebarButton, symbol: "sidebar.leading", fallback: "sidebar.left",
                        tooltipKey: "menu.toggleSidebar", action: #selector(sidebarClicked), target: self)
        // 左簇：导航三段（chevron.backward / chevron.forward / arrow.up）
        navControl.segmentCount = 3
        navControl.trackingMode = .momentary
        navControl.segmentStyle = .separated
        let navSpecs = [("chevron.backward", "menu.back"), ("chevron.forward", "menu.forward"),
                        ("arrow.up", "menu.goUp")]
        for (i, s) in navSpecs.enumerated() {
            navControl.setImage(NSImage.officialSymbol(s.0, accessibility: L10n.t(s.1)), forSegment: i)
            navControl.setToolTip(L10n.t(s.1), forSegment: i)
            navControl.setWidth(26, forSegment: i)
        }
        navControl.target = self
        navControl.action = #selector(navClicked(_:))
        // 长按后退/前进段 → 弹出该方向历史菜单（§3；短按仍走 momentary 单击动作）
        let navLongPress = NSPressGestureRecognizer(target: self, action: #selector(navLongPressed(_:)))
        navLongPress.minimumPressDuration = 0.4
        navControl.addGestureRecognizer(navLongPress)
        // 左簇：视图三段（square.grid.2x2 / list.bullet / rectangle.split.3x1）
        viewModeControl.segmentCount = 3
        viewModeControl.trackingMode = .selectOne
        let viewSpecs = [("square.grid.2x2", "menu.viewAsIcons"), ("list.bullet", "menu.viewAsList"),
                         ("rectangle.split.3x1", "menu.viewAsColumns")]
        for (i, s) in viewSpecs.enumerated() {
            viewModeControl.setImage(NSImage.officialSymbol(s.0, accessibility: L10n.t(s.1)), forSegment: i)
            viewModeControl.setToolTip(L10n.t(s.1), forSegment: i)
            viewModeControl.setWidth(28, forSegment: i)
        }
        viewModeControl.target = self
        viewModeControl.action = #selector(viewModeClicked(_:))

        // 右簇：动作四钮（响应链 target=nil 上抛活动窗格 FileListViewController；任务钮定向 ProgressWindowController）
        buildIconButton(airdropButton, symbol: "airdrop", fallback: "dot.radiowaves.left.and.right",
                        tooltipKey: "toolbar.airdrop",
                        action: #selector(FileListViewController.airdropSelected(_:)), target: nil)
        buildIconButton(terminalButton, symbol: "apple.terminal", fallback: "terminal",
                        tooltipKey: "toolbar.terminal",
                        action: #selector(FileListViewController.openInTerminal(_:)), target: nil)
        buildIconButton(tasksButton, symbol: "arrow.up.arrow.down", fallback: nil,
                        tooltipKey: "toolbar.tasks",
                        action: #selector(ProgressWindowController.toggleVisible(_:)),
                        target: ProgressWindowController.shared)
        buildIconButton(trashButton, symbol: "trash", fallback: nil, tooltipKey: "menu.moveToTrash",
                        action: #selector(FileListViewController.moveToTrash(_:)), target: nil)
        // 右簇：布局五段（rectangle 同族；PaneLayout.symbolName 与 §6.1 表一致）
        layoutControl.segmentCount = PaneLayout.allCases.count
        layoutControl.trackingMode = .selectOne
        layoutControl.segmentStyle = .separated
        for (i, layout) in PaneLayout.allCases.enumerated() {
            layoutControl.setImage(NSImage.officialSymbol(layout.symbolName, accessibility: layout.localizedName),
                                   forSegment: i)
            layoutControl.setToolTip(layout.localizedName, forSegment: i)
            layoutControl.setWidth(28, forSegment: i)
        }
        layoutControl.target = self
        layoutControl.action = #selector(layoutClicked(_:))

        // A1 左簇：侧栏｜导航｜视图（簇间 8pt + 发丝竖线 = 视觉 16pt 簇距）
        let leftStack = NSStackView(views: [
            sidebarButton, hairlineV(), navControl, hairlineV(), viewModeControl,
        ])
        leftStack.orientation = .horizontal
        leftStack.alignment = .centerY
        leftStack.spacing = 8
        leftStack.translatesAutoresizingMaskIntoConstraints = false
        // A1 右簇：动作四钮（内部 4pt）｜布局五段
        let actionsStack = NSStackView(views: [airdropButton, terminalButton, tasksButton, trashButton])
        actionsStack.orientation = .horizontal
        actionsStack.alignment = .centerY
        actionsStack.spacing = 4
        let rightStack = NSStackView(views: [actionsStack, hairlineV(), layoutControl])
        rightStack.orientation = .horizontal
        rightStack.alignment = .centerY
        rightStack.spacing = 8
        rightStack.translatesAutoresizingMaskIntoConstraints = false

        toolbarRow.translatesAutoresizingMaskIntoConstraints = false
        toolbarRow.addSubview(leftStack)
        toolbarRow.addSubview(rightStack)

        // ── 发丝分隔线 ───────────────────────────────────────────────────
        let hair1 = hairlineH(), hair2 = hairlineH()
        for v in [tabRow, hair1, toolbarRow, hair2] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        tabRowLeading = workspaceTabBar.leadingAnchor.constraint(equalTo: tabRow.leadingAnchor)
        NSLayoutConstraint.activate([
            // 行1
            tabRow.topAnchor.constraint(equalTo: topAnchor),
            tabRow.leadingAnchor.constraint(equalTo: leadingAnchor),
            tabRow.trailingAnchor.constraint(equalTo: trailingAnchor),
            tabRow.heightAnchor.constraint(equalToConstant: Self.tabRowHeight),
            tabRowLeading,
            workspaceTabBar.trailingAnchor.constraint(equalTo: tabRow.trailingAnchor),
            workspaceTabBar.topAnchor.constraint(equalTo: tabRow.topAnchor),
            workspaceTabBar.bottomAnchor.constraint(equalTo: tabRow.bottomAnchor),
            // 发丝线1
            hair1.topAnchor.constraint(equalTo: tabRow.bottomAnchor),
            hair1.leadingAnchor.constraint(equalTo: leadingAnchor),
            hair1.trailingAnchor.constraint(equalTo: trailingAnchor),
            hair1.heightAnchor.constraint(equalToConstant: 1),
            // 行2：左簇顶格 leading，右簇顶格 trailing，中段弹性留白 = 窗口拖动把手
            toolbarRow.topAnchor.constraint(equalTo: hair1.bottomAnchor),
            toolbarRow.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbarRow.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbarRow.heightAnchor.constraint(equalToConstant: Self.toolbarRowHeight),
            leftStack.leadingAnchor.constraint(equalTo: toolbarRow.leadingAnchor, constant: 8),
            leftStack.centerYAnchor.constraint(equalTo: toolbarRow.centerYAnchor),
            rightStack.trailingAnchor.constraint(equalTo: toolbarRow.trailingAnchor, constant: -8),
            rightStack.centerYAnchor.constraint(equalTo: toolbarRow.centerYAnchor),
            leftStack.trailingAnchor.constraint(lessThanOrEqualTo: rightStack.leadingAnchor, constant: -8),
            // 发丝线2（甲板底）
            hair2.topAnchor.constraint(equalTo: toolbarRow.bottomAnchor),
            hair2.leadingAnchor.constraint(equalTo: leadingAnchor),
            hair2.trailingAnchor.constraint(equalTo: trailingAnchor),
            hair2.heightAnchor.constraint(equalToConstant: 1),
            hair2.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: 同步（活动窗格/位置/布局变化时由 MainWindowController 回灌）

    func updateWorkspaces(titles: [String], active: Int) {
        workspaceTabBar.update(titles: titles, active: active)
    }

    func syncViewMode(_ raw: Int) {
        if viewModeControl.selectedSegment != raw { viewModeControl.selectedSegment = raw }
    }

    func syncLayout(_ layout: PaneLayout) {
        let idx = PaneLayout.allCases.firstIndex(of: layout) ?? 0
        if layoutControl.selectedSegment != idx { layoutControl.selectedSegment = idx }
    }

    /// 导航段 enabled 反映 canGoBack/Forward/Up
    func syncNav(canBack: Bool, canForward: Bool, canUp: Bool) {
        navControl.setEnabled(canBack, forSegment: 0)
        navControl.setEnabled(canForward, forSegment: 1)
        navControl.setEnabled(canUp, forSegment: 2)
    }

    /// 动作钮校验（FG-1：与原工具栏 autovalidate 等价）：AirDrop/废纸篓需选中；终端/任务恒可用
    func validateActions(hasSelection: Bool) {
        airdropButton.isEnabled = hasSelection
        trashButton.isEnabled = hasSelection
        terminalButton.isEnabled = true
        tasksButton.isEnabled = true
    }

    /// 侧栏折叠态：标签行让位红绿灯（§1）
    func setSidebarCollapsed(_ collapsed: Bool) {
        tabRowLeading.constant = collapsed ? Self.trafficLightInset : 0
    }

    // MARK: 动作转发

    @objc private func sidebarClicked() { deckDelegate?.deckToggleSidebar() }

    @objc private func navClicked(_ sender: NSSegmentedControl) {
        switch sender.selectedSegment {
        case 0: deckDelegate?.deckGoBack()
        case 1: deckDelegate?.deckGoForward()
        case 2: deckDelegate?.deckGoUp()
        default: break
        }
    }

    /// 长按导航段弹历史菜单：段 0=后退 / 段 1=前进（段 2 上层无历史，忽略）
    private struct NavHistoryPick { let forward: Bool; let index: Int }

    @objc private func navLongPressed(_ gr: NSPressGestureRecognizer) {
        guard gr.state == .began, navControl.bounds.width > 0 else { return }
        let loc = gr.location(in: navControl)
        let seg = Int(loc.x / (navControl.bounds.width / 3))
        let forward: Bool
        if seg <= 0 { forward = false } else if seg == 1 { forward = true } else { return }
        guard let urls = deckDelegate?.deckHistory(forward: forward), !urls.isEmpty else { return }
        let menu = NSMenu()
        for (i, url) in urls.enumerated() {
            let item = menu.addItem(withTitle: url.path == "/" ? "/" : url.lastPathComponent,
                                    action: #selector(navHistoryPicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = NavHistoryPick(forward: forward, index: i)
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 14, height: 14)
            item.image = icon
        }
        menu.popUp(positioning: nil, at: NSPoint(x: loc.x, y: navControl.bounds.height + 2), in: navControl)
    }

    @objc private func navHistoryPicked(_ sender: NSMenuItem) {
        guard let pick = sender.representedObject as? NavHistoryPick else { return }
        deckDelegate?.deckJumpHistory(forward: pick.forward, index: pick.index)
    }

    @objc private func viewModeClicked(_ sender: NSSegmentedControl) {
        guard let mode = PaneViewMode(rawValue: sender.selectedSegment) else { return }
        deckDelegate?.deckSetViewMode(mode)
    }

    @objc private func layoutClicked(_ sender: NSSegmentedControl) {
        let layouts = PaneLayout.allCases
        guard layouts.indices.contains(sender.selectedSegment) else { return }
        deckDelegate?.deckSetLayout(layouts[sender.selectedSegment])
    }

    // MARK: 窗口拖动 + 双击缩放（自定义标题栏惯例；mouseDownCanMoveWindow=false 以便截获双击）

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        guard let window else { super.mouseDown(with: event); return }
        if event.clickCount == 2 {
            performDoubleClickAction(on: window)
        } else {
            window.performDrag(with: event)  // 系统托管拖动（尊重 Spaces/贴边）
        }
    }

    /// 双击甲板空白 = 系统缩放行为（依系统偏好 AppleActionOnDoubleClick）
    private func performDoubleClickAction(on window: NSWindow) {
        let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
        switch action {
        case "Minimize": window.performMiniaturize(nil)
        case "None": break
        default: window.performZoom(nil)  // Maximize/Zoom（默认）
        }
    }

    // MARK: 工具

    private func buildIconButton(_ button: NSButton, symbol name: String, fallback: String?,
                                 tooltipKey: String, action: Selector, target: AnyObject?) {
        button.image = NSImage.officialSymbol(name, fallback: fallback, accessibility: L10n.t(tooltipKey))
        button.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        button.isBordered = false
        button.bezelStyle = .accessoryBarAction
        button.setButtonType(.momentaryChange)
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = L10n.t(tooltipKey)
        button.target = target
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 24),
            button.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    /// 簇间发丝竖线（20pt 高，separatorColor）
    private func hairlineV() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.separatorColor.cgColor
        v.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            v.widthAnchor.constraint(equalToConstant: 1),
            v.heightAnchor.constraint(equalToConstant: 20),
        ])
        return v
    }

    /// 水平发丝线（NSBox separator，系统语义色）
    private func hairlineH() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}

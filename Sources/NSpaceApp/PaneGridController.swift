import AppKit
import SessionStore

/// 窗格布局（QSpace 12 布局的 v1 子集）
enum PaneLayout: Int, CaseIterable {
    case single = 1     // 单窗格
    case dualH          // 双列（左右）
    case dualV          // 双行（上下）
    case tripleH        // 三列
    case quad           // 四宫格

    var paneCount: Int {
        switch self {
        case .single: 1
        case .dualH, .dualV: 2
        case .tripleH: 3
        case .quad: 4
        }
    }

    /// 本地化名键（菜单/设置窗/注册表共用，避免键散落）
    var titleKey: String {
        switch self {
        case .single: "layout.single"
        case .dualH: "layout.dualH"
        case .dualV: "layout.dualV"
        case .tripleH: "layout.tripleH"
        case .quad: "layout.quad"
        }
    }

    var localizedName: String { L10n.t(titleKey) }

    var symbolName: String {
        switch self {
        case .single: "rectangle"
        case .dualH: "rectangle.split.2x1"
        case .dualV: "rectangle.split.1x2"
        case .tripleH: "rectangle.split.3x1"
        case .quad: "rectangle.split.2x2"
        }
    }
}

/// 窗格网格 + 焦点协调：窗格池懒建、切布局保状态、Tab 循环焦点、活动窗格高亮。
/// 切走的窗格 hidden-not-destroyed（标签/历史/滚动位置全保留）
@MainActor
final class PaneGridController: NSViewController {
    private(set) var layout: PaneLayout = .single
    /// 窗格池：最多 4 个，懒创建，切布局不销毁
    private var pool: [PaneViewController] = []
    private(set) var activePaneIndex = 0
    private let initialDirectory: URL

    /// 文件操作桥（由 MainWindowController 注入后下传各窗格）
    var coordinator: FileOpsCoordinator? {
        didSet { pool.forEach { $0.coordinator = coordinator } }
    }

    var onActiveLocationChange: ((URL) -> Void)?
    /// 活动窗格计数/选中变化上抛（甲板动作按钮 enabled 重验；M17）
    var onActiveStatusChange: (() -> Void)?

    var activePane: PaneViewController { pool[activePaneIndex] }
    var visiblePanes: [PaneViewController] { Array(pool.prefix(layout.paneCount)) }

    init(initialDirectory: URL) {
        self.initialDirectory = initialDirectory
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建 UI，无 xib") }

    override func loadView() {
        view = NSView()
        ensurePanes(count: layout.paneCount)
        rebuildGrid()
    }

    // MARK: 布局切换（⌃⌘1..5 / 工具栏）

    func apply(layout newLayout: PaneLayout) {
        guard newLayout != layout else { return }
        layout = newLayout
        ensurePanes(count: layout.paneCount)
        // 北极星：布局切走的窗格整体挂起（watcher 真停），切回的恢复（mtime 变才重载）
        for (i, pane) in pool.enumerated() {
            if i < layout.paneCount { pane.resumePane() } else { pane.suspendPane() }
        }
        if activePaneIndex >= layout.paneCount { setActivePane(0) }
        rebuildGrid()
        // rebuildGrid 会 removeFromSuperview 掉旧层级：挂在被移除视图上的 firstResponder 会被
        // AppKit 打回窗口本身（不是任何 NSView）——从此键盘全哑，用户得先随便点一下才恢复。
        // 地址栏正在编辑时（firstResponder 是 field editor）最容易撞上。重建后显式把焦点收口。
        view.window?.makeFirstResponder(activePane.focusTarget)
    }

    private func ensurePanes(count: Int) {
        while pool.count < count {
            let index = pool.count
            // 新窗格开在活动窗格的当前位置（QSpace 惯例），首个开初始目录
            let dir = pool.isEmpty ? initialDirectory : activePane.activeTab.browser.current
            let pane = PaneViewController(directory: dir)
            pane.coordinator = coordinator
            pane.onRequestFocus = { [weak self, weak pane] in
                guard let self, let pane, let i = self.pool.firstIndex(where: { $0 === pane }) else { return }
                self.setActivePane(i)
            }
            pane.onLocationChange = { [weak self, weak pane] url in
                guard let self, let pane else { return }
                if pane === self.activePane { self.onActiveLocationChange?(url) }
            }
            pane.onStatusChange = { [weak self, weak pane] in
                guard let self, let pane else { return }
                if pane === self.activePane { self.onActiveStatusChange?() }
            }
            addChild(pane)
            pool.append(pane)
            _ = index
        }
    }

    private var currentGrid: NSView?
    private var needsEqualize = false

    private func rebuildGrid() {
        view.subviews.forEach { $0.removeFromSuperview() }
        let panes = visiblePanes.map(\.view)
        let grid: NSView
        switch layout {
        case .single:
            grid = panes[0]
        case .dualH:
            grid = makeSplit(vertical: true, panes)
        case .dualV:
            grid = makeSplit(vertical: false, panes)
        case .tripleH:
            grid = makeSplit(vertical: true, panes)
        case .quad:
            let top = makeSplit(vertical: true, [panes[0], panes[1]])
            let bottom = makeSplit(vertical: true, [panes[2], panes[3]])
            grid = makeSplit(vertical: false, [top, bottom])
        }
        grid.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: view.topAnchor),
            grid.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        currentGrid = grid
        needsEqualize = true
        refreshActiveHighlight()
        view.needsLayout = true
    }

    /// 等分必须在真实布局尺寸就绪后执行；窗口尺寸未稳定前持续重equalize
    /// （只跑一次会在尺寸后续增长时把空间全给末窗格 → 首行/首列塌陷）
    private var lastLayoutSize: NSSize = .zero

    override func viewDidLayout() {
        super.viewDidLayout()
        guard needsEqualize, let grid = currentGrid,
              grid.bounds.height > 1, grid.bounds.width > 1 else { return }
        equalizeSplits(in: grid)
        if grid.bounds.size == lastLayoutSize {
            needsEqualize = false  // 连续两次布局尺寸一致 = 稳定，交还用户拖拽自由
        }
        lastLayoutSize = grid.bounds.size
    }

    private func makeSplit(vertical: Bool, _ subviews: [NSView]) -> NSSplitView {
        let split = NSSplitView()
        split.isVertical = vertical
        split.dividerStyle = .thin
        // NSSplitView 按子视图当前 frame 比例分配空间；复用窗格带着旧 frame 进来
        // 会导致某行/列塌陷 —— 显式预设等分 frame，比例分配恒 1/n（确定性，无布局时序竞态）
        let n = CGFloat(subviews.count)
        let nominal = NSSize(width: 1200, height: 800)
        for (i, sub) in subviews.enumerated() {
            sub.translatesAutoresizingMaskIntoConstraints = true
            // 必设 [.width,.height]：默认 none 会把残留 frame 转成必需固定尺寸约束，
            // 经约束引擎反推窗口坍缩（视图/布局切换后窗口被改尺寸的真凶，探针点名）
            sub.autoresizingMask = [.width, .height]
            sub.frame = vertical
                ? NSRect(x: CGFloat(i) * nominal.width / n, y: 0,
                         width: nominal.width / n, height: nominal.height)
                : NSRect(x: 0, y: CGFloat(i) * nominal.height / n,
                         width: nominal.width, height: nominal.height / n)
            split.addArrangedSubview(sub)
        }
        split.frame = NSRect(origin: .zero, size: nominal)
        return split
    }

    private func equalizeSplits(in root: NSView) {
        guard let split = root as? NSSplitView else { return }
        let count = split.arrangedSubviews.count
        let total = split.isVertical ? split.bounds.width : split.bounds.height
        guard count > 1, total > 0 else { return }
        let each = (total - CGFloat(count - 1) * split.dividerThickness) / CGFloat(count)
        for i in 1..<count {
            split.setPosition(CGFloat(i) * (each + split.dividerThickness) - split.dividerThickness, ofDividerAt: i - 1)
        }
        for sub in split.arrangedSubviews { equalizeSplits(in: sub) }
    }

    // MARK: 焦点协调

    func setActivePane(_ index: Int) {
        guard index < layout.paneCount else { return }
        let sameAsActive = (index == activePaneIndex)
        activePaneIndex = index
        refreshActiveHighlight()                         // 幂等且廉价：多窗格 restore/首布局着色须恒执行
        view.window?.makeFirstResponder(activePane.focusTarget)
        // 同窗格点击：不重推位置/状态。窗格内选中变化本就经 pane.onStatusChange 更新甲板，
        // 此处再推一次是"改选中前的旧值" → 双刷卡顿（I-33）；跨窗格切换才需要这一推。
        guard !sameAsActive else { return }
        onActiveLocationChange?(activePane.activeTab.browser.current)
        onActiveStatusChange?()
    }

    private func refreshActiveHighlight() {
        // 单窗格不描色（无歧义时不加视觉噪声）；非活动窗格仅多窗格时暗化
        let multi = layout.paneCount > 1
        for (i, pane) in pool.enumerated() {
            let active = multi && i == activePaneIndex
            pane.setActive(active, dimmed: multi && !active)
        }
    }

    /// 外观变更后重刷各窗格描色/暗化（强调色/高亮开关/暗化 alpha 即时生效）
    func refreshTheme() {
        refreshActiveHighlight()
    }

    /// Tab 键循环窗格焦点
    func cycleFocus(backward: Bool = false) {
        let count = layout.paneCount
        guard count > 1 else { return }
        let next = backward
            ? (activePaneIndex - 1 + count) % count
            : (activePaneIndex + 1) % count
        setActivePane(next)
    }

    /// 全部窗格（含隐藏池）应用标签栏显隐
    func setPaneTabBarsVisible(_ visible: Bool) {
        for pane in pool { pane.setTabBarVisible(visible) }
    }

    // MARK: 会话快照/恢复（M11）

    func sessionWindow() -> SessionWindow {
        SessionWindow(layoutRaw: layout.rawValue,
                      panes: visiblePanes.map { $0.sessionPane() },
                      activePaneIndex: activePaneIndex)
    }

    func restoreSession(_ w: SessionWindow) {
        _ = view  // 先强制 loadView（窗格池就位）
        if let l = PaneLayout(rawValue: w.layoutRaw) { apply(layout: l) }
        for (pane, sp) in zip(visiblePanes, w.panes) {
            pane.restoreSession(sp)
        }
        setActivePane(min(max(0, w.activePaneIndex), layout.paneCount - 1))
    }

    // MARK: 菜单命令

    @objc func applyLayout(_ sender: NSMenuItem) {
        guard let layout = PaneLayout(rawValue: sender.tag) else { return }
        apply(layout: layout)
    }
}

extension PaneGridController: @preconcurrency NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(applyLayout(_:)) {
            menuItem.state = menuItem.tag == layout.rawValue ? .on : .off
        }
        return true
    }
}

import AppKit

/// 面包屑地址栏（自绘，不用 NSPathControl——需要 chevron 弹子目录与后续分段拖放）
/// I-37 宽度自适应：不再横向滚动，而是随窗格宽度实时重排——
///   ① 段名超 ~18 字符中部省略（完整名进 toolTip）；
///   ② 放不下时保留根段 + 末尾若干段，中间层级折叠为一个「…」段，点击弹菜单列出全部被折叠层级；
///   ③ resize / 布局切换经 layout() 重算，从「全展示」平滑退化到「逐级折叠」。全层级永远可达。
/// 布局 4pt 标尺；点击空白或 ⌘L 切换到路径编辑器（PathEditorField）
@MainActor
final class BreadcrumbBar: NSView {
    var onNavigate: ((URL) -> Void)?
    var onBeginEditing: (() -> Void)?
    /// 拖文件到分段的投放意图上抛：(urls, 目标祖先目录, ⌥强制复制) → Pane → coordinator
    var onDropFiles: ((_ urls: [URL], _ target: URL, _ forceCopy: Bool) -> Void)?

    /// 单段显示名字符上限：超出则中部省略（完整名进 toolTip）
    private static let maxSegmentChars = 18
    /// 左右内缩（4pt 阶梯）
    private static let edgeInset: CGFloat = 8
    /// chevron 分隔箭头的固定占位宽（4pt 阶梯）。
    /// 16 → 8：段命中盒左右各留的 4pt 余量**从这里让出来**，于是每级总宽
    /// （段字形 + segHitPadX×2 + chevronWidth = 字形 + 16）与改前完全一致，
    /// 折叠阈值不右移。否则同宽度下会少显一层路径（审查实测：dualH 600 窗、
    /// 侧栏折叠、4 层路径，改前全展示、改后退化成折叠）。
    /// 箭头字形实测 7pt，装得进 8pt；且命中盒现在是全高 20pt，
    /// 面积 8×20=160pt² 仍比改前的 16×6.5=104pt² 大 54%。
    private static let chevronWidth: CGFloat = 8
    /// 段命中盒左右各留的余量（4pt 阶梯）：点到名字旁边一点点仍是这一段，不被隔壁 chevron 抢走
    private static let segHitPadX: CGFloat = 4
    /// 段命中宽（纯函数：layout 与自测共用同一口径，不许各算一遍）
    static func segmentHitWidth(glyphWidth: CGFloat) -> CGFloat {
        max(1, glyphWidth) + segHitPadX * 2
    }

    /// 一级路径的完整模型：段按钮 + 其后的下钻 chevron
    private struct Level {
        let url: URL
        let fullTitle: String
        let button: SegmentButton
        let chevron: ChevronButton
    }
    private var levels: [Level] = []
    private let ellipsis = EllipsisButton()

    private(set) var url: URL = FileManager.default.homeDirectoryForCurrentUser

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        ellipsis.onPick = { [weak self] target in self?.onNavigate?(target) }
        ellipsis.isHidden = true
        addSubview(ellipsis)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建 UI，无 xib") }

    func setURL(_ url: URL) {
        self.url = url
        rebuildLevels()
        needsLayout = true
    }

    /// 点击空白区进入编辑模式（QSpace 惯例）
    override func mouseDown(with event: NSEvent) {
        onBeginEditing?()
    }

    // MARK: 段模型构建（URL 变化时）

    private func rebuildLevels() {
        for lvl in levels { lvl.button.removeFromSuperview(); lvl.chevron.removeFromSuperview() }
        levels.removeAll()

        // 按 path 组件正向构建（严禁 deletingLastPathComponent 向上循环——
        // macOS 对 "/" 返回 "/.."，不等于自身，会造成无限循环+内存爆炸）
        var components: [URL] = [URL(fileURLWithPath: "/")]
        var cursor = URL(fileURLWithPath: "/")
        for part in url.standardizedFileURL.path.split(separator: "/") {
            cursor.appendPathComponent(String(part))
            components.append(cursor)
        }

        for (index, segURL) in components.enumerated() {
            let full = index == 0 ? "/" : segURL.lastPathComponent
            let display = Self.truncatedMiddle(full, max: Self.maxSegmentChars)
            let button = SegmentButton(displayTitle: display, fullTitle: full, url: segURL)
            button.onClick = { [weak self] in self?.onNavigate?(segURL) }
            button.onDropFiles = { [weak self] urls, target, forceCopy in
                self?.onDropFiles?(urls, target, forceCopy)
            }
            let chevron = ChevronButton(parentURL: segURL)
            chevron.onPick = { [weak self] child in self?.onNavigate?(child) }
            addSubview(button)
            addSubview(chevron)
            levels.append(Level(url: segURL, fullTitle: full, button: button, chevron: chevron))
        }
    }

    /// 中部省略：段名超 max 字符时保留首尾、中间以「…」替代（"很长很长的…文件夹名"）。
    private static func truncatedMiddle(_ s: String, max: Int) -> String {
        let chars = Array(s)
        guard chars.count > max else { return s }
        let keep = max - 1                    // 让位给「…」
        let head = (keep + 1) / 2
        let tail = keep - head
        return String(chars.prefix(head)) + "…" + String(chars.suffix(tail))
    }

    // MARK: 宽度自适应重排（resize / 布局切换 / URL 变化都经此）

    /// 最近一次实际排布的内容右缘（供自测断言「不溢出」：应 ≤ bounds.width）
    private(set) var lastContentRight: CGFloat = 0
    /// 最近一次被折叠的中间层级（供「…」菜单与自测；根段与可见末段不入内）
    private(set) var collapsedURLs: [URL] = []

    override func layout() {
        super.layout()
        guard !levels.isEmpty else { lastContentRight = 0; collapsedURLs = []; return }

        let h = bounds.height
        let leftInset = Self.edgeInset
        let rightInset = Self.edgeInset
        let avail = bounds.width - leftInset - rightInset
        let chevW = Self.chevronWidth

        func segW(_ i: Int) -> CGFloat { Self.segmentHitWidth(glyphWidth: levels[i].button.intrinsicContentSize.width) }
        // 每级占位 = 段宽 + 其后 chevron
        func levelW(_ i: Int) -> CGFloat { segW(i) + chevW }

        let n = levels.count
        var fullWidth: CGFloat = 0
        for i in 0..<n { fullWidth += levelW(i) }

        // 全部装得下 → 顺序铺开，隐藏「…」
        if fullWidth <= avail {
            ellipsis.isHidden = true
            collapsedURLs = []
            var x = leftInset
            for i in 0..<n {
                place(levels[i].button, at: &x, width: segW(i), height: h)
                place(levels[i].chevron, at: &x, width: chevW, height: h)
            }
            for lvl in levels { lvl.button.isHidden = false; lvl.chevron.isHidden = false }
            lastContentRight = x
            return
        }

        // 需折叠：根段常驻；末尾贪心尽量多留；中间折进「…」段。
        ellipsis.configure()
        let ellW = max(20, ellipsis.intrinsicContentSize.width)

        // 决定可见的末尾起点 tailStart（levels[tailStart ..< n] 全可见）
        // 预算 = 根段(+chev) + 「…」段 + 末尾各级
        let rootCost = levelW(0)
        var tailStart = n - 1
        var tailCost = levelW(n - 1)
        // 至少保留末段；随后从倒数第二段起逐段回收，装得下才纳入（且不吞掉根段位）
        var i = n - 2
        while i >= 1 {
            let cost = levelW(i)
            if rootCost + ellW + tailCost + cost <= avail {
                tailCost += cost
                tailStart = i
                i -= 1
            } else {
                break
            }
        }

        // 布置：根段 → 「…」 → 末尾段们
        var x = leftInset
        // 先全部隐藏，再显式点亮参与排布的
        for lvl in levels { lvl.button.isHidden = true; lvl.chevron.isHidden = true }

        // 「装得下底线」（对抗审查用真实 layout() 实测到的回归）：
        // root + 「…」 + 强制可见的末段这个**种子**本身也可能装不下（窄窗格 + 长末段名）。
        // 旧版把它无条件铺开，于是 lastContentRight 越过 bounds.width，I-37「不溢出」不变量被打破。
        // 段宽 +2×segHitPadX 之后这个阈值被抬高，所以底线必须补上：
        //   ① 种子装不下 → 连根段一起折进「…」（I-37 的「全层级永远可达」由菜单兜住，不丢层级）
        //   ② 逐个按剩余预算 clamp → x 结构上不可能越过 leftInset + avail
        var remaining = avail
        func placeClamped(_ v: NSView, desired: CGFloat) -> Bool {
            guard remaining > 0 else { return false }
            let w = min(desired, remaining)
            place(v, at: &x, width: w, height: h)
            remaining -= w
            return true
        }

        let seedFits = rootCost + ellW + levelW(n - 1) <= avail
        var collapsed: [URL] = []

        if seedFits {
            _ = placeClamped(levels[0].button, desired: segW(0))
            levels[0].button.isHidden = false
            _ = placeClamped(levels[0].chevron, desired: chevW)
            levels[0].chevron.isHidden = false
            collapsed = (1..<tailStart).map { levels[$0].url }
        } else {
            // 根段也放不下：它进折叠菜单（含根，仍然可达）
            collapsed = (0..<max(1, n - 1)).map { levels[$0].url }
        }

        collapsedURLs = collapsed
        ellipsis.collapsedURLs = collapsed
        // 连「…」都放不下时必须真的隐藏它：否则留下一个"可见但未被排布"的旧 frame，
        // 那既是幽灵命中区，也会让 uiTestHasEllipsis 撒谎
        ellipsis.isHidden = !placeClamped(ellipsis, desired: ellW)

        let visibleTailStart = seedFits ? tailStart : n - 1
        for j in visibleTailStart..<n {
            guard placeClamped(levels[j].button, desired: segW(j)) else { break }
            levels[j].button.isHidden = false
            if placeClamped(levels[j].chevron, desired: chevW) {
                levels[j].chevron.isHidden = false
            }
        }
        lastContentRight = x
    }

    /// 放置一个子视图：**frame 就是命中盒**，占满整条 bar 的高度（字形居中交给 cell 自己画）。
    ///
    /// 反面教材（用户报告 bug，v0.19.17）：旧版把 frame 高度收成 intrinsicContentSize.height
    /// 再垂直居中，于是 20pt 的栏里段按钮只有 14pt、chevron 只有 6.5pt，上下都是死区——
    /// 点进死区就穿透到本视图的 mouseDown → onBeginEditing，用户看到的就是
    /// 「要点到文件夹正中心才跳转，偏一点变成输入模式」。
    /// 实测死区占比：段 6/20=30%（换算到 24pt 地址行是 42%）、chevron 13.5/20=68%。
    private func place(_ v: NSView, at x: inout CGFloat, width: CGFloat, height: CGFloat) {
        v.frame = NSRect(x: x, y: 0, width: width, height: height)
        x += width
    }

    // MARK: 自测通道（NSPACE_UITEST；I-37）

    /// 内容右缘（含左内缩），应 ≤ bounds.width（不溢出）
    var uiTestContentRight: CGFloat { lastContentRight }
    /// 是否存在「…」折叠段
    var uiTestHasEllipsis: Bool { !ellipsis.isHidden }
    /// 被折叠的中间层级 URL（「…」菜单来源）
    var uiTestCollapsedURLs: [URL] { collapsedURLs }
    /// 真实构建「…」菜单（与点击弹出同一构建函数）；无折叠返回 nil
    func uiTestEllipsisMenu() -> NSMenu? {
        guard !ellipsis.isHidden else { return nil }
        return ellipsis.buildMenu()
    }
    /// 当前可见的末段（当前目录段）的 toolTip（应 == 完整名）
    var uiTestLastSegmentToolTip: String? { levels.last?.button.toolTip }
    /// 当前可见末段完整名
    var uiTestLastSegmentFullName: String? { levels.last?.fullTitle }

    // ---- 命中盒探针（用户报告"要点正中心才跳转"）----
    // 断言必须打在**命中区**上，不是打在 frame 上：只验 frame 的断言，把 place() 改回
    // 居中矮盒照样能算对数,验不出"点不到"。故这里走 AppKit 自己派发 mouseDown 用的
    // NSView.hitTest(_:)，不复刻。

    /// hitTest 落在哪一类节点上
    enum HitKind: String { case segment, chevron, ellipsis, bar, none }

    /// 在 bar 自身坐标系的一点做**真实** hitTest。
    /// hitTest(_:) 收的是「接收者 superview」坐标系，故先换算上去。
    func uiTestHitKind(at p: NSPoint) -> HitKind {
        guard let sp = superview else { return .none }
        let v = hitTest(convert(p, to: sp))
        if v === self { return .bar }
        if v is SegmentButton { return .segment }
        if v is ChevronButton { return .chevron }
        if v is EllipsisButton { return .ellipsis }
        return v == nil ? .none : .bar
    }

    /// 命中点落在段按钮上则触发它真实的 action 并回报该段 URL；不落在段上返回 nil。
    /// 直调 action 而非合成鼠标事件：NSCell.trackMouse 会开嵌套事件循环，headless 会挂。
    func uiTestActivateSegment(at p: NSPoint) -> URL? {
        guard let sp = superview,
              let b = hitTest(convert(p, to: sp)) as? SegmentButton else { return nil }
        _ = b.target?.perform(b.action, with: b)
        return b.url
    }

    /// 当前可见段的 (URL, frame)（bar 局部坐标）
    var uiTestVisibleSegments: [(url: URL, frame: NSRect)] {
        levels.filter { !$0.button.isHidden }.map { ($0.url, $0.button.frame) }
    }
    /// 当前可见 chevron 的 frame（bar 局部坐标）
    var uiTestVisibleChevronFrames: [NSRect] {
        levels.filter { !$0.chevron.isHidden }.map { $0.chevron.frame }
    }
    /// 可见末段的字形宽（intrinsic）——用于验「命中宽 == 字形宽 + 2×padX」
    var uiTestLastSegmentGlyphWidth: CGFloat? {
        levels.last(where: { !$0.button.isHidden })?.button.intrinsicContentSize.width
    }
    /// 段命中盒左右余量总量（自测口径与产品口径同源）
    static var uiTestSegHitPadTotal: CGFloat { segHitPadX * 2 }
}

/// 路径分段按钮：点击导航 + 文件投放目标（拖文件到分段=投进该祖先目录）
@MainActor
private final class SegmentButton: NSButton {
    let url: URL
    var onClick: (() -> Void)?
    /// 投放回调：(urls, 本分段目录, ⌥强制复制)
    var onDropFiles: ((_ urls: [URL], _ target: URL, _ forceCopy: Bool) -> Void)?

    init(displayTitle: String, fullTitle: String, url: URL) {
        self.url = url
        super.init(frame: .zero)
        self.title = displayTitle
        self.toolTip = fullTitle          // I-37：完整名进 toolTip（截断段悬停可见全名）
        bezelStyle = .accessoryBarAction
        isBordered = false
        font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        contentTintColor = .labelColor
        target = self
        action = #selector(clicked)
        setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        wantsLayer = true
        dropHighlight.cornerRadius = 4
        dropHighlight.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(dropHighlight)
        registerForDraggedTypes([.fileURL])
    }

    /// 投放高亮层：与命中盒**解耦**——命中盒占满 bar 全高（否则上下是死区），
    /// 但高亮不能跟着占满，那样会顶到地址行边缘看着像个色块。
    /// 高亮铺满命中盒的**宽度**（= 字形 + 2×segHitPadX，与真正接受投放的区域同宽——
    /// 这是刻意的，高亮该指示「投这里会落到哪一段」），只上下各内缩 2pt 避开地址行边缘。
    private let dropHighlight = CALayer()
    /// 高亮相对命中盒的上下内缩（≤2pt 视错觉修正档，grid-lint 豁免）
    private static let dropHighlightInsetY: CGFloat = 2

    override func layout() {
        super.layout()
        dropHighlight.frame = bounds.insetBy(dx: 0, dy: Self.dropHighlightInsetY)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建 UI，无 xib") }

    @objc private func clicked() { onClick?() }

    // MARK: 投放目标（语义同列表：默认同卷移动/跨卷复制、⌥ 复制）

    private func dragOperation(_ info: any NSDraggingInfo) -> NSDragOperation {
        guard let urls = info.draggingPasteboard.readObjects(
                forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return [] }
        // 拒绝把目录投进它自己/子孙
        guard urls.allSatisfy({ !FileOpsCoordinator.isSelfOrDescendant(destination: url, ofSource: $0) }) else {
            return []
        }
        let forceCopy = info.draggingSourceOperationMask == .copy
        // 全部来源已在本分段目录：移动是无操作 → 拒绝（⌥ 复制放行）
        let destPath = url.standardizedFileURL.path
        if !forceCopy, urls.allSatisfy({ $0.standardizedFileURL.deletingLastPathComponent().path == destPath }) {
            return []
        }
        if forceCopy { return .copy }
        return urls.allSatisfy({ FileOpsCoordinator.isSameVolume($0, url) }) ? .move : .copy
    }

    private func setDropHighlight(_ on: Bool) {
        dropHighlight.backgroundColor = on
            ? Theme.accent.withAlphaComponent(0.10).cgColor
            : NSColor.clear.cgColor
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let op = dragOperation(sender)
        setDropHighlight(op != [])
        return op
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dragOperation(sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        setDropHighlight(false)
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        setDropHighlight(false)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        dragOperation(sender) != []
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        setDropHighlight(false)
        guard let urls = sender.draggingPasteboard.readObjects(
                forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        onDropFiles?(urls, url, sender.draggingSourceOperationMask == .copy)
        return true
    }
}

/// 分段间箭头：点击弹出该级子目录菜单（懒构建）
@MainActor
private final class ChevronButton: NSButton {
    let parentURL: URL
    var onPick: ((URL) -> Void)?

    init(parentURL: URL) {
        self.parentURL = parentURL
        super.init(frame: .zero)
        title = ""
        image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: L10n.t("addressbar.subfolders"))
        symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        contentTintColor = .tertiaryLabelColor
        isBordered = false
        target = self
        action = #selector(showMenu)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建 UI，无 xib") }

    @objc private func showMenu() {
        let menu = NSMenu()
        let fm = FileManager.default
        let children = (try? fm.contentsOfDirectory(at: parentURL,
                                                    includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                                                    options: [.skipsHiddenFiles])) ?? []
        let dirs = children
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]))
                .map { ($0.isDirectory ?? false) && !($0.isPackage ?? false) } ?? false }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        if dirs.isEmpty {
            let item = menu.addItem(withTitle: L10n.t("addressbar.noSubfolders"), action: nil, keyEquivalent: "")
            item.isEnabled = false
        }
        for dir in dirs {
            let item = menu.addItem(withTitle: dir.lastPathComponent, action: #selector(pick(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = dir
            item.image = NSWorkspace.shared.icon(for: .folder)
            item.image?.size = NSSize(width: 14, height: 14)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 2), in: self)
    }

    @objc private func pick(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        onPick?(url)
    }
}

/// 折叠段「…」：代表被隐藏的中间层级；点击弹菜单列出全部被折叠层级（带层级缩进），点任意项即导航。
/// 保证「深层级永远可达」——即便窗格再窄，全部祖先都躺在这个菜单里。
@MainActor
private final class EllipsisButton: NSButton {
    var onPick: ((URL) -> Void)?
    var collapsedURLs: [URL] = []

    init() {
        super.init(frame: .zero)
        isBordered = false
        contentTintColor = .secondaryLabelColor
        target = self
        action = #selector(showMenu)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建 UI，无 xib") }

    /// 官方 ellipsis 符号，取不到则纯文字「…」兜底（§6.1 官方符号铁律 + 回退）
    func configure() {
        if let img = NSImage.officialSymbol("ellipsis",
                                            accessibility: L10n.t("addressbar.collapsedLevels")) {
            image = img
            symbolConfiguration = .init(pointSize: 11, weight: .semibold)
            title = ""
        } else {
            image = nil
            title = "…"
            font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        }
        toolTip = L10n.t("addressbar.collapsedLevels")
    }

    /// 构建折叠层级菜单（点击弹出与自测共用）：按路径顺序，带层级缩进；点项即导航。
    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        if collapsedURLs.isEmpty {
            let item = menu.addItem(withTitle: L10n.t("addressbar.noSubfolders"), action: nil, keyEquivalent: "")
            item.isEnabled = false
            return menu
        }
        for (i, dir) in collapsedURLs.enumerated() {
            let item = menu.addItem(withTitle: dir.lastPathComponent,
                                    action: #selector(pick(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = dir
            item.indentationLevel = i          // 层级缩进（路径越深缩进越大）
            item.image = NSWorkspace.shared.icon(for: .folder)
            item.image?.size = NSSize(width: 14, height: 14)
        }
        return menu
    }

    @objc private func showMenu() {
        buildMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 2), in: self)
    }

    @objc private func pick(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        onPick?(url)
    }
}

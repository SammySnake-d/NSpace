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
    /// chevron 分隔箭头的固定占位宽（4pt 阶梯）
    private static let chevronWidth: CGFloat = 16

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

        func segW(_ i: Int) -> CGFloat { max(1, levels[i].button.intrinsicContentSize.width) }
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

        place(levels[0].button, at: &x, width: segW(0), height: h)
        levels[0].button.isHidden = false
        place(levels[0].chevron, at: &x, width: chevW, height: h)
        levels[0].chevron.isHidden = false

        collapsedURLs = (1..<tailStart).map { levels[$0].url }
        ellipsis.collapsedURLs = collapsedURLs
        ellipsis.isHidden = false
        place(ellipsis, at: &x, width: ellW, height: h)

        for j in tailStart..<n {
            place(levels[j].button, at: &x, width: segW(j), height: h)
            levels[j].button.isHidden = false
            place(levels[j].chevron, at: &x, width: chevW, height: h)
            levels[j].chevron.isHidden = false
        }
        lastContentRight = x
    }

    /// 垂直居中放置一个子视图，并推进游标
    private func place(_ v: NSView, at x: inout CGFloat, width: CGFloat, height: CGFloat) {
        let vh = min(max(1, v.intrinsicContentSize.height), height)
        v.frame = NSRect(x: x, y: ((height - vh) / 2).rounded(), width: width, height: vh)
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
        layer?.cornerRadius = 4
        registerForDraggedTypes([.fileURL])
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
        layer?.backgroundColor = on
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

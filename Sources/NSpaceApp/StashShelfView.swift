import AppKit
import StashStore

/// 暂存架专区（QSpace 式堆叠牌堆，M14/M16/M17）：B2 hover-reveal——
/// 常态只见牌堆 + 计数药丸（居中）；悬停 150ms 底部浮出动作条（overlay 浮层，不改布局）；
/// 拖拽悬停显示 accent 发丝内圈投放高亮。隐性语义：操作零文字，官方 SF Symbol + tooltip。
@MainActor
final class StashShelfView: NSView {
    private(set) weak var controller: StashShelfController?

    private let emptyIcon = NSImageView()
    private let emptyLabel = NSTextField(labelWithString: L10n.t("stash.empty"))
    private let stackPile = StashPileView()
    private let countButton = NSButton()
    private let contentGroup = NSStackView()
    private let dropCatcher = StashDropCatcher()
    /// hover 浮出的动作条（overlay：frame 定位，不入 Auto Layout 主链，不改布局——FG-4 空间防抖）
    private let floatBar = NSVisualEffectView()
    private let floatButtons = NSStackView()
    /// 拖拽投放高亮：accent 发丝内圈（frame 定位的 overlay 环）
    private let ringView = NSView()
    private var heightConstraint: NSLayoutConstraint?
    private var hoverTimer: Timer?
    private var tracking: NSTrackingArea?

    /// 恒定高度（空/满一致不跳变）：牌堆区视觉稳定居中（QSpace 规格）
    private static let emptyHeight: CGFloat = 148
    private static let filledHeight: CGFloat = 148

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        registerForDraggedTypes([.fileURL])

        emptyIcon.image = NSImage.officialSymbol("tray.and.arrow.down",
                                                 accessibility: L10n.t("sidebar.stash"))
        emptyIcon.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        emptyIcon.contentTintColor = .tertiaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 11)
        emptyLabel.textColor = .tertiaryLabelColor

        // 计数药丸："N ⌄" / "名称 ⌄"（10% accent 浅底、tabular-nums）；点击=逐项管理菜单
        countButton.bezelStyle = .accessoryBarAction
        countButton.isBordered = false
        countButton.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        countButton.imagePosition = .imageTrailing
        countButton.image = NSImage.officialSymbol("chevron.down", accessibility: L10n.t("stash.manage"))
        countButton.symbolConfiguration = .init(pointSize: 8, weight: .semibold)
        countButton.contentTintColor = .labelColor
        countButton.toolTip = L10n.t("stash.manage")
        countButton.target = self
        countButton.action = #selector(showManageMenu(_:))
        countButton.wantsLayer = true
        countButton.layer?.cornerRadius = 8

        // 牌堆列（堆 + 计数药丸）——常态唯一可见组，148pt 区内居中
        contentGroup.orientation = .vertical
        contentGroup.spacing = 2
        contentGroup.alignment = .centerX
        contentGroup.addArrangedSubview(stackPile)
        contentGroup.addArrangedSubview(countButton)

        for sub in [emptyIcon, emptyLabel, contentGroup] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            addSubview(sub)
        }

        // hover 浮条（overlay 材质 + 发丝框 + 阴影，五钮 20×20 间距 4：拷贝/移动/AirDrop/清空/更多）
        buildFloatBar()

        // accent 发丝内圈（拖拽悬停投放高亮；frame 定位）
        ringView.wantsLayer = true
        ringView.layer?.borderWidth = 1
        ringView.layer?.cornerRadius = 8
        ringView.isHidden = true
        addSubview(ringView)
        // accent 相关三处 layer 色（药丸底 / 投放环边框 / 环底）集中一次设置，
        // 并在主题广播 / 明暗切换时重解析——原先在 init 一次性取 cgColor，运行期改强调色/外观不刷新。
        applyAccentColors()
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged),
                                               name: .nspaceThemeChanged, object: nil)

        // 顶层透明捕手（最后添加=z序最前）：拖放目标查找按注册视图进行、不受 hitTest 影响，
        // 单点全域接管；hitTest=nil 让点击/hover 穿透到按钮/牌堆
        dropCatcher.shelf = self
        dropCatcher.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dropCatcher)
        NSLayoutConstraint.activate([
            dropCatcher.topAnchor.constraint(equalTo: topAnchor),
            dropCatcher.bottomAnchor.constraint(equalTo: bottomAnchor),
            dropCatcher.leadingAnchor.constraint(equalTo: leadingAnchor),
            dropCatcher.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        let height = heightAnchor.constraint(equalToConstant: Self.emptyHeight)
        heightConstraint = height
        NSLayoutConstraint.activate([
            height,
            // 空态：图标+文字整体居中（恒高区内视觉稳定）
            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor, constant: 12),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            emptyIcon.trailingAnchor.constraint(equalTo: emptyLabel.leadingAnchor, constant: -8),
            emptyIcon.centerYAnchor.constraint(equalTo: emptyLabel.centerYAnchor),
            // 牌堆组整体居中（随侧栏宽度自适应，无硬编码偏移；牌堆可放大 112×100）
            contentGroup.centerXAnchor.constraint(equalTo: centerXAnchor),
            contentGroup.centerYAnchor.constraint(equalTo: centerYAnchor),
            contentGroup.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
            stackPile.widthAnchor.constraint(equalToConstant: 112),
            stackPile.heightAnchor.constraint(equalToConstant: 100),
        ])
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建 UI，无 xib") }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// accent 三处 layer 色集中设置（外观感知：controlAccentColor 随明暗解析）
    private func applyAccentColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let accent = Theme.accent
            countButton.layer?.backgroundColor = accent.withAlphaComponent(0.10).cgColor
            ringView.layer?.borderColor = accent.cgColor
            ringView.layer?.backgroundColor = accent.withAlphaComponent(0.06).cgColor
        }
    }

    @objc private func themeChanged() { applyAccentColors() }

    /// 系统明暗切换：controlAccentColor 等外观相关色需重解析
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAccentColors()
    }

    /// hover 浮条（overlay：所有子钮 frame 由自身 Auto Layout 决定，但 floatBar 本身 frame 定位）
    private func buildFloatBar() {
        floatBar.material = .menu
        floatBar.blendingMode = .withinWindow
        floatBar.state = .active
        floatBar.wantsLayer = true
        floatBar.layer?.cornerRadius = 8
        floatBar.layer?.borderWidth = 1
        floatBar.layer?.borderColor = NSColor.separatorColor.cgColor
        floatBar.shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.28)
            s.shadowBlurRadius = 8
            s.shadowOffset = NSSize(width: 0, height: -1)
            return s
        }()
        floatBar.isHidden = true
        floatBar.translatesAutoresizingMaskIntoConstraints = true  // overlay：不入 Auto Layout 主链

        // 五钮：拷贝/移动/AirDrop/清空/更多（§6.1 官方符号；20×20）
        let specs: [(String, String?, String, Selector, Int)] = [
            ("doc.on.doc", nil, "stash.copyHere", #selector(performAction(_:)), StashAction.copyHere.tag),
            ("arrow.forward.square", nil, "stash.moveHere", #selector(performAction(_:)), StashAction.moveHere.tag),
            ("airdrop", "dot.radiowaves.left.and.right", "stash.airdrop", #selector(performAction(_:)), StashAction.airdrop.tag),
            ("trash", nil, "stash.clear", #selector(clearAll(_:)), 0),
            ("ellipsis.circle", nil, "stash.manage", #selector(showManageMenuFromButton(_:)), 0),
        ]
        for (symbol, fallback, key, action, tag) in specs {
            let button = NSButton()
            button.image = NSImage.officialSymbol(symbol, fallback: fallback, accessibility: L10n.t(key))
            button.symbolConfiguration = .init(pointSize: 12, weight: .medium)
            button.isBordered = false
            button.contentTintColor = .secondaryLabelColor
            button.toolTip = L10n.t(key)
            button.target = self
            button.action = action
            button.tag = tag
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 20),
                button.heightAnchor.constraint(equalToConstant: 20),
            ])
            floatButtons.addArrangedSubview(button)
        }
        floatButtons.orientation = .horizontal
        floatButtons.alignment = .centerY
        floatButtons.spacing = 4
        floatButtons.translatesAutoresizingMaskIntoConstraints = false
        floatBar.addSubview(floatButtons)
        NSLayoutConstraint.activate([
            floatButtons.topAnchor.constraint(equalTo: floatBar.topAnchor, constant: 4),
            floatButtons.bottomAnchor.constraint(equalTo: floatBar.bottomAnchor, constant: -4),
            floatButtons.leadingAnchor.constraint(equalTo: floatBar.leadingAnchor, constant: 8),
            floatButtons.trailingAnchor.constraint(equalTo: floatBar.trailingAnchor, constant: -8),
        ])
        addSubview(floatBar)  // 加为子视图但 frame 定位（不入主链）
    }

    /// 控制器注入（幂等）：接管 onChange 驱动本区刷新
    func attach(_ controller: StashShelfController) {
        guard self.controller !== controller else { return }
        self.controller = controller
        controller.onChange = { [weak self] in self?.refresh() }
        controller.start()
    }

    // MARK: UISelfTest 度量入口（§6.3）
    /// 常态动作条隐藏（hover 才浮出）
    var actionBarHidden: Bool { floatBar.isHidden }
    /// 浮条为 overlay（frame 定位，不参与 Auto Layout 主链）
    var actionBarIsOverlay: Bool { floatBar.translatesAutoresizingMaskIntoConstraints }
    /// I-07 回归探针：填充态 contentGroup 相对本区中心的水平偏移（|·|≤2pt 视为居中）
    var contentGroupCenterOffsetX: CGFloat {
        guard !contentGroup.isHidden else { return 0 }
        layoutSubtreeIfNeeded()
        return contentGroup.frame.midX - bounds.midX
    }

    private func refresh() {
        let items = controller?.items ?? []
        let empty = items.isEmpty
        emptyIcon.isHidden = !empty
        emptyLabel.isHidden = !empty
        contentGroup.isHidden = empty
        heightConstraint?.constant = empty ? Self.emptyHeight : Self.filledHeight
        if empty { hideFloatBar() }

        guard let controller, !empty else { return }
        let resolved: [(item: StashItem, url: URL?)] = items.map { ($0, controller.store.resolve($0)) }
        stackPile.configure(urls: resolved.map(\.url))
        stackPile.onDragAll = { [weak self] in self?.allResolvedURLs() ?? [] }
        // 单项显示名称，多项显示数量（QSpace 惯例）
        if resolved.count == 1 {
            countButton.title = resolved[0].url?.lastPathComponent ?? L10n.t("stash.missing")
        } else {
            countButton.title = String(resolved.count)
        }
    }

    private func allResolvedURLs() -> [URL] {
        guard let controller else { return [] }
        return controller.items.compactMap { controller.store.resolve($0) }
    }

    // MARK: overlay 定位（floatBar 底部居中 / ringView 内嵌）——不影响主链布局

    override func layout() {
        super.layout()
        ringView.frame = bounds.insetBy(dx: 4, dy: 4)
        let barSize = floatBar.fittingSize
        let w = max(barSize.width, 132)
        let h = max(barSize.height, 28)
        floatBar.frame = NSRect(x: (bounds.width - w) / 2,
                                y: 8,
                                width: w, height: h)
    }

    // MARK: hover-reveal（悬停 150ms 浮出，移出即隐；拖拽期间不浮出）

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        scheduleFloatBar()
    }

    override func mouseExited(with event: NSEvent) {
        hideFloatBar()
    }

    private func scheduleFloatBar() {
        guard !(controller?.items.isEmpty ?? true) else { return }  // 空态无动作
        hoverTimer?.invalidate()
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, !(self.controller?.items.isEmpty ?? true), self.ringView.isHidden else { return }
                self.floatBar.isHidden = false
            }
        }
    }

    private func hideFloatBar() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        floatBar.isHidden = true
    }

    // MARK: "N ⌄" 条目管理菜单

    @objc private func showManageMenu(_ sender: NSButton) {
        guard let controller else { return }
        let menu = NSMenu()
        for item in controller.items {
            let url = controller.store.resolve(item)
            let row = NSMenuItem(title: url?.lastPathComponent ?? L10n.t("stash.missing"),
                                 action: nil, keyEquivalent: "")
            if let url {
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                icon.size = NSSize(width: 16, height: 16)
                row.image = icon
            }
            let sub = NSMenu()
            let remove = sub.addItem(withTitle: L10n.t("stash.remove"),
                                     action: #selector(removeOne(_:)), keyEquivalent: "")
            remove.target = self
            remove.representedObject = item.id
            row.submenu = sub
            menu.addItem(row)
        }
        menu.addItem(.separator())
        let clear = menu.addItem(withTitle: L10n.t("stash.clear"),
                                 action: #selector(clearAll(_:)), keyEquivalent: "")
        clear.target = self
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    @objc private func removeOne(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        controller?.remove(ids: [id])
    }

    // MARK: 操作（浮条图标钮）

    @objc private func performAction(_ sender: NSButton) {
        guard let action = StashAction.from(tag: sender.tag) else { return }
        controller?.perform(action)
    }

    @objc private func clearAll(_ sender: Any?) {
        controller?.clearAll()
    }

    /// "更多"钮：弹条目管理菜单（与 "N ⌄" 同源）
    @objc private func showManageMenuFromButton(_ sender: NSButton) {
        showManageMenu(sender)
    }

    // MARK: 整区投放目标（文件与目录都收；子视图统一转发到这三个方法）

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // 挂进 sidebar 视觉层级后重注册，防外层容器重建吞掉注册
        registerForDraggedTypes([.fileURL])
    }

    func dropHighlight(_ on: Bool) {
        // 拖拽悬停：隐浮条，显 accent 发丝内圈（原位反馈，不改布局）
        if on { hideFloatBar() }
        ringView.isHidden = !on
    }

    func dropOperation(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let has = sender.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        return has ? .copy : []
    }

    func acceptDrop(_ sender: any NSDraggingInfo) -> Bool {
        dropHighlight(false)
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
            !urls.isEmpty else { return false }
        controller?.add(urls)
        return true
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let op = dropOperation(sender)
        dropHighlight(op != [])
        return op
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dropOperation(sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        dropHighlight(false)
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        dropHighlight(false)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        acceptDrop(sender)
    }
}

extension StashAction {
    var tag: Int {
        switch self {
        case .copyHere: 1
        case .moveHere: 2
        case .airdrop: 3
        }
    }

    static func from(tag: Int) -> StashAction? {
        switch tag {
        case 1: .copyHere
        case 2: .moveHere
        case 3: .airdrop
        default: nil
        }
    }
}

/// 牌堆视图：最多 3 层图标错位堆叠（最新在顶）；拖动 = 整摞文件一起拖出
@MainActor
private final class StashPileView: NSView {
    private var layers: [NSImageView] = []
    /// 拖拽时取整摞 URL（延迟解析保持最新）
    var onDragAll: (() -> [URL])?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])  // 牌堆区域的投放转发给专区（防子视图遮蔽父级）
        for _ in 0..<3 {
            let iv = NSImageView()
            iv.imageScaling = .scaleProportionallyUpOrDown
            iv.unregisterDraggedTypes()      // 图像视图绝不自收拖放
            iv.translatesAutoresizingMaskIntoConstraints = false
            addSubview(iv)
            layers.append(iv)
        }
    }

    private var shelf: StashShelfView? { superview?.superview as? StashShelfView }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let op = shelf?.dropOperation(sender) ?? []
        shelf?.dropHighlight(op != [])
        return op
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        shelf?.dropOperation(sender) ?? []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        shelf?.dropHighlight(false)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        shelf?.acceptDrop(sender) ?? false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建 UI，无 xib") }

    override func layout() {
        super.layout()
        // 错位堆叠：底层往左上偏 6pt/层，顶层居中（macOS 拖拽堆惯例；牌堆放大到 ~112×100）
        let size: CGFloat = 80
        let visibleLayers = layers.filter { !$0.isHidden }
        for (pos, iv) in visibleLayers.enumerated() {
            let depth = CGFloat(visibleLayers.count - 1 - pos)  // 顶层（最后）depth=0
            iv.frame = NSRect(x: (bounds.width - size) / 2 - depth * 6,
                              y: (bounds.height - size) / 2 + depth * 6 - 6,
                              width: size, height: size)
        }
    }

    /// urls 顺序 = 入架顺序；取最后 3 个，最新在顶层
    func configure(urls: [URL?]) {
        let tail = urls.suffix(3)
        for (i, iv) in layers.enumerated() {
            let idx = tail.count - (layers.count - i)  // 对齐尾部
            if idx >= 0, let url = Array(tail)[idx] {
                let img = NSWorkspace.shared.icon(forFile: url.path)
                img.size = NSSize(width: 80, height: 80)
                iv.image = img
                iv.isHidden = false
            } else if idx >= 0 {
                iv.image = NSImage.officialSymbol("questionmark.square.dashed",
                                                  accessibility: L10n.t("stash.missing"))
                iv.isHidden = false
            } else {
                iv.isHidden = true
            }
        }
        needsLayout = true
        toolTip = L10n.t("stash.dragHint")
    }

    // 拖动牌堆 = 整摞拖出（每项一个 NSDraggingItem，帧错位成堆叠视觉）
    override func mouseDragged(with event: NSEvent) {
        let urls = onDragAll?() ?? []
        guard !urls.isEmpty else { return }
        let items = urls.enumerated().map { (i, url) -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            let offset = CGFloat(min(i, 3)) * 5
            item.setDraggingFrame(NSRect(x: bounds.midX - 32 + offset, y: bounds.midY - 32 + offset,
                                         width: 64, height: 64), contents: icon)
            return item
        }
        beginDraggingSession(with: items, event: event, source: self)
    }
}

extension StashPileView: NSDraggingSource {
    nonisolated func draggingSession(_ session: NSDraggingSession,
                                     sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .move, .generic]
    }
}


/// 暂存架拖放捕手：盖满专区、注册 fileURL；普通鼠标事件穿透（hitTest=nil），
/// 拖放目标查找按注册视图进行、不受 hitTest 影响——单点接管根治子视图吞冒泡
@MainActor
final class StashDropCatcher: NSView {
    weak var shelf: StashShelfView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建 UI，无 xib") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let op = shelf?.dropOperation(sender) ?? []
        shelf?.dropHighlight(op != [])
        return op
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        shelf?.dropOperation(sender) ?? []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        shelf?.dropHighlight(false)
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        shelf?.dropHighlight(false)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        shelf?.acceptDrop(sender) ?? false
    }
}

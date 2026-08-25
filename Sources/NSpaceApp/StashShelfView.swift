import AppKit
import StashStore

/// 暂存架专区（QSpace 式堆叠牌堆，M14/M16）：多项叠成一摞 + "N ⌄" 下拉管理 + 纯图标操作条。
/// 拖动牌堆 = 整摞文件一起拖出；隐性语义：操作零文字，图标 + tooltip。
@MainActor
final class StashShelfView: NSView {
    private(set) weak var controller: StashShelfController?

    private let titleLabel = NSTextField(labelWithString: L10n.t("sidebar.stash"))
    private let emptyIcon = NSImageView()
    private let emptyLabel = NSTextField(labelWithString: L10n.t("stash.empty"))
    private let stackPile = StashPileView()
    private let countButton = NSButton()
    private let actionsStack = NSStackView()
    private let dropCatcher = StashDropCatcher()
    private var heightConstraint: NSLayoutConstraint?

    /// 空态 56pt（内联提示行），有货 176pt——最大化利用空间（用户点名占空比）
    private static let emptyHeight: CGFloat = 56
    private static let filledHeight: CGFloat = 176

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        registerForDraggedTypes([.fileURL])

        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor

        emptyIcon.image = NSImage(systemSymbolName: "tray.and.arrow.down",
                                  accessibilityDescription: L10n.t("sidebar.stash"))
        emptyIcon.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        emptyIcon.contentTintColor = .tertiaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 11)
        emptyLabel.textColor = .tertiaryLabelColor

        // "N ⌄" / "名称 ⌄"：点击弹出条目管理菜单（隐性语义：数字即入口）
        countButton.bezelStyle = .accessoryBarAction
        countButton.isBordered = false
        countButton.font = .systemFont(ofSize: 12, weight: .medium)
        countButton.imagePosition = .imageTrailing
        countButton.image = NSImage(systemSymbolName: "chevron.down",
                                    accessibilityDescription: L10n.t("stash.manage"))
        countButton.symbolConfiguration = .init(pointSize: 8, weight: .semibold)
        countButton.contentTintColor = .labelColor
        countButton.toolTip = L10n.t("stash.manage")
        countButton.target = self
        countButton.action = #selector(showManageMenu(_:))

        // 纯图标操作条（竖排；FG-1：空暂存架时隐藏）
        actionsStack.orientation = .vertical
        actionsStack.spacing = 10
        actionsStack.alignment = .centerX
        let actions: [(String, String, StashAction?)] = [
            ("doc.on.doc", "stash.copyHere", .copyHere),
            ("arrow.right.square", "stash.moveHere", .moveHere),
            ("dot.radiowaves.left.and.right", "stash.airdrop", .airdrop),
            ("trash", "stash.clear", nil),  // nil = 清空
        ]
        for (symbol, key, action) in actions {
            let button = NSButton()
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: L10n.t(key))
            button.symbolConfiguration = .init(pointSize: 14, weight: .medium)
            button.isBordered = false
            button.contentTintColor = .secondaryLabelColor
            button.toolTip = L10n.t(key)  // 隐性语义 + 微 tooltip
            button.target = self
            if let action {
                button.action = #selector(performAction(_:))
                button.tag = action.tag
            } else {
                button.action = #selector(clearAll(_:))
            }
            actionsStack.addArrangedSubview(button)
            button.widthAnchor.constraint(equalToConstant: 32).isActive = true
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        }

        for sub in [titleLabel, emptyIcon, emptyLabel, stackPile, countButton, actionsStack] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            addSubview(sub)
        }
        // 顶层透明捕手（最后添加=z序最前）：本系统上未注册子视图会吞拖放冒泡，
        // 逐个转发不彻底——改为单点全域接管；hitTest=nil 让点击穿透到按钮/牌堆
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
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),

            // 空态内联一行：图标+文字（56pt 高占空比最小化）
            emptyIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            emptyIcon.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 6),
            emptyLabel.leadingAnchor.constraint(equalTo: emptyIcon.trailingAnchor, constant: 6),
            emptyLabel.centerYAnchor.constraint(equalTo: emptyIcon.centerYAnchor),

            // 牌堆居中（给右侧操作条留位），计数钮居其下
            stackPile.centerXAnchor.constraint(equalTo: centerXAnchor, constant: -12),
            stackPile.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
            stackPile.widthAnchor.constraint(equalToConstant: 96),
            stackPile.heightAnchor.constraint(equalToConstant: 92),
            countButton.centerXAnchor.constraint(equalTo: stackPile.centerXAnchor),
            countButton.topAnchor.constraint(equalTo: stackPile.bottomAnchor, constant: 4),

            actionsStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            actionsStack.centerYAnchor.constraint(equalTo: stackPile.centerYAnchor),
        ])
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建 UI，无 xib") }

    /// 控制器注入（幂等）：接管 onChange 驱动本区刷新
    func attach(_ controller: StashShelfController) {
        guard self.controller !== controller else { return }
        self.controller = controller
        controller.onChange = { [weak self] in self?.refresh() }
        controller.start()
    }

    private func refresh() {
        let items = controller?.items ?? []
        let empty = items.isEmpty
        emptyIcon.isHidden = !empty
        emptyLabel.isHidden = !empty
        stackPile.isHidden = empty
        countButton.isHidden = empty
        actionsStack.isHidden = empty
        heightConstraint?.constant = empty ? Self.emptyHeight : Self.filledHeight

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

    // MARK: 操作（图标条）

    @objc private func performAction(_ sender: NSButton) {
        guard let action = StashAction.from(tag: sender.tag) else { return }
        controller?.perform(action)
    }

    @objc private func clearAll(_ sender: Any?) {
        controller?.clearAll()
    }

    // MARK: 整区投放目标（文件与目录都收；子视图统一转发到这三个方法）

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // 挂进 sidebar 视觉层级后重注册，防外层容器重建吞掉注册
        registerForDraggedTypes([.fileURL])
    }

    func dropHighlight(_ on: Bool) {
        layer?.backgroundColor = on
            ? NSColor.controlAccentColor.withAlphaComponent(0.10).cgColor
            : NSColor.clear.cgColor
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

    private var shelf: StashShelfView? { superview as? StashShelfView }

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
        // 错位堆叠：底层往左上偏 6pt/层，顶层居中（macOS 拖拽堆惯例）
        let size: CGFloat = 72
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
                img.size = NSSize(width: 72, height: 72)
                iv.image = img
                iv.isHidden = false
            } else if idx >= 0 {
                iv.image = NSImage(systemSymbolName: "questionmark.square.dashed",
                                   accessibilityDescription: L10n.t("stash.missing"))
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

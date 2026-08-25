import AppKit
import StashStore

/// 暂存架专区（QSpace 式，M14）：侧栏顶部独立区域——大图标卡片 + 纯图标操作条。
/// 隐性语义原则：操作零文字，图标 + tooltip（30ms 识别 vs 300ms 阅读）。
/// 整区为投放目标；卡片可拖出；权威状态经 StashShelfController → StashStore。
@MainActor
final class StashShelfView: NSView {
    private(set) weak var controller: StashShelfController?

    private let titleLabel = NSTextField(labelWithString: L10n.t("sidebar.stash"))
    private let emptyIcon = NSImageView()
    private let emptyLabel = NSTextField(labelWithString: L10n.t("stash.empty"))
    private let cardsScroll = NSScrollView()
    private let cardsStack = NSStackView()
    private let actionsStack = NSStackView()
    private var heightConstraint: NSLayoutConstraint?

    /// 空态 88pt，有货 224pt（QSpace 规格：大图标卡片要有真实呼吸空间）
    private static let emptyHeight: CGFloat = 88
    private static let filledHeight: CGFloat = 224

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        registerForDraggedTypes([.fileURL])

        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor

        emptyIcon.image = NSImage(systemSymbolName: "tray.and.arrow.down",
                                  accessibilityDescription: L10n.t("sidebar.stash"))
        emptyIcon.symbolConfiguration = .init(pointSize: 22, weight: .light)
        emptyIcon.contentTintColor = .tertiaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 11)
        emptyLabel.textColor = .tertiaryLabelColor

        cardsStack.orientation = .horizontal
        cardsStack.spacing = 8
        cardsStack.alignment = .centerY
        cardsStack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 4)
        cardsScroll.documentView = cardsStack
        // documentView 用 AutoLayout 必须钉边到 contentView，否则 frame 恒零（卡片全不可见的元凶）
        cardsStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            cardsStack.topAnchor.constraint(equalTo: cardsScroll.contentView.topAnchor),
            cardsStack.bottomAnchor.constraint(equalTo: cardsScroll.contentView.bottomAnchor),
            cardsStack.leadingAnchor.constraint(equalTo: cardsScroll.contentView.leadingAnchor),
            cardsStack.trailingAnchor.constraint(greaterThanOrEqualTo: cardsScroll.contentView.trailingAnchor),
            cardsStack.heightAnchor.constraint(equalTo: cardsScroll.contentView.heightAnchor),
        ])
        cardsScroll.drawsBackground = false
        cardsScroll.hasHorizontalScroller = true
        cardsScroll.hasVerticalScroller = false
        cardsScroll.autohidesScrollers = true
        cardsScroll.verticalScrollElasticity = .none

        // 纯图标操作条（竖排；FG-1：空暂存架时隐藏）
        actionsStack.orientation = .vertical
        actionsStack.spacing = 12
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
            button.widthAnchor.constraint(equalToConstant: 26).isActive = true
            button.heightAnchor.constraint(equalToConstant: 22).isActive = true
        }

        for sub in [titleLabel, emptyIcon, emptyLabel, cardsScroll, actionsStack] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            addSubview(sub)
        }
        let height = heightAnchor.constraint(equalToConstant: Self.emptyHeight)
        heightConstraint = height
        NSLayoutConstraint.activate([
            height,
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),

            emptyIcon.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyIcon.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 2),
            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.topAnchor.constraint(equalTo: emptyIcon.bottomAnchor, constant: 4),

            cardsScroll.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            cardsScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            cardsScroll.trailingAnchor.constraint(equalTo: actionsStack.leadingAnchor, constant: -2),
            cardsScroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

            actionsStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            actionsStack.centerYAnchor.constraint(equalTo: cardsScroll.centerYAnchor),
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
        cardsScroll.isHidden = empty
        actionsStack.isHidden = empty
        heightConstraint?.constant = empty ? Self.emptyHeight : Self.filledHeight

        cardsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let controller else { return }
        for item in items {
            let url = controller.store.resolve(item)
            let card = StashCardView(item: item, url: url)
            card.onRemove = { [weak controller] id in controller?.remove(ids: [id]) }
            cardsStack.addArrangedSubview(card)
        }
    }

    // MARK: 操作（图标条）

    @objc private func performAction(_ sender: NSButton) {
        guard let action = StashAction.from(tag: sender.tag) else { return }
        controller?.perform(action)
    }

    @objc private func clearAll(_ sender: NSButton) {
        controller?.clearAll()
    }

    // MARK: 整区投放目标（文件与目录都收）

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        layer?.backgroundColor = NSColor.clear.cgColor
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
            !urls.isEmpty else { return false }
        controller?.add(urls)
        return true
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

/// 暂存项卡片：大图标 + 名称（QSpace 式）；可拖出、右键移除
@MainActor
private final class StashCardView: NSView {
    let itemID: UUID
    let url: URL?
    var onRemove: ((UUID) -> Void)?

    init(item: StashItem, url: URL?) {
        self.itemID = item.id
        self.url = url
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6

        let icon = NSImageView()
        if let url {
            let image = NSWorkspace.shared.icon(forFile: url.path)
            image.size = NSSize(width: 72, height: 72)
            icon.image = image
        } else {
            icon.image = NSImage(systemSymbolName: "questionmark.square.dashed",
                                 accessibilityDescription: L10n.t("stash.missing"))
            icon.contentTintColor = .tertiaryLabelColor
        }
        let name = NSTextField(labelWithString: url?.lastPathComponent ?? L10n.t("stash.missing"))
        name.font = .systemFont(ofSize: 11)
        name.textColor = url == nil ? .tertiaryLabelColor : .labelColor
        name.alignment = .center
        name.lineBreakMode = .byTruncatingMiddle
        name.maximumNumberOfLines = 2
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for sub in [icon, name] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            addSubview(sub)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 104),
            heightAnchor.constraint(equalToConstant: 128),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.widthAnchor.constraint(equalToConstant: 72),
            icon.heightAnchor.constraint(equalToConstant: 72),
            name.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 4),
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            name.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            name.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -6),
        ])
        toolTip = url?.path
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建 UI，无 xib") }

    // 拖出（投到窗格/Finder/面包屑任何 fileURL 目标）
    override func mouseDragged(with event: NSEvent) {
        guard let url else { return }
        let dragItem = NSDraggingItem(pasteboardWriter: url as NSURL)
        dragItem.setDraggingFrame(bounds, contents: NSWorkspace.shared.icon(forFile: url.path))
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        let remove = menu.addItem(withTitle: L10n.t("stash.remove"),
                                  action: #selector(removeClicked), keyEquivalent: "")
        remove.target = self
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func removeClicked() {
        onRemove?(itemID)
    }
}

extension StashCardView: NSDraggingSource {
    nonisolated func draggingSession(_ session: NSDraggingSession,
                                     sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .move, .generic]
    }
}

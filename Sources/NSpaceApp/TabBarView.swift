import AppKit

/// 每窗格紧凑标签栏：选择/新建/关闭/中键关闭（QSpace 每窗格独立标签语义）
@MainActor
final class TabBarView: NSView {
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onNew: (() -> Void)?

    private let stack = NSStackView()
    private let scroll = NSScrollView()
    private let addButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 4, bottom: 2, right: 2)
        stack.translatesAutoresizingMaskIntoConstraints = false

        scroll.documentView = stack
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.verticalScrollElasticity = .none
        scroll.translatesAutoresizingMaskIntoConstraints = false

        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: L10n.t("tab.new"))
        addButton.isBordered = false
        addButton.bezelStyle = .accessoryBarAction
        addButton.target = self
        addButton.action = #selector(newTab)
        addButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scroll)
        addSubview(addButton)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: addButton.leadingAnchor, constant: -2),
            stack.heightAnchor.constraint(equalTo: scroll.heightAnchor),
            addButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            addButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            addButton.widthAnchor.constraint(equalToConstant: 20),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建 UI，无 xib") }

    func update(titles: [String], active: Int) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, title) in titles.enumerated() {
            let item = TabItemView(title: title, isActive: i == active, closable: titles.count > 1)
            item.onSelect = { [weak self] in self?.onSelect?(i) }
            item.onClose = { [weak self] in self?.onClose?(i) }
            stack.addArrangedSubview(item)
        }
    }

    @objc private func newTab() { onNew?() }
}

/// 单个标签（胶囊样式；hover 显示关闭钮；中键关闭）
@MainActor
private final class TabItemView: NSView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let isActive: Bool
    private let closable: Bool
    private var tracking: NSTrackingArea?

    init(title: String, isActive: Bool, closable: Bool) {
        self.isActive = isActive
        self.closable = closable
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.backgroundColor = isActive
            ? Theme.accent.withAlphaComponent(0.18).cgColor
            : NSColor.clear.cgColor

        label.stringValue = title
        label.font = .systemFont(ofSize: 11)
        label.lineBreakMode = .byTruncatingTail
        label.textColor = isActive ? .labelColor : .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: L10n.t("tab.close"))
        closeButton.symbolConfiguration = .init(pointSize: 7, weight: .bold)
        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(closeTab)
        closeButton.isHidden = true
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(label)
        addSubview(closeButton)
        NSLayoutConstraint.activate([
            closeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 12),
            label.leadingAnchor.constraint(equalTo: closeButton.trailingAnchor, constant: 1),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(lessThanOrEqualToConstant: 160),
            heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建 UI，无 xib") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        if closable { closeButton.isHidden = false }
    }

    override func mouseExited(with event: NSEvent) {
        closeButton.isHidden = true
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?()
    }

    override func otherMouseDown(with event: NSEvent) {
        if closable, event.buttonNumber == 2 { onClose?() }
    }

    @objc private func closeTab() { onClose?() }
}

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
    /// 尾部配件槽（甲板工作区标签条用：版本徽章嵌于此，位于"＋"按钮左侧）。
    /// 无配件时宽度收缩为 0（低优先 width==0 兜底），有配件时随内容撑开。
    private let accessoryHost = NSView()

    /// 标签胶囊高度（窗格标签 20；甲板工作区标签 28——行高 40 的 QSpace 密度）
    var itemHeight: CGFloat = 20

    /// 甲板位于标题栏区（fullSizeContentView）：不覆写则点击被窗口拖拽机制吞掉（I-12）
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        stack.orientation = .horizontal
        stack.alignment = .centerY
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

        accessoryHost.translatesAutoresizingMaskIntoConstraints = false
        let emptyWidth = accessoryHost.widthAnchor.constraint(equalToConstant: 0)
        emptyWidth.priority = .init(1)   // 最低优先：有配件时被内容约束覆盖，无配件时收缩为 0
        emptyWidth.isActive = true

        addSubview(scroll)
        addSubview(accessoryHost)
        addSubview(addButton)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: accessoryHost.leadingAnchor, constant: -2),
            stack.heightAnchor.constraint(equalTo: scroll.heightAnchor),
            accessoryHost.centerYAnchor.constraint(equalTo: centerYAnchor),
            accessoryHost.trailingAnchor.constraint(equalTo: addButton.leadingAnchor, constant: -8),
            addButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            addButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            addButton.widthAnchor.constraint(equalToConstant: 20),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建 UI，无 xib") }

    /// 甲板样式（M17）：透明底，透出 TopDeckView 的 .titlebar 材质（工作区标签条复用同一标签语法）
    func useTransparentBackground() {
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    /// 栏内任何一点，只要 x 落在某个胶囊的横向范围里就归它。
    ///
    /// 这条不只是"把上下 6pt 死区也算进去"——它是「点标签文字不切换」的**修复本体**（用户报告）。
    /// 真机实测：胶囊正中的原始 hitTest 返回的是 **NSScrollView**，不是胶囊也不是标签；
    /// 这个滚动视图在全尺寸标题栏窗口里带自动内缩，命中几何与画出来的胶囊错位
    /// （关掉 automaticallyAdjustsContentInsets 后原始命中变成 NSStackView，仍到不了胶囊）。
    /// NSScrollView.mouseDown 什么都不做，点击就死在那——只有快捷键能切换。
    /// 按 x 从栏这一层直接把命中派给胶囊，绕过那层几何。反证：撤掉本方法，
    /// 经窗口真实派发的点击 `点后活动 1→1`，用户症状原样复现。
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        // 已经命中胶囊 / 加号 / 配件 → 照旧
        if hit !== self, hit !== scroll, hit !== scroll.contentView, hit !== stack { return hit }
        // 命中的是空白：按 x 找胶囊
        for case let item as TabItemView in stack.arrangedSubviews where !item.isHidden {
            let r = item.convert(item.bounds, to: self)
            if point.x >= r.minX, point.x <= r.maxX, bounds.contains(point) { return item }
        }
        return hit
    }

    func update(titles: [String], active: Int) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, title) in titles.enumerated() {
            let item = TabItemView(title: title, isActive: i == active,
                                   closable: titles.count > 1, height: itemHeight)
            item.onSelect = { [weak self] in self?.onSelect?(i) }
            item.onClose = { [weak self] in self?.onClose?(i) }
            stack.addArrangedSubview(item)
        }
    }

    @objc private func newTab() { onNew?() }

    // ---- 自测通道（I-72）----
    /// 第 i 个胶囊在本栏坐标系里的 frame
    func uiTestItemFrame(_ i: Int) -> NSRect? {
        let items = stack.arrangedSubviews.compactMap { $0 as? TabItemView }
        guard items.indices.contains(i) else { return nil }
        return items[i].convert(items[i].bounds, to: self)
    }
    /// 第 i 个胶囊是否接受「第一下」点击（从别的 App 点过来不用点两次）
    func uiTestItemAcceptsFirstMouse(_ i: Int) -> Bool {
        let items = stack.arrangedSubviews.compactMap { $0 as? TabItemView }
        return items.indices.contains(i) && items[i].acceptsFirstMouse(for: nil)
    }
    /// 在本栏坐标系的一点做**真实** hitTest，回报是否命中第 i 个胶囊（走 AppKit 派发 mouseDown 的同一条路）
    func uiTestHitsItem(_ i: Int, at p: NSPoint) -> Bool {
        guard let sp = superview else { return false }
        let items = stack.arrangedSubviews.compactMap { $0 as? TabItemView }
        guard items.indices.contains(i) else { return false }
        return hitTest(convert(p, to: sp)) === items[i]
    }
    /// 把 mouseDown **直接投给 hitTest 解析出的视图**（确定性：不经 App 激活门）。
    /// 与 AppKit 真实派发的差别只在"要不要先激活 App"那一层——那层在用户正用着机器时随机吃掉第一下，
    /// 真门实测同一代码 3 轮 1 绿 2 红。命中解析本身（上面的 hitTest）才是修复本体。
    func uiTestClickResolved(at p: NSPoint, in window: NSWindow) -> String {
        guard let sp = superview, let target = hitTest(convert(p, to: sp)),
              let ev = NSEvent.mouseEvent(with: .leftMouseDown, location: convert(p, to: nil),
                                          modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil,
                                          eventNumber: 0, clickCount: 1, pressure: 1) else { return "nil" }
        target.mouseDown(with: ev)
        return String(describing: type(of: target))
    }

    /// 经**窗口的真实事件派发**点一下（NSWindow.sendEvent → 标题栏区域判定 → hitTest →
    /// mouseDownCanMoveWindow → 目标视图）。直接调 target.mouseDown 会绕过前面每一段——
    /// 而用户报的"点了不切换"恰恰可能死在那几段里。用 postEvent 而不是 sendEvent：
    /// 若 AppKit 在 down 上开了追踪循环，紧跟的 up 能让它退出，不会把自测挂死。
    func uiTestClick(at p: NSPoint, in window: NSWindow) {
        let loc = convert(p, to: nil)
        let t = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: loc, modifierFlags: [],
                                            timestamp: t, windowNumber: window.windowNumber, context: nil,
                                            eventNumber: 0, clickCount: 1, pressure: 1),
              let up = NSEvent.mouseEvent(with: .leftMouseUp, location: loc, modifierFlags: [],
                                          timestamp: t + 0.05, windowNumber: window.windowNumber, context: nil,
                                          eventNumber: 0, clickCount: 1, pressure: 0) else { return }
        // 直接交给窗口派发，不经 NSApp：自测跑在用户正在使用的机器上，App 常不是活动应用，
        // NSApp 那层会把第一下点击当"激活"吃掉（真门实测同一代码一轮 1→0、两轮 1→1）。
        // window.sendEvent 仍走 NSThemeFrame 标题栏区判定 → hitTest → mouseDownCanMoveWindow → 目标视图。
        window.sendEvent(down)
        window.sendEvent(up)
    }

    /// 设置尾部配件（版本徽章）；传 nil 清空。配件填满 accessoryHost，其宽度随配件内容。
    func setTrailingAccessory(_ view: NSView?) {
        accessoryHost.subviews.forEach { $0.removeFromSuperview() }
        guard let view else { return }
        view.translatesAutoresizingMaskIntoConstraints = false
        accessoryHost.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: accessoryHost.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: accessoryHost.trailingAnchor),
            view.centerYAnchor.constraint(equalTo: accessoryHost.centerYAnchor),
        ])
    }
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

    /// 同 TabBarView：标题栏区内必须禁窗口拖拽接管，否则 mouseDown 收不到（I-12）
    override var mouseDownCanMoveWindow: Bool { false }

    init(title: String, isActive: Bool, closable: Bool, height: CGFloat) {
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
        // I-23：文字必须在胶囊正中——对称 12/12 内边距 + 居中对齐；
        // 关闭钮 hover 时叠加在左内边距区，不参与布局（原先"给关闭钮留位"导致文字偏移）
        label.alignment = .center
        NSLayoutConstraint.activate([
            closeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 12),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(lessThanOrEqualToConstant: 160),
            heightAnchor.constraint(equalToConstant: height),
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

    /// 从别的 App 点过来的**第一下**就要切换（Safari 标签同款）。默认 false 时第一下只激活窗口、
    /// 不派发 mouseDown——用户在别的 App 里看完东西回来点标签，"点了没反应"、再点一下才动。
    /// （注：我一度认定是胶囊里的 NSTextField 吞掉了点击——真机 hitTest 实测标签是穿透的，
    /// 那条根因不成立，对应改动已撤。）
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onSelect?()
    }

    override func otherMouseDown(with event: NSEvent) {
        if closable, event.buttonNumber == 2 { onClose?() }
    }

    @objc private func closeTab() { onClose?() }
}

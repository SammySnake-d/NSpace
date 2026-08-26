import AppKit

/// 上报用户交互的表视图（窗格焦点协调：点击即请求激活所属窗格）。
/// 另承载右键菜单构造钩子与 Return 键（触发行内重命名）。
@MainActor
final class FocusReportingTableView: NSTableView {
    var onInteract: (() -> Void)?
    /// 右键菜单提供者：入参为点击行（-1 表示空白区，走目录级菜单）
    var menuProvider: ((Int) -> NSMenu?)?
    /// Return 键：触发选中行的行内重命名
    var onReturn: (() -> Void)?
    /// Return 键（enterAction=open 时）：打开选中项
    var onOpenSelected: (() -> Void)?
    /// Backspace 键（无 ⌘ 修饰）：按 backspaceAction 分发（忽略/返回/废纸篓/上层）
    var onBackspaceAction: (() -> Void)?
    /// 空格键：Quick Look 预览开关（Finder 肌肉记忆）
    var onSpace: (() -> Void)?
    /// 拖拽移出/结束（spring-loaded 计时器取消用）
    var onDragExited: (() -> Void)?
    /// ←/→ 键（分栏视图列间移动用；nil 时交回系统默认行为）
    var onArrowLeft: (() -> Void)?
    var onArrowRight: (() -> Void)?
    /// 组头行判定（M26）：真时该行为组头，点击切折叠、不参与选中语义
    var isGroupRowProvider: ((Int) -> Bool)?
    /// 组头行点击（M26）：切换该行所属组的折叠态
    var onGroupRowClick: ((Int) -> Void)?

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onDragExited?()
        super.draggingExited(sender)
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        onDragExited?()
        super.draggingEnded(sender)
    }

    override func mouseDown(with event: NSEvent) {
        onInteract?()
        // 组头行：单击切折叠（不落入 super 的选中/双击链）
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        if row >= 0, isGroupRowProvider?(row) == true {
            onGroupRowClick?(row)
            return
        }
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        onInteract?()
        super.rightMouseDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        onInteract?()
        return super.becomeFirstResponder()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        onInteract?()
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        // 组头行右键：不改选中（组头不可选），直接交 menuProvider 出组过滤菜单
        if row >= 0, isGroupRowProvider?(row) == true {
            return menuProvider?(row)
        }
        // 右击未选中行 → 先把它设为唯一选中（Finder 语义）
        if row >= 0, !selectedRowIndexes.contains(row) {
            selectRowIndexes([row], byExtendingSelection: false)
        }
        return menuProvider?(row)
    }

    override func keyDown(with event: NSEvent) {
        // 纯 ⌘↑/⌘↓ 落到表 = 导航菜单未接（禁用态）——吞掉，不让默认"跳选行"顶替导航语义（I-39）；
        // 带 ⇧/⌥/⌃ 的组合（如 ⇧⌘↓ 扩选）不吞，保持系统行为
        if event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
           event.keyCode == 125 || event.keyCode == 126 { return }
        // Return（36）/ Enter（76）：按使用习惯分发（rename→行内重命名 / open→打开选中）
        if event.keyCode == 36 || event.keyCode == 76 {
            if Preferences.enterAction == "open" { onOpenSelected?() } else { onReturn?() }
            return
        }
        // Backspace（51）：⌘⌫ 保持废纸篓语义交回菜单快捷键；无 ⌘ 时按使用习惯分发
        if event.keyCode == 51 {
            if event.modifierFlags.contains(.command) {
                super.keyDown(with: event)
            } else {
                onBackspaceAction?()
            }
            return
        }
        if event.keyCode == 49, let onSpace {
            onSpace()
            return
        }
        // ←（123）/ →（124）：分栏视图接管列间移动；未接管时交回默认
        if event.keyCode == 123, let onArrowLeft {
            onArrowLeft()
            return
        }
        if event.keyCode == 124, let onArrowRight {
            onArrowRight()
            return
        }
        super.keyDown(with: event)
    }
}

/// 行内重命名编辑框：Enter 提交、Esc 取消、失焦提交；可只选中文件名主体（不含扩展名）
@MainActor
final class InlineRenameField: NSTextField, NSTextFieldDelegate {
    var onCommit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    private var finished = false

    init(string: String) {
        super.init(frame: .zero)
        stringValue = string
        isEditable = true
        isBordered = true
        isBezeled = true
        bezelStyle = .squareBezel
        drawsBackground = true
        font = .systemFont(ofSize: Formatters.listFontSize)
        lineBreakMode = .byTruncatingTail
        focusRingType = .default
        delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建 UI，无 xib") }

    /// 选中文件名主体（扩展名保留不选）；无扩展名则全选
    func selectBaseName() {
        guard let editor = currentEditor() else { return }
        let ns = stringValue as NSString
        let base = ns.deletingPathExtension
        if base.count > 0, base.count < ns.length {
            editor.selectedRange = NSRange(location: 0, length: base.count)
        } else {
            editor.selectAll(nil)
        }
    }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) { commit(); return true }
        if selector == #selector(NSResponder.cancelOperation(_:)) { cancel(); return true }
        return false
    }

    /// 失焦 = 提交（Finder 语义）
    func controlTextDidEndEditing(_ obj: Notification) {
        guard !finished else { return }
        commit()
    }

    private func commit() { guard !finished else { return }; finished = true; onCommit?(stringValue) }
    private func cancel() { guard !finished else { return }; finished = true; onCancel?() }
}

/// 名称单元格：图标 + 文本；支持行内重命名（label ⟷ 可编辑框）
@MainActor
final class NameCellView: NSTableCellView {
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var editor: InlineRenameField?

    /// 提交/取消回调（由 FileListViewController 注入，接 .rename 提交与 FG-6 回滚）
    var onRenameCommit: ((String) -> Void)?
    var onRenameCancel: (() -> Void)?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.lineBreakMode = .byTruncatingMiddle
        label.font = .systemFont(ofSize: 12)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)
        addSubview(label)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        textField = label
        imageView = iconView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建 UI，无 xib") }

    func configure(icon: NSImage, name: String, dimmed: Bool) {
        iconView.image = icon
        label.stringValue = name
        label.font = .systemFont(ofSize: Formatters.listFontSize)  // 每次配置重取字号（列重建时即时生效）
        label.textColor = dimmed ? .secondaryLabelColor : .labelColor
    }

    var isEditing: Bool { editor != nil }

    /// 进入行内编辑：隐藏 label，覆盖一个可编辑框，选中文件名主体
    func beginRename() {
        guard editor == nil, let win = window else { return }
        let field = InlineRenameField(string: label.stringValue)
        field.onCommit = { [weak self] newName in self?.finish(commit: newName) }
        field.onCancel = { [weak self] in self?.finish(commit: nil) }
        field.translatesAutoresizingMaskIntoConstraints = false
        editor = field
        label.isHidden = true
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 4),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        win.makeFirstResponder(field)
        field.selectBaseName()
    }

    private func finish(commit: String?) {
        let field = editor
        editor = nil
        field?.removeFromSuperview()
        label.isHidden = false
        if let name = commit { onRenameCommit?(name) } else { onRenameCancel?() }
    }
}

/// 组头行视图（M26 列表分组）：折叠三角 + 「2026年8月」 + 项数（tabular-nums 次级墨色）。
/// 整行可点击切换折叠（onToggle）；右键菜单由表视图 menuProvider 按行类型分发。
/// 行高 24、floatsGroupRows 悬浮由 FileListViewController 配置。
@MainActor
final class GroupHeaderView: NSTableCellView {
    private let chevron = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.contentTintColor = .secondaryLabelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .labelColor
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.textColor = .secondaryLabelColor
        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)  // tabular-nums
        addSubview(chevron)
        addSubview(titleLabel)
        addSubview(countLabel)
        NSLayoutConstraint.activate([
            chevron.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 12),
            chevron.heightAnchor.constraint(equalToConstant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            countLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            countLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建 UI，无 xib") }

    func configure(title: String, count: Int, collapsed: Bool) {
        chevron.image = NSImage.officialSymbol(collapsed ? "chevron.right" : "chevron.down",
                                               fallback: collapsed ? "arrowtriangle.right.fill"
                                                                    : "arrowtriangle.down.fill",
                                               accessibility: title)
        titleLabel.stringValue = title
        countLabel.stringValue = L10n.f("group.count", count)
    }
}

/// 纯文本单元格（日期/大小/种类）
@MainActor
final class TextCellView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        textField = label
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建 UI，无 xib") }

    /// 普通文本（种类列等）；日期列传 monospacedDigits=true → 等宽数字，刷新不抖动（塔夫特）
    func configure(_ text: String, alignment: NSTextAlignment, monospacedDigits: Bool = false) {
        let size = Formatters.listFontSize  // 每次配置重取字号（列重建时即时生效）
        label.stringValue = text
        label.textColor = .secondaryLabelColor  // 复用格重置（上轮可能被大小列改成 attributed/labelColor）
        label.font = monospacedDigits
            ? .monospacedDigitSystemFont(ofSize: size, weight: .regular)
            : .systemFont(ofSize: size)
        label.alignment = alignment
    }

    /// 大小列：数值 labelColor + 单位 secondaryLabelColor（墨色三级，单位灰阶退后），等宽数字。
    func configureSize(value: String, unit: String, alignment: NSTextAlignment) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: Formatters.listFontSize, weight: .regular)
        // I-34：窄列宽下禁止折行（"151.4 MB"折两行会撑爆 22pt 行高）——单行 + 头部截断保单位可见
        label.usesSingleLineMode = true
        label.lineBreakMode = .byTruncatingHead
        let s = NSMutableAttributedString(string: value,
            attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        if !unit.isEmpty {
            s.append(NSAttributedString(string: " " + unit,
                attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
        }
        label.attributedStringValue = s
        label.alignment = alignment
    }
}

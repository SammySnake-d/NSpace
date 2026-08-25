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
    /// 拖拽移出/结束（spring-loaded 计时器取消用）
    var onDragExited: (() -> Void)?

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
        // 右击未选中行 → 先把它设为唯一选中（Finder 语义）
        if row >= 0, !selectedRowIndexes.contains(row) {
            selectRowIndexes([row], byExtendingSelection: false)
        }
        return menuProvider?(row)
    }

    override func keyDown(with event: NSEvent) {
        // Return（36）/ Enter（76）触发重命名；其余交回默认（方向键/空格 QL 等）
        if event.keyCode == 36 || event.keyCode == 76 {
            onReturn?()
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
        font = .systemFont(ofSize: 12)
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
            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
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

    func configure(_ text: String, alignment: NSTextAlignment) {
        label.stringValue = text
        label.alignment = alignment
    }
}

import AppKit
import NSpaceContracts

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
    /// 焦点先验与名称列/URL 映射（防非活动窗格误触发、非名称列误触发、重载漂移行号）
    var isPaneActiveProvider: (() -> Bool)?
    var itemURLProvider: ((Int) -> URL?)?
    var rowForURLProvider: ((URL) -> Int?)?
    /// 组头行判定（M26）：真时该行为组头，点击不参与选中语义
    var isGroupRowProvider: ((Int) -> Bool)?
    /// 组头行点击（M26）
    var onGroupRowClick: ((Int) -> Void)?

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onDragExited?()
        super.draggingExited(sender)
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        onDragExited?()
        super.draggingEnded(sender)
    }

    /// I-43：本次 super.mouseDown 期间是否发起了拖拽（由 delegate 的 pasteboardWriterForRow 置位）——
    /// 用于区分"纯单击已选中行"(需抢先收敛) 与"拖拽多选"(选中保持不动)。
    var dragInitiated = false

    /// 单击已选中项 → 重命名（用户报告：只有 Enter 能触发）。
    /// `onSingleClickRename` 由 FileListViewController 接到 beginRename(row:)。
    var onSingleClickRename: ((Int) -> Void)?
    /// 待触发的重命名（等一个双击间隔；双击到来即作废）
    private var pendingRenameToken = 0

    /// 单击重命名的决策谓词（由 InlineRenameCoordinator 统一实现，保留原签名供 UISelfTest 回归验证）
    static func shouldScheduleRename(clickedRow: Int, modifiers: NSEvent.ModifierFlags,
                                     clickCount: Int, selectedCount: Int,
                                     rowIsSelected: Bool, isGroupRow: Bool) -> Bool {
        InlineRenameCoordinator.shouldScheduleSingleClickRename(
            wasPaneAlreadyActive: true,
            inNameArea: true,
            dragInitiated: false,
            clickedRow: clickedRow,
            modifiers: modifiers,
            clickCount: clickCount,
            selectedCount: selectedCount,
            rowIsSelected: rowIsSelected,
            isGroupRow: isGroupRow
        )
    }

    /// 取消待触发的重命名（双击、导航、键盘操作都要作废它）
    func cancelPendingRename() { pendingRenameToken += 1 }

    /// I-43 决策谓词（纯函数，可确定性单测）：是否需要在 super.mouseDown 后抢先把选中收敛为单选。
    /// 仅「无修饰键 + 单击(非双击) + 当前多选 + 点在已选中行」时为真——此即 AppKit 会等双击间隔的场景。
    static func shouldPreemptCollapse(clickedRow: Int, modifiers: NSEvent.ModifierFlags,
                                      clickCount: Int, selectedCount: Int, rowIsSelected: Bool) -> Bool {
        clickedRow >= 0
            && modifiers.intersection([.command, .shift, .option, .control]).isEmpty
            && clickCount == 1
            && selectedCount > 1
            && rowIsSelected
    }

    override func mouseDown(with event: NSEvent) {
        let wasPaneActive = isPaneActiveProvider?() ?? true
        onInteract?()
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        let col = self.column(at: point)
        let isGroup = row >= 0 && isGroupRowProvider?(row) == true
        if isGroup { return }

        if Self.shouldPreemptCollapse(clickedRow: row, modifiers: event.modifierFlags,
                                      clickCount: event.clickCount,
                                      selectedCount: selectedRowIndexes.count,
                                      rowIsSelected: selectedRowIndexes.contains(row)) {
            dragInitiated = false
            super.mouseDown(with: event)
            if !dragInitiated {
                selectRowIndexes([row], byExtendingSelection: false)
            }
            return
        }

        if event.clickCount >= 2 { cancelPendingRename() }

        let inNameCol = tableColumns.count <= 1
            ? (col == 0)
            : (col >= 0 && col < tableColumns.count && tableColumns[col].identifier.rawValue == "name")

        let willScheduleRename = InlineRenameCoordinator.shouldScheduleSingleClickRename(
            wasPaneAlreadyActive: wasPaneActive,
            inNameArea: inNameCol,
            dragInitiated: false,
            clickedRow: row,
            modifiers: event.modifierFlags,
            clickCount: event.clickCount,
            selectedCount: selectedRowIndexes.count,
            rowIsSelected: selectedRowIndexes.contains(row),
            isGroupRow: isGroup
        )
        let targetURL = willScheduleRename ? itemURLProvider?(row) : nil
        if willScheduleRename { dragInitiated = false }

        super.mouseDown(with: event)

        if willScheduleRename, !dragInitiated, let fire = onSingleClickRename {
            pendingRenameToken += 1
            let token = pendingRenameToken
            let delay = NSEvent.doubleClickInterval
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.pendingRenameToken == token, !self.dragInitiated else { return }
                let resolvedRow: Int?
                if let targetURL, let resolver = self.rowForURLProvider {
                    resolvedRow = resolver(targetURL)
                } else {
                    resolvedRow = row
                }
                guard let finalRow = resolvedRow,
                      finalRow >= 0,
                      self.selectedRowIndexes.count == 1,
                      self.selectedRowIndexes.contains(finalRow),
                      self.isGroupRowProvider?(finalRow) != true else { return }
                fire(finalRow)
            }
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        cancelPendingRename()
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
        cancelPendingRename()   // 键盘一动就作废「单击待重命名」，避免打字打到一半冒出输入框
        // 纯 ⌘↑/⌘↓ 落到表 = 导航菜单未接（禁用态）——吞掉，不让默认"跳选行"顶替导航语义（I-39）；
        // 带 ⇧/⌥/⌃ 的组合（如 ⇧⌘↓ 扩选）不吞，保持系统行为
        if event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
           event.keyCode == 125 || event.keyCode == 126 { return }
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        // Return（36）/ Enter（76）：仅无修饰键时按使用习惯分发（⌘↩ 等交系统/菜单）
        if (event.keyCode == 36 || event.keyCode == 76), mods.isEmpty {
            if Preferences.enterAction == "open" { onOpenSelected?() } else { onReturn?() }
            return
        }
        // F2（120）：无论 enterAction 为何，始终触发行内重命名
        if event.keyCode == 120, mods.isEmpty {
            onReturn?()
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
        if event.keyCode == 49, mods.isEmpty, let onSpace {
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

/// 名称单元格：图标 + 文本；支持行内重命名（label ⟷ 统一 InlineRenameField）
@MainActor
final class NameCellView: NSTableCellView {
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    let renameField = InlineRenameField()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.lineBreakMode = .byTruncatingMiddle
        label.font = .systemFont(ofSize: Formatters.listFontSize)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        renameField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)
        addSubview(label)
        addSubview(renameField)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            renameField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 4),
            renameField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            renameField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        textField = label
        imageView = iconView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建 UI，无 xib") }

    override func prepareForReuse() {
        super.prepareForReuse()
        renameField.endEditAppearance()
        label.isHidden = false
    }

    func configure(icon: NSImage, name: String, dimmed: Bool) {
        iconView.image = icon
        label.stringValue = name
        label.font = .systemFont(ofSize: Formatters.listFontSize)
        label.textColor = dimmed ? .secondaryLabelColor : .labelColor
    }

    var isEditing: Bool { !renameField.isHidden }

    func setEditingAppearance(_ editing: Bool) {
        label.isHidden = editing
        if !editing {
            renameField.endEditAppearance()
        }
    }

    func beginRename(
        for item: FileItem,
        using renameCoordinator: InlineRenameCoordinator,
        hostView: NSView,
        prepareVisibleFrame: () -> Void,
        onCommit: @escaping (String) async -> URL?,
        onFinish: @escaping (URL?, Bool) -> Void,
        onTabStep: ((URL, Bool) -> Void)? = nil
    ) {
        label.isHidden = true
        renameCoordinator.begin(
            item: item,
            field: renameField,
            font: .systemFont(ofSize: Formatters.listFontSize),
            hostView: hostView,
            prepareVisibleFrame: prepareVisibleFrame,
            commitRename: onCommit,
            finishUI: { [weak self] renamedURL, restoreFocus in
                self?.label.isHidden = false
                onFinish(renamedURL, restoreFocus)
            },
            onTabStep: onTabStep
        )
    }
}

/// 组头行视图（M26 列表分组）：折叠占位去除 + 「2026年8月」 + 项数（tabular-nums 次级墨色）
@MainActor
final class GroupHeaderView: NSTableCellView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        wantsLayer = true
        refreshLayerAppearance()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .labelColor
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.textColor = .secondaryLabelColor
        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        addSubview(titleLabel)
        addSubview(countLabel)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            countLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            countLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建 UI，无 xib") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshLayerAppearance()
    }

    private func refreshLayerAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.12).cgColor
        }
    }

    func configure(title: String, count: Int) {
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

/// 底部留白可右键的滚动视图：`contentInsets.bottom` 让出的那条带子落在 clip view 上，
/// 表视图收不到那儿的点击，于是事件上浮到本层——在这里出目录级菜单。
///
/// 为什么不用"加几行假的空行"：那会污染表的数据源，行数、选中、分组计数全要跟着说谎。
@MainActor
final class BlankAreaScrollView: NSScrollView {
    /// 空白区右键 → 目录级菜单（由 FileListViewController 提供，与 clickedRow: -1 同一份）
    var onBlankMenu: (() -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        onBlankMenu?() ?? super.menu(for: event)
    }
}

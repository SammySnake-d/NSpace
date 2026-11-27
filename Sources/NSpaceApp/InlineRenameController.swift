import AppKit
import NSpaceContracts

/// 行内重命名规则与统一文本框 + 生命周期协调器（MIT 独立公理：三视图共享同一编辑状态机）
@MainActor
final class InlineRenameField: NSTextField, NSTextFieldDelegate {
    var onCommit: ((String, Bool?) -> Void)?
    var onCancel: (() -> Void)?

    private var didResolveTransaction = false
    private var isFinishingTransaction = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建 UI，无 xib") }

    private func configureAppearance() {
        isBordered = false
        isBezeled = false
        drawsBackground = true
        backgroundColor = .textBackgroundColor
        textColor = .labelColor
        focusRingType = .none
        usesSingleLineMode = true
        isEditable = false
        isSelectable = false
        isHidden = true
        delegate = self

        if let cell = cell as? NSTextFieldCell {
            cell.isScrollable = true
            cell.wraps = false
            cell.lineBreakMode = .byClipping
        }

        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.borderWidth = 1
        refreshLayerAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshLayerAppearance()
    }

    private func refreshLayerAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
            layer?.borderColor = Theme.accent.cgColor
        }
    }

    func prepareForEdit(name: String, font: NSFont?) {
        didResolveTransaction = false
        isFinishingTransaction = false
        if let font { self.font = font }
        stringValue = name
        isEditable = true
        isSelectable = true
        isHidden = false
    }

    func endEditAppearance() {
        isEditable = false
        isSelectable = false
        isHidden = true
    }

    /// 选中基本名（UTF-16 口径）：文件夹/无点隐藏文件选全名，普通文件只选扩展名之前
    func applyStemSelection(isDirectory: Bool, isPackage: Bool) {
        let name = stringValue
        let ns = name as NSString
        guard ns.length > 0 else { return }
        let range: NSRange
        if isDirectory && !isPackage {
            range = NSRange(location: 0, length: ns.length)
        } else {
            let dot = ns.range(of: ".", options: .backwards)
            if dot.location != NSNotFound, dot.location > 0 {
                range = NSRange(location: 0, length: dot.location)
            } else {
                range = NSRange(location: 0, length: ns.length)
            }
        }
        if let editor = currentEditor() as? NSTextView {
            editor.selectedRange = range
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        // IME 组合输入中不抢 Enter / Esc / Tab
        if textView.hasMarkedText() { return false }

        if commandSelector == #selector(NSResponder.insertNewline(_:)) ||
            commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
            resolve(commit: true, movement: .return)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            resolve(commit: false, movement: .cancel)
            return true
        }
        if commandSelector == #selector(NSResponder.insertTab(_:)) {
            resolve(commit: true, movement: .tab)
            return true
        }
        if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
            resolve(commit: true, movement: .backtab)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard !didResolveTransaction, !isFinishingTransaction else { return }
        let rawMovement = obj.userInfo?["NSTextMovement"] as? Int
        let movement = rawMovement.flatMap(NSTextMovement.init(rawValue:)) ?? .other
        switch movement {
        case .cancel:
            resolve(commit: false, movement: .cancel)
        case .tab, .backtab:
            resolve(commit: true, movement: movement)
        default:
            resolve(commit: true, movement: movement)
        }
    }

    private func resolve(commit: Bool, movement: NSTextMovement) {
        guard !didResolveTransaction, !isFinishingTransaction else { return }
        didResolveTransaction = true
        isFinishingTransaction = true

        let editedValue = (currentEditor()?.string ?? stringValue)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // 先解除字段自身响应链，再隐藏，防止 AppKit 自动结束编辑二次重入
        endEditAppearance()
        if let win = window, win.firstResponder === currentEditor() || win.firstResponder === self {
            win.endEditing(for: self)
        }

        if commit && !editedValue.isEmpty {
            let tabDirection: Bool? = movement == .tab ? true : (movement == .backtab ? false : nil)
            onCommit?(editedValue, tabDirection)
        } else {
            onCancel?()
        }
        isFinishingTransaction = false
    }
}

/// 单选重命名与跨重载防干扰协调器：隔离「行内编辑中」的视图刷新，防 FSEvents 打断输入与丢失焦点
@MainActor
final class InlineRenameCoordinator {
    private(set) var editingURL: URL?
    private(set) weak var activeField: InlineRenameField?
    private weak var hostView: NSView?
    private var deferredReloadBlock: (() -> Void)?
    private(set) var isCommitting = false

    var isEditing: Bool { activeField != nil || isCommitting }

    /// 统一单击触发重命名谓词：仅活跃窗格 + 名称区 + 无拖拽 + 单击 + 单选 + 点中已选行 + 无修饰键 + 非分组头
    static func shouldScheduleSingleClickRename(
        wasPaneAlreadyActive: Bool,
        inNameArea: Bool,
        dragInitiated: Bool,
        clickedRow: Int,
        modifiers: NSEvent.ModifierFlags,
        clickCount: Int,
        selectedCount: Int,
        rowIsSelected: Bool,
        isGroupRow: Bool
    ) -> Bool {
        guard wasPaneAlreadyActive, inNameArea, !dragInitiated else { return false }
        guard clickedRow >= 0, !isGroupRow else { return false }
        guard clickCount == 1, selectedCount == 1, rowIsSelected else { return false }
        let relevant = modifiers.intersection([.shift, .command, .option, .control])
        return relevant.isEmpty
    }

    /// 尝试执行视图重载；若正处于重命名，则暂存最后一次快照更新，待编辑结束/完成后统一补刷
    @discardableResult
    func runOrDefer(_ reloadBlock: @escaping () -> Void) -> Bool {
        if isEditing {
            deferredReloadBlock = reloadBlock
            return true
        }
        reloadBlock()
        return false
    }

    func begin(
        item: FileItem,
        field: InlineRenameField,
        font: NSFont?,
        hostView: NSView,
        prepareVisibleFrame: () -> Void,
        commitRename: @escaping (String) async -> URL?,
        finishUI: @escaping (_ renamedURL: URL?, _ restoreFocus: Bool) -> Void,
        onTabStep: ((URL, Bool) -> Void)? = nil
    ) {
        if let prev = activeField, prev !== field {
            prev.onCancel?()
        }
        editingURL = item.url
        activeField = field
        self.hostView = hostView

        let originalName = item.name
        field.prepareForEdit(name: originalName, font: font)
        prepareVisibleFrame()

        field.superview?.layoutSubtreeIfNeeded()
        if let win = field.window ?? hostView.window {
            win.contentView?.layoutSubtreeIfNeeded()
            _ = win.makeFirstResponder(field)
        }
        field.applyStemSelection(isDirectory: item.isDirectory, isPackage: item.isPackage)

        field.onCancel = { [weak self, weak field] in
            guard let self else { return }
            field?.endEditAppearance()
            self.activeField = nil
            self.editingURL = nil
            let shouldRestore = self.shouldRestoreFocusToHost(field: field)
            finishUI(nil, shouldRestore)
            self.flushDeferredReload()
        }

        field.onCommit = { [weak self, weak field] proposedName, tabDirection in
            guard let self else { return }
            field?.endEditAppearance()
            self.activeField = nil
            self.editingURL = nil
            let shouldRestore = self.shouldRestoreFocusToHost(field: field)
            // 若因 Enter/Tab 结束而非点去别处，立刻归还宿主视图焦点，避免 I/O 期间焦点停在 NSWindow 上
            if shouldRestore, let win = self.hostView?.window {
                win.makeFirstResponder(self.hostView)
            }

            if proposedName == originalName || proposedName.contains("/") {
                finishUI(nil, shouldRestore)
                self.flushDeferredReload()
                if let forward = tabDirection {
                    onTabStep?(item.url, forward)
                }
                return
            }

            self.isCommitting = true
            Task { @MainActor [weak self] in
                let resultURL = await commitRename(proposedName)
                guard let self else { return }
                self.isCommitting = false
                let stillRestore = shouldRestore && self.shouldRestoreFocusToHost(field: nil)
                finishUI(resultURL, stillRestore)
                self.flushDeferredReload()
                if let forward = tabDirection {
                    onTabStep?(resultURL ?? item.url, forward)
                }
            }
        }
    }

    func cancelIfNeeded() {
        if let field = activeField {
            field.endEditAppearance()
            field.onCancel?()
        }
        activeField = nil
        editingURL = nil
    }

    private func shouldRestoreFocusToHost(field: InlineRenameField?) -> Bool {
        guard let win = hostView?.window ?? field?.window else { return false }
        let fr = win.firstResponder
        return fr === nil || fr === win || fr === hostView || fr === field || fr === field?.currentEditor()
    }

    private func flushDeferredReload() {
        guard !isEditing, let pending = deferredReloadBlock else { return }
        deferredReloadBlock = nil
        pending()
    }
}

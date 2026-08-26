import AppKit
import PathComplete

/// 路径编辑器：⌘L/点击空白呼出；输入即补全（PathComplete 胶囊）；Enter 导航、Esc 取消
@MainActor
final class PathEditorField: NSTextField, NSTextFieldDelegate {
    var onCommit: ((URL) -> Void)?
    var onCancel: (() -> Void)?

    private let completer: any PathCompleting = PathCompleter()
    private var completing = false
    /// controlTextDidChange 是否正在栈上（用于证明 complete 触发在文本变更事务之外）
    private var inTextDidChange = false
    /// I-30 探针：末次补全候选数
    private(set) var uiTestLastCompletionCount = -1
    /// I-30 探针：末次补全是否在文本变更事务【之外】触发（true=已延迟；同步 bug 时为 false）
    private(set) var uiTestCompletionWasDeferred = false

    init() {
        super.init(frame: .zero)
        delegate = self
        font = .monospacedSystemFont(ofSize: NSFont.systemFontSize(for: .small), weight: .regular)
        placeholderString = L10n.t("addressbar.placeholder")
        cell?.usesSingleLineMode = true
        cell?.isScrollable = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建 UI，无 xib") }

    func beginEditing(with path: String) {
        stringValue = path
        window?.makeFirstResponder(self)
        currentEditor()?.moveToEndOfLine(nil)
    }

    // MARK: 补全（输入即触发 complete:，防重入）

    func controlTextDidChange(_ notification: Notification) {
        guard !completing, currentEditor() is NSTextView else { return }
        // I-30：complete(nil) 必须【延迟到下一 runloop】触发，不可在 controlTextDidChange 内同步调用。
        // 同步调用时首次输入的补全 popup 被文本变更事务吞掉（首键无补全，需第二键才浮出）；
        // 异步派发让文本变更先落定，补全 popup 首键即出。
        inTextDidChange = true
        defer { inTextDidChange = false }
        DispatchQueue.main.async { [weak self] in
            guard let self, let editor = self.currentEditor() as? NSTextView else { return }
            self.completing = true
            // UITEST 无头环境：AppKit 补全 popup 会进入嵌套事件循环且无事件可退（主线程栈实锤
            // NSTextViewCompletionController 挂死、饿死看门狗）。自测只核"事务外触发"契约与候选数
            //（completions 回调仍走），不弹真 popup；产品路径不变。
            if UISelfTest.isEnabled {
                var idx = -1
                _ = self.control(self, textView: editor,
                                 completions: [],
                                 forPartialWordRange: editor.rangeForUserCompletion,
                                 indexOfSelectedItem: &idx)
            } else {
                editor.complete(nil)
            }
            self.completing = false
        }
    }

    func control(_ control: NSControl, textView: NSTextView,
                 completions words: [String], forPartialWordRange charRange: NSRange,
                 indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String] {
        index.pointee = -1
        // I-30 契约核实：complete 必须在 controlTextDidChange 返回后才触发（否则首键 popup 被吞）
        uiTestCompletionWasDeferred = !inTextDidChange
        // 对整行内容补全（系统默认按词切分，路径需整行语义）
        let result = completer.complete(stringValue)
        uiTestLastCompletionCount = result.count
        return result
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            let raw = stringValue.trimmingCharacters(in: .whitespaces)
            guard !raw.isEmpty else { onCancel?(); return true }
            let expanded = (raw as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
                onCommit?(URL(fileURLWithPath: expanded))
            } else {
                // 就地反馈：路径无效抖动示意，不弹窗（spec 做工不变量）
                shake()
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel?()
            return true
        default:
            return false
        }
    }

    private func shake() {
        let animation = CAKeyframeAnimation(keyPath: "position.x")
        animation.values = [0, -6, 6, -4, 4, 0].map { frame.midX + $0 }
        animation.duration = 0.3
        layer?.add(animation, forKey: "shake")
        NSSound.beep()
    }
}

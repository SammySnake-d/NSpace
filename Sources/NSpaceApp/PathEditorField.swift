import AppKit
import PathComplete

/// 路径编辑器：⌘L/点击空白呼出；输入即补全（PathComplete 胶囊）；Enter 导航、Esc 取消
@MainActor
final class PathEditorField: NSTextField, NSTextFieldDelegate {
    var onCommit: ((URL) -> Void)?
    var onCancel: (() -> Void)?

    private let completer: any PathCompleting = PathCompleter()
    private var completing = false

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
        guard !completing, let editor = currentEditor() as? NSTextView else { return }
        completing = true
        editor.complete(nil)
        completing = false
    }

    func control(_ control: NSControl, textView: NSTextView,
                 completions words: [String], forPartialWordRange charRange: NSRange,
                 indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String] {
        index.pointee = -1
        // 对整行内容补全（系统默认按词切分，路径需整行语义）
        return completer.complete(stringValue)
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

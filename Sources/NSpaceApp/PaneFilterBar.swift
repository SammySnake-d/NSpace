import AppKit

/// 窗格内实时文件名过滤条（⌘F 呼出，24pt 紧凑单行，严格 4pt 栅格）
@MainActor
final class PaneFilterBar: NSView, NSTextFieldDelegate {
    var onQueryChanged: ((String) -> Void)?
    var onDismissAndFocusView: (() -> Void)?
    var onMoveDownToView: (() -> Void)?

    private let searchIcon = NSImageView()
    private let inputField = NSTextField()
    private let countLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let bottomHairline = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        setupUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建 UI，无 xib") }

    private func setupUI() {
        searchIcon.image = NSImage.officialSymbol("line.3.horizontal.decrease.circle")
        searchIcon.contentTintColor = .secondaryLabelColor
        searchIcon.translatesAutoresizingMaskIntoConstraints = false

        inputField.placeholderString = L10n.t("filter.placeholder")
        inputField.isBordered = false
        inputField.drawsBackground = false
        inputField.focusRingType = .none
        inputField.font = .systemFont(ofSize: 12)
        inputField.textColor = .labelColor
        inputField.usesSingleLineMode = true
        inputField.delegate = self
        inputField.translatesAutoresizingMaskIntoConstraints = false

        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .right
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        closeButton.image = NSImage.officialSymbol("xmark.circle.fill")
        closeButton.isBordered = false
        closeButton.bezelStyle = .regularSquare
        closeButton.contentTintColor = .tertiaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        bottomHairline.wantsLayer = true
        bottomHairline.translatesAutoresizingMaskIntoConstraints = false

        addSubview(searchIcon)
        addSubview(inputField)
        addSubview(countLabel)
        addSubview(closeButton)
        addSubview(bottomHairline)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),

            searchIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            searchIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            searchIcon.widthAnchor.constraint(equalToConstant: 12),
            searchIcon.heightAnchor.constraint(equalToConstant: 12),

            inputField.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 4),
            inputField.centerYAnchor.constraint(equalTo: centerYAnchor),
            inputField.trailingAnchor.constraint(lessThanOrEqualTo: countLabel.leadingAnchor, constant: -8),

            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            countLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -4),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),

            bottomHairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomHairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomHairline.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomHairline.heightAnchor.constraint(equalToConstant: 1)
        ])

        refreshAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }

    private func refreshAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            bottomHairline.layer?.backgroundColor = NSColor.separatorColor.cgColor
        }
    }

    func focusField() {
        window?.makeFirstResponder(inputField)
        inputField.selectText(nil)
    }

    func clearAndDismiss() {
        inputField.stringValue = ""
        updateCounts(shown: 0, total: 0, filtering: false)
        onQueryChanged?("")
        onDismissAndFocusView?()
    }

    func setQueryText(_ query: String) {
        inputField.stringValue = query
    }

    func updateCounts(shown: Int, total: Int, filtering: Bool) {
        if filtering {
            countLabel.stringValue = L10n.f("filter.count", shown, total)
        } else {
            countLabel.stringValue = ""
        }
    }

    @objc private func closeTapped() {
        clearAndDismiss()
    }

    func controlTextDidChange(_ obj: Notification) {
        onQueryChanged?(inputField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            clearAndDismiss()
            return true
        }
        if commandSelector == #selector(NSResponder.moveDown(_:))
            || commandSelector == #selector(NSResponder.insertNewline(_:)) {
            onMoveDownToView?()
            return true
        }
        return false
    }
}

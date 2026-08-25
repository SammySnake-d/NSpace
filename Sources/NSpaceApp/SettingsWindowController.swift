import AppKit

/// 设置窗口（⌘,）：v1 只放真实功能——默认程序接管 + 权限引导（FG-1 无假控件）
@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private let defaultHandlerButton = NSButton()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = L10n.t("settings.title")
        window.center()
        super.init(window: window)
        buildUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建 UI，无 xib") }

    override func showWindow(_ sender: Any?) {
        refreshState()
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildUI() {
        let title = NSTextField(labelWithString: L10n.t("settings.finderSection"))
        title.font = .systemFont(ofSize: 13, weight: .semibold)

        defaultHandlerButton.title = L10n.t("settings.setDefault")
        defaultHandlerButton.bezelStyle = .push
        defaultHandlerButton.target = self
        defaultHandlerButton.action = #selector(setAsDefault)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor

        let limitation = NSTextField(wrappingLabelWithString: L10n.t("settings.limitationNote"))
        limitation.font = .systemFont(ofSize: 11)
        limitation.textColor = .tertiaryLabelColor

        let fdaButton = NSButton(title: L10n.t("settings.openFDA"), target: self,
                                 action: #selector(openFDA))
        fdaButton.bezelStyle = .push
        let fdaNote = NSTextField(wrappingLabelWithString: L10n.t("settings.fdaNote"))
        fdaNote.font = .systemFont(ofSize: 11)
        fdaNote.textColor = .tertiaryLabelColor

        let stack = NSStackView(views: [title, defaultHandlerButton, statusLabel, limitation,
                                        NSBox.separatorLine(), fdaButton, fdaNote])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor),
        ])
        window?.contentView = content
    }

    private func refreshState() {
        if FinderIntegration.isDefaultFolderHandler {
            statusLabel.stringValue = L10n.t("settings.isDefault")
            statusLabel.textColor = .systemGreen
            defaultHandlerButton.isEnabled = false
        } else {
            statusLabel.stringValue = L10n.t("settings.notDefault")
            statusLabel.textColor = .secondaryLabelColor
            defaultHandlerButton.isEnabled = true
        }
    }

    @objc private func setAsDefault() {
        defaultHandlerButton.isEnabled = false
        FinderIntegration.requestDefaultFolderHandler { [weak self] error in
            if let error {
                // 就地反馈：状态行红字，不弹窗
                self?.statusLabel.stringValue = String(format: L10n.t("settings.setFailed"),
                                                       error.localizedDescription)
                self?.statusLabel.textColor = .systemRed
                self?.defaultHandlerButton.isEnabled = true
            } else {
                self?.refreshState()
            }
        }
    }

    @objc private func openFDA() {
        FinderIntegration.openFullDiskAccessSettings()
    }
}

extension NSBox {
    static func separatorLine() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}

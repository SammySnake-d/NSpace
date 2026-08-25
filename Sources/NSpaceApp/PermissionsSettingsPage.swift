import AppKit

/// 权限设置页：完全磁盘访问（FDA）状态检测 + 引导。检测走只读探测（FinderIntegration.hasFullDiskAccess，
/// 不违 BG-1）；状态行绿✓/橙⚠，配"打开系统设置""重新检测"按钮与说明文案。
@MainActor
final class PermissionsSettingsPage: NSObject, SettingsPage {
    var pageTitleKey: String { "settings.tab.permissions" }

    private let statusLabel = NSTextField(wrappingLabelWithString: "")

    func makeView() -> NSView {
        let header = NSTextField(labelWithString: L10n.t("settings.perm.fdaTitle"))
        header.font = .systemFont(ofSize: 13, weight: .semibold)

        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        refreshStatus()

        let openButton = NSButton(title: L10n.t("settings.perm.open"), target: self,
                                  action: #selector(openSettings))
        openButton.bezelStyle = .push
        let recheckButton = NSButton(title: L10n.t("settings.perm.recheck"), target: self,
                                     action: #selector(recheck))
        recheckButton.bezelStyle = .push
        let buttons = NSStackView(views: [openButton, recheckButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let note = NSTextField(wrappingLabelWithString: L10n.t("settings.perm.note"))
        note.font = .systemFont(ofSize: 11)
        note.textColor = .tertiaryLabelColor

        let stack = NSStackView(views: [header, statusLabel, buttons,
                                        NSBox.separatorLine(), note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)

        let v = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: v.topAnchor),
            stack.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor),
        ])
        return v
    }

    /// 重新探测并刷新状态行（授权后回本页点"重新检测"即时反映）
    private func refreshStatus() {
        if FinderIntegration.hasFullDiskAccess() {
            statusLabel.stringValue = L10n.t("settings.perm.granted")
            statusLabel.textColor = .systemGreen
        } else {
            statusLabel.stringValue = L10n.t("settings.perm.denied")
            statusLabel.textColor = .systemOrange
        }
    }

    @objc private func openSettings() {
        FinderIntegration.openFullDiskAccessSettings()
    }

    @objc private func recheck() {
        refreshStatus()
    }
}

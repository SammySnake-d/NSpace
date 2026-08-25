import AppKit

/// 归档设置页（SettingsPage 插件）：压缩格式 / 压缩后保留原文件 / 解压包裹文件夹 / 解压后保留压缩包。
/// 全部落 Preferences 外部化键；控件即时生效。作为 SettingsPages.extraPages 一员被设置窗渲染成一个页签。
@MainActor
final class ArchiveSettingsPage: NSObject, SettingsPage {
    var pageTitleKey: String { "settings.tab.archive" }

    func makeView() -> NSView {
        // 作用域说明置顶：本页只管 NSpace 自带压缩/解压命令，双击打开始终走系统默认程序（I-06）
        let scopeNote = NSTextField(wrappingLabelWithString: L10n.t("settings.archiveScopeNote"))
        scopeNote.font = .systemFont(ofSize: 11)
        scopeNote.textColor = .secondaryLabelColor

        // 压缩格式 popup
        let formatLabel = NSTextField(labelWithString: L10n.t("settings.archiveFormat"))
        formatLabel.font = .systemFont(ofSize: 12)
        let formatPopup = NSPopUpButton()
        for o in Preferences.archiveFormatOptions {
            formatPopup.addItem(withTitle: L10n.t(o.nameKey))
            formatPopup.lastItem?.representedObject = o.id
        }
        if let idx = Preferences.archiveFormatOptions.firstIndex(where: { $0.id == Preferences.archiveFormat }) {
            formatPopup.selectItem(at: idx)
        }
        formatPopup.target = self
        formatPopup.action = #selector(formatChanged(_:))
        let formatRow = NSStackView(views: [formatLabel, formatPopup])
        formatRow.orientation = .horizontal
        formatRow.spacing = 8
        formatLabel.widthAnchor.constraint(equalToConstant: 150).isActive = true

        // 压缩后保留原文件
        let keepOriginal = checkbox("settings.archiveKeepOriginal",
                                    checked: Preferences.archiveKeepOriginal,
                                    action: #selector(keepOriginalChanged(_:)))

        // 解压确保创建包裹文件夹 + 说明
        let wrapper = checkbox("settings.extractCreateWrapper",
                               checked: Preferences.extractCreateWrapper,
                               action: #selector(wrapperChanged(_:)))
        let wrapperNote = NSTextField(wrappingLabelWithString: L10n.t("settings.extractWrapperNote"))
        wrapperNote.font = .systemFont(ofSize: 11)
        wrapperNote.textColor = .tertiaryLabelColor

        // 解压后保留压缩包
        let keepArchive = checkbox("settings.extractKeepArchive",
                                   checked: Preferences.extractKeepArchive,
                                   action: #selector(keepArchiveChanged(_:)))

        // 弱加密诚实说明
        let cryptoNote = NSTextField(wrappingLabelWithString: L10n.t("settings.archiveCryptoNote"))
        cryptoNote.font = .systemFont(ofSize: 11)
        cryptoNote.textColor = .tertiaryLabelColor

        let stack = NSStackView(views: [scopeNote, NSBox.separatorLine(), formatRow, keepOriginal,
                                        NSBox.separatorLine(), wrapper, wrapperNote, keepArchive,
                                        NSBox.separatorLine(), cryptoNote])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)

        let container = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
        ])
        return container
    }

    private func checkbox(_ titleKey: String, checked: Bool, action: Selector) -> NSButton {
        let b = NSButton(checkboxWithTitle: L10n.t(titleKey), target: self, action: action)
        b.state = checked ? .on : .off
        b.font = .systemFont(ofSize: 12)
        return b
    }

    @objc private func formatChanged(_ sender: NSPopUpButton) {
        if let id = sender.selectedItem?.representedObject as? String { Preferences.archiveFormat = id }
    }

    @objc private func keepOriginalChanged(_ sender: NSButton) {
        Preferences.archiveKeepOriginal = sender.state == .on
    }

    @objc private func wrapperChanged(_ sender: NSButton) {
        Preferences.extractCreateWrapper = sender.state == .on
    }

    @objc private func keepArchiveChanged(_ sender: NSButton) {
        Preferences.extractKeepArchive = sender.state == .on
    }
}

import AppKit

/// 设置窗口（⌘,）三页签：通用（外部化默认配置）/ 快捷键（注册表可录制）/ 替代 Finder。
/// 原则：所有可配置项集中于此（Preferences/KeyBindings 外部化，零硬编码散落）。
@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private let statusLabel = NSTextField(wrappingLabelWithString: "")

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
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
        refreshFinderState()
        refreshRevealState()
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildUI() {
        let tabs = NSTabView()
        tabs.translatesAutoresizingMaskIntoConstraints = false

        let general = NSTabViewItem(identifier: "general")
        general.label = L10n.t("settings.tab.general")
        general.view = buildGeneralTab()
        tabs.addTabViewItem(general)

        let keys = NSTabViewItem(identifier: "keys")
        keys.label = L10n.t("settings.tab.shortcuts")
        keys.view = buildShortcutsTab()
        tabs.addTabViewItem(keys)

        for (i, page) in SettingsPages.extraPages.enumerated() {
            let item = NSTabViewItem(identifier: "extra\(i)")
            item.label = L10n.t(page.pageTitleKey)
            item.view = page.makeView()
            tabs.addTabViewItem(item)
        }

        let finder = NSTabViewItem(identifier: "finder")
        finder.label = L10n.t("settings.finderSection")
        finder.view = buildFinderTab()
        tabs.addTabViewItem(finder)

        let content = NSView()
        content.addSubview(tabs)
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            tabs.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            tabs.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
        window?.contentView = content
    }

    // MARK: 通用页（Preferences 外部化项全暴露）

    private func popupRow(_ titleKey: String, options: [(tag: Int, title: String)],
                          selectedTag: Int, action: Selector) -> NSView {
        let label = NSTextField(labelWithString: L10n.t(titleKey))
        label.font = .systemFont(ofSize: 12)
        let popup = NSPopUpButton()
        for o in options {
            popup.addItem(withTitle: o.title)
            popup.lastItem?.tag = o.tag
        }
        popup.selectItem(withTag: selectedTag)
        popup.target = self
        popup.action = action
        let row = NSStackView(views: [label, popup])
        row.orientation = .horizontal
        row.spacing = 8
        label.widthAnchor.constraint(equalToConstant: 152).isActive = true
        return row
    }

    private func checkRow(_ titleKey: String, checked: Bool, action: Selector) -> NSButton {
        let b = NSButton(checkboxWithTitle: L10n.t(titleKey), target: self, action: action)
        b.state = checked ? .on : .off
        b.font = .systemFont(ofSize: 12)
        return b
    }

    private func buildGeneralTab() -> NSView {
        let layoutRow = popupRow("settings.defaultLayout",
            options: PaneLayout.allCases.map { ($0.rawValue, $0.localizedName) },
            selectedTag: Preferences.defaultLayoutRaw,
            action: #selector(defaultLayoutChanged(_:)))
        let viewRow = popupRow("settings.defaultView",
            options: [(0, L10n.t("menu.viewAsIcons")), (1, L10n.t("menu.viewAsList")), (2, L10n.t("menu.viewAsColumns"))],
            selectedTag: Preferences.defaultViewModeRaw,
            action: #selector(defaultViewChanged(_:)))
        let termRow = popupRow("settings.terminal",
            options: Preferences.terminalOptions.enumerated().map { ($0.offset, L10n.t($0.element.nameKey)) },
            selectedTag: Preferences.terminalOptions.firstIndex { $0.id == Preferences.terminalChoice } ?? 0,
            action: #selector(terminalChanged(_:)))

        let hidden = checkRow("settings.showHidden", checked: Preferences.showHiddenByDefault,
                              action: #selector(showHiddenChanged(_:)))
        let folders = checkRow("settings.foldersFirst", checked: Preferences.foldersFirst,
                               action: #selector(foldersFirstChanged(_:)))
        let paneBar = checkRow("menu.togglePaneTabBar", checked: PaneViewController.paneTabBarVisible,
                               action: #selector(paneBarChanged(_:)))

        let note = NSTextField(wrappingLabelWithString: L10n.t("settings.applyNote"))
        note.font = .systemFont(ofSize: 11)
        note.textColor = .tertiaryLabelColor

        // I-14：默认书签种子可删可恢复——恢复按钮补齐缺失种子（按路径去重，不动用户书签）
        let restoreSeeds = NSButton(title: L10n.t("settings.restoreSeeds"), target: self,
                                    action: #selector(restoreDefaultSeeds))
        restoreSeeds.bezelStyle = .push

        // M22：热更新——自动检查开关 + 手动"检查更新"按钮（有新版走徽章流程）
        let autoUpdate = checkRow("settings.autoCheckUpdates", checked: Preferences.autoCheckUpdates,
                                  action: #selector(autoCheckUpdatesChanged(_:)))
        let checkUpdate = NSButton(title: L10n.t("settings.checkForUpdates"), target: self,
                                   action: #selector(checkForUpdates))
        checkUpdate.bezelStyle = .push

        // M24：全局呼出/隐藏热键（Carbon，无需辅助功能权限；替代 Raycast 桥接）
        let hotkeyLabel = NSTextField(labelWithString: L10n.t("settings.globalHotkey"))
        hotkeyLabel.font = .systemFont(ofSize: 12)
        hotkeyLabel.widthAnchor.constraint(equalToConstant: 152).isActive = true
        let hotkeyRecorder = GlobalHotkeyRecorderButton()
        let hotkeyRow = NSStackView(views: [hotkeyLabel, hotkeyRecorder])
        hotkeyRow.orientation = .horizontal
        hotkeyRow.spacing = 8
        let hotkeyNote = NSTextField(wrappingLabelWithString: L10n.t("settings.globalHotkey.note"))
        hotkeyNote.font = .systemFont(ofSize: 11)
        hotkeyNote.textColor = .tertiaryLabelColor

        let stack = NSStackView(views: [layoutRow, viewRow, termRow,
                                        NSBox.separatorLine(), hidden, folders, paneBar,
                                        NSBox.separatorLine(), hotkeyRow, hotkeyNote,
                                        NSBox.separatorLine(), restoreSeeds,
                                        NSBox.separatorLine(), autoUpdate, checkUpdate,
                                        NSBox.separatorLine(), note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        return wrap(stack)
    }

    @objc private func defaultLayoutChanged(_ sender: NSPopUpButton) {
        Preferences.defaultLayoutRaw = sender.selectedTag()
    }

    @objc private func defaultViewChanged(_ sender: NSPopUpButton) {
        Preferences.defaultViewModeRaw = sender.selectedTag()
    }

    @objc private func terminalChanged(_ sender: NSPopUpButton) {
        let idx = sender.indexOfSelectedItem
        guard Preferences.terminalOptions.indices.contains(idx) else { return }
        Preferences.terminalChoice = Preferences.terminalOptions[idx].id
    }

    @objc private func showHiddenChanged(_ sender: NSButton) {
        Preferences.showHiddenByDefault = sender.state == .on
    }

    @objc private func foldersFirstChanged(_ sender: NSButton) {
        Preferences.foldersFirst = sender.state == .on
    }

    @objc private func paneBarChanged(_ sender: NSButton) {
        PaneViewController.paneTabBarVisible = sender.state == .on
        for case let wc as MainWindowController in NSApp.windows.compactMap(\.windowController) {
            wc.grid.setPaneTabBarsVisible(PaneViewController.paneTabBarVisible)
        }
    }

    @objc private func autoCheckUpdatesChanged(_ sender: NSButton) {
        Preferences.autoCheckUpdates = sender.state == .on
    }

    @objc private func checkForUpdates() {
        UpdateController.shared.manualCheck(from: window)
    }

    @objc private func restoreDefaultSeeds() {
        let wcs = NSApp.windows.compactMap { $0.windowController as? MainWindowController }
        guard let first = wcs.first else { return }
        Task { @MainActor in
            let added = await first.sidebar.model.restoreDefaultSeeds()
            for wc in wcs.dropFirst() { wc.sidebar.model.rebuild() }
            Toast.show(String(format: L10n.t("toast.seedsRestored"), added), in: first.window)
        }
    }

    // MARK: 快捷键页（注册表驱动 + 录制）

    private func buildShortcutsTab() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)

        let hint = NSTextField(wrappingLabelWithString: L10n.t("settings.shortcutHint"))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        stack.addArrangedSubview(hint)

        for entry in KeyBindings.registry {
            let label = NSTextField(labelWithString: L10n.t(entry.titleKey))
            label.font = .systemFont(ofSize: 12)
            label.widthAnchor.constraint(equalToConstant: 180).isActive = true
            let recorder = ShortcutRecorderButton(bindingID: entry.id)
            let reset = NSButton()
            reset.image = NSImage(systemSymbolName: "arrow.uturn.backward",
                                  accessibilityDescription: L10n.t("settings.resetKey"))
            reset.isBordered = false
            reset.toolTip = L10n.t("settings.resetKey")
            reset.target = self
            reset.action = #selector(resetBinding(_:))
            reset.identifier = .init(entry.id)
            let row = NSStackView(views: [label, recorder, reset])
            row.orientation = .horizontal
            row.spacing = 8
            stack.addArrangedSubview(row)
        }

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
        ])
        return scroll
    }

    @objc private func resetBinding(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        KeyBindings.reset(id)
        KeyBindings.rebuildMenus()
        // 刷新同排录制钮标题
        if let row = sender.superview as? NSStackView,
           let recorder = row.arrangedSubviews.compactMap({ $0 as? ShortcutRecorderButton }).first {
            recorder.refreshTitle()
        }
    }

    // MARK: 替代 Finder 页（原有内容）

    private let revealCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let revealStatus = NSTextField(wrappingLabelWithString: "")

    private func buildFinderTab() -> NSView {
        // I-28：Reveal 接管（NSFileViewer 全局键，QSpace 同机制）——「打开文件位置/在 Finder 中显示」
        // 族调用改落 NSpace 并选中目标；可随时关闭还给 Finder
        let revealHeader = NSTextField(labelWithString: L10n.t("settings.reveal.title"))
        revealHeader.font = .systemFont(ofSize: 13, weight: .semibold)
        revealCheck.title = L10n.t("settings.reveal.toggle")
        revealCheck.font = .systemFont(ofSize: 12)
        revealCheck.target = self
        revealCheck.action = #selector(revealToggled(_:))
        revealStatus.font = .systemFont(ofSize: 11)
        refreshRevealState()
        let revealNote = NSTextField(wrappingLabelWithString: L10n.t("settings.reveal.note"))
        revealNote.font = .systemFont(ofSize: 11)
        revealNote.textColor = .tertiaryLabelColor

        // I-25 UI 收尾：设默认程序被 OS 锁死后按钮=永败假按钮（违 FG-1），撤按钮改诚实状态陈述
        let folderHeader = NSTextField(labelWithString: L10n.t("settings.folderDefault.title"))
        folderHeader.font = .systemFont(ofSize: 13, weight: .semibold)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor

        let limitation = NSTextField(wrappingLabelWithString: L10n.t("settings.limitationNote"))
        limitation.font = .systemFont(ofSize: 11)
        limitation.textColor = .tertiaryLabelColor

        // 完全磁盘访问的按钮与说明统一收口在「权限」页（I-09 去重），此页只留替代 Finder 主题内容
        let stack = NSStackView(views: [revealHeader, revealCheck, revealStatus, revealNote,
                                        NSBox.separatorLine(),
                                        folderHeader, statusLabel, limitation])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        return wrap(stack)
    }

    private func wrap(_ stack: NSStackView) -> NSView {
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

    private func refreshFinderState() {
        if FinderIntegration.isDefaultFolderHandler {
            // 万一某个未来系统版本解锁——状态照实变绿
            statusLabel.stringValue = L10n.t("settings.isDefault")
            statusLabel.textColor = .systemGreen
        } else {
            statusLabel.stringValue = L10n.t("settings.folderDefault.locked")
            statusLabel.textColor = .secondaryLabelColor
        }
    }

    /// Reveal 接管状态刷新（三态：NSpace/Finder/其他——失效残留给红字警示+勾选即修复）
    private func refreshRevealState() {
        switch FinderIntegration.revealHandler {
        case .nspace:
            revealCheck.state = .on
            revealStatus.stringValue = L10n.t("settings.reveal.on")
            revealStatus.textColor = .systemGreen
        case .finder:
            revealCheck.state = .off
            revealStatus.stringValue = L10n.t("settings.reveal.off")
            revealStatus.textColor = .secondaryLabelColor
        case .other(let id, let resolvable):
            revealCheck.state = .off
            revealStatus.stringValue = String(format: L10n.t(resolvable ? "settings.reveal.other"
                                                                        : "settings.reveal.stale"), id)
            revealStatus.textColor = resolvable ? .secondaryLabelColor : .systemRed
        }
    }

    @objc private func revealToggled(_ sender: NSButton) {
        FinderIntegration.setRevealTakeover(sender.state == .on)
        refreshRevealState()
        Toast.show(L10n.t(sender.state == .on ? "toast.revealOn" : "toast.revealOff"), in: window)
    }

}

extension NSBox {
    static func separatorLine() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}

/// 快捷键录制钮：点击进入录制态，按下组合键即保存；Esc 取消、⌫ 清空
@MainActor
final class ShortcutRecorderButton: NSButton {
    let bindingID: String
    private var monitor: Any?

    init(bindingID: String) {
        self.bindingID = bindingID
        super.init(frame: .zero)
        bezelStyle = .rounded
        font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        target = self
        action = #selector(beginRecording)
        widthAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true
        refreshTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建 UI，无 xib") }

    func refreshTitle() {
        title = KeyBindings.display(bindingID)
    }

    @objc private func beginRecording() {
        guard monitor == nil else { return }
        title = L10n.t("settings.pressKey")
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            defer { self.endRecording() }
            if event.keyCode == 53 {  // Esc 取消
                self.refreshTitle()
                return nil
            }
            if event.keyCode == 51 {  // ⌫ 清空（无快捷键）
                KeyBindings.set(self.bindingID, key: "", mods: [])
                KeyBindings.rebuildMenus()
                self.refreshTitle()
                return nil
            }
            guard let chars = event.charactersIgnoringModifiers, !chars.isEmpty else { return nil }
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            KeyBindings.set(self.bindingID, key: chars.lowercased(), mods: mods)
            KeyBindings.rebuildMenus()
            self.refreshTitle()
            return nil
        }
    }

    private func endRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}


/// 全局热键录制钮（M24）：记录 keyCode+修饰键（Carbon 需 keyCode）；至少一个修饰键；Esc 取消、⌫ 清除
@MainActor
final class GlobalHotkeyRecorderButton: NSButton {
    private var monitor: Any?

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        target = self
        action = #selector(beginRecording)
        widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        refreshTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建 UI，无 xib") }

    func refreshTitle() {
        title = GlobalHotkey.current?.display ?? L10n.t("settings.globalHotkey.unset")
    }

    @objc private func beginRecording() {
        guard monitor == nil else { return }
        title = L10n.t("settings.pressKey")
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            defer { self.endRecording() }
            if event.keyCode == 53 { self.refreshTitle(); return nil }          // Esc 取消
            if event.keyCode == 51 {                                             // ⌫ 清除
                GlobalHotkey.clear()
                self.refreshTitle()
                return nil
            }
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !mods.isEmpty else { NSSound.beep(); self.refreshTitle(); return nil }
            var disp = ""
            if mods.contains(.control) { disp += "⌃" }
            if mods.contains(.option) { disp += "⌥" }
            if mods.contains(.shift) { disp += "⇧" }
            if mods.contains(.command) { disp += "⌘" }
            let keyName: String = {
                switch event.keyCode {
                case 49: return "Space"
                case 36: return "↩"
                case 48: return "⇥"
                default: return (event.charactersIgnoringModifiers ?? "?").uppercased()
                }
            }()
            GlobalHotkey.set(mods: mods, keyCode: UInt32(event.keyCode), display: disp + keyName)
            self.refreshTitle()
            Toast.show(L10n.t("toast.globalHotkeySet"), in: self.window)
            return nil
        }
    }

    private func endRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}

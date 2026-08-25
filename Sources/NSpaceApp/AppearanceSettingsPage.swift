import AppKit

/// 外观设置页（QSpace 外观面 v1 子集）：明暗模式 / 主题色板 / 列表字号 / 活动窗格高亮 / 非活动窗格暗化。
/// 全部即时生效并持久化：明暗·强调色·高亮·暗化经 Theme.broadcastChanged 重刷；字号经列重建路径重刷。
@MainActor
final class AppearanceSettingsPage: NSObject, SettingsPage {
    var pageTitleKey: String { "settings.tab.appearance" }

    /// 明暗模式三选一（0=跟随系统 / 1=浅色 / 2=深色）
    private var modeButtons: [NSButton] = []
    /// 色板按钮（tag=调色板下标；系统项 tag=-1）
    private var accentButtons: [NSButton] = []
    private let dimValueLabel = NSTextField(labelWithString: "")

    func makeView() -> NSView {
        let stack = NSStackView(views: [
            sectionLabel("settings.appearance.mode"),
            buildModeRow(),
            NSBox.separatorLine(),
            sectionLabel("settings.appearance.accent"),
            buildAccentRow(),
            NSBox.separatorLine(),
            buildFontRow(),
            buildHighlightRow(),
            buildDimRow(),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        refreshAccentSelection()

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

    // MARK: 小节标题

    private func sectionLabel(_ key: String) -> NSTextField {
        let label = NSTextField(labelWithString: L10n.t(key))
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        return label
    }

    // MARK: 明暗模式（radio 三选一）

    private func buildModeRow() -> NSView {
        let specs: [(tag: Int, key: String)] = [
            (0, "settings.appearance.system"),
            (1, "settings.appearance.light"),
            (2, "settings.appearance.dark"),
        ]
        let current = modeTag(for: Preferences.appearanceMode)
        for spec in specs {
            let b = NSButton(radioButtonWithTitle: L10n.t(spec.key),
                             target: self, action: #selector(modeChanged(_:)))
            b.tag = spec.tag
            b.font = .systemFont(ofSize: 12)
            b.state = spec.tag == current ? .on : .off
            modeButtons.append(b)
        }
        let row = NSStackView(views: modeButtons)
        row.orientation = .horizontal
        row.spacing = 16
        return row
    }

    private func modeTag(for raw: String) -> Int {
        switch raw {
        case "light": 1
        case "dark": 2
        default: 0
        }
    }

    @objc private func modeChanged(_ sender: NSButton) {
        for b in modeButtons { b.state = b === sender ? .on : .off }
        Preferences.appearanceMode = switch sender.tag {
            case 1: "light"
            case 2: "dark"
            default: "system"
        }
        Theme.broadcastChanged()
    }

    // MARK: 主题色板（8 色 + 系统项）

    private func buildAccentRow() -> NSView {
        // 系统项（tag=-1）：跟随系统强调色
        let systemDot = accentDot(color: .controlAccentColor, tag: -1,
                                  tooltip: L10n.t("accent.system"), showGlyph: true)
        accentButtons.append(systemDot)
        var dots: [NSView] = [systemDot]
        for (i, c) in Theme.accentPalette.enumerated() {
            let dot = accentDot(color: NSColor(hex: c.hex) ?? .controlAccentColor, tag: i,
                                tooltip: L10n.t(c.nameKey), showGlyph: false)
            accentButtons.append(dot)
            dots.append(dot)
        }
        let row = NSStackView(views: dots)
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    /// 单个色点：无边框圆形按钮，选中态加白/灰描边环
    private func accentDot(color: NSColor, tag: Int, tooltip: String, showGlyph: Bool) -> NSButton {
        let b = NSButton()
        b.title = ""
        b.tag = tag
        b.toolTip = tooltip
        b.isBordered = false
        b.wantsLayer = true
        b.target = self
        b.action = #selector(accentChanged(_:))
        b.layer?.cornerRadius = 8
        b.layer?.backgroundColor = color.cgColor
        b.layer?.borderColor = NSColor.controlBackgroundColor.cgColor
        if showGlyph {
            // 系统项加一枚小圆点符号，区别于纯色
            b.image = NSImage(systemSymbolName: "circle.dashed",
                              accessibilityDescription: tooltip)
            b.imagePosition = .imageOnly
            b.contentTintColor = .white
        }
        NSLayoutConstraint.activate([
            b.widthAnchor.constraint(equalToConstant: 16),
            b.heightAnchor.constraint(equalToConstant: 16),
        ])
        return b
    }

    @objc private func accentChanged(_ sender: NSButton) {
        Preferences.accentColorHex = sender.tag < 0 ? nil : Theme.accentPalette[sender.tag].hex
        refreshAccentSelection()
        Theme.broadcastChanged()
    }

    /// 刷新色板选中环（匹配当前偏好）
    private func refreshAccentSelection() {
        let selectedTag: Int
        if let hex = Preferences.accentColorHex,
           let idx = Theme.accentPalette.firstIndex(where: { $0.hex.caseInsensitiveCompare(hex) == .orderedSame }) {
            selectedTag = idx
        } else {
            selectedTag = -1
        }
        for b in accentButtons {
            b.layer?.borderWidth = b.tag == selectedTag ? 2 : 0
        }
    }

    // MARK: 列表字号（11-14 popup）

    private func buildFontRow() -> NSView {
        let label = NSTextField(labelWithString: L10n.t("settings.appearance.fontSize"))
        label.font = .systemFont(ofSize: 12)
        let popup = NSPopUpButton()
        for size in 11...14 {
            popup.addItem(withTitle: "\(size)")
            popup.lastItem?.tag = size
        }
        popup.selectItem(withTag: Preferences.listFontSize)
        popup.target = self
        popup.action = #selector(fontSizeChanged(_:))
        let row = NSStackView(views: [label, popup])
        row.orientation = .horizontal
        row.spacing = 8
        label.widthAnchor.constraint(equalToConstant: 152).isActive = true
        return row
    }

    @objc private func fontSizeChanged(_ sender: NSPopUpButton) {
        Preferences.listFontSize = sender.selectedTag()
        // 复用列重建路径：所有列表视图重建列 + 按新字号重取字体/行高
        NotificationCenter.default.post(name: .nspaceColumnsChanged, object: nil)
    }

    // MARK: 高亮活动窗格

    private func buildHighlightRow() -> NSButton {
        let b = NSButton(checkboxWithTitle: L10n.t("settings.appearance.highlightActive"),
                         target: self, action: #selector(highlightChanged(_:)))
        b.state = Preferences.activePaneHighlight ? .on : .off
        b.font = .systemFont(ofSize: 12)
        return b
    }

    @objc private func highlightChanged(_ sender: NSButton) {
        Preferences.activePaneHighlight = sender.state == .on
        Theme.broadcastChanged()
    }

    // MARK: 非活动窗格暗化（0-30% slider）

    private func buildDimRow() -> NSView {
        let label = NSTextField(labelWithString: L10n.t("settings.appearance.dimInactive"))
        label.font = .systemFont(ofSize: 12)
        let slider = NSSlider(value: Preferences.inactivePaneDimming * 100, minValue: 0, maxValue: 30,
                              target: self, action: #selector(dimChanged(_:)))
        slider.isContinuous = true
        slider.widthAnchor.constraint(equalToConstant: 160).isActive = true
        dimValueLabel.font = .systemFont(ofSize: 11)
        dimValueLabel.textColor = .secondaryLabelColor
        updateDimValueLabel()
        let row = NSStackView(views: [label, slider, dimValueLabel])
        row.orientation = .horizontal
        row.spacing = 8
        label.widthAnchor.constraint(equalToConstant: 152).isActive = true
        return row
    }

    @objc private func dimChanged(_ sender: NSSlider) {
        Preferences.inactivePaneDimming = sender.doubleValue / 100
        updateDimValueLabel()
        Theme.broadcastChanged()
    }

    private func updateDimValueLabel() {
        dimValueLabel.stringValue = "\(Int((Preferences.inactivePaneDimming * 100).rounded()))%"
    }
}

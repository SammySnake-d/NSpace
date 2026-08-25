import AppKit

/// 使用习惯设置页（QSpace 对齐子集）：Enter/Backspace/拖放/双击空白/默认排序/窗格标签上限，
/// 以及底部"打开模式"小节（外部 open-URL 落点）。全部项经 Preferences 外部化，即时生效于新标签/新操作。
@MainActor
final class BehaviorSettingsPage: NSObject, SettingsPage {
    var pageTitleKey: String { "settings.tab.behavior" }

    // 取值表（tag=索引；持久化存字符串/整数值，规避魔法数散落）
    private let enterValues = ["rename", "open"]
    private let backspaceValues = ["ignore", "back", "delete", "up"]
    private let dragValues = ["auto", "copy", "move"]
    private let sortKeyValues = ["name", "dateModified", "size", "kind"]
    private let tabLimitValues = [0, 5, 10, 20]
    private let openTargetValues = ["newTab", "activePane"]

    func makeView() -> NSView {
        let enterRow = radioRow("settings.behavior.enter",
            optionKeys: ["settings.behavior.enter.rename", "settings.behavior.enter.open"],
            selectedTag: enterValues.firstIndex(of: Preferences.enterAction) ?? 0,
            action: #selector(enterChanged(_:)))

        let backspaceRow = popupRow("settings.behavior.backspace",
            optionKeys: ["settings.behavior.backspace.ignore", "settings.behavior.backspace.back",
                         "settings.behavior.backspace.delete", "settings.behavior.backspace.up"],
            selectedTag: backspaceValues.firstIndex(of: Preferences.backspaceAction) ?? 0,
            action: #selector(backspaceChanged(_:)))

        let dragRow = radioRow("settings.behavior.drag",
            optionKeys: ["settings.behavior.drag.auto", "settings.behavior.drag.copy",
                         "settings.behavior.drag.move"],
            selectedTag: dragValues.firstIndex(of: Preferences.dragBehavior) ?? 0,
            action: #selector(dragChanged(_:)))

        let blank = checkRow("settings.behavior.doubleClickBlank",
            checked: Preferences.doubleClickBlank, action: #selector(doubleClickBlankChanged(_:)))

        let sortRow = makeSortRow()

        let tabLimitRow = popupRow("settings.behavior.tabLimit",
            optionKeys: ["settings.behavior.tabLimit.none", "settings.behavior.tabLimit.5",
                         "settings.behavior.tabLimit.10", "settings.behavior.tabLimit.20"],
            selectedTag: tabLimitValues.firstIndex(of: Preferences.paneTabLimit) ?? 0,
            action: #selector(tabLimitChanged(_:)))
        let tabLimitNote = note("settings.behavior.tabLimit.note")

        // I-17：工作区标签上限（M17 新增外部化键，同超限覆盖最老语义）
        let wsLimitRow = popupRow("settings.behavior.wsTabLimit",
            optionKeys: ["settings.behavior.tabLimit.none", "settings.behavior.tabLimit.5",
                         "settings.behavior.tabLimit.10", "settings.behavior.tabLimit.20"],
            selectedTag: tabLimitValues.firstIndex(of: Preferences.workspaceTabLimit) ?? 0,
            action: #selector(wsTabLimitChanged(_:)))

        // 打开模式小节（对应 QSpace"打开到"）
        let openHeader = sectionHeader("settings.behavior.openSection")
        let openRow = popupRow("settings.behavior.openTarget",
            optionKeys: ["settings.behavior.openTarget.newTab", "settings.behavior.openTarget.activePane"],
            selectedTag: openTargetValues.firstIndex(of: Preferences.externalOpenTarget) ?? 0,
            action: #selector(openTargetChanged(_:)))
        let openNote = note("settings.behavior.openTarget.note")

        let stack = NSStackView(views: [
            enterRow, backspaceRow, dragRow, blank, sortRow,
            NSBox.separatorLine(), tabLimitRow, wsLimitRow, tabLimitNote,
            NSBox.separatorLine(), openHeader, openRow, openNote,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        return wrap(stack)
    }

    // MARK: 默认排序行（键 popup + 升降序 popup 并列）

    private func makeSortRow() -> NSView {
        let label = fieldLabel("settings.behavior.sort")
        let keyPopup = NSPopUpButton()
        for (i, key) in ["settings.behavior.sort.name", "settings.behavior.sort.dateModified",
                         "settings.behavior.sort.size", "settings.behavior.sort.kind"].enumerated() {
            keyPopup.addItem(withTitle: L10n.t(key))
            keyPopup.lastItem?.tag = i
        }
        keyPopup.selectItem(withTag: sortKeyValues.firstIndex(of: Preferences.defaultSortKey) ?? 0)
        keyPopup.target = self
        keyPopup.action = #selector(sortKeyChanged(_:))

        let orderPopup = NSPopUpButton()
        for (i, key) in ["settings.behavior.sort.asc", "settings.behavior.sort.desc"].enumerated() {
            orderPopup.addItem(withTitle: L10n.t(key))
            orderPopup.lastItem?.tag = i
        }
        orderPopup.selectItem(withTag: Preferences.defaultSortAscending ? 0 : 1)
        orderPopup.target = self
        orderPopup.action = #selector(sortOrderChanged(_:))

        let row = NSStackView(views: [label, keyPopup, orderPopup])
        row.orientation = .horizontal
        row.spacing = 8
        label.widthAnchor.constraint(equalToConstant: 132).isActive = true
        return row
    }

    // MARK: 行/控件工厂

    private func fieldLabel(_ key: String) -> NSTextField {
        let l = NSTextField(labelWithString: L10n.t(key))
        l.font = .systemFont(ofSize: 12)
        return l
    }

    private func radioRow(_ labelKey: String, optionKeys: [String], selectedTag: Int,
                          action: Selector) -> NSView {
        let label = fieldLabel(labelKey)
        let radios = NSStackView()
        radios.orientation = .horizontal
        radios.spacing = 8
        for (i, key) in optionKeys.enumerated() {
            let b = NSButton(radioButtonWithTitle: L10n.t(key), target: self, action: action)
            b.tag = i
            b.font = .systemFont(ofSize: 12)
            b.state = (i == selectedTag) ? .on : .off
            radios.addArrangedSubview(b)
        }
        let row = NSStackView(views: [label, radios])
        row.orientation = .horizontal
        row.spacing = 8
        label.widthAnchor.constraint(equalToConstant: 132).isActive = true
        return row
    }

    private func popupRow(_ labelKey: String, optionKeys: [String], selectedTag: Int,
                          action: Selector) -> NSView {
        let label = fieldLabel(labelKey)
        let popup = NSPopUpButton()
        for (i, key) in optionKeys.enumerated() {
            popup.addItem(withTitle: L10n.t(key))
            popup.lastItem?.tag = i
        }
        popup.selectItem(withTag: selectedTag)
        popup.target = self
        popup.action = action
        let row = NSStackView(views: [label, popup])
        row.orientation = .horizontal
        row.spacing = 8
        label.widthAnchor.constraint(equalToConstant: 132).isActive = true
        return row
    }

    private func checkRow(_ titleKey: String, checked: Bool, action: Selector) -> NSButton {
        let b = NSButton(checkboxWithTitle: L10n.t(titleKey), target: self, action: action)
        b.state = checked ? .on : .off
        b.font = .systemFont(ofSize: 12)
        return b
    }

    private func sectionHeader(_ key: String) -> NSTextField {
        let l = NSTextField(labelWithString: L10n.t(key))
        l.font = .systemFont(ofSize: 12, weight: .semibold)
        return l
    }

    private func note(_ key: String) -> NSTextField {
        let n = NSTextField(wrappingLabelWithString: L10n.t(key))
        n.font = .systemFont(ofSize: 11)
        n.textColor = .tertiaryLabelColor
        return n
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

    // MARK: 动作（即时落 Preferences）

    @objc private func enterChanged(_ sender: NSButton) {
        guard enterValues.indices.contains(sender.tag) else { return }
        Preferences.enterAction = enterValues[sender.tag]
    }

    @objc private func backspaceChanged(_ sender: NSPopUpButton) {
        let t = sender.selectedTag()
        guard backspaceValues.indices.contains(t) else { return }
        Preferences.backspaceAction = backspaceValues[t]
    }

    @objc private func dragChanged(_ sender: NSButton) {
        guard dragValues.indices.contains(sender.tag) else { return }
        Preferences.dragBehavior = dragValues[sender.tag]
    }

    @objc private func doubleClickBlankChanged(_ sender: NSButton) {
        Preferences.doubleClickBlank = sender.state == .on
    }

    @objc private func sortKeyChanged(_ sender: NSPopUpButton) {
        let t = sender.selectedTag()
        guard sortKeyValues.indices.contains(t) else { return }
        Preferences.defaultSortKey = sortKeyValues[t]
    }

    @objc private func sortOrderChanged(_ sender: NSPopUpButton) {
        Preferences.defaultSortAscending = sender.selectedTag() == 0  // 0=升序 1=降序
    }

    @objc private func tabLimitChanged(_ sender: NSPopUpButton) {
        let t = sender.selectedTag()
        guard tabLimitValues.indices.contains(t) else { return }
        Preferences.paneTabLimit = tabLimitValues[t]
    }

    @objc private func wsTabLimitChanged(_ sender: NSPopUpButton) {
        let t = sender.selectedTag()
        guard tabLimitValues.indices.contains(t) else { return }
        Preferences.workspaceTabLimit = tabLimitValues[t]
    }

    @objc private func openTargetChanged(_ sender: NSPopUpButton) {
        let t = sender.selectedTag()
        guard openTargetValues.indices.contains(t) else { return }
        Preferences.externalOpenTarget = openTargetValues[t]
    }
}

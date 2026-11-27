import AppKit
import BatchRename
import NSpaceContracts

/// 批量重命名面板（驱动 BatchRenamePlanner 实时预览 + BatchRenameNode 原子提交）
@MainActor
final class BatchRenameSheetController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private static var live: BatchRenameSheetController?

    private let panel: NSPanel
    private let sources: [URL]
    private weak var hostWindow: NSWindow?
    private let onConfirm: ([RenamePair]) -> Void

    private let modeControl = NSSegmentedControl()
    private let rulePanelsContainer = NSView()

    // 规则 0：查找替换
    private let findField = NSTextField()
    private let replaceField = NSTextField()
    private let matchCaseCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let regexCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let applyExtCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)

    // 规则 1：前后缀
    private let prefixField = NSTextField()
    private let suffixField = NSTextField()

    // 规则 2：数字序列
    private let seqBaseField = NSTextField()
    private let seqStartField = NSTextField()
    private let seqStepField = NSTextField()
    private let seqPadPopup = NSPopUpButton()
    private let seqPosPopup = NSPopUpButton()

    // 规则 3：大小写
    private let casePopup = NSPopUpButton()

    // 扩展名模式
    private let extPopup = NSPopUpButton()
    private let customExtField = NSTextField()

    private let tableView = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let applyButton = NSButton(title: "", target: nil, action: nil)

    private var previews: [BatchRenamePreview] = []
    private var ruleViews: [NSView] = []

    static func present(sources: [URL], hostWindow: NSWindow?, onConfirm: @escaping ([RenamePair]) -> Void) {
        guard !sources.isEmpty else { return }
        let controller = BatchRenameSheetController(sources: sources, hostWindow: hostWindow, onConfirm: onConfirm)
        live = controller
        controller.updatePreviews()
        if let hostWindow {
            hostWindow.beginSheet(controller.panel) { _ in }
        } else {
            controller.panel.center()
            controller.panel.makeKeyAndOrderFront(nil)
        }
    }

    private init(sources: [URL], hostWindow: NSWindow?, onConfirm: @escaping ([RenamePair]) -> Void) {
        self.sources = sources
        self.hostWindow = hostWindow
        self.onConfirm = onConfirm
        self.panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = L10n.f("batchRename.title", sources.count)
        super.init()
        buildUI()
    }

    private func buildUI() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 440))

        modeControl.segmentCount = 4
        modeControl.setLabel(L10n.t("batchRename.mode.replace"), forSegment: 0)
        modeControl.setLabel(L10n.t("batchRename.mode.affix"), forSegment: 1)
        modeControl.setLabel(L10n.t("batchRename.mode.sequence"), forSegment: 2)
        modeControl.setLabel(L10n.t("batchRename.mode.case"), forSegment: 3)
        modeControl.selectedSegment = 0
        modeControl.target = self
        modeControl.action = #selector(ruleInputsChanged)

        rulePanelsContainer.translatesAutoresizingMaskIntoConstraints = false
        let replacePane = buildReplacePane()
        let affixPane = buildAffixPane()
        let sequencePane = buildSequencePane()
        let casePane = buildCasePane()
        ruleViews = [replacePane, affixPane, sequencePane, casePane]
        for (i, pane) in ruleViews.enumerated() {
            pane.translatesAutoresizingMaskIntoConstraints = false
            pane.isHidden = (i != 0)
            rulePanelsContainer.addSubview(pane)
            NSLayoutConstraint.activate([
                pane.topAnchor.constraint(equalTo: rulePanelsContainer.topAnchor),
                pane.bottomAnchor.constraint(equalTo: rulePanelsContainer.bottomAnchor),
                pane.leadingAnchor.constraint(equalTo: rulePanelsContainer.leadingAnchor),
                pane.trailingAnchor.constraint(equalTo: rulePanelsContainer.trailingAnchor),
            ])
        }

        // 扩展名行
        let extLabel = NSTextField(labelWithString: L10n.t("batchRename.extLabel"))
        extLabel.font = .systemFont(ofSize: 12)
        extPopup.addItems(withTitles: [
            L10n.t("batchRename.ext.keep"),
            L10n.t("batchRename.ext.lower"),
            L10n.t("batchRename.ext.upper"),
            L10n.t("batchRename.ext.replace")
        ])
        extPopup.target = self
        extPopup.action = #selector(ruleInputsChanged)
        customExtField.placeholderString = "txt"
        customExtField.delegate = self
        customExtField.isHidden = true

        // 预览表格
        let colOld = NSTableColumn(identifier: .init("old"))
        colOld.title = L10n.t("batchRename.col.old")
        colOld.width = 232
        let colNew = NSTableColumn(identifier: .init("new"))
        colNew.title = L10n.t("batchRename.col.new")
        colNew.width = 264
        tableView.addTableColumn(colOld)
        tableView.addTableColumn(colNew)
        tableView.rowHeight = 20
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.dataSource = self
        tableView.delegate = self

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        let cancelBtn = NSButton(title: L10n.t("conflict.cancel"), target: self, action: #selector(cancelTapped))
        cancelBtn.bezelStyle = .rounded
        cancelBtn.keyEquivalent = "\u{1b}"

        applyButton.title = L10n.t("batchRename.apply")
        applyButton.bezelStyle = .rounded
        applyButton.keyEquivalent = "\r"
        applyButton.target = self
        applyButton.action = #selector(applyTapped)

        for v in [modeControl, rulePanelsContainer, extLabel, extPopup, customExtField,
                  scroll, statusLabel, cancelBtn, applyButton] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }

        NSLayoutConstraint.activate([
            modeControl.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            modeControl.centerXAnchor.constraint(equalTo: root.centerXAnchor),

            rulePanelsContainer.topAnchor.constraint(equalTo: modeControl.bottomAnchor, constant: 12),
            rulePanelsContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            rulePanelsContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            rulePanelsContainer.heightAnchor.constraint(equalToConstant: 80),

            extLabel.topAnchor.constraint(equalTo: rulePanelsContainer.bottomAnchor, constant: 8),
            extLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            extPopup.centerYAnchor.constraint(equalTo: extLabel.centerYAnchor),
            extPopup.leadingAnchor.constraint(equalTo: extLabel.trailingAnchor, constant: 8),
            customExtField.centerYAnchor.constraint(equalTo: extLabel.centerYAnchor),
            customExtField.leadingAnchor.constraint(equalTo: extPopup.trailingAnchor, constant: 8),
            customExtField.widthAnchor.constraint(equalToConstant: 96),

            scroll.topAnchor.constraint(equalTo: extLabel.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            scroll.bottomAnchor.constraint(equalTo: cancelBtn.topAnchor, constant: -12),

            statusLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            statusLabel.centerYAnchor.constraint(equalTo: applyButton.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: cancelBtn.leadingAnchor, constant: -12),

            cancelBtn.trailingAnchor.constraint(equalTo: applyButton.leadingAnchor, constant: -8),
            cancelBtn.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            applyButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            applyButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])

        panel.contentView = root
    }

    private func buildReplacePane() -> NSView {
        let v = NSView()
        let findLabel = NSTextField(labelWithString: L10n.t("batchRename.find"))
        let repLabel = NSTextField(labelWithString: L10n.t("batchRename.replaceWith"))
        findField.delegate = self
        replaceField.delegate = self
        matchCaseCheck.title = L10n.t("batchRename.matchCase")
        regexCheck.title = L10n.t("batchRename.regex")
        applyExtCheck.title = L10n.t("batchRename.includeExt")
        for c in [matchCaseCheck, regexCheck, applyExtCheck] {
            c.target = self
            c.action = #selector(ruleInputsChanged)
        }
        for sub in [findLabel, findField, repLabel, replaceField, matchCaseCheck, regexCheck, applyExtCheck] as [NSView] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(sub)
        }
        NSLayoutConstraint.activate([
            findLabel.topAnchor.constraint(equalTo: v.topAnchor, constant: 4),
            findLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            findField.centerYAnchor.constraint(equalTo: findLabel.centerYAnchor),
            findField.leadingAnchor.constraint(equalTo: findLabel.trailingAnchor, constant: 8),
            findField.widthAnchor.constraint(equalToConstant: 160),
            repLabel.centerYAnchor.constraint(equalTo: findLabel.centerYAnchor),
            repLabel.leadingAnchor.constraint(equalTo: findField.trailingAnchor, constant: 12),
            replaceField.centerYAnchor.constraint(equalTo: findLabel.centerYAnchor),
            replaceField.leadingAnchor.constraint(equalTo: repLabel.trailingAnchor, constant: 8),
            replaceField.trailingAnchor.constraint(equalTo: v.trailingAnchor),

            matchCaseCheck.topAnchor.constraint(equalTo: findField.bottomAnchor, constant: 12),
            matchCaseCheck.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            regexCheck.centerYAnchor.constraint(equalTo: matchCaseCheck.centerYAnchor),
            regexCheck.leadingAnchor.constraint(equalTo: matchCaseCheck.trailingAnchor, constant: 16),
            applyExtCheck.centerYAnchor.constraint(equalTo: matchCaseCheck.centerYAnchor),
            applyExtCheck.leadingAnchor.constraint(equalTo: regexCheck.trailingAnchor, constant: 16),
        ])
        return v
    }

    private func buildAffixPane() -> NSView {
        let v = NSView()
        let pLabel = NSTextField(labelWithString: L10n.t("batchRename.prefix"))
        let sLabel = NSTextField(labelWithString: L10n.t("batchRename.suffix"))
        prefixField.delegate = self
        suffixField.delegate = self
        for sub in [pLabel, prefixField, sLabel, suffixField] as [NSView] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(sub)
        }
        NSLayoutConstraint.activate([
            pLabel.topAnchor.constraint(equalTo: v.topAnchor, constant: 8),
            pLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            prefixField.centerYAnchor.constraint(equalTo: pLabel.centerYAnchor),
            prefixField.leadingAnchor.constraint(equalTo: pLabel.trailingAnchor, constant: 8),
            prefixField.widthAnchor.constraint(equalToConstant: 160),
            sLabel.centerYAnchor.constraint(equalTo: pLabel.centerYAnchor),
            sLabel.leadingAnchor.constraint(equalTo: prefixField.trailingAnchor, constant: 16),
            suffixField.centerYAnchor.constraint(equalTo: pLabel.centerYAnchor),
            suffixField.leadingAnchor.constraint(equalTo: sLabel.trailingAnchor, constant: 8),
            suffixField.trailingAnchor.constraint(equalTo: v.trailingAnchor),
        ])
        return v
    }

    private func buildSequencePane() -> NSView {
        let v = NSView()
        let bLabel = NSTextField(labelWithString: L10n.t("batchRename.seqBase"))
        let stLabel = NSTextField(labelWithString: L10n.t("batchRename.seqStart"))
        let spLabel = NSTextField(labelWithString: L10n.t("batchRename.seqStep"))
        seqBaseField.stringValue = ""
        seqBaseField.placeholderString = "_"
        seqStartField.stringValue = "1"
        seqStepField.stringValue = "1"
        for f in [seqBaseField, seqStartField, seqStepField] { f.delegate = self }
        seqPadPopup.addItems(withTitles: ["001", "01", "1", "0001"])
        seqPosPopup.addItems(withTitles: [
            L10n.t("batchRename.pos.prefix"),
            L10n.t("batchRename.pos.suffix"),
            L10n.t("batchRename.pos.replace")
        ])
        for p in [seqPadPopup, seqPosPopup] {
            p.target = self
            p.action = #selector(ruleInputsChanged)
        }
        for sub in [bLabel, seqBaseField, seqPosPopup, stLabel, seqStartField, spLabel, seqStepField, seqPadPopup] as [NSView] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(sub)
        }
        NSLayoutConstraint.activate([
            bLabel.topAnchor.constraint(equalTo: v.topAnchor, constant: 4),
            bLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            seqBaseField.centerYAnchor.constraint(equalTo: bLabel.centerYAnchor),
            seqBaseField.leadingAnchor.constraint(equalTo: bLabel.trailingAnchor, constant: 8),
            seqBaseField.widthAnchor.constraint(equalToConstant: 140),
            seqPosPopup.centerYAnchor.constraint(equalTo: bLabel.centerYAnchor),
            seqPosPopup.leadingAnchor.constraint(equalTo: seqBaseField.trailingAnchor, constant: 12),

            stLabel.topAnchor.constraint(equalTo: seqBaseField.bottomAnchor, constant: 12),
            stLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            seqStartField.centerYAnchor.constraint(equalTo: stLabel.centerYAnchor),
            seqStartField.leadingAnchor.constraint(equalTo: stLabel.trailingAnchor, constant: 8),
            seqStartField.widthAnchor.constraint(equalToConstant: 56),
            spLabel.centerYAnchor.constraint(equalTo: stLabel.centerYAnchor),
            spLabel.leadingAnchor.constraint(equalTo: seqStartField.trailingAnchor, constant: 12),
            seqStepField.centerYAnchor.constraint(equalTo: stLabel.centerYAnchor),
            seqStepField.leadingAnchor.constraint(equalTo: spLabel.trailingAnchor, constant: 8),
            seqStepField.widthAnchor.constraint(equalToConstant: 56),
            seqPadPopup.centerYAnchor.constraint(equalTo: stLabel.centerYAnchor),
            seqPadPopup.leadingAnchor.constraint(equalTo: seqStepField.trailingAnchor, constant: 12),
        ])
        return v
    }

    private func buildCasePane() -> NSView {
        let v = NSView()
        let label = NSTextField(labelWithString: L10n.t("batchRename.caseLabel"))
        casePopup.addItems(withTitles: [
            L10n.t("batchRename.case.lower"),
            L10n.t("batchRename.case.upper"),
            L10n.t("batchRename.case.title")
        ])
        casePopup.target = self
        casePopup.action = #selector(ruleInputsChanged)
        for sub in [label, casePopup] as [NSView] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(sub)
        }
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: v.topAnchor, constant: 8),
            label.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            casePopup.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            casePopup.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
        ])
        return v
    }

    @objc private func ruleInputsChanged() {
        let selected = modeControl.selectedSegment
        for (i, rv) in ruleViews.enumerated() {
            rv.isHidden = (i != selected)
        }
        customExtField.isHidden = (extPopup.indexOfSelectedItem != 3)
        updatePreviews()
    }

    func controlTextDidChange(_ obj: Notification) {
        updatePreviews()
    }

    private func currentRule() -> BatchRenameRule {
        switch modeControl.selectedSegment {
        case 1:
            return .addAffix(prefix: prefixField.stringValue, suffix: suffixField.stringValue)
        case 2:
            let start = Int(seqStartField.stringValue) ?? 1
            let step = max(1, Int(seqStepField.stringValue) ?? 1)
            let padMap = [3, 2, 1, 4]
            let padding = padMap[min(max(0, seqPadPopup.indexOfSelectedItem), padMap.count - 1)]
            let posMap: [BatchRenameSequencePosition] = [.prefix, .suffix, .replace]
            let pos = posMap[min(max(0, seqPosPopup.indexOfSelectedItem), posMap.count - 1)]
            return .numberSequence(base: seqBaseField.stringValue, start: start, step: step,
                                   padding: padding, position: pos)
        case 3:
            let modes: [BatchRenameCase] = [.lowercase, .uppercase, .titlecase]
            let mode = modes[min(max(0, casePopup.indexOfSelectedItem), modes.count - 1)]
            return .changeCase(mode)
        default:
            return .replaceText(
                find: findField.stringValue,
                replacement: replaceField.stringValue,
                matchCase: matchCaseCheck.state == .on,
                useRegex: regexCheck.state == .on,
                applyToExtension: applyExtCheck.state == .on
            )
        }
    }

    private func currentExtMode() -> BatchRenameExtMode {
        switch extPopup.indexOfSelectedItem {
        case 1: .lowercase
        case 2: .uppercase
        case 3: .replace(customExtField.stringValue)
        default: .keep
        }
    }

    private func updatePreviews() {
        previews = BatchRenamePlanner.preview(sources: sources, rule: currentRule(), extMode: currentExtMode())
        tableView.reloadData()

        let issues = previews.filter { !$0.isValid }
        let changedCount = previews.filter(\.changed).count
        if !issues.isEmpty {
            statusLabel.textColor = .systemRed
            statusLabel.stringValue = L10n.f("batchRename.issues", issues.count)
            applyButton.isEnabled = false
        } else if changedCount == 0 {
            statusLabel.textColor = .secondaryLabelColor
            statusLabel.stringValue = L10n.t("batchRename.noChanges")
            applyButton.isEnabled = false
        } else {
            statusLabel.textColor = .secondaryLabelColor
            statusLabel.stringValue = L10n.f("batchRename.willRename", changedCount)
            applyButton.isEnabled = true
        }
    }

    @objc private func cancelTapped() {
        closeSheet(confirmed: false)
    }

    @objc private func applyTapped() {
        guard applyButton.isEnabled else { return }
        closeSheet(confirmed: true)
    }

    private func closeSheet(confirmed: Bool) {
        if let hostWindow {
            hostWindow.endSheet(panel)
        }
        panel.orderOut(nil)
        if confirmed {
            let pairs = previews.filter { $0.changed && $0.isValid }
                .map { RenamePair(source: $0.source, newName: $0.newName) }
            onConfirm(pairs)
        }
        BatchRenameSheetController.live = nil
    }

    // MARK: NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { previews.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard previews.indices.contains(row) else { return nil }
        let p = previews[row]
        let cell = NSTextField(labelWithString: "")
        cell.font = .systemFont(ofSize: 12)
        cell.lineBreakMode = .byTruncatingMiddle
        if tableColumn?.identifier.rawValue == "old" {
            cell.stringValue = p.currentName
            cell.textColor = .secondaryLabelColor
        } else if let issue = p.issue {
            cell.stringValue = "\(p.newName) (\(issue))"
            cell.textColor = .systemRed
        } else {
            cell.stringValue = p.newName
            cell.textColor = p.changed ? .labelColor : .tertiaryLabelColor
        }
        return cell
    }
}

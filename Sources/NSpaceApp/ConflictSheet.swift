import AppKit
import NSpaceContracts

// MARK: - 决议状态机（纯逻辑 seam：UI 与 UISelfTest 共用，无 AppKit 依赖，可 headless 断言）

/// 逐冲突推进的决议状态机。checkbox 勾选时按「目标文件夹」批量：
/// 一次决议套用到当前冲突所属文件夹内的全部未决冲突；跨文件夹需分别决议（面板逐文件夹再现）。
struct ConflictDecisionMachine {
    let conflicts: [FileConflict]
    private(set) var decisions: [URL: ConflictDecision] = [:]
    private(set) var cancelled = false

    init(_ conflicts: [FileConflict]) { self.conflicts = conflicts }

    /// 首个尚未决议的冲突（决议后自然推进；批量后跳过整个文件夹）
    var currentConflict: FileConflict? {
        cancelled ? nil : conflicts.first { decisions[$0.source] == nil }
    }
    var isComplete: Bool { cancelled || currentConflict == nil }
    /// nil = 用户取消整个操作（契约：ConflictArbiter 返回 nil）
    var result: [URL: ConflictDecision]? { cancelled ? nil : decisions }

    private func folderKey(_ c: FileConflict) -> String {
        c.existing.deletingLastPathComponent().standardizedFileURL.path
    }

    /// 仅决议当前这一条（未勾 checkbox）
    mutating func decideCurrent(_ d: ConflictDecision) {
        guard let c = currentConflict else { return }
        decisions[c.source] = d
    }

    /// 批量决议：当前冲突所属文件夹内全部未决冲突套用同一决议（勾了 checkbox）。
    /// checkbox 一次只作用于一个文件夹——多文件夹冲突需多次（面板逐文件夹再现）。
    mutating func decideCurrentFolder(_ d: ConflictDecision) {
        guard let c = currentConflict else { return }
        let key = folderKey(c)
        for x in conflicts where decisions[x.source] == nil && folderKey(x) == key {
            decisions[x.source] = d
        }
    }

    mutating func cancel() { cancelled = true }
}

// MARK: - 冲突裁决 Arbiter（内核经此在活动窗口就地弹自绘 sheet）

/// 无状态 → 线程安全（@unchecked Sendable，仅在 MainActor 上触碰 UI）。
final class ConflictSheet: ConflictArbiter, @unchecked Sendable {
    func arbitrate(operation id: UUID, conflicts: [FileConflict]) async -> [URL: ConflictDecision]? {
        await withCheckedContinuation { (cont: CheckedContinuation<[URL: ConflictDecision]?, Never>) in
            Task { @MainActor in
                ConflictSheetController.present(conflicts) { cont.resume(returning: $0) }
            }
        }
    }

    // MARK: UISelfTest headless seam（绝不弹真模态——看门狗会挂死；只驱动决议状态机验批量/推进/取消）

    /// 逐动作驱动状态机，回终局决议；action：("item", d) 决议当前 / ("folder", d) 批量本文件夹 / ("cancel", _)
    @MainActor
    static func uiTestResolve(_ conflicts: [FileConflict],
                              actions: [(String, ConflictDecision?)]) -> [URL: ConflictDecision]? {
        var m = ConflictDecisionMachine(conflicts)
        for (kind, decision) in actions where !m.isComplete {
            switch kind {
            case "item":   if let d = decision { m.decideCurrent(d) }
            case "folder": if let d = decision { m.decideCurrentFolder(d) }
            case "cancel": m.cancel()
            default: break
            }
        }
        return m.result
    }

    /// 面板出现次数（= 需要用户逐次拍板的文件夹数，勾 checkbox 情形）：逐文件夹批量直到全决。
    @MainActor
    static func uiTestFolderPromptCount(_ conflicts: [FileConflict], batchDecision: ConflictDecision) -> Int {
        var m = ConflictDecisionMachine(conflicts)
        var prompts = 0
        while !m.isComplete { prompts += 1; m.decideCurrentFolder(batchDecision) }
        return prompts
    }

    /// 无模态构建并配置首冲突的面板供截图/断言（人眼终审自绘布局；不 beginSheet，不进模态）
    @MainActor
    static func uiTestPanel(_ conflicts: [FileConflict], host: NSWindow) -> NSWindow? {
        ConflictSheetController.uiTestPanel(conflicts, host: host)
    }
}

// MARK: - 自绘 sheet 控制器（三按钮右对齐 取消/合并/替换 + 左下「应用到此文件夹」checkbox；QSpace 观感）

@MainActor
private final class ConflictSheetController: NSObject {
    private static var live: ConflictSheetController?   // 生命周期锚（sheet 存活期间持有自己）

    private let panel: NSPanel
    private let hostWindow: NSWindow
    private var machine: ConflictDecisionMachine
    private let completion: ([URL: ConflictDecision]?) -> Void

    // 内容控件（逐冲突重配置）
    private let titleLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(labelWithString: "")
    private let srcIcon = NSImageView()
    private let srcLabel = NSTextField(labelWithString: "")
    private let dstIcon = NSImageView()
    private let dstLabel = NSTextField(labelWithString: "")
    private let applyFolderCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private var mergeButton: NSButton?

    static func present(_ conflicts: [FileConflict],
                        completion: @escaping ([URL: ConflictDecision]?) -> Void) {
        guard let host = NSApp.keyWindow ?? NSApp.mainWindow, !conflicts.isEmpty else {
            completion(conflicts.isEmpty ? [:] : nil); return
        }
        let c = ConflictSheetController(conflicts: conflicts, host: host, completion: completion)
        live = c
        c.start()
    }

    private init(conflicts: [FileConflict], host: NSWindow,
                 completion: @escaping ([URL: ConflictDecision]?) -> Void) {
        self.hostWindow = host
        self.machine = ConflictDecisionMachine(conflicts)
        self.completion = completion
        self.panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 224),
                             styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        buildContent()
    }

    private func start() {
        guard let conflict = machine.currentConflict else { finish(machine.result); return }
        configure(for: conflict)
        hostWindow.beginSheet(panel) { _ in }   // 决议经按钮 action 走 finish(endSheet)，此回调不承载结果
    }

    /// UISelfTest：无模态构建并配置首冲突，返回面板窗口供截图/断言（不 beginSheet，不持 live）
    static func uiTestPanel(_ conflicts: [FileConflict], host: NSWindow) -> NSWindow? {
        guard let first = conflicts.first else { return nil }
        let c = ConflictSheetController(conflicts: conflicts, host: host, completion: { _ in })
        c.configure(for: first)
        c.panel.layoutIfNeeded()
        return c.panel
    }

    // MARK: 逐冲突重配置

    private func configure(for conflict: FileConflict) {
        titleLabel.stringValue = L10n.f("conflict.title", conflict.existing.lastPathComponent)
        messageLabel.stringValue = L10n.t("conflict.message")
        configureRow(icon: srcIcon, label: srcLabel, title: L10n.t("conflict.source"), url: conflict.source)
        configureRow(icon: dstIcon, label: dstLabel, title: L10n.t("conflict.existing"), url: conflict.existing)
        // 合并仅对「双方都是目录」有意义；文件冲突禁用（保持三按钮布局一致，禁用即诚实不可点）
        mergeButton?.isEnabled = conflict.bothDirectories
        // checkbox 每次面板出现（每文件夹）重置为未勾——勾选是对"这一次这个文件夹"的显式批量选择
        applyFolderCheck.state = .off
    }

    private func configureRow(icon: NSImageView, label: NSTextField, title: String, url: URL) {
        icon.image = NSWorkspace.shared.icon(forFile: url.path)
        icon.image?.size = NSSize(width: 20, height: 20)
        let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey])
        let sizeStr: String = (vals?.isDirectory == true)
            ? "—" : (vals?.fileSize).map { Formatters.size.string(fromByteCount: Int64($0)) } ?? "—"
        let dateStr = vals?.contentModificationDate.map { Formatters.date.string(from: $0) } ?? "—"
        label.stringValue = "\(title)   \(dateStr) · \(sizeStr)"
    }

    // MARK: 动作（勾 checkbox → 批量本文件夹；否则只决当前）

    @objc private func onReplace() { apply(.replace) }
    @objc private func onMerge() { apply(.mergeFolders) }
    @objc private func onCancel() { machine.cancel(); finish(nil) }

    private func apply(_ d: ConflictDecision) {
        if applyFolderCheck.state == .on { machine.decideCurrentFolder(d) } else { machine.decideCurrent(d) }
        if let next = machine.currentConflict { configure(for: next) } else { finish(machine.result) }
    }

    private func finish(_ decisions: [URL: ConflictDecision]?) {
        hostWindow.endSheet(panel)
        panel.orderOut(nil)
        completion(decisions)
        ConflictSheetController.live = nil
    }

    // MARK: 布局构建（4pt 网格；三按钮右对齐 + 左下 checkbox）

    private func buildContent() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 224))

        titleLabel.font = .boldSystemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        messageLabel.font = .systemFont(ofSize: 11)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.maximumNumberOfLines = 2

        for lb in [srcLabel, dstLabel] {
            lb.font = .systemFont(ofSize: 11)
            lb.textColor = .secondaryLabelColor
            lb.lineBreakMode = .byTruncatingMiddle
        }

        applyFolderCheck.title = L10n.t("conflict.applyFolder")
        applyFolderCheck.font = .systemFont(ofSize: 11)

        // 三按钮：取消 / 合并 / 替换（右对齐，替换为默认=回车）
        let cancelB = makeButton("conflict.cancel", #selector(onCancel)); cancelB.keyEquivalent = "\u{1b}"
        let mergeB = makeButton("conflict.merge", #selector(onMerge)); mergeButton = mergeB
        let replaceB = makeButton("conflict.replace", #selector(onReplace)); replaceB.keyEquivalent = "\r"
        let buttonStack = NSStackView(views: [cancelB, mergeB, replaceB])
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 8

        for v in [titleLabel, messageLabel, srcIcon, srcLabel, dstIcon, dstLabel, applyFolderCheck, buttonStack] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }

        let pad: CGFloat = 20
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: pad),
            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: pad),
            titleLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -pad),

            messageLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            messageLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: pad),
            messageLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -pad),

            srcIcon.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 16),
            srcIcon.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: pad),
            srcIcon.widthAnchor.constraint(equalToConstant: 20),
            srcIcon.heightAnchor.constraint(equalToConstant: 20),
            srcLabel.centerYAnchor.constraint(equalTo: srcIcon.centerYAnchor),
            srcLabel.leadingAnchor.constraint(equalTo: srcIcon.trailingAnchor, constant: 8),
            srcLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -pad),

            dstIcon.topAnchor.constraint(equalTo: srcIcon.bottomAnchor, constant: 8),
            dstIcon.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: pad),
            dstIcon.widthAnchor.constraint(equalToConstant: 20),
            dstIcon.heightAnchor.constraint(equalToConstant: 20),
            dstLabel.centerYAnchor.constraint(equalTo: dstIcon.centerYAnchor),
            dstLabel.leadingAnchor.constraint(equalTo: dstIcon.trailingAnchor, constant: 8),
            dstLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -pad),

            applyFolderCheck.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: pad),
            applyFolderCheck.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -pad),
            buttonStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -pad),
            buttonStack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -pad),
            buttonStack.leadingAnchor.constraint(greaterThanOrEqualTo: applyFolderCheck.trailingAnchor, constant: 12),
        ])
        panel.contentView = root
    }

    private func makeButton(_ key: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: L10n.t(key), target: self, action: action)
        b.bezelStyle = .rounded
        return b
    }
}

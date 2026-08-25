import AppKit
import NSpaceKernel
import NSpaceContracts

/// 操作进度窗（单例）：订阅 kernel.projections()，每操作一行。
/// >0.5s 未终态才 orderFront；全部终态 2s 后自动关闭；失败行就地红字。
@MainActor
final class ProgressWindowController: NSWindowController {
    static let shared = ProgressWindowController()

    private var kernel: OperationKernel?
    private var streamTask: Task<Void, Never>?
    private var rows: [UUID: ProgressRowView] = [:]
    private var rates: [UUID: (bytes: Int64, at: Date)] = [:]
    private let stack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: L10n.t("progress.empty"))
    private var pendingShow: Task<Void, Never>?
    private var pendingHide: Task<Void, Never>?

    private init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 120),
                            styleMask: [.titled, .closable, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = L10n.t("progress.title")
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        super.init(window: panel)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            content.heightAnchor.constraint(greaterThanOrEqualToConstant: 96),
        ])
        panel.contentView = content
        updateEmptyState()
    }

    /// 空态:无任务时给"暂无任务"说明,而不是一块空白(用户报告)
    private func updateEmptyState() {
        emptyLabel.isHidden = !rows.isEmpty
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建 UI，无 xib") }

    /// 工具栏"任务状态"图标：手动开关任务窗
    @objc func toggleVisible(_ sender: Any?) {
        if window?.isVisible == true {
            window?.orderOut(nil)
        } else {
            updateEmptyState()
            window?.center()
            window?.makeKeyAndOrderFront(nil)
        }
    }

    func start(kernel: OperationKernel) {
        guard streamTask == nil else { return }
        self.kernel = kernel
        streamTask = Task { [weak self] in
            guard let stream = await self?.kernel?.projections() else { return }
            for await p in stream {
                self?.apply(p)
            }
        }
    }

    // MARK: 投影消费

    private func apply(_ p: OperationProjection) {
        let row: ProgressRowView
        if let existing = rows[p.id] {
            row = existing
        } else {
            row = ProgressRowView(kind: p.kind)
            row.onCancel = { [weak self] in Task { await self?.kernel?.cancel(p.id) } }
            rows[p.id] = row
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        }
        row.update(p, rate: rate(for: p))
        updateEmptyState()
        window?.layoutIfNeeded()
        scheduleVisibility()
    }

    /// 字节速率：相邻两次投影的字节增量 / 时间增量
    private func rate(for p: OperationProjection) -> Double? {
        let now = Date()
        defer { rates[p.id] = (p.bytesDone, now) }
        guard let prev = rates[p.id] else { return nil }
        let dt = now.timeIntervalSince(prev.at)
        guard dt > 0.01, p.bytesDone >= prev.bytes else { return nil }
        return Double(p.bytesDone - prev.bytes) / dt
    }

    // MARK: 显隐时序（>0.5s 才显；全终态 2s 后关）

    private var hasActive: Bool { rows.values.contains { !$0.isTerminal } }

    private func scheduleVisibility() {
        if hasActive {
            pendingHide?.cancel(); pendingHide = nil
            if window?.isVisible != true, pendingShow == nil {
                pendingShow = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    guard let self, !Task.isCancelled, self.hasActive else { self?.pendingShow = nil; return }
                    self.window?.center()
                    self.window?.orderFront(nil)
                    self.pendingShow = nil
                }
            }
        } else {
            pendingShow?.cancel(); pendingShow = nil
            // 全终态：无论窗口是否显示都要清理累积的行（隐藏窗口也需回收）
            if !rows.isEmpty, pendingHide == nil {
                pendingHide = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    guard let self, !Task.isCancelled, !self.hasActive else { self?.pendingHide = nil; return }
                    if self.window?.isVisible == true { self.window?.orderOut(nil) }
                    self.clearRows()
                    self.pendingHide = nil
                }
            }
        }
    }

    private func clearRows() {
        rows.values.forEach { $0.removeFromSuperview() }
        rows.removeAll()
        rates.removeAll()
    }
}

/// 单操作行：kind 图标 + 进度条 + 当前文件 + 字节速率 + 取消按钮；失败就地红字
@MainActor
final class ProgressRowView: NSView {
    var onCancel: (() -> Void)?
    private(set) var isTerminal = false

    private let icon = NSImageView()
    private let bar = NSProgressIndicator()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let cancelButton = NSButton()

    init(kind: OperationSpec.Kind) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        icon.image = NSImage(systemSymbolName: Self.symbol(kind),
                             accessibilityDescription: nil)
        icon.contentTintColor = .controlAccentColor
        bar.isIndeterminate = false
        bar.minValue = 0; bar.maxValue = 1
        bar.controlSize = .small
        title.font = .systemFont(ofSize: 11)
        title.lineBreakMode = .byTruncatingMiddle
        detail.font = .systemFont(ofSize: 10)
        detail.textColor = .secondaryLabelColor
        cancelButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: L10n.t("progress.cancel"))
        cancelButton.isBordered = false
        cancelButton.bezelStyle = .inline
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        cancelButton.toolTip = L10n.t("progress.cancel")

        for v in [icon, bar, title, detail, cancelButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor),
            icon.topAnchor.constraint(equalTo: topAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),
            cancelButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            cancelButton.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            cancelButton.widthAnchor.constraint(equalToConstant: 20),
            bar.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            bar.trailingAnchor.constraint(equalTo: cancelButton.leadingAnchor, constant: -8),
            bar.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            title.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            title.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            title.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 2),
            detail.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
            detail.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建 UI，无 xib") }

    @objc private func cancelTapped() { onCancel?() }

    func update(_ p: OperationProjection, rate: Double?) {
        isTerminal = p.state.isTerminal
        if p.bytesTotal > 0 {
            bar.isIndeterminate = false
            bar.doubleValue = min(1, Double(p.bytesDone) / Double(p.bytesTotal))
        } else if !p.state.isTerminal {
            bar.isIndeterminate = true
            bar.startAnimation(nil)
        }

        switch p.state {
        case .failed(let message, _):
            bar.stopAnimation(nil)
            title.stringValue = message
            title.textColor = .systemRed
            detail.stringValue = ""
            cancelButton.isHidden = true
        case .completed:
            bar.doubleValue = 1
            title.stringValue = (p.currentPath as NSString?)?.lastPathComponent ?? ""
            title.textColor = .labelColor
            detail.stringValue = L10n.t("progress.done")
            cancelButton.isHidden = true
        case .cancelled:
            title.stringValue = L10n.t("progress.cancelled")
            title.textColor = .secondaryLabelColor
            detail.stringValue = ""
            cancelButton.isHidden = true
        default:
            title.textColor = .labelColor
            title.stringValue = (p.currentPath as NSString?)?.lastPathComponent ?? L10n.t("progress.preparing")
            let counts = "\(p.filesDone)/\(max(p.filesTotal, p.filesDone))"
            let rateStr = rate.map { " · " + Formatters.size.string(fromByteCount: Int64($0)) + "/s" } ?? ""
            detail.stringValue = counts + rateStr
            cancelButton.isHidden = false
        }
    }

    private static func symbol(_ kind: OperationSpec.Kind) -> String {
        switch kind {
        case .copy: "doc.on.doc"
        case .move: "arrow.right"
        case .trash: "trash"
        case .duplicate: "plus.square.on.square"
        case .rename: "pencil"
        case .newFolder: "folder.badge.plus"
        case .newFile: "doc.badge.plus"
        case .compress: "doc.zipper"
        case .extract: "arrow.up.bin"
        }
    }
}

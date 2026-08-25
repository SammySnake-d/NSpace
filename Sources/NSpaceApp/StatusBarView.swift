import AppKit

/// 窗格底部状态条（QSpace 式，24pt）：左侧"N 项（已选 M 项）"，右侧"可用 X GB"。
/// 卷容量只在目录变化/标签切换时读一次（statfs 级只读开销），绝不轮询——北极星零空闲功耗。
@MainActor
final class StatusBarView: NSView {
    private let countLabel = NSTextField(labelWithString: "")
    private let spaceLabel = NSTextField(labelWithString: "")
    /// 选中药丸（10% accent 底、圆角=高/2、等宽数字）：有选中才显；无选中只留总数 countLabel
    private let selectionPill = NSView()
    private let selectionLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        // 计数/可用容量：等宽数字（tabular-nums）——刷新时数字不抖动（塔夫特）
        for label in [countLabel, spaceLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }

        // 选中药丸（参照暂存计数药丸）：24pt 条内 16pt 居中，圆角 8=高/2
        selectionPill.wantsLayer = true
        selectionPill.layer?.cornerRadius = 8
        selectionPill.isHidden = true
        selectionPill.identifier = .init("statusSelectionPill")
        selectionPill.translatesAutoresizingMaskIntoConstraints = false
        selectionLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        selectionLabel.textColor = .labelColor
        selectionLabel.lineBreakMode = .byTruncatingTail
        selectionLabel.translatesAutoresizingMaskIntoConstraints = false
        selectionPill.addSubview(selectionLabel)
        addSubview(selectionPill)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            countLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            selectionPill.leadingAnchor.constraint(equalTo: countLabel.trailingAnchor, constant: 8),
            selectionPill.centerYAnchor.constraint(equalTo: centerYAnchor),
            selectionPill.heightAnchor.constraint(equalToConstant: 16),
            selectionLabel.leadingAnchor.constraint(equalTo: selectionPill.leadingAnchor, constant: 8),
            selectionLabel.trailingAnchor.constraint(equalTo: selectionPill.trailingAnchor, constant: -8),
            selectionLabel.centerYAnchor.constraint(equalTo: selectionPill.centerYAnchor),
            spaceLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            spaceLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            selectionPill.trailingAnchor.constraint(lessThanOrEqualTo: spaceLabel.leadingAnchor, constant: -8),
        ])
        applyAccentColor()
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged),
                                               name: .nspaceThemeChanged, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建 UI，无 xib") }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// UISelfTest 探针：选中药丸当前是否可见
    var selectionPillVisible: Bool { !selectionPill.isHidden }

    /// 药丸底 10% accent（外观感知：随明暗/强调色变更重解析——见 StashShelfView.applyAccentColors）
    private func applyAccentColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            selectionPill.layer?.backgroundColor = Theme.accent.withAlphaComponent(0.10).cgColor
        }
    }

    @objc private func themeChanged() { applyAccentColor() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAccentColor()
    }

    // 外观感知不透明底衬：用 updateLayer 让明暗切换自动重解析——原先无底衬时，
    // 深色外观下这条 24pt 状态条在自渲染截图中不可见（项数/可用空间读不到）。
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }

    /// 计数：countLabel 恒显总数"N 项"；有选中时药丸显"已选 M 项 · 大小"，无选中隐藏药丸
    func update(itemCount: Int, selectedCount: Int, selectedBytes: Int64) {
        countLabel.stringValue = String(format: L10n.t("status.items"), itemCount)
        if selectedCount > 0 {
            let sizeStr = selectedBytes > 0 ? Formatters.size.string(fromByteCount: selectedBytes) : ""
            selectionLabel.stringValue = sizeStr.isEmpty
                ? String(format: L10n.t("status.selectedCount"), selectedCount)
                : String(format: L10n.t("status.selectedPill"), selectedCount, sizeStr)
            selectionPill.isHidden = false
        } else {
            selectionPill.isHidden = true
        }
    }

    /// 右侧可用空间：读当前目录所在卷的重要用途可用容量（只读一次，不轮询）；
    /// 读不到或为 0（只读卷 DMG 等）则留空，不显示误导性"0 KB 可用"
    func updateVolume(for url: URL) {
        let capacity = (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        spaceLabel.stringValue = capacity > 0
            ? String(format: L10n.t("status.available"), Formatters.size.string(fromByteCount: capacity))
            : ""
    }
}

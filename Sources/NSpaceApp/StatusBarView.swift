import AppKit

/// 窗格底部状态条（QSpace 式，22pt）：左侧"N 项（已选 M 项）"，右侧"可用 X GB"。
/// 卷容量只在目录变化/标签切换时读一次（statfs 级只读开销），绝不轮询——北极星零空闲功耗。
@MainActor
final class StatusBarView: NSView {
    private let countLabel = NSTextField(labelWithString: "")
    private let spaceLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        for label in [countLabel, spaceLabel] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 22),
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            countLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            spaceLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            spaceLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            countLabel.trailingAnchor.constraint(lessThanOrEqualTo: spaceLabel.leadingAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建 UI，无 xib") }

    /// 左侧计数：有选中显示"N 项（已选 M 项）"，否则"N 项"
    func update(itemCount: Int, selectedCount: Int) {
        countLabel.stringValue = selectedCount > 0
            ? String(format: L10n.t("status.itemsSelected"), itemCount, selectedCount)
            : String(format: L10n.t("status.items"), itemCount)
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

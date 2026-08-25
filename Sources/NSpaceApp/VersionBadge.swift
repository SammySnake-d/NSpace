import AppKit

/// App 版本读取（唯一读取点）：走 Bundle.main 的 Info.plist（.app 包内由 build-app.sh 注入
/// CFBundleShortVersionString=VERSION / CFBundleVersion=git 提交数）。
/// 裸二进制（swift run 开发态）无 Info.plist 时回退占位，不崩。
@MainActor
enum AppVersion {
    /// 短版本号（如 "0.9.3"）；缺省回退 "0.0.0"
    static var shortVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
            .flatMap { $0.isEmpty ? nil : $0 } ?? "0.0.0"
    }

    /// 构建号（如 "482"）；缺省回退 "0"
    static var buildNumber: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String)
            .flatMap { $0.isEmpty ? nil : $0 } ?? "0"
    }
}

/// 版本徽章（M22）：甲板工作区标签条最右端（"＋"按钮左侧）的小药丸。
/// 常态：文字"v{短版本}"、11px tabular-nums、10% 中性浅底、tooltip"NSpace vX.Y.Z (build N)"。
/// 有可用更新：文字后加" ↑"、底色改 Theme.accent 18%、tooltip 变提示、可点击触发更新流程。
/// 铁律 BG-1：本视图只显示与转发点击，下载/替换全在 UpdateEngine 胶囊（经 onClick 回调上抛甲板）。
/// 零新增配色：常态用系统语义色（labelColor 低透明），更新态用 Theme.accent。
@MainActor
final class VersionBadgeView: NSView {
    /// 点击回调（仅更新态可点；由甲板转发至 UpdateController）
    var onClick: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private var updateAvailable = false

    /// 甲板位于标题栏区（fullSizeContentView）：不覆写则点击被窗口拖拽机制吞掉（同 TabBarView）
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8

        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 20),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        applyState()
        // 主题强调色变更后重刷（更新态底色/文字用 Theme.accent）
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged),
                                               name: .nspaceThemeChanged, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建 UI，无 xib") }

    /// 更新可用态切换（nil=无更新；非 nil=有新版 vX.Y.Z）。
    func setUpdateAvailable(_ available: Bool, latestVersion: String? = nil) {
        updateAvailable = available
        latestVersionCache = latestVersion
        applyState(latestVersion: latestVersion)
    }

    private func applyState(latestVersion: String? = nil) {
        let v = AppVersion.shortVersion
        if updateAvailable {
            label.stringValue = "v\(v) ↑"
            label.textColor = Theme.accent
            layer?.backgroundColor = Theme.accent.withAlphaComponent(0.18).cgColor
            let latest = latestVersion ?? ""
            toolTip = latest.isEmpty
                ? L10n.t("badge.updateAvailableGeneric")
                : L10n.f("badge.updateAvailable", latest)
        } else {
            label.stringValue = "v\(v)"
            label.textColor = .secondaryLabelColor
            // 10% 中性浅底（系统语义色，零新增配色）
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.1).cgColor
            toolTip = L10n.f("badge.tooltip", v, AppVersion.buildNumber)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard updateAvailable else { super.mouseDown(with: event); return }
        onClick?()
    }

    /// 主题色变更后重刷（更新态底色/文字用 Theme.accent）
    func refreshTheme() { applyState(latestVersion: latestVersionCache) }

    private var latestVersionCache: String?

    @objc private func themeChanged() { refreshTheme() }
}

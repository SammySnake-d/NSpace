import AppKit
import UpdateEngine

/// 热更新编排（App 层，@MainActor）：拥有 UpdateEngine 胶囊，串起"检查→徽章→下载→安装→重启"。
/// 铁律 BG-1：所有下载/解压/文件替换在 UpdateEngine 胶囊内完成；本控制器只做编排、读 Preferences、
/// 驱动徽章与 L1 吐司/重启提示。App 层允许单例（pod-lint 只约束胶囊 Axiom 2）。
@MainActor
final class UpdateController {
    static let shared = UpdateController()

    private let engine = UpdateEngine()
    /// 当前已知的可用更新（nil=无）；徽章与流程据此
    private(set) var available: UpdateInfo?
    /// 下载/安装进行中（防重入：徽章重复点击、检查与安装并发）
    private var busy = false

    private init() {}

    private var feedURL: URL? { URL(string: Preferences.updateFeedURL) }

    // MARK: 自动检查（启动后台，20 小时节流，失败静默）

    /// autoCheckUpdates 开且距 lastUpdateCheck > 20 小时 → 异步检查；失败静默，不打扰。
    func autoCheckIfDue() {
        guard Preferences.autoCheckUpdates else { return }
        let now = Date().timeIntervalSince1970
        let elapsed = now - Preferences.lastUpdateCheck
        guard elapsed > 20 * 3600 else { return }
        guard let url = feedURL else { return }
        Task { [weak self] in
            guard let self else { return }
            let info = try? await self.engine.check(feedURL: url, currentVersion: AppVersion.shortVersion)
            Preferences.lastUpdateCheck = Date().timeIntervalSince1970
            if let info { self.markAvailable(info) }
        }
    }

    // MARK: 手动检查（设置-通用页按钮；有新版走徽章流程，无新版/失败吐司告知）

    func manualCheck(from window: NSWindow?) {
        guard let url = feedURL else {
            Toast.show(L10n.t("update.badFeedURL"), in: window)
            return
        }
        Toast.show(L10n.t("update.checking"), in: window)
        Task { [weak self] in
            guard let self else { return }
            do {
                let info = try await self.engine.check(feedURL: url, currentVersion: AppVersion.shortVersion)
                Preferences.lastUpdateCheck = Date().timeIntervalSince1970
                if let info {
                    self.markAvailable(info)
                    Toast.show(L10n.f("update.found", info.version), in: window)
                } else {
                    self.available = nil
                    self.refreshBadges()
                    Toast.show(L10n.t("update.upToDate"), in: window)
                }
            } catch {
                Toast.show(L10n.f("update.checkFailed", (error as NSError).localizedDescription), in: window)
            }
        }
    }

    // MARK: 徽章点击 → 下载 + 安装 + 重启提示

    func startUpdateFlow(from window: NSWindow?) {
        guard !busy, let info = available else { return }
        busy = true
        Toast.show(L10n.t("update.downloading"), in: window)
        Task { [weak self] in
            guard let self else { return }
            defer { self.busy = false }
            do {
                let staged = try await self.engine.downloadAndStage(info: info)
                try await self.engine.install(staged: staged, into: Bundle.main.bundleURL)
                self.presentRestart(from: window, version: info.version)
            } catch {
                Toast.show(L10n.f("update.installFailed", (error as NSError).localizedDescription), in: window)
            }
        }
    }

    // MARK: 私有

    /// 记录可用更新并刷新所有窗口徽章为"↑"态。
    private func markAvailable(_ info: UpdateInfo) {
        available = info
        refreshBadges()
    }

    /// 广播徽章态到所有主窗甲板。
    private func refreshBadges() {
        for case let wc as MainWindowController in NSApp.windows.compactMap(\.windowController) {
            wc.deck.versionBadge.setUpdateAvailable(available != nil, latestVersion: available?.version)
        }
    }

    /// 安装成功：提示重启（L1 吐司告知就绪 + 交互确认重启，因 L1 吐司本身不可点）。
    /// 重启 = open 新实例（就地已替换的 .app）+ NSApp.terminate。
    private func presentRestart(from window: NSWindow?, version: String) {
        Toast.show(L10n.t("update.ready"), in: window)
        let alert = NSAlert()
        alert.messageText = L10n.f("update.readyTitle", version)
        alert.informativeText = L10n.t("update.readyBody")
        alert.addButton(withTitle: L10n.t("update.restartNow"))
        alert.addButton(withTitle: L10n.t("update.later"))
        let respond: (NSApplication.ModalResponse) -> Void = { resp in
            MainActor.assumeIsolated {
                if resp == .alertFirstButtonReturn { UpdateController.relaunch() }
            }
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: respond)
        } else {
            respond(alert.runModal())
        }
    }

    /// 重启当前 App：以新实例打开就地更新后的 .app，再终止本进程。
    static func relaunch() {
        let bundleURL = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }
}

import AppKit
import UniformTypeIdentifiers

/// Finder 替代集成：把 NSpace 注册为 public.folder 默认打开程序。
/// 诚实限制（与 QSpace 相同）：NSWorkspace.activateFileViewerSelecting 类
/// "Reveal in Finder" 硬编码发给 Finder，无法拦截；能接管的是 LaunchServices
/// 打开文件夹的路径（open 命令、第三方 App 的"打开文件夹"）。
@MainActor
enum FinderIntegration {
    /// 当前 public.folder 的默认处理程序是否已是本 App（设置页据此照实显示状态；
    /// 万一未来某个系统版本解锁 public.folder，状态会自动变绿）。
    static var isDefaultFolderHandler: Bool {
        guard let handler = NSWorkspace.shared.urlForApplication(toOpen: .folder) else { return false }
        return handler.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    // 注：曾有 requestDefaultFolderHandler 申请成为默认文件夹程序，但 macOS 把 public.folder
    // 锁死给 Finder——setDefaultApplication(toOpen: .folder) 恒返回 paramErr(-50)，实测连已公证的
    // 第三方 App 也设不了。故该方法是永败死代码，已删；设置页(I-25)改为诚实状态陈述而非永败按钮。

    /// 打开系统设置的完全磁盘访问面板（TCC 引导）。
    /// 先跑一次只读探测：访问受保护目录的尝试会让 TCC 自动把 NSpace 挂进 FDA 列表
    /// （用户无需点"＋"，直接拨开关——与其他 App 的"自动出现在列表"同机制）。
    static func openFullDiskAccessSettings() {
        _ = hasFullDiskAccess()
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }

    /// 完全磁盘访问探测（只读，不违 BG-1）：尝试列出受 TCC 保护目录（Safari/Mail）。
    /// 能列出（即便空目录）= 已授权；被拒时 contentsOfDirectory 抛错 → 未授权。
    static func hasFullDiskAccess() -> Bool {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        for probe in ["Library/Safari", "Library/Mail"] {
            let url = home.appendingPathComponent(probe)
            var isDir: ObjCBool = false
            // 目录本身可 stat（TCC 只挡内容读取）；不存在则跳过（未启用 Mail 等）
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
            if (try? fm.contentsOfDirectory(atPath: url.path)) != nil { return true }
        }
        return false
    }

    // MARK: Reveal 接管（I-28：NSFileViewer 全局键——QSpace 同机制，实验实证 2026-08-26）
    // `open -R`/第三方"打开文件位置"走此键路由；普通"打开文件夹"默认程序仍被 OS 锁定 Finder。

    /// Reveal 处理者三态
    enum RevealHandler: Equatable {
        case nspace
        case finder
        /// 指向其他 bundle id；resolvable=false 即残留失效（如已删的 QSpace）——点"打开位置"会没反应
        case other(id: String, resolvable: Bool)
    }

    static var revealHandler: RevealHandler {
        guard let id = CFPreferencesCopyValue("NSFileViewer" as CFString,
                                              kCFPreferencesAnyApplication,
                                              kCFPreferencesCurrentUser,
                                              kCFPreferencesAnyHost) as? String, !id.isEmpty else {
            return .finder
        }
        if id == "com.nspace.NSpace" { return .nspace }
        let resolvable = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil
        return .other(id: id, resolvable: resolvable)
    }

    /// 开/关 Reveal 接管：写/删全局 NSFileViewer 键（即时生效，无需重启系统组件）
    static func setRevealTakeover(_ on: Bool) {
        CFPreferencesSetValue("NSFileViewer" as CFString,
                              on ? "com.nspace.NSpace" as CFString : nil,
                              kCFPreferencesAnyApplication,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(kCFPreferencesAnyApplication,
                                 kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }
}

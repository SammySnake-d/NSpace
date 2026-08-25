import AppKit
import UniformTypeIdentifiers

/// Finder 替代集成：把 NSpace 注册为 public.folder 默认打开程序。
/// 诚实限制（与 QSpace 相同）：NSWorkspace.activateFileViewerSelecting 类
/// "Reveal in Finder" 硬编码发给 Finder，无法拦截；能接管的是 LaunchServices
/// 打开文件夹的路径（open 命令、第三方 App 的"打开文件夹"）。
@MainActor
enum FinderIntegration {
    /// 当前 public.folder 的默认处理程序是否已是本 App
    static var isDefaultFolderHandler: Bool {
        guard let handler = NSWorkspace.shared.urlForApplication(toOpen: .folder) else { return false }
        return handler.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    /// 申请成为默认文件夹处理程序（系统会弹确认对话框）
    static func requestDefaultFolderHandler(completion: @escaping @MainActor (Error?) -> Void) {
        NSWorkspace.shared.setDefaultApplication(
            at: Bundle.main.bundleURL, toOpen: .folder) { error in
            Task { @MainActor in completion(error) }
        }
    }

    /// 打开系统设置的完全磁盘访问面板（TCC 引导）
    static func openFullDiskAccessSettings() {
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
}

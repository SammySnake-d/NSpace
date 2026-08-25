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
}

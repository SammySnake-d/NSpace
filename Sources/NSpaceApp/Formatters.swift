import AppKit
import UniformTypeIdentifiers
import NSpaceContracts

/// 展示格式化器：全部缓存复用（DateFormatter/ByteCountFormatter 构造昂贵）；
/// kind 显示串与图标按 UTType 缓存（万级目录滚动零重复计算）
@MainActor
enum Formatters {
    /// 列表/单元格字号（外观设置项；读 Preferences.listFontSize）——变更后经列重建路径重刷
    static var listFontSize: CGFloat { CGFloat(Preferences.listFontSize) }

    static let date: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    static let size: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    private static var kindCache: [String: String] = [:]
    private static var iconCache: [String: NSImage] = [:]
    private static var fullIconCache: [String: NSImage] = [:]

    static func kind(forTypeID id: String?, isDirectory: Bool) -> String {
        guard let id else { return isDirectory ? L10n.t("kind.folder") : L10n.t("kind.document") }
        if let cached = kindCache[id] { return cached }
        let name = UTType(id)?.localizedDescription
            ?? (isDirectory ? L10n.t("kind.folder") : L10n.t("kind.document"))
        kindCache[id] = name
        return name
    }

    /// 图标双路径：普通文件走 UTType 通用图标（同步快路径，按类型缓存）；
    /// 包/应用（.app 等）的真实图标存于 bundle 内，必须按文件路径读，否则显示空白——按路径缓存
    static func icon(for item: FileItem) -> NSImage {
        if item.isPackage {
            let key = "path:" + item.url.path
            if let cached = iconCache[key] { return cached }
            let image = NSWorkspace.shared.icon(forFile: item.url.path)
            image.size = NSSize(width: 16, height: 16)
            iconCache[key] = image
            return image
        }
        let key = item.contentTypeID ?? (item.isDirectory ? "public.folder" : "public.data")
        if let cached = iconCache[key] { return cached }
        let type = UTType(key) ?? (item.isDirectory ? .folder : .data)
        let image = NSWorkspace.shared.icon(for: type)
        image.size = NSSize(width: 16, height: 16)
        iconCache[key] = image
        return image
    }

    /// 大图标（图标网格/分栏预览列用）：保留系统多分辨率表示、不改 size——
    /// 与 16pt 列表缓存分开（NSImage.size 是共享可变态，混用会把列表图标撑大）；显示端由 NSImageView 按需缩放
    static func fullIcon(for item: FileItem) -> NSImage {
        let key: String = item.isPackage
            ? "path:" + item.url.path
            : (item.contentTypeID ?? (item.isDirectory ? "public.folder" : "public.data"))
        if let cached = fullIconCache[key] { return cached }
        let image: NSImage = item.isPackage
            ? NSWorkspace.shared.icon(forFile: item.url.path)
            : NSWorkspace.shared.icon(for: UTType(key) ?? (item.isDirectory ? .folder : .data))
        fullIconCache[key] = image
        return image
    }
}

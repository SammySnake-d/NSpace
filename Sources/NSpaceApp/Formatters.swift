import AppKit
import UniformTypeIdentifiers

/// 展示格式化器：全部缓存复用（DateFormatter/ByteCountFormatter 构造昂贵）；
/// kind 显示串与图标按 UTType 缓存（万级目录滚动零重复计算）
@MainActor
enum Formatters {
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

    static func kind(forTypeID id: String?, isDirectory: Bool) -> String {
        guard let id else { return isDirectory ? L10n.t("kind.folder") : L10n.t("kind.document") }
        if let cached = kindCache[id] { return cached }
        let name = UTType(id)?.localizedDescription
            ?? (isDirectory ? L10n.t("kind.folder") : L10n.t("kind.document"))
        kindCache[id] = name
        return name
    }

    /// UTType 通用图标：同步快路径（逐文件精确图标/缩略图由 IconThumb 胶囊在 M10 升级）
    static func icon(forTypeID id: String?, isDirectory: Bool) -> NSImage {
        let key = id ?? (isDirectory ? "public.folder" : "public.data")
        if let cached = iconCache[key] { return cached }
        let type = UTType(key) ?? (isDirectory ? .folder : .data)
        let image = NSWorkspace.shared.icon(for: type)
        image.size = NSSize(width: 16, height: 16)
        iconCache[key] = image
        return image
    }
}

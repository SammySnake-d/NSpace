import AppKit
import UniformTypeIdentifiers
import NSpaceContracts

/// 展示格式化器：全部缓存复用（DateFormatter/ByteCountFormatter 构造昂贵）；
/// kind 显示串与图标按 UTType 缓存（万级目录滚动零重复计算）
@MainActor
enum Formatters {
    /// 列表/单元格字号（外观设置项；读 Preferences.listFontSize）——变更后经列重建路径重刷
    static var listFontSize: CGFloat { CGFloat(Preferences.listFontSize) }

    /// 相对时间显示（M29）：今天/昨天 →「今天 22:57」；本年 → 省年份「8月24日 22:57」；
    /// 仅非本年 → 带年份「2025年8月24日 22:57」。`now` 可注入以便确定性测试。
    /// 参照 Finder：列表列与「显示简介」均用相对格式，本年不赘述年份（用户点名 2026-08-27）。
    static func relativeDate(_ date: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        if cal.isDate(date, inSameDayAs: now) {
            return L10n.t("date.today") + " " + timeOnly.string(from: date)
        }
        if let yst = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(date, inSameDayAs: yst) {
            return L10n.t("date.yesterday") + " " + timeOnly.string(from: date)
        }
        if cal.isDate(date, equalTo: now, toGranularity: .year) {
            return sameYearDateTime.string(from: date)
        }
        return otherYearDateTime.string(from: date)
    }

    /// 仅时间「22:57」——今天/昨天前缀后拼接（`j` 依 locale 定 12/24 时制）
    private static let timeOnly: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("jmm")
        return f
    }()

    /// 本年日期「8月24日 22:57」（en:「Aug 24, 10:57 PM」）——无年份
    private static let sameYearDateTime: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMdjmm")
        return f
    }()

    /// 非本年日期「2025年8月24日 22:57」——带年份
    private static let otherYearDateTime: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("yMMMdjmm")
        return f
    }()

    static let size: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    /// 大小串拆成（数值, 单位）——供大小列墨色三级分色（数值 labelColor / 单位 secondaryLabelColor）。
    /// 以最后一个空格为界；无空格（罕见）则整串作数值、单位空。
    static func sizeParts(fromByteCount bytes: Int64) -> (value: String, unit: String) {
        let s = size.string(fromByteCount: bytes)
        if let r = s.range(of: " ", options: .backwards) {
            return (String(s[..<r.lowerBound]), String(s[r.upperBound...]))
        }
        return (s, "")
    }

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

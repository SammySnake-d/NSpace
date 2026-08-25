import AppKit
import NSpaceContracts
import VolumeInfo
import BookmarkStore

/// 侧边栏树模型：书签（BookmarkStore，含起始位置种子）+ iCloud + 位置（VolumeInfo）。
/// 暂存架（StashStore）在专区呈现不入 outline。NSOutlineView 需要引用身份，故节点为 class。
@MainActor
final class SidebarGroupNode {
    /// 分组种类；rawValue 即分组顺序持久化键（Preferences.sidebarGroupOrder / 拖拽 pasteboard）
    enum Kind: String { case bookmarks, icloud, volumes }
    let kind: Kind
    let title: String
    var children: [SidebarLeafNode] = []

    init(kind: Kind, title: String) {
        self.kind = kind
        self.title = title
    }
}

@MainActor
final class SidebarLeafNode {
    enum Payload {
        case place(URL)
        case bookmark(BookmarkItem)
        case volume(VolumeItem)
    }
    let payload: Payload
    let title: String
    let icon: NSImage
    /// 导航目标；书签目标丢失时为 nil（UI 置灰）
    let url: URL?
    let subtitle: String?
    /// 标题色覆盖（操作行等非导航行不按 url==nil 置灰）
    let titleColor: NSColor?
    /// 图标着色（Finder 式蓝色收藏图标）
    let tint: NSColor?

    init(payload: Payload, title: String, icon: NSImage, url: URL?, subtitle: String? = nil,
         titleColor: NSColor? = nil, tint: NSColor? = nil) {
        self.payload = payload
        self.title = title
        self.icon = icon
        self.url = url
        self.subtitle = subtitle
        self.titleColor = titleColor
        self.tint = tint
    }
}

@MainActor
final class SidebarModel {
    let bookmarkStore: BookmarkStore
    private let volumeInfo = VolumeInfo()

    /// 暂存架控制器（MainWindowController 注入；M14 起由 StashShelfView 专区消费）
    var stash: StashShelfController?

    private(set) var groups: [SidebarGroupNode] = []
    var onChange: (() -> Void)?
    private var volumeWatchTask: Task<Void, Never>?

    init(bookmarkStore: BookmarkStore) {
        self.bookmarkStore = bookmarkStore
    }

    func start() {
        // 起始位置种子：新装/无 bookmarks.json 时把个人域已知目录注入书签（一次性，胶囊幂等）
        Task { [weak self] in
            guard let self else { return }
            await self.bookmarkStore.seedIfEmpty(Self.seedPlaces())
            self.rebuild()
        }
        // 卷挂载/卸载自动刷新
        volumeWatchTask = Task { [weak self] in
            guard let self else { return }
            for await _ in self.volumeInfo.changes() {
                self.rebuild()
            }
        }
    }

    // 模型与窗口同生命周期；如需提前停表调 stop()
    func stop() { volumeWatchTask?.cancel() }

    func eject(_ item: VolumeItem) throws {
        try volumeInfo.eject(item.url)
    }

    func rebuild() {
        Task { [weak self] in
            guard let self else { return }
            let bookmarks = await self.bookmarkStore.all()
            self.applyRebuild(bookmarks: bookmarks)
        }
    }

    private func applyRebuild(bookmarks: [BookmarkItem]) {
        // 书签组：起始位置种子与用户书签同栈。home 域已知路径用 SF Symbol+符号蓝，否则真实文件图标。
        let bookmarkGroup = SidebarGroupNode(kind: .bookmarks, title: L10n.t("sidebar.bookmarks"))
        bookmarkGroup.children = bookmarks.map { item in
            let url = bookmarkStore.resolve(item)
            let icon: NSImage
            var tint: NSColor? = nil
            if let url, let (symbol, color) = Self.symbolFor(url: url),
               let symImage = NSImage(systemSymbolName: symbol, accessibilityDescription: item.name) {
                icon = symImage
                tint = color
            } else {
                icon = url.map { NSWorkspace.shared.icon(forFile: $0.path) }
                    ?? NSWorkspace.shared.icon(for: .folder)
            }
            icon.size = NSSize(width: 16, height: 16)
            return SidebarLeafNode(payload: .bookmark(item), title: item.name, icon: icon,
                                   url: url, tint: tint)
        }

        // iCloud 独立分组（QSpace 同构）：仅当 iCloud 云盘目录存在才有条目/显示
        let icloudGroup = SidebarGroupNode(kind: .icloud, title: L10n.t("sidebar.icloud.section"))
        let icloudURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        if FileManager.default.fileExists(atPath: icloudURL.path) {
            let icon = NSImage(systemSymbolName: "icloud", accessibilityDescription: L10n.t("sidebar.icloud"))
                ?? NSWorkspace.shared.icon(for: .folder)
            icon.size = NSSize(width: 16, height: 16)
            icloudGroup.children = [SidebarLeafNode(payload: .place(icloudURL),
                                                    title: L10n.t("sidebar.icloud"), icon: icon,
                                                    url: icloudURL, tint: .systemBlue)]
        }

        let volumeGroup = SidebarGroupNode(kind: .volumes, title: L10n.t("sidebar.volumes"))
        volumeGroup.children = volumeInfo.volumes().map { vol in
            let icon = NSWorkspace.shared.icon(forFile: vol.url.path)
            icon.size = NSSize(width: 16, height: 16)
            // 只读卷（DMG 等）可用容量为 0：显示"只读"而非误导性的"0 KB 可用"
            let subtitle: String?
            if vol.availableCapacity > 0 {
                let free = ByteCountFormatter.string(fromByteCount: vol.availableCapacity, countStyle: .file)
                subtitle = String(format: L10n.t("sidebar.available"), free)
            } else {
                subtitle = L10n.t("sidebar.readOnly")
            }
            return SidebarLeafNode(payload: .volume(vol), title: vol.name, icon: icon, url: vol.url,
                                   subtitle: subtitle)
        }

        // 按 Preferences.sidebarGroupOrder 输出分组顺序（用户点名：书签可拖到最前）。
        // 空的 iCloud 组不显示；顺序表未覆盖的分组按固定序补尾（向后兼容/新分组）。
        var available: [String: SidebarGroupNode] = [
            SidebarGroupNode.Kind.bookmarks.rawValue: bookmarkGroup,
            SidebarGroupNode.Kind.volumes.rawValue: volumeGroup,
        ]
        if !icloudGroup.children.isEmpty {
            available[SidebarGroupNode.Kind.icloud.rawValue] = icloudGroup
        }
        var ordered: [SidebarGroupNode] = []
        for key in Preferences.sidebarGroupOrder {
            if let g = available.removeValue(forKey: key) { ordered.append(g) }
        }
        for key in [SidebarGroupNode.Kind.bookmarks.rawValue,
                    SidebarGroupNode.Kind.icloud.rawValue,
                    SidebarGroupNode.Kind.volumes.rawValue] {
            if let g = available.removeValue(forKey: key) { ordered.append(g) }
        }
        groups = ordered
        onChange?()
    }

    /// 起始位置种子候选（个人域已知位置；不含 iCloud——iCloud 独立成节）。存在才纳入。
    /// name 由此给定（BookmarkStore 胶囊不含 L10n），与后续 symbolFor 的路径映射对齐。
    static func seedPlaces() -> [(URL, String)] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates: [(URL, String)] = [
            (home, L10n.t("sidebar.home")),
            (home.appendingPathComponent("Desktop"), L10n.t("sidebar.desktop")),
            (home.appendingPathComponent("Documents"), L10n.t("sidebar.documents")),
            (home.appendingPathComponent("Movies"), L10n.t("sidebar.movies")),
            (home.appendingPathComponent("Music"), L10n.t("sidebar.music")),
            (home.appendingPathComponent("Pictures"), L10n.t("sidebar.pictures")),
            (home.appendingPathComponent("Downloads"), L10n.t("sidebar.downloads")),
            (URL(fileURLWithPath: "/Applications"), L10n.t("sidebar.applications")),
        ]
        return candidates.filter { FileManager.default.fileExists(atPath: $0.0.path) }
    }

    /// home 域已知位置 → (SF Symbol, 符号蓝)。书签行渲染时匹配：命中用符号蓝标，否则真实文件夹图标。
    static func symbolFor(url: URL) -> (String, NSColor)? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let map: [(URL, String)] = [
            (home, "house"),
            (home.appendingPathComponent("Desktop"), "desktopcomputer"),
            (home.appendingPathComponent("Documents"), "doc"),
            (home.appendingPathComponent("Movies"), "film"),
            (home.appendingPathComponent("Music"), "music.note"),
            (home.appendingPathComponent("Pictures"), "photo"),
            (home.appendingPathComponent("Downloads"), "arrow.down.circle"),
            (URL(fileURLWithPath: "/Applications"), "app"),
        ]
        let target = url.standardizedFileURL.path
        for (u, symbol) in map where u.standardizedFileURL.path == target {
            return (symbol, .systemBlue)
        }
        return nil
    }
}

import AppKit
import NSpaceContracts
import VolumeInfo
import BookmarkStore

/// 侧边栏树模型：起始位置（静态）+ 书签（BookmarkStore）+ 位置（VolumeInfo）。
/// NSOutlineView 需要引用身份，故节点为 class。
@MainActor
final class SidebarGroupNode {
    enum Kind { case favorites, bookmarks, volumes }
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

    init(payload: Payload, title: String, icon: NSImage, url: URL?, subtitle: String? = nil) {
        self.payload = payload
        self.title = title
        self.icon = icon
        self.url = url
        self.subtitle = subtitle
    }
}

@MainActor
final class SidebarModel {
    let bookmarkStore: BookmarkStore
    private let volumeInfo = VolumeInfo()

    private(set) var groups: [SidebarGroupNode] = []
    var onChange: (() -> Void)?
    private var volumeWatchTask: Task<Void, Never>?

    init(bookmarkStore: BookmarkStore) {
        self.bookmarkStore = bookmarkStore
    }

    func start() {
        rebuild()
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
        let favorites = SidebarGroupNode(kind: .favorites, title: L10n.t("sidebar.favorites"))
        favorites.children = Self.standardPlaces()

        let bookmarkGroup = SidebarGroupNode(kind: .bookmarks, title: L10n.t("sidebar.bookmarks"))
        bookmarkGroup.children = bookmarks.map { item in
            let url = bookmarkStore.resolve(item)
            let icon: NSImage = url.map { NSWorkspace.shared.icon(forFile: $0.path) }
                ?? NSWorkspace.shared.icon(for: .folder)
            icon.size = NSSize(width: 16, height: 16)
            return SidebarLeafNode(payload: .bookmark(item), title: item.name, icon: icon, url: url)
        }

        let volumeGroup = SidebarGroupNode(kind: .volumes, title: L10n.t("sidebar.volumes"))
        volumeGroup.children = volumeInfo.volumes().map { vol in
            let icon = NSWorkspace.shared.icon(forFile: vol.url.path)
            icon.size = NSSize(width: 16, height: 16)
            let free = ByteCountFormatter.string(fromByteCount: vol.availableCapacity, countStyle: .file)
            return SidebarLeafNode(payload: .volume(vol), title: vol.name, icon: icon, url: vol.url,
                                   subtitle: String(format: L10n.t("sidebar.available"), free))
        }

        groups = [favorites, bookmarkGroup, volumeGroup]
        onChange?()
    }

    /// 起始位置：存在才显示（FG-1 无真实目标不留死条目）
    private static func standardPlaces() -> [SidebarLeafNode] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let icloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        let candidates: [(String, URL, String)] = [
            (L10n.t("sidebar.home"), home, "house"),
            (L10n.t("sidebar.desktop"), home.appendingPathComponent("Desktop"), "menubar.dock.rectangle"),
            (L10n.t("sidebar.documents"), home.appendingPathComponent("Documents"), "doc"),
            (L10n.t("sidebar.downloads"), home.appendingPathComponent("Downloads"), "arrow.down.circle"),
            (L10n.t("sidebar.applications"), URL(fileURLWithPath: "/Applications"), "app"),
            (L10n.t("sidebar.icloud"), icloud, "icloud"),
        ]
        return candidates.compactMap { name, url, symbol in
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: name)
                ?? NSWorkspace.shared.icon(for: .folder)
            return SidebarLeafNode(payload: .place(url), title: name, icon: icon, url: url)
        }
    }
}

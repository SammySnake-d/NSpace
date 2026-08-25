import Foundation
import NSpaceContracts

/// 书签权威状态唯一 Commit Owner（actor 串行提交，BG-5/BG-8 单进程定界）。
/// 存储目录构造注入（Axiom 2）：App 传 Application Support，测试传临时目录。
public actor BookmarkStore {
    private let fileURL: URL
    private var items: [BookmarkItem] = []
    private var loaded = false
    /// 起始位置种子是否已注入过（落盘于 Archive；一次性，避免用户清空后又被重新 seed）
    private var seeded = false

    /// 落盘结构（seeded 标志 + 条目）。旧档案是纯 [BookmarkItem] 数组，
    /// 解码失败即回退旧格式（items 非空视为已 seed，向后兼容）。
    private struct Archive: Codable {
        var seeded: Bool
        var items: [BookmarkItem]
    }

    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("bookmarks.json")
    }

    // MARK: 查询

    public func all() async -> [BookmarkItem] {
        await ensureLoaded()
        return items
    }

    /// 解析书签目标（目标已删除返回 nil，UI 据此置灰）
    public nonisolated func resolve(_ item: BookmarkItem) -> URL? {
        var stale = false
        return try? URL(resolvingBookmarkData: item.bookmarkData, options: [],
                        relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    // MARK: 变更（全部经此 actor 串行提交 + 原子落盘）

    @discardableResult
    public func add(_ url: URL, name: String? = nil) async throws -> BookmarkItem {
        await ensureLoaded()
        let data: Data
        do {
            data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch {
            throw BookmarkError(.external, "无法创建书签: \(error.localizedDescription)")
        }
        let item = BookmarkItem(name: name ?? url.lastPathComponent, bookmarkData: data)
        items.append(item)
        try persist()
        return item
    }

    public func remove(_ id: UUID) async throws {
        await ensureLoaded()
        items.removeAll { $0.id == id }
        try persist()
    }

    public func rename(_ id: UUID, to name: String) async throws {
        await ensureLoaded()
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].name = name
        try persist()
    }

    /// 拖拽排序
    public func move(from source: Int, to destination: Int) async throws {
        await ensureLoaded()
        guard items.indices.contains(source),
              destination >= 0, destination <= items.count else { return }
        let item = items.remove(at: source)
        items.insert(item, at: min(destination, items.count))
        try persist()
    }

    /// 起始位置种子：仅当从未 seed 过且当前为空时写入这些目录（新装/无 bookmarks.json）。
    /// 种子书签与用户书签同栈——可拖排/重命名/移除。seeded 标志落盘，二次调用幂等跳过。
    /// name 由 App 层给定（胶囊不含 L10n）；bookmarkData 创建失败的目标跳过（不影响其余）。
    public func seedIfEmpty(_ urls: [(URL, String)]) async {
        await ensureLoaded()
        // 已 seed 或已有条目：只置标志（幂等落盘），不注入种子
        guard !seeded, items.isEmpty else {
            if !seeded {
                seeded = true
                try? persist()
            }
            return
        }
        for (url, name) in urls {
            guard let data = try? url.bookmarkData(options: [],
                                                   includingResourceValuesForKeys: nil,
                                                   relativeTo: nil) else { continue }
            items.append(BookmarkItem(name: name, bookmarkData: data))
        }
        seeded = true
        try? persist()
    }

    /// 恢复缺失的默认种子（I-14 用户语义：种子可删、可随时恢复）。
    /// 按解析后 standardized 路径去重——已存在的目标跳过，只补缺失项；返回实际新增数。
    /// 设置窗「恢复默认书签」与 App 层旧档案一次性补种都走这里。
    @discardableResult
    public func restoreMissingSeeds(_ urls: [(URL, String)]) async -> Int {
        await ensureLoaded()
        let existing = Set(items.compactMap { resolve($0)?.standardizedFileURL.path })
        var added = 0
        for (url, name) in urls where !existing.contains(url.standardizedFileURL.path) {
            guard let data = try? url.bookmarkData(options: [],
                                                   includingResourceValuesForKeys: nil,
                                                   relativeTo: nil) else { continue }
            items.append(BookmarkItem(name: name, bookmarkData: data))
            added += 1
        }
        if added > 0 {
            seeded = true
            try? persist()
        }
        return added
    }

    // MARK: 私有：加载与原子落盘

    private func ensureLoaded() async {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL) else { return }
        // 新结构（Archive）优先；旧纯数组档案回退：items 非空视为已 seed（向后兼容）
        if let archive = try? JSONDecoder().decode(Archive.self, from: data) {
            items = archive.items
            seeded = archive.seeded
        } else if let legacy = try? JSONDecoder().decode([BookmarkItem].self, from: data) {
            items = legacy
            seeded = !legacy.isEmpty
        }
    }

    private func persist() throws {
        do {
            let dir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Archive(seeded: seeded, items: items))
            // 原子替换：崩溃安全（spec 容错矩阵：落盘失败保内存态，抛错由调用方原位提示）
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw BookmarkError(.external, "书签保存失败: \(error.localizedDescription)")
        }
    }
}

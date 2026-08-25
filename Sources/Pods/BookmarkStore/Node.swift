import Foundation
import NSpaceContracts

/// 书签权威状态唯一 Commit Owner（actor 串行提交，BG-5/BG-8 单进程定界）。
/// 存储目录构造注入（Axiom 2）：App 传 Application Support，测试传临时目录。
public actor BookmarkStore {
    private let fileURL: URL
    private var items: [BookmarkItem] = []
    private var loaded = false

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

    // MARK: 私有：加载与原子落盘

    private func ensureLoaded() async {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL) else { return }
        items = (try? JSONDecoder().decode([BookmarkItem].self, from: data)) ?? []
    }

    private func persist() throws {
        do {
            let dir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(items)
            // 原子替换：崩溃安全（spec 容错矩阵：落盘失败保内存态，抛错由调用方原位提示）
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw BookmarkError(.external, "书签保存失败: \(error.localizedDescription)")
        }
    }
}

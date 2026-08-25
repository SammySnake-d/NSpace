import Foundation
import NSpaceContracts

/// 暂存架权威状态唯一 Commit Owner（actor 串行提交，BG-5/BG-8 单进程定界）。
/// 存储目录构造注入（Axiom 2）：App 传 Application Support，测试传临时目录。
public actor StashStore {
    private let fileURL: URL
    private var items: [StashItem] = []
    private var loaded = false

    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("stash.json")
    }

    // MARK: 查询

    public func all() async -> [StashItem] {
        await ensureLoaded()
        return items
    }

    /// 解析暂存目标（目标已删除返回 nil，UI 据此置灰）
    public nonisolated func resolve(_ item: StashItem) -> URL? {
        var stale = false
        return try? URL(resolvingBookmarkData: item.bookmarkData, options: [],
                        relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    // MARK: 变更（全部经此 actor 串行提交 + 原子落盘）

    /// 批量加入（同路径去重：已暂存的路径静默跳过）；返回实际新增项
    @discardableResult
    public func add(_ urls: [URL]) async throws -> [StashItem] {
        await ensureLoaded()
        var seen = Set(items.compactMap { resolve($0)?.standardizedFileURL.path })
        var added: [StashItem] = []
        for url in urls {
            let path = url.standardizedFileURL.path
            guard !seen.contains(path) else { continue }
            let data: Data
            do {
                data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            } catch {
                throw StashError(.external, "无法暂存「\(url.lastPathComponent)」: \(error.localizedDescription)")
            }
            seen.insert(path)
            added.append(StashItem(bookmarkData: data))
        }
        guard !added.isEmpty else { return [] }
        items.append(contentsOf: added)
        try persist()
        return added
    }

    public func remove(ids: [UUID]) async throws {
        await ensureLoaded()
        let removal = Set(ids)
        items.removeAll { removal.contains($0.id) }
        try persist()
    }

    public func clear() async throws {
        await ensureLoaded()
        items = []
        try persist()
    }

    // MARK: 私有：加载与原子落盘

    private func ensureLoaded() async {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL) else { return }
        items = (try? JSONDecoder().decode([StashItem].self, from: data)) ?? []
    }

    private func persist() throws {
        do {
            let dir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(items)
            // 原子替换：崩溃安全（spec 容错矩阵：落盘失败保内存态，抛错由调用方原位提示）
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw StashError(.external, "暂存架保存失败: \(error.localizedDescription)")
        }
    }
}

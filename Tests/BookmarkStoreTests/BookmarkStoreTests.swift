import Testing
import Foundation
import BookmarkStore

/// 黑盒验收：真实临时目录（无 Fake Mock）
@Suite struct BookmarkStoreTests {
    func makeStore() throws -> (BookmarkStore, URL, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nspace-bm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appendingPathComponent("target-folder")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return (BookmarkStore(directory: dir), dir, target)
    }

    @Test func addResolveRoundTrip() async throws {
        let (store, dir, target) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let item = try await store.add(target)
        #expect(item.name == "target-folder")
        let resolved = store.resolve(item)
        #expect(resolved?.standardizedFileURL.path == target.standardizedFileURL.path)
    }

    @Test func persistenceSurvivesReload() async throws {
        let (store, dir, target) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await store.add(target, name: "自定义名")
        // 新实例从磁盘重载（跨启动持久化验收）
        let store2 = BookmarkStore(directory: dir)
        let items = await store2.all()
        #expect(items.count == 1)
        #expect(items.first?.name == "自定义名")
    }

    @Test func removeRenameMove() async throws {
        let (store, dir, target) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try await store.add(target, name: "A")
        let b = try await store.add(target, name: "B")
        try await store.rename(a.id, to: "A2")
        try await store.move(from: 1, to: 0)
        var items = await store.all()
        #expect(items.map(\.name) == ["B", "A2"])
        try await store.remove(b.id)
        items = await store.all()
        #expect(items.map(\.name) == ["A2"])
    }

    // MARK: 起始位置种子（seedIfEmpty）

    /// 首次写入：空档案 seed 注入给定目录
    @Test func seedFirstTimeWrites() async throws {
        let (store, dir, target) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        await store.seedIfEmpty([(target, "种子")])
        let items = await store.all()
        #expect(items.count == 1)
        #expect(items.first?.name == "种子")
    }

    /// 二次不重复：同实例再调 + 跨实例重载后 seeded 标志落盘，均不再 seed
    @Test func seedSecondTimeNoDuplicate() async throws {
        let (store, dir, target) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        await store.seedIfEmpty([(target, "种子")])
        await store.seedIfEmpty([(target, "种子")])
        #expect(await store.all().count == 1)
        // 用户移除种子后，跨实例重载不应再被 seed（seeded 标志已落盘）
        let only = await store.all()[0]
        try await store.remove(only.id)
        let store2 = BookmarkStore(directory: dir)
        await store2.seedIfEmpty([(target, "种子")])
        #expect(await store2.all().isEmpty)
    }

    /// 已有条目不 seed：先有用户书签则跳过种子注入
    @Test func seedSkippedWhenItemsExist() async throws {
        let (store, dir, target) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await store.add(target, name: "用户书签")
        await store.seedIfEmpty([(target, "种子")])
        let items = await store.all()
        #expect(items.count == 1)
        #expect(items.first?.name == "用户书签")
    }

    /// 向后兼容：旧纯数组档案（无 seeded 字段）items 非空视为已 seed，不被种子污染
    @Test func legacyArchiveTreatedAsSeeded() async throws {
        let (store, dir, target) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        // 手写旧格式 bookmarks.json（纯 [BookmarkItem] 数组）
        let data = try target.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let legacy = [BookmarkItem(name: "旧书签", bookmarkData: data)]
        let json = try JSONEncoder().encode(legacy)
        try json.write(to: dir.appendingPathComponent("bookmarks.json"), options: .atomic)
        _ = store  // 用新实例读旧档
        let store2 = BookmarkStore(directory: dir)
        await store2.seedIfEmpty([(target, "种子")])
        let items = await store2.all()
        #expect(items.count == 1)
        #expect(items.first?.name == "旧书签")
    }
}

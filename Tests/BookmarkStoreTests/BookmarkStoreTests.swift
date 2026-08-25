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
}

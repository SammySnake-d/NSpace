import Testing
import Foundation
import StashStore

/// 黑盒验收：真实临时目录夹具（无 Fake Mock）
@Suite struct StashStoreTests {
    /// 建临时夹具：存储目录 + 两个真实文件 + 一个真实子目录
    func makeFixture() throws -> (StashStore, dir: URL, fileA: URL, fileB: URL, folder: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nspace-stash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileA = dir.appendingPathComponent("a.txt")
        let fileB = dir.appendingPathComponent("b.txt")
        try Data("A".utf8).write(to: fileA)
        try Data("B".utf8).write(to: fileB)
        let folder = dir.appendingPathComponent("sub-folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (StashStore(directory: dir), dir, fileA, fileB, folder)
    }

    @Test func addResolveRoundTrip() async throws {
        let (store, dir, fileA, _, folder) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        // 收文件也收目录（与书签组只收目录不同）
        let added = try await store.add([fileA, folder])
        #expect(added.count == 2)
        let items = await store.all()
        #expect(items.count == 2)
        let resolved = items.compactMap { store.resolve($0)?.standardizedFileURL.path }
        #expect(resolved.contains(fileA.standardizedFileURL.path))
        #expect(resolved.contains(folder.standardizedFileURL.path))
    }

    @Test func dedupSamePath() async throws {
        let (store, dir, fileA, fileB, _) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await store.add([fileA])
        // 重复加入同路径（含同批内重复）不产生新项
        let added = try await store.add([fileA, fileA, fileB])
        #expect(added.count == 1)
        let items = await store.all()
        #expect(items.count == 2)
    }

    @Test func removeAndClear() async throws {
        let (store, dir, fileA, fileB, folder) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let added = try await store.add([fileA, fileB, folder])
        try await store.remove(ids: [added[0].id])
        var items = await store.all()
        #expect(items.count == 2)
        #expect(!items.contains { $0.id == added[0].id })
        try await store.clear()
        items = await store.all()
        #expect(items.isEmpty)
    }

    @Test func persistenceSurvivesReload() async throws {
        let (store, dir, fileA, _, folder) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await store.add([fileA, folder])
        // 新实例从磁盘重载（跨启动持久化验收）
        let store2 = StashStore(directory: dir)
        let items = await store2.all()
        #expect(items.count == 2)
        let resolved = items.compactMap { store2.resolve($0)?.standardizedFileURL.path }
        #expect(resolved.contains(fileA.standardizedFileURL.path))
    }

    @Test func resolveMissingTargetReturnsNil() async throws {
        let (store, dir, fileA, _, _) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let added = try await store.add([fileA])
        try FileManager.default.removeItem(at: fileA)
        // 目标已删除 → resolve 返回 nil（UI 据此置灰），项本身仍在
        #expect(store.resolve(added[0]) == nil)
        let items = await store.all()
        #expect(items.count == 1)
    }
}

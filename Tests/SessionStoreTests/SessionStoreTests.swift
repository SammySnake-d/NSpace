import Testing
import Foundation
import SessionStore

/// 黑盒验收：真实临时目录（无 Fake Mock）
@Suite struct SessionStoreTests {
    func makeStore() throws -> (SessionStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nspace-ss-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (SessionStore(directory: dir), dir)
    }

    static func sample() -> SessionSnapshot {
        SessionSnapshot(windows: [
            SessionWindow(layoutRaw: 5,
                          panes: [
                            SessionPane(tabs: [SessionTab(path: "/tmp"),
                                               SessionTab(path: "/usr", sortKey: "size", sortAscending: false)],
                                        activeTabIndex: 1),
                            SessionPane(tabs: [SessionTab(path: "/", includeHidden: true)], activeTabIndex: 0),
                          ],
                          activePaneIndex: 1),
        ])
    }

    @Test func roundTripThroughDisk() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let snap = Self.sample()
        await store.save(snap)
        await store.flush()  // 跳过防抖立即落盘
        // 新实例从磁盘重载（跨启动恢复验收）
        let store2 = SessionStore(directory: dir)
        let loaded = await store2.load()
        #expect(loaded == snap)
    }

    @Test func missingFileReturnsNil() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let loaded = await store.load()
        #expect(loaded == nil)
    }

    @Test func corruptFileReturnsNil() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("not json{{".utf8).write(to: dir.appendingPathComponent("session.json"))
        let loaded = await store.load()
        #expect(loaded == nil)
    }

    @Test func debounceCoalescesWrites() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        // 连续 save 只留最后一份（防抖合并）
        var snap = Self.sample()
        await store.save(snap)
        snap.windows[0].activePaneIndex = 0
        await store.save(snap)
        await store.flush()
        let loaded = await SessionStore(directory: dir).load()
        #expect(loaded?.windows[0].activePaneIndex == 0)
    }
}

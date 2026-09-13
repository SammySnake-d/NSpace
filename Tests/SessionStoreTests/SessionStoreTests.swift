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
            SessionWorkspaces(workspaces: [
                SessionWindow(layoutRaw: 5,
                              panes: [
                                SessionPane(tab: SessionTab(path: "/usr", sortKey: "size",
                                                            sortAscending: false)),
                                SessionPane(tab: SessionTab(path: "/", includeHidden: true)),
                              ],
                              activePaneIndex: 1),
                SessionWindow(layoutRaw: 1,
                              panes: [SessionPane(tab: SessionTab(path: "/etc"))],
                              activePaneIndex: 0),
            ], activeWorkspace: 0),
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
        snap.windows[0].activeWorkspace = 1
        await store.save(snap)
        await store.flush()
        let loaded = await SessionStore(directory: dir).load()
        #expect(loaded?.windows[0].activeWorkspace == 1)
    }

    /// 旧格式（windows 每项直接是 SessionWindow）一次性迁移：包成单窗口的工作区数组
    @Test func legacyFormatMigratesToWorkspaces() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        // 手写旧结构 JSON（M13：windows=[SessionWindow]，各存一份）
        let legacyJSON = """
        {"windows":[
          {"layoutRaw":1,"activePaneIndex":0,"panes":[{"activeTabIndex":0,"tabs":[{"path":"/tmp","sortKey":"name","sortAscending":true,"includeHidden":false}]}]},
          {"layoutRaw":2,"activePaneIndex":0,"panes":[{"activeTabIndex":0,"tabs":[{"path":"/usr","sortKey":"name","sortAscending":true,"includeHidden":false}]}]}
        ]}
        """
        try Data(legacyJSON.utf8).write(to: dir.appendingPathComponent("session.json"))
        let loaded = await store.load()
        // 两个旧窗口 → 一个窗口的两个工作区
        #expect(loaded?.windows.count == 1)
        #expect(loaded?.windows[0].workspaces.count == 2)
        #expect(loaded?.windows[0].activeWorkspace == 0)
        #expect(loaded?.windows[0].workspaces[1].layoutRaw == 2)
    }

    /// 窗格内多标签（M13）退役的一次性迁移：旧档案每个窗格是 `tabs` 数组 + `activeTabIndex`，
    /// 新结构只有一个 `tab`。必须留下**当时活动的那个**，不是第一个——用户真实会话里活动标签
    /// 普遍不是 0（外部打开一路往后堆），取错就等于把他正在看的目录换成很久以前那个。
    @Test func legacyPaneTabsKeepActiveTabOnly() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let legacyJSON = """
        {"windows":[{"activeWorkspace":0,"workspaces":[
          {"layoutRaw":2,"activePaneIndex":0,"panes":[
            {"activeTabIndex":2,"tabs":[
              {"path":"/tmp","sortKey":"name","sortAscending":true,"includeHidden":false},
              {"path":"/usr","sortKey":"name","sortAscending":true,"includeHidden":false},
              {"path":"/etc","sortKey":"size","sortAscending":false,"includeHidden":true,"viewMode":0}]},
            {"activeTabIndex":0,"tabs":[
              {"path":"/var","sortKey":"name","sortAscending":true,"includeHidden":false}]}
          ]}
        ]}]}
        """
        try Data(legacyJSON.utf8).write(to: dir.appendingPathComponent("session.json"))
        let loaded = await store.load()
        let panes = try #require(loaded?.windows.first?.workspaces.first?.panes)
        #expect(panes.count == 2)
        // 索引 2 那个（不是 /tmp），且它的排序/隐藏/视图模式一并带过来
        #expect(panes[0].tab.path == "/etc")
        #expect(panes[0].tab.sortKey == "size")
        #expect(panes[0].tab.sortAscending == false)
        #expect(panes[0].tab.includeHidden == true)
        #expect(panes[0].tab.viewMode == 0)
        #expect(panes[1].tab.path == "/var")
    }

    /// 越界的 activeTabIndex 不许让整份会话解码失败（那等于用户所有窗口一起丢）
    @Test func legacyPaneTabsOutOfRangeIndexFallsBackToFirst() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let legacyJSON = """
        {"windows":[{"activeWorkspace":0,"workspaces":[
          {"layoutRaw":1,"activePaneIndex":0,"panes":[
            {"activeTabIndex":7,"tabs":[
              {"path":"/tmp","sortKey":"name","sortAscending":true,"includeHidden":false}]}
          ]}
        ]}]}
        """
        try Data(legacyJSON.utf8).write(to: dir.appendingPathComponent("session.json"))
        let loaded = await store.load()
        #expect(loaded?.windows.first?.workspaces.first?.panes.first?.tab.path == "/tmp")
    }

    /// 迁移只发生在读的那一次：存回去就是新结构，旧键不再出现在磁盘上
    @Test func migratedSessionWritesNewShapeOnly() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("session.json")
        let legacyJSON = """
        {"windows":[{"activeWorkspace":0,"workspaces":[
          {"layoutRaw":1,"activePaneIndex":0,"panes":[
            {"activeTabIndex":1,"tabs":[
              {"path":"/tmp","sortKey":"name","sortAscending":true,"includeHidden":false},
              {"path":"/usr","sortKey":"name","sortAscending":true,"includeHidden":false}]}
          ]}
        ]}]}
        """
        try Data(legacyJSON.utf8).write(to: file)
        let loaded = try #require(await store.load())
        await store.save(loaded)
        await store.flush()
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("\"tab\""))
        #expect(!text.contains("\"tabs\""))
        #expect(!text.contains("activeTabIndex"))
        #expect(text.contains("/usr"))       // 留下的是当时活动的那个
        #expect(!text.contains("/tmp"))
    }
}

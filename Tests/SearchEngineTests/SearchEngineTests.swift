import Testing
import Foundation
@testable import SearchEngine

/// 黑盒验收：通道B（隐藏文件扫描）用真实临时夹具树精确断言；
/// 通道A（Spotlight）依赖系统索引状态，只做"能启动能停止不崩"的宽松断言（不做假 Mock）。
@MainActor
@Suite struct SearchEngineTests {
    /// 夹具树：可见命中 + 点隐藏命中 + 隐藏目录内命中 + 深层命中 + 巨坑目录内命中（应被跳过）
    func makeFixture() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nspace-search-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent(".hiddensub"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        let files = [
            "visible-nsneedle.txt",
            ".hidden-nsneedle.txt",
            ".hiddensub/inside-nsneedle.txt",
            "sub/deep-nsneedle.txt",
            "node_modules/skip-nsneedle.txt",
            "unrelated.txt",
        ]
        for f in files {
            try Data("x".utf8).write(to: dir.appendingPathComponent(f))
        }
        return dir
    }

    /// 收集流结果直到自然收尾或超时（超时取消 = 验证协作式停止）
    func collect(_ request: SearchRequest, timeout: Double = 5) async -> [SearchHit] {
        let engine = SearchEngine()
        let stream = engine.search(request)
        let task = Task { @MainActor in
            var out: [SearchHit] = []
            for await batch in stream {
                out.append(contentsOf: batch)
            }
            return out
        }
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            task.cancel()
        }
        let result = await task.value
        watchdog.cancel()
        return result
    }

    @Test func hiddenChannelFindsHiddenByName() async throws {
        let dir = try makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hits = await collect(SearchRequest(query: "nsneedle", scope: .directory(dir),
                                               searchNames: true, searchContents: false,
                                               includeHidden: true))
        let names = Set(hits.map(\.name))
        // 点隐藏文件、隐藏目录内文件、可见文件、深层文件全部按名命中
        #expect(names.contains(".hidden-nsneedle.txt"))
        #expect(names.contains("inside-nsneedle.txt"))
        #expect(names.contains("visible-nsneedle.txt"))
        #expect(names.contains("deep-nsneedle.txt"))
        #expect(!names.contains("unrelated.txt"))
    }

    @Test func skippedDirectoriesAreNotScanned() async throws {
        let dir = try makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hits = await collect(SearchRequest(query: "nsneedle", scope: .directory(dir),
                                               searchNames: true, searchContents: false,
                                               includeHidden: true))
        // node_modules 巨坑目录被跳过
        #expect(!hits.contains { $0.name == "skip-nsneedle.txt" })
    }

    @Test func includeHiddenOffOmitsHiddenChannel() async throws {
        let dir = try makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        // 关闭隐藏通道：只走 Spotlight，临时目录/隐藏文件不入索引 → 隐藏文件必不出现
        let hits = await collect(SearchRequest(query: "nsneedle", scope: .directory(dir),
                                               searchNames: true, searchContents: false,
                                               includeHidden: false), timeout: 2)
        #expect(!hits.contains { $0.name == ".hidden-nsneedle.txt" })
        #expect(!hits.contains { $0.name == "inside-nsneedle.txt" })
    }

    @Test func resultsAreDeduplicatedByURL() async throws {
        let dir = try makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        // 双通道同时开：同一 URL 严禁重复出现在合并流中
        let hits = await collect(SearchRequest(query: "nsneedle", scope: .directory(dir),
                                               searchNames: true, searchContents: false,
                                               includeHidden: true))
        let paths = hits.map(\.url.path)
        #expect(Set(paths).count == paths.count)
    }

    @Test func emptyQueryFinishesImmediately() async throws {
        let dir = try makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hits = await collect(SearchRequest(query: "", scope: .directory(dir),
                                               searchNames: true, searchContents: false,
                                               includeHidden: true), timeout: 1)
        #expect(hits.isEmpty)
    }

    @Test func spotlightChannelStartsAndStopsWithoutCrash() async throws {
        let dir = try makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        // 通道A 宽松断言：内容搜索启动后 0.5s 取消，流必须终止且不崩（不苛求索引返回结果）
        let hits = await collect(SearchRequest(query: "nsneedle", scope: .directory(dir),
                                               searchNames: true, searchContents: true,
                                               includeHidden: false), timeout: 0.5)
        _ = hits  // 结果内容不作断言（依赖 Spotlight 索引状态）
        #expect(Bool(true))
    }

    @Test func resultsAreCappedAtMaxResults() async throws {
        // 卡死根因回归：命中数超上限时引擎必须封顶停通道（否则主线程读全量 → 卡死/CPU 暴涨）。
        // 用通道B 递归扫描构造 maxResults+200 个匹配文件，断言流总产出 ≤ 上限。
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nspace-search-cap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let n = SearchLimits.maxResults + 200
        for i in 0..<n {
            try Data("x".utf8).write(to: dir.appendingPathComponent("capneedle-\(i).txt"))
        }
        let hits = await collect(SearchRequest(query: "capneedle", scope: .directory(dir),
                                               searchNames: true, searchContents: false,
                                               includeHidden: true), timeout: 10)
        #expect(hits.count <= SearchLimits.maxResults)
        #expect(hits.count >= SearchLimits.maxResults - 50)   // 确实逼近上限（证明扫到了大量、且封顶）
    }
    // MARK: v0.19.17 —— "能看到却搜不到 .claude" 的四条独立真因（用户报告）

    /// 真因① 遍历顺序：`FileManager.enumerator` 是惰性前序 DFS，拿到一个 depth-1 目录后
    /// 会把它整棵子树走完才回到下一个 depth-1 兄弟。真机实测 `~/.claude` DFS 要 15.5s
    /// 才被**枚举到**（第 75 万项），BFS 0.006s（第 104 项）。
    ///
    /// 本断言与目录枚举顺序**无关**（不靠运气）：夹具 root/{d1/leaf, d2/leaf} 下，
    /// DFS 无论先走 d1 还是 d2，都必然产出 depth-2 之后才回到另一个 depth-1
    /// → 「深度单调不减」必然被打破。BFS 则恒成立。
    @Test func levelOrderWalkEmitsNonDecreasingDepths() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("nspace-bfs-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        for d in ["d1", "d2"] {
            try fm.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: root.appendingPathComponent("\(d)/leaf.txt"))
        }
        var depths: [Int] = []
        LevelOrderWalk.walk(root: root, skipDirectoryNames: [], shouldContinue: { true }) { _, depth, _ in
            depths.append(depth)
        }
        #expect(depths == depths.sorted(), "深度必须单调不减，实得 \(depths)")
        #expect(depths.count == 4)                       // 反空断言：夹具真被走到了
        #expect(depths.filter { $0 == 1 }.count == 2)    // 两个 depth-1 目录都在 depth-2 之前
    }

    /// 真因① 的**接线**：上一条只证明 LevelOrderWalk 自己是 BFS，把 scan() 换回 DFS
    /// 它照样全绿（对抗审查实测 3/3）。这条打在 scan() 真实产出的命中序列上。
    ///
    /// 夹具 root/{m-dirA/m-inner, m-dirB/m-inner}，四项全部匹配 "nswire"。
    /// DFS 无论先走哪个目录，都必然是 depth1→depth2→depth1→depth2；BFS 恒为 1,1,2,2。
    /// 与目录枚举顺序无关。
    @Test func scanDeliversShallowHitsBeforeDeepOnes() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("nspace-wire-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        for d in ["nswire-dirA", "nswire-dirB"] {
            try fm.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: root.appendingPathComponent("\(d)/nswire-inner.txt"))
        }
        var order: [SearchHit] = []
        SearchSession.scan(root: root,
                           request: SearchRequest(query: "nswire", scope: .directory(root),
                                                  includeHidden: true)) { order.append(contentsOf: $0) }
        let rootDepth = root.standardizedFileURL.pathComponents.count
        let depths = order.map { $0.url.standardizedFileURL.pathComponents.count - rootDepth }
        #expect(depths == depths.sorted(), "scan() 产出的深度必须单调不减，实得 \(depths)")
        #expect(depths.count == 4)                      // 反空断言：四项都到齐
        #expect(depths.prefix(2).allSatisfy { $0 == 1 }) // 两个 depth-1 目录在任何 depth-2 之前
    }

    /// 真因② 发射条件：旧版只有 `batch.count >= 50` 和「整棵扫完」两个发射点。
    /// 低命中率查询（~ 下搜 ".claude" 只有 135 条命中 / 198 万项）命中被攥在栈上，
    /// 实测第一批要等到 17.9s（第 50 条命中），扫完要 45s。
    ///
    /// 夹具两个命中分处 depth 1 与 depth 3，中间隔 5000 个不命中项。
    /// 加了时间发射后浅层命中会**单独成批**先发出 → 至少 2 次发射；
    /// 只有计数发射时 2 < 50，全程只有收尾那一次发射 → 断言必红。
    @Test func sparseHitIsNotWithheldUntilScanEnds() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("nspace-flush-\(UUID().uuidString)")
        let deepDir = root.appendingPathComponent("bulk/deep")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: deepDir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent("flushneedle-shallow.txt"))   // depth 1
        try Data("x".utf8).write(to: deepDir.appendingPathComponent("flushneedle-deep.txt"))   // depth 3
        for i in 0..<5000 {                                                                    // depth 2 填充
            try Data().write(to: root.appendingPathComponent("bulk/pad-\(i).bin"))
        }
        var emits: [[SearchHit]] = []
        SearchSession.scan(root: root,
                           request: SearchRequest(query: "flushneedle", scope: .directory(root),
                                                  includeHidden: true),
                           flushInterval: 1_000_000) { emits.append($0) }   // 1ms 窗，配 5000 项(~12ms)夹具
        #expect(emits.count >= 2, "浅层命中必须先单独发出，实得 \(emits.count) 次发射")
        #expect(emits.first?.contains { $0.name == "flushneedle-shallow.txt" } == true,
                "第一批必须是 depth-1 的那条，实得 \(emits.first?.map(\.name) ?? [])")
        #expect(emits.flatMap { $0 }.count == 2)         // 反空断言：两条命中都到齐
    }

    /// 真因③ 跳过名单里的目录**本身**永远不可能成为命中：旧版 skip 分支在匹配测试
    /// **之前** `continue`，于是搜 "node_modules" / "Library" / ".git" 搜不到那个目录自己。
    @Test func skippedDirectoryItselfCanStillBeAHit() async throws {
        // 专用夹具：坑内文件名**也**包含查询词。用共享夹具的 skip-nsneedle.txt 时
        // 「仍然不下钻」那句是恒真的（查询词 node_modules 根本匹配不到它），等于没断言。
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("nspace-skip-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir.appendingPathComponent("node_modules"),
                               withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dir.appendingPathComponent("node_modules/node_modules-inside.txt"))
        let hits = await collect(SearchRequest(query: "node_modules", scope: .directory(dir),
                                               searchNames: true, searchContents: false,
                                               includeHidden: true))
        #expect(hits.contains { $0.name == "node_modules" && $0.isDirectory },
                "巨坑目录自身必须可被命中，实得 \(hits.map(\.name))")
        // 仍然不下钻：坑内那个**同样匹配**的文件必须不出现（跳过语义没被一起改掉）
        #expect(!hits.contains { $0.name == "node_modules-inside.txt" },
                "跳过语义必须保留，实得 \(hits.map(\.name))")
    }

    /// 真因④ 结果封顶饿死通道B：通道A 在首个 gathering 通知里就能一次读满 2000 条，
    /// `append()` 随即 `keptCount >= maxResults` → `teardown()` → `scanTask.cancel()`，
    /// 通道B 攥在栈上的 batch 直接作废。于是任何 Spotlight 命中 ≥2000 的词，
    /// 「包含隐藏文件」是个静默空开关。预留后通道A 吃不满全部名额。
    @Test func spotlightBudgetReservesRoomForTheScanChannel() {
        // 通道B 在跑：通道A 单次最多读 maxResults - scanReserve（旧公式会给出全部 maxResults）
        #expect(SearchLimits.spotlightReadBudget(kept: 0, scanAlive: true)
                == SearchLimits.maxResults - SearchLimits.scanReserve)
        #expect(SearchLimits.scanReserve > 0)                       // 反焊死：预留必须真的有量
        // 通道B 已收工：不再预留，通道A 可用满额度（否则白丢结果）
        #expect(SearchLimits.spotlightReadBudget(kept: 0, scanAlive: false) == SearchLimits.maxResults)
        // 已读接近上限时预算归零，绝不负数
        #expect(SearchLimits.spotlightReadBudget(kept: SearchLimits.maxResults, scanAlive: true) == 0)
        #expect(SearchLimits.spotlightReadBudget(kept: SearchLimits.maxResults + 99, scanAlive: false) == 0)
    }
    /// 封顶必须**逐条**守，不能靠"批次恒为 50 所以正好落在 2000"这种巧合：
    /// 加了时间发射之后批次大小不定，越顶后才发现会多留最多 49 条。
    /// 直接喂 7 条一批（7 不整除 2000）——端到端夹具做不出这个条件（命中都在同一目录、
    /// 批次恒 50，keptCount 本来就正好落上限，第一版据此写的断言是假绿）。
    @Test func hardCapLandsExactlyOnLimitWithIrregularBatches() async throws {
        let (stream, cont) = AsyncStream<[SearchHit]>.makeStream()
        let session = SearchSession(request: SearchRequest(query: "capx", scope: .global),
                                    continuation: cont)
        let collector = Task { @MainActor in
            var out: [SearchHit] = []
            for await b in stream { out.append(contentsOf: b) }
            return out
        }
        var i = 0
        while i < SearchLimits.maxResults + 100 {
            let batch = (0..<7).map { k -> SearchHit in
                SearchHit(url: URL(fileURLWithPath: "/tmp/nspace-capx-\(i + k)"),
                          name: "capx-\(i + k)", isDirectory: false,
                          size: nil, modified: nil, contentTypeID: nil)
            }
            session.append(batch)
            i += 7
        }
        session.stop()
        let got = await collector.value
        #expect(got.count == SearchLimits.maxResults, "实得 \(got.count)，必须正好等于上限")
        #expect(Set(got.map(\.url.path)).count == got.count)   // 反空断言：去重后仍是这个数
    }
    /// 首批免节流：扫描侧 150ms 发射窗之后，append() 又压 300ms 节流，
    /// 稀疏查询的首个结果上屏要 ~450ms。首批直接推出去，后续才节流。
    ///
    /// 这条**不是**计时断言：`hasYielded` 在 append 返回那一刻就是终值，
    /// 所以它是确定性的。端到端测同一件事会变成易抖的计时断言，那种不写。
    @Test func firstBatchBypassesThrottleButLaterSmallBatchesDoNot() async throws {
        let (stream, cont) = AsyncStream<[SearchHit]>.makeStream()
        let session = SearchSession(request: SearchRequest(query: "thr", scope: .global),
                                    continuation: cont)
        func hit(_ i: Int) -> SearchHit {
            SearchHit(url: URL(fileURLWithPath: "/tmp/nspace-thr-\(i)"), name: "thr-\(i)",
                      isDirectory: false, size: nil, modified: nil, contentTypeID: nil)
        }
        // 首批：必须**立刻**推出（不进 300ms 计划）
        session.append([hit(1)])
        #expect(session.hasYielded, "首批必须立刻推出，不许压 300ms 节流")
        #expect(session.bufferedCount == 0, "首批应已清空缓冲，实得 \(session.bufferedCount)")
        // 第二批小批：节流仍要生效（否则每条命中都跨线程推一次，白烧 CPU）
        session.append([hit(2)])
        #expect(session.bufferedCount == 1, "第二批小批必须留在缓冲里受节流，实得 \(session.bufferedCount)")
        session.stop()
        _ = stream
    }
}

import Testing
import Foundation
import SearchEngine

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
}

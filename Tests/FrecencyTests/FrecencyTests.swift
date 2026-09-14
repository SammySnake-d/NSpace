import Testing
import Foundation
@testable import Frecency

@Suite struct FrecencyRankingTests {

    // MARK: frecency 衰减

    @Test func freshScoreEqualsCount() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let e = FrecencyEntry(count: 5, lastAccess: now)
        #expect(SearchRanking.frecencyScore(e, now: now) == 5)
    }

    @Test func halfLifeHalvesScore() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let past = now.addingTimeInterval(-30 * 86_400)   // 30 天前
        let e = FrecencyEntry(count: 4, lastAccess: past)
        let s = SearchRanking.frecencyScore(e, now: now, halfLifeDays: 30)
        #expect(abs(s - 2.0) < 0.001)   // 4 × 0.5^1 = 2
    }

    @Test func recentBeatsFrequentButOld() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let oftenButOld = FrecencyEntry(count: 50, lastAccess: now.addingTimeInterval(-365 * 86_400))
        let onceButToday = FrecencyEntry(count: 1, lastAccess: now)
        #expect(SearchRanking.frecencyScore(onceButToday, now: now)
                > SearchRanking.frecencyScore(oftenButOld, now: now))
    }

    // MARK: 匹配质量分层

    @Test func matchTierOrdering() {
        let exact = SearchRanking.matchScore(query: "report", name: "report", path: "/a/report")!
        let prefix = SearchRanking.matchScore(query: "rep", name: "report.pdf", path: "/a/report.pdf")!
        let wordStart = SearchRanking.matchScore(query: "budget", name: "2026 budget.xlsx", path: "/a/2026 budget.xlsx")!
        let substr = SearchRanking.matchScore(query: "udg", name: "budget.xlsx", path: "/a/budget.xlsx")!
        let pathOnly = SearchRanking.matchScore(query: "docs", name: "report.pdf", path: "/docs/report.pdf")!
        #expect(exact > prefix)
        #expect(prefix > wordStart)
        #expect(wordStart > substr)
        #expect(substr > pathOnly)
    }

    @Test func noMatchReturnsNil() {
        #expect(SearchRanking.matchScore(query: "zzzz", name: "report.pdf", path: "/a/report.pdf") == nil)
    }

    @Test func subsequenceAcronymMatches() {
        // "prfi8" 命中 "program files 86"（Listary 式缩写），但弱于真子串
        let acr = SearchRanking.matchScore(query: "prfi8", name: "program files 86", path: "/x/program files 86")
        #expect(acr != nil)
        let realSub = SearchRanking.matchScore(query: "files", name: "program files 86", path: "/x/program files 86")!
        #expect(realSub > acr!)
    }

    // MARK: 融合——短查询 frecency 主导 / 长查询匹配主导

    @Test func shortQueryFrecencyDominates() {
        // 查询短（1 字符，match 平庸）时，高 frecency 应把它顶到高 match/低 frecency 之上
        let lowMatchHighFrec = SearchRanking.fused(match: 400, frecency: 20, queryLen: 1)
        let highMatchNoFrec = SearchRanking.fused(match: 600, frecency: 0, queryLen: 1)
        #expect(lowMatchHighFrec > highMatchNoFrec)
    }

    @Test func longQueryMatchDominates() {
        // 查询长（精确输入）时，匹配质量差应压过 frecency 差
        let bestMatchNoFrec = SearchRanking.fused(match: 800, frecency: 0, queryLen: 8)
        let poorMatchHighFrec = SearchRanking.fused(match: 200, frecency: 20, queryLen: 8)
        #expect(bestMatchNoFrec > poorMatchHighFrec)
    }
}

@Suite struct FrecencyStoreTests {
    func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("nspace-frecency-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func recordIncrementsAndScores() async {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = FrecencyStore(directory: dir)
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let url = dir.appendingPathComponent("a.txt")
        await store.record(url, now: now)
        await store.record(url, now: now)
        let s = await store.score(forPath: url.standardizedFileURL.path, now: now)
        #expect(s == 2)   // 两次、同刻 → count 2、无衰减
        let miss = await store.score(forPath: "/nope", now: now)
        #expect(miss == 0)
    }

    @Test func persistenceRoundTrip() async {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let url = dir.appendingPathComponent("keep.txt")
        do {
            let store = FrecencyStore(directory: dir)
            await store.record(url, now: now)
            await store.record(url, now: now)
            await store.record(url, now: now)
        }
        // 新实例从磁盘恢复
        let reopened = FrecencyStore(directory: dir)
        let s = await reopened.score(forPath: url.standardizedFileURL.path, now: now)
        #expect(s == 3)
    }

    @Test func pruneEvictsLowestWhenOverCapacity() async {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = FrecencyStore(directory: dir, maxEntries: 10)
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        // 一个高频"热"路径 + 大量一次性冷路径 → 超限后热路径必须留存
        let hot = dir.appendingPathComponent("hot.txt")
        for _ in 0..<20 { await store.record(hot, now: now) }
        for i in 0..<30 { await store.record(dir.appendingPathComponent("cold-\(i).txt"), now: now) }
        let c = await store.count()
        #expect(c <= 10)
        #expect(await store.score(forPath: hot.standardizedFileURL.path, now: now) > 0)   // 热路径未被淘汰
    }

    // MARK: 多词查询 + 大小写优先（用户报告）

    /// 排序层必须和搜索层同一口径：带空格的查询在这里也得算得出分。
    /// 否则会出现"引擎找得到、排序判 0 分沉到最底下"的分裂——用户看到的仍然像是没搜到。
    @Test func multiTermQueryScoresInsteadOfReturningNil() {
        let s = SearchRanking.matchScore(query: "override md",
                                         name: "OVERRIDE.md", path: "/u/.claude/OVERRIDE.md")
        #expect(s != nil, "带空格的查询必须能算出分，实得 nil")
        // 单词整串匹配时代这里恒为 nil：名字里没有空格，既不是子串也不是子序列
        #expect((s ?? 0) > 0)
    }

    /// 每个词都要沾边：有一个词谁都不沾，整条不算（与引擎的 AND 语义一致）
    @Test func multiTermRequiresEveryTermToMatch() {
        #expect(SearchRanking.matchScore(query: "override zzz",
                                         name: "OVERRIDE.md", path: "/u/OVERRIDE.md") == nil)
    }

    /// 用户要求：「优先展示匹配大小写的，然后后面是不匹配大小写的，但是字符一样的」
    @Test func caseExactRanksAboveCaseInsensitive() {
        let exactCase = SearchRanking.matchScore(query: "override",
                                                 name: "override.md", path: "/a/override.md")!
        let otherCase = SearchRanking.matchScore(query: "override",
                                                 name: "OVERRIDE.md", path: "/a/OVERRIDE.md")!
        #expect(exactCase > otherCase,
                "大小写一致的该排前面：\(exactCase) vs \(otherCase)")
    }

    /// 但大小写加成**不许越档**：一个弱匹配（名内子串）不能因为大小写碰巧一致
    /// 就压过一个强匹配（前缀命中）。加成上限 50 < 最小档距 200，这条钉住它。
    @Test func caseBonusNeverOutranksAStrongerMatchTier() {
        // 前缀档（800），大小写不一致
        let strongerWrongCase = SearchRanking.matchScore(query: "rep",
                                                         name: "REPORT.pdf", path: "/a/REPORT.pdf")!
        // 名内子串档（400 区间），大小写完全一致
        let weakerExactCase = SearchRanking.matchScore(query: "port",
                                                       name: "report.pdf", path: "/a/report.pdf")!
        #expect(strongerWrongCase > weakerExactCase,
                "档位必须压过大小写加成：\(strongerWrongCase) vs \(weakerExactCase)")
    }
}

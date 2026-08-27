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
}

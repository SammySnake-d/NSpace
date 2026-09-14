import Foundation
import NSpaceContracts

// Frecency 胶囊唯一对外契约面（Axiom 3）：使用习惯学习排序（frecency + 匹配质量融合）的词汇表。
// frecency = frequency（打开频次）× recency（新近，指数衰减）——搜索按此自动排序（M28，Listary 式）。

/// 单条记账：某路径的累计打开次数 + 最近一次打开时刻。
public struct FrecencyEntry: Sendable, Hashable, Codable {
    public var count: Int
    public var lastAccess: Date

    public init(count: Int, lastAccess: Date) {
        self.count = count
        self.lastAccess = lastAccess
    }
}

/// 使用习惯学习排序的纯逻辑（无状态、线程无关）：匹配质量打分 + 与 frecency 的融合。
/// 与 [[FrecencyStore]] 解耦——Store 管持久化与衰减，Ranking 管"这条命中该排多前"。
public enum SearchRanking {
    /// frecency 衰减：`count × 0.5^(ageDays / halfLifeDays)`（默认半衰期 30 天）。
    /// 一周前打开一次 ≈ 0.85；30 天前 = 0.5；一年前几近 0。
    public static func frecencyScore(_ e: FrecencyEntry, now: Date, halfLifeDays: Double = 30) -> Double {
        let ageDays = max(0, now.timeIntervalSince(e.lastAccess) / 86_400)
        return Double(e.count) * pow(0.5, ageDays / halfLifeDays)
    }

    /// 匹配质量分层（越大越好；完全不沾边返回 nil）：
    /// 精确名 > 名前缀 > 名词边界 > 名子串 > 路径子串 > 名子序列(缩写) > 路径子序列。
    /// 参照 fzf/fzy：词首/连续命中加权。大小写不敏感，但**同档内大小写一致的排前面**（见 caseBonus）。
    ///
    /// 查询按空白切词，**每个词都要沾边**（任一词不沾边即 nil），得分取各词平均。
    /// 不这么做的话，带空格的查询在这里恒得 nil：整串 `"override md"` 既不是
    /// `override.md` 的子串、也不是它的子序列（名字里没有空格），于是搜索引擎那边刚修好
    /// 能找到，排序这边又把它判成 0 分沉到底——两层必须同一口径。
    public static func matchScore(query: String, name: String, path: String) -> Double? {
        let terms = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !terms.isEmpty else { return nil }
        var total = 0.0
        for t in terms {
            guard let s = termScore(term: t, name: name, path: path) else { return nil }
            total += s
        }
        return total / Double(terms.count)
    }

    /// 单个词的匹配质量（分层同上）。
    private static func termScore(term: String, name: String, path: String) -> Double? {
        let q = term.lowercased()
        guard !q.isEmpty else { return nil }
        let n = name.lowercased()
        let p = path.lowercased()

        // 大小写一致加成：这个词能在名字里**原样**（区分大小写）找到就给。
        // 上限 50，**小于任何两档之间的间距**（最小间距 200）：它只在同一档里排先后，
        // 绝不让一个弱匹配因为大小写碰巧一致就越过强匹配。
        // 用户要求：「优先展示匹配大小写的，然后后面是不匹配大小写的，但是字符一样的」。
        let bonus: Double = name.contains(term) ? 50 : 0

        if n == q { return 1000 + bonus }
        if n.hasPrefix(q) { return 800 + bonus }
        if let r = n.range(of: q) {
            // 名内子串：命中处前一字符是分隔符 → 词边界（更强）；否则普通子串（按位置轻惩罚）
            let idx = n.distance(from: n.startIndex, to: r.lowerBound)
            let atWordStart = idx == 0 || isSeparator(n[n.index(r.lowerBound, offsetBy: -1)])
            return (atWordStart ? 600 : 400) - Double(min(idx, 50)) + bonus
        }
        if p.contains(q) { return 200 + bonus }
        if let sub = subsequenceScore(query: q, in: n) { return 100 + sub }   // 缩写/模糊（名）
        if let sub = subsequenceScore(query: q, in: p) { return 50 + sub }    // 缩写/模糊（路径）
        return nil
    }

    /// 融合：`match + frecencyWeight(queryLen) × log(1+frecency)`。
    /// 权重随查询变长而减小——短查询靠使用习惯、长查询靠匹配质量（Listary 观测行为）。
    public static func fused(match: Double, frecency: Double, queryLen: Int) -> Double {
        let w: Double = queryLen <= 2 ? 400 : (queryLen <= 4 ? 200 : 100)
        return match + w * log(1 + max(0, frecency))
    }

    // MARK: 私有

    private static func isSeparator(_ c: Character) -> Bool {
        c == " " || c == "-" || c == "_" || c == "." || c == "/" || c == "("
    }

    /// 子序列匹配（query 的字符按序出现在 text 中即可）；连续命中额外加分。不匹配返回 nil。
    private static func subsequenceScore(query: String, in text: String) -> Double? {
        var qi = query.startIndex
        var consecutive = 0, bestRun = 0, run = 0
        var lastMatched = false
        for ch in text {
            if qi < query.endIndex, ch == query[qi] {
                qi = query.index(after: qi)
                if lastMatched { run += 1; bestRun = max(bestRun, run) } else { run = 0 }
                lastMatched = true
                consecutive += 1
            } else {
                lastMatched = false
            }
        }
        guard qi == query.endIndex else { return nil }   // query 未被完整覆盖
        return Double(bestRun) * 5   // 连续段越长越像"真的在打这个词"
    }
}

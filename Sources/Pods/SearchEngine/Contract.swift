import Foundation
import NSpaceContracts

// SearchEngine 胶囊唯一对外契约面（Axiom 3）：聚焦搜索的请求/命中词汇表

public enum SearchLimits {
    /// 单次搜索的结果硬上限：全局 Spotlight（NSMetadataQueryLocalComputerScope）常见词能命中十万级，
    /// 无上限地在主线程读全部 result(at:) + 铺进 NSTableView 会直接卡死、CPU 暴涨。达上限即停两通道。
    /// UI 据此显示"仅显示前 N 条，请细化关键词"。2000 足够定位单文件，且主线程成本恒有界。
    public static let maxResults = 2000

    /// 通道B（隐藏文件扫描）在通道A 仍能读的时候被预留的名额。
    ///
    /// 真红：通道A 在首个 gathering 通知（0.3s）里就能一次读满 2000 条，`append()` 随即
    /// `keptCount >= maxResults` → `flushNow(); teardown()` → `scanTask.cancel()`，通道B
    /// 那一刻还攥在栈上的 batch 直接作废。于是任何 Spotlight 命中数 ≥2000 的查询，
    /// 「包含隐藏文件」是个**静默空开关**——这是"能看到却搜不到"的另一个独立触发器。
    /// 预留后通道A 最多吃到 maxResults - scanReserve，通道B 恒有名额落地。
    public static let scanReserve = 500

    /// 通道A 单次 drain 的读取预算（纯函数：单测可确定性断言，无需依赖 Spotlight 索引状态）
    public static func spotlightReadBudget(kept: Int, scanAlive: Bool) -> Int {
        max(0, maxResults - kept - (scanAlive ? scanReserve : 0))
    }
}

public struct SearchRequest: Sendable {
    public enum Scope: Sendable {
        case global
        case directory(URL)
    }

    public let query: String
    public let scope: Scope
    /// 按名称搜（通道A Spotlight kMDItemFSName + 通道B 文件名扫描）
    public let searchNames: Bool
    /// 按内容全文搜（只走通道A Spotlight kMDItemTextContent——全文索引无法自建，诚实降级）
    public let searchContents: Bool
    /// 隐藏文件通道开关（超越 Spotlight：不依赖索引、不跳过隐藏文件，只支持按名搜）
    public let includeHidden: Bool
    /// 通道B 递归扫描跳过的巨坑目录名（可配置）
    public let skippedDirectoryNames: Set<String>

    public init(query: String, scope: Scope,
                searchNames: Bool = true, searchContents: Bool = false,
                includeHidden: Bool = false,
                skippedDirectoryNames: Set<String> = ["node_modules", ".git", ".Trash", "Library"]) {
        self.query = query
        self.scope = scope
        self.searchNames = searchNames
        self.searchContents = searchContents
        self.includeHidden = includeHidden
        self.skippedDirectoryNames = skippedDirectoryNames
    }
}

/// 搜索命中（构建时已取好展示属性，UI 零补 stat）
public struct SearchHit: Sendable, Hashable {
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let size: Int64?
    public let modified: Date?
    /// UTType.identifier（UI 按 conform 做种类过滤）
    public let contentTypeID: String?

    public init(url: URL, name: String, isDirectory: Bool,
                size: Int64?, modified: Date?, contentTypeID: String?) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
        self.contentTypeID = contentTypeID
    }
}

/// 查询词元：把输入按空白切成若干词，逐词匹配、顺序无关、大小写与变音不敏感。
///
/// 用户报告：在 `~/.claude` 里搜 `override md` 报「未找到」，而目录里就摆着 `OVERRIDE.md`。
/// 大小写不是原因（两条通道本来就用 `localizedCaseInsensitiveContains` / `CONTAINS[cd]`，
/// 实测 `override` 单独搜能命中）——真凶是那个**空格**：整串 `"override md"` 被当作一个
/// 连续子串去找，而文件名里那个位置是点号。`md override` 同样找不到，正是这一条的佐证。
///
/// 纯函数、无状态：两条通道共用同一口径，也才验得住（整串匹配时代那道判定散在扫描循环里）。
public enum QueryTerms {
    /// 切词。连续空白合并，首尾空白丢弃；空查询得空数组。
    public static func split(_ query: String) -> [String] {
        query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// 所有词都出现在 `name` 里即命中（AND，顺序无关，大小写/变音不敏感）。
    /// 空词组永不命中——否则空查询会把整个磁盘当成结果。
    public static func matches(_ name: String, terms: [String]) -> Bool {
        guard !terms.isEmpty else { return false }
        return terms.allSatisfy { name.localizedCaseInsensitiveContains($0) }
    }
}

public struct SearchError: ClassifiedError {
    public let errorClass: ErrorClass
    public let localizedDescription: String

    init(_ cls: ErrorClass, _ message: String) {
        self.errorClass = cls
        self.localizedDescription = message
    }
}

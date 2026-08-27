import Foundation
import NSpaceContracts

/// 「年/月」分组纯逻辑（M26）：列表与图标视图共用的唯一真源——
/// 分组键格式、组日期取用、桶划分集中于此，杜绝 index 算术与键格式在各视图散落（BG）。
@MainActor
enum FileGrouping {
    /// 该排序键是否为日期类（仅日期类才分组）
    static func isDateKey(_ k: SortSpec.Key) -> Bool {
        k == .dateModified || k == .created || k == .added
    }

    /// 分组是否生效：偏好开 且 排序键为日期类
    static func active(_ sort: SortSpec) -> Bool {
        Preferences.listGrouping && isDateKey(sort.key)
    }

    private static func date(for item: FileItem, key: SortSpec.Key) -> Date? {
        switch key {
        case .dateModified: return item.modified
        case .created: return item.created
        case .added: return item.added
        default: return nil
        }
    }

    /// 当前时刻注入点（M29）：产品用真实 Date；测试注入固定时钟以确定性验证相对桶落位。
    /// 与 [[Formatters.relativeDate]] 的 now 同源语义（此处集中一处，避免各视图各取 Date）。
    static var nowProvider: () -> Date = { Date() }

    /// 「往年」标题格式器（本地化：zh→2025年 / en→2025）——仅非本年分桶用
    private static func yearTitle(_ year: Int) -> String {
        String(format: L10n.t("group.year"), year)
    }

    /// 组键（稳定，跨语言不变，用于折叠/过滤记账）+ 组标题（本地化显示）。
    /// 相对分桶（M29，用户点名）：今天/昨天/本周/本月/今年更早/往年(YYYY年)——由近及远，
    /// 键前缀 g0..g5 保证「往年」多年份按年细分且组序天然随排序方向（items 已按日期排序）。
    static func keyTitle(for item: FileItem, key: SortSpec.Key) -> (key: String, title: String) {
        guard let date = date(for: item, key: key) else {
            return ("__nodate__", L10n.t("group.noDate"))
        }
        let cal = Calendar.current
        let now = nowProvider()
        if cal.isDate(date, inSameDayAs: now) {
            return ("g0-today", L10n.t("group.today"))
        }
        if let yst = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(date, inSameDayAs: yst) {
            return ("g1-yesterday", L10n.t("group.yesterday"))
        }
        if cal.isDate(date, equalTo: now, toGranularity: .weekOfYear) {
            return ("g2-week", L10n.t("group.thisWeek"))
        }
        if cal.isDate(date, equalTo: now, toGranularity: .month) {
            return ("g3-month", L10n.t("group.thisMonth"))
        }
        if cal.isDate(date, equalTo: now, toGranularity: .year) {
            return ("g4-year-earlier", L10n.t("group.earlierThisYear"))
        }
        let year = cal.component(.year, from: date)
        return (String(format: "g5-%04d", year), yearTitle(year))
    }

    struct Group: Equatable {
        let key: String
        let title: String
        /// 组内项在原 items 数组中的下标（保持排序后的相对顺序）
        let indices: [Int]
    }

    /// 相对桶的"新近度"秩（越新越小）：今天0<昨天1<本周2<本月3<今年更早4<往年(按年，新年份更小)<无日期。
    /// 组顺序据此排（I-49）——不再靠"首次出现"，因「文件夹置顶」使 items=[文件夹段][文件段] 非全局单调，
    /// 会把只含文件的桶（如"今天"仅一个文件）挤到文件夹建立的桶序之后。
    static func recencyRank(ofKey key: String) -> Int {
        switch key {
        case "g0-today": return 0
        case "g1-yesterday": return 1
        case "g2-week": return 2
        case "g3-month": return 3
        case "g4-year-earlier": return 4
        case "__nodate__": return Int.max
        default:
            if key.hasPrefix("g5-"), let y = Int(key.dropFirst(3)) { return 5 + (9999 - y) }
            return Int.max - 1
        }
    }

    /// 已按 sort 排序的 items → 有序分组：**组顺序按相对时间新近度**（direction-aware，不受 foldersFirst 打乱），
    /// 组内保持项的相对顺序（含文件夹置顶）。纯函数，可黑盒单测。
    /// 日期降序（newest first）→ 组按 rank 升序（今天在最前）；日期升序 → rank 降序（今天在最后）。
    static func buckets(_ items: [FileItem], key: SortSpec.Key, ascending: Bool) -> [Group] {
        var indexBuckets: [String: [Int]] = [:]
        var titles: [String: String] = [:]
        for (i, item) in items.enumerated() {
            let (gk, gt) = keyTitle(for: item, key: key)
            if indexBuckets[gk] == nil { indexBuckets[gk] = []; titles[gk] = gt }
            indexBuckets[gk]?.append(i)
        }
        let orderedKeys = indexBuckets.keys.sorted {
            let ra = recencyRank(ofKey: $0), rb = recencyRank(ofKey: $1)
            return ascending ? ra > rb : ra < rb
        }
        return orderedKeys.map { Group(key: $0, title: titles[$0] ?? $0, indices: indexBuckets[$0] ?? []) }
    }
}

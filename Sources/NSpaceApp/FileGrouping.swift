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

    /// 「YYYY年M月」标题格式器（本地化：zh→2026年8月 / en→August 2026）
    private static let titleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("yMMMM")
        return f
    }()

    /// 组键（稳定，跨语言不变，用于折叠/过滤记账）+ 组标题（本地化显示）
    static func keyTitle(for item: FileItem, key: SortSpec.Key) -> (key: String, title: String) {
        guard let date = date(for: item, key: key) else {
            return ("__nodate__", L10n.t("group.noDate"))
        }
        let comps = Calendar.current.dateComponents([.year, .month], from: date)
        let stableKey = String(format: "%04d-%02d", comps.year ?? 0, comps.month ?? 0)
        return (stableKey, titleFormatter.string(from: date))
    }

    struct Group: Equatable {
        let key: String
        let title: String
        /// 组内项在原 items 数组中的下标（保持排序后的相对顺序）
        let indices: [Int]
    }

    /// 已按 sort 排序的 items → 有序分组：组顺序=组在项序列中首次出现的顺序（排序方向天然决定组序），
    /// 组内保持项的相对顺序。纯函数，可黑盒单测。
    static func buckets(_ items: [FileItem], key: SortSpec.Key) -> [Group] {
        var order: [String] = []
        var indexBuckets: [String: [Int]] = [:]
        var titles: [String: String] = [:]
        for (i, item) in items.enumerated() {
            let (gk, gt) = keyTitle(for: item, key: key)
            if indexBuckets[gk] == nil { indexBuckets[gk] = []; order.append(gk); titles[gk] = gt }
            indexBuckets[gk]?.append(i)
        }
        return order.map { Group(key: $0, title: titles[$0] ?? $0, indices: indexBuckets[$0] ?? []) }
    }
}

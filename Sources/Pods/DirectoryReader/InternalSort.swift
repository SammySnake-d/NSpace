import Foundation
import NSpaceContracts

// 私有关注点：Finder 式排序（localizedStandardCompare、文件夹优先可选）
// 用三值比较保证严格弱序（降序时相等元素不得互判"小于"，否则 sort 崩溃）

func sortItems(_ items: inout [FileItem], by order: SortSpec) {
    items.sort { a, b in
        if order.foldersFirst {
            let aDir = a.isDirectory && !a.isPackage
            let bDir = b.isDirectory && !b.isPackage
            if aDir != bDir { return aDir }
        }
        let cmp: ComparisonResult
        switch order.key {
        case .name:
            cmp = a.name.localizedStandardCompare(b.name)
        case .dateModified:
            cmp = compare(a.modified ?? .distantPast, b.modified ?? .distantPast)
        case .size:
            cmp = compare(a.size ?? -1, b.size ?? -1)
        case .kind:
            cmp = compare(a.contentTypeID ?? "", b.contentTypeID ?? "")
        }
        if cmp == .orderedSame {
            // 同键值时按名字恒升序打破平局（与主方向无关，保持稳定观感）
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        return order.ascending ? cmp == .orderedAscending : cmp == .orderedDescending
    }
}

private func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
    if a < b { return .orderedAscending }
    if a > b { return .orderedDescending }
    return .orderedSame
}

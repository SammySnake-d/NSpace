import Foundation
import NSpaceContracts

// 私有关注点：操作计划构建 + 预扫描 + 冲突检测/裁决应用

struct TransferPlan {
    enum Mode { case copy, move }
    struct Entry {
        let source: URL
        /// 目标完整路径（含最终文件名，keepBoth 裁决后可能改名）
        var destination: URL
        /// mergeFolders 裁决标记：递归合并而非整体替换
        var merge = false
    }
    let mode: Mode
    var entries: [Entry]
}

func makePlan(_ spec: OperationSpec) throws -> TransferPlan {
    switch spec.kind {
    case .copy, .move:
        guard let destDir = spec.destination, !spec.sources.isEmpty else {
            throw TransferError(.logic, "copy/move 需要 sources 与 destination")
        }
        let mode: TransferPlan.Mode = spec.kind == .move ? .move : .copy
        return TransferPlan(mode: mode, entries: spec.sources.map {
            .init(source: $0, destination: destDir.appendingPathComponent($0.lastPathComponent))
        })
    case .duplicate:
        guard !spec.sources.isEmpty else { throw TransferError(.logic, "duplicate 需要 sources") }
        // 制作副本 = 同目录复制，恒 keepBoth 命名，绝不产生冲突
        return TransferPlan(mode: .copy, entries: spec.sources.map { src in
            let dir = src.deletingLastPathComponent()
            return .init(source: src, destination: dir.appendingPathComponent(keepBothName(for: src, in: dir)))
        })
    default:
        throw TransferError(.logic, "TransferNode 不处理 \(spec.kind.rawValue)")
    }
}

struct ScanTotals { var files = 0; var bytes: Int64 = 0 }

/// 预扫描：文件计数 + 字节总量（目录深走；进度分母），并保留每源小计供 move 快路径记账
func preScan(sources: [URL]) throws -> (total: ScanTotals, perSource: [URL: ScanTotals]) {
    let fm = FileManager.default
    var total = ScanTotals()
    var perSource: [URL: ScanTotals] = [:]
    let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey]
    for src in sources {
        guard let rv = try? src.resourceValues(forKeys: keys) else {
            throw TransferError(.external, "无法访问源: \(src.lastPathComponent)", path: src.path)
        }
        var sub = ScanTotals()
        if rv.isDirectory == true {
            if let walker = fm.enumerator(at: src, includingPropertiesForKeys: Array(keys),
                                          options: [], errorHandler: nil) {
                for case let child as URL in walker {
                    let crv = try? child.resourceValues(forKeys: keys)
                    if crv?.isDirectory != true {
                        sub.files += 1
                        sub.bytes += Int64(crv?.fileSize ?? 0)
                    }
                }
            }
        } else {
            sub.files = 1
            sub.bytes = Int64(rv.fileSize ?? 0)
        }
        perSource[src] = sub
        total.files += sub.files
        total.bytes += sub.bytes
    }
    return (total, perSource)
}

/// 冲突检测 → 请求裁决 → 应用决议，返回最终待执行条目
func resolveConflicts(plan: TransferPlan, context: NodeContext) async throws -> [TransferPlan.Entry] {
    let fm = FileManager.default
    var conflicts: [FileConflict] = []
    for entry in plan.entries where fm.fileExists(atPath: entry.destination.path) {
        var srcDir: ObjCBool = false, dstDir: ObjCBool = false
        _ = fm.fileExists(atPath: entry.source.path, isDirectory: &srcDir)
        _ = fm.fileExists(atPath: entry.destination.path, isDirectory: &dstDir)
        conflicts.append(FileConflict(source: entry.source, existing: entry.destination,
                                      bothDirectories: srcDir.boolValue && dstDir.boolValue))
    }
    guard !conflicts.isEmpty else { return plan.entries }

    guard let decisions = await context.resolveConflicts(conflicts) else {
        throw CancellationError()  // 用户在冲突面板取消整个操作
    }

    var result: [TransferPlan.Entry] = []
    for var entry in plan.entries {
        guard fm.fileExists(atPath: entry.destination.path) else { result.append(entry); continue }
        switch decisions[entry.source] ?? .skip {
        case .skip:
            continue
        case .replace:
            do { try fm.removeItem(at: entry.destination) } catch {
                throw TransferError(.external, "无法替换目标: \(error.localizedDescription)",
                                    path: entry.destination.path)
            }
            result.append(entry)
        case .keepBoth:
            let dir = entry.destination.deletingLastPathComponent()
            entry.destination = dir.appendingPathComponent(keepBothName(for: entry.source, in: dir))
            result.append(entry)
        case .mergeFolders:
            entry.merge = true
            result.append(entry)
        }
    }
    return result
}

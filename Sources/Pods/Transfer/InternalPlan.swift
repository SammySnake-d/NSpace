import Foundation
import NSpaceContracts

// 私有关注点：操作计划构建 + 预扫描 + 冲突检测/裁决应用

struct TransferPlan {
    enum Mode { case copy, move }
    struct Entry {
        let source: URL
        /// 目标完整路径（含最终文件名，keepBoth/rename 裁决后可能改名）
        var destination: URL
        /// mergeFolders 裁决标记：递归合并而非整体替换
        var merge = false
        /// replace 裁决标记：传输时（微步 3）删目标再写——绝不在裁决阶段预删（防批量取消丢未传输目标）
        var replaceExisting = false
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
    // 仅当存在磁盘冲突时才询问用户；无磁盘冲突也要跑下面的批内占名 pass（防批内同名互撞）
    var decisions: [URL: ConflictDecision] = [:]
    if !conflicts.isEmpty {
        guard let d = await context.resolveConflicts(conflicts) else {
            throw CancellationError()  // 用户在冲突面板取消整个操作
        }
        decisions = d
    }

    var result: [TransferPlan.Entry] = []
    // 批内已占用目标名：keepBoth/rename 去重不能只看磁盘（两条同名源都算出 "a 2" 会撞车，跨卷 move 先删源无副本→永久丢失）；
    // 无磁盘冲突的直通条目也必须占名 + 撞名自动改名（两个不同目录同名源拷进同一空目录同样会互撞）。
    var claimed = Set<String>()
    let existsOrClaimed: (URL) -> Bool = { u in
        fm.fileExists(atPath: u.path) || claimed.contains(u.standardizedFileURL.path)
    }
    for entry in plan.entries {
        if fm.fileExists(atPath: entry.destination.path) {
            // 磁盘冲突：按裁决落地（applyDecision 内部用 existsOrClaimed 去重）
            if let resolved = try applyDecision(decisions[entry.source] ?? .skip, to: entry, claimed: &claimed) {
                claimed.insert(resolved.destination.standardizedFileURL.path)
                result.append(resolved)
            }
        } else if claimed.contains(entry.destination.standardizedFileURL.path) {
            // 无磁盘冲突但撞上批内已占名 → 非破坏性自动改名（Finder 同款；绝不让两条落到同一目标）
            var e = entry
            let dir = e.destination.deletingLastPathComponent()
            e.destination = dir.appendingPathComponent(
                uniqueName(base: e.destination.deletingPathExtension().lastPathComponent,
                           ext: e.destination.pathExtension, in: dir, existsCheck: existsOrClaimed))
            claimed.insert(e.destination.standardizedFileURL.path)
            result.append(e)
        } else {
            claimed.insert(entry.destination.standardizedFileURL.path)
            result.append(entry)
        }
    }
    return result
}

/// 两个 URL 是否指向同一物理文件（inode 级同一性）：符号链接别名 / 大小写不敏感卷变体
/// 都被词法 path 判等漏掉，故用 fileResourceIdentifier；取不到时回退解析符号链接后比较。
/// 自源安全律的判定必须走这里——词法判等会让别名路径下的「替换」删掉源本体（数据丢失）。
func isSameFile(_ a: URL, _ b: URL) -> Bool {
    let key: Set<URLResourceKey> = [.fileResourceIdentifierKey]
    if let ia = try? a.resourceValues(forKeys: key).fileResourceIdentifier,
       let ib = try? b.resourceValues(forKeys: key).fileResourceIdentifier {
        return ia.isEqual(ib)
    }
    // 回退（标识符取不到，仅异类网络/FUSE 挂载）：解析符号链接后按大小写不敏感比较。
    // 偏保守——大小写敏感卷上两个仅大小写不同的文件会被判"同一"→替换收敛为改名（多一份副本，
    // 但绝不删源）；这是安全方向，胜过词法判等在大小写不敏感卷上漏判而删源。
    return a.resolvingSymlinksInPath().standardizedFileURL.path
        .compare(b.resolvingSymlinksInPath().standardizedFileURL.path, options: .caseInsensitive) == .orderedSame
}

/// 单条冲突决议落地（含 M27-B 自源安全律：destination 即 source 本体时，
/// 「替换/合并」会删除或自合并正作为拷贝源的文件 → 一律中和为「两者保留」改名，绝不删源）。
/// 返回 nil = 跳过该条。replace 只打标记、真正删目标推迟到微步 3 传输时（防批量取消丢未传输目标）。
private func applyDecision(_ decision: ConflictDecision,
                          to entry: TransferPlan.Entry,
                          claimed: inout Set<String>) throws -> TransferPlan.Entry? {
    var entry = entry
    let dir = entry.destination.deletingLastPathComponent()
    // 自源判定走 inode 级（词法 path 判等会被符号链接/大小写别名绕过 → 删源丢数据）
    let isSelf = isSameFile(entry.destination, entry.source)
    // keepBoth/rename 去重时把"批内已占用名"也视作已存在
    let exists: (URL) -> Bool = { u in
        FileManager.default.fileExists(atPath: u.path) || claimed.contains(u.standardizedFileURL.path)
    }

    switch decision {
    case .skip:
        return nil
    case .keepBoth:
        entry.destination = dir.appendingPathComponent(keepBothName(for: entry.source, in: dir, existsCheck: exists))
        return entry
    case .replace:
        if isSelf {
            // 自源：替换会删掉正作为拷贝源的文件 → 安全收敛为改名保留（绝不删源）
            entry.destination = dir.appendingPathComponent(keepBothName(for: entry.source, in: dir, existsCheck: exists))
            return entry
        }
        entry.replaceExisting = true   // 删目标推迟到传输时（微步 3）
        return entry
    case .mergeFolders:
        if isSelf {
            // 自源目录合并会自我递归 → 安全收敛为改名保留
            entry.destination = dir.appendingPathComponent(keepBothName(for: entry.source, in: dir, existsCheck: exists))
            return entry
        }
        entry.merge = true
        return entry
    case .rename(let newName):
        // 从用户输入取单一文件名组件（顺带剥离任何目录分隔，防路径逃逸）
        let comp = URL(fileURLWithPath: newName)
        let base = comp.deletingPathExtension().lastPathComponent
        let ext = comp.pathExtension
        guard !base.isEmpty else {
            // 空名兜底：退化 keepBoth（绝不用空名或覆盖源）
            entry.destination = dir.appendingPathComponent(keepBothName(for: entry.source, in: dir, existsCheck: exists))
            return entry
        }
        // uniqueName 保证不覆盖既有/批内已占用、不落到源本体（撞名自动 " 2"），安全律不可绕过
        entry.destination = dir.appendingPathComponent(uniqueName(base: base, ext: ext, in: dir, existsCheck: exists))
        return entry
    }
}

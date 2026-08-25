import Foundation
import NSpaceContracts
import NSpaceKernel
import DirectoryReader
import Transfer

// CLI-First 探针：绕过 UI 编排单独驱动每个胶囊节点（L-readonly / L-irreversible）。
// 不进 .app、不进生产二进制。每接入一个胶囊就加一个子命令。

let args = Array(CommandLine.arguments.dropFirst())

func usage() -> Never {
    print("""
    nspace-probe — NSpace 胶囊节点活体探针
    用法:
      nspace-probe list <目录> [--hidden] [--sort name|dateModified|size|kind] [--desc]   # L-readonly: DirectoryReader
      nspace-probe copy <源…> <目标目录> [--move] [--on-conflict skip|replace|keepBoth|merge]  # L-irreversible: Transfer(经内核全链路)
    """)
    exit(2)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

guard let command = args.first else { usage() }
let rest = Array(args.dropFirst())

switch command {
case "list":
    await runList(rest)
case "copy":
    await runCopy(rest)
default:
    FileHandle.standardError.write("未知子命令: \(command)\n".data(using: .utf8)!)
    usage()
}

// MARK: - list（活体只读：真实文件系统）

func runList(_ args: [String]) async {
    var dir: URL?
    var hidden = false
    var sort = SortSpec()
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--hidden": hidden = true
        case "--desc": sort.ascending = false
        case "--sort":
            i += 1
            guard i < args.count, let key = SortSpec.Key(rawValue: args[i]) else { fail("--sort 取值: name|dateModified|size|kind") }
            sort.key = key
        default:
            dir = URL(fileURLWithPath: (args[i] as NSString).expandingTildeInPath)
        }
        i += 1
    }
    guard let dir else { usage() }

    let reader = DirectoryReader()
    do {
        let t0 = Date()
        let snap = try await reader.load(ReadRequest(directory: dir, includeHidden: hidden, sort: sort))
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        for item in snap.items {
            let mark = item.isDirectory ? "d" : "-"
            let size = item.size.map { String($0) } ?? "-"
            print("\(mark) \(size)\t\(item.name)")
        }
        print("—— \(snap.items.count) 项, generation=\(snap.generation), 耗时 \(ms)ms")
    } catch {
        fail("读取失败: \(error.localizedDescription)")
    }
}

// MARK: - copy（活体不可逆：走 内核→节点 全链路，验证机制连通性）

struct FixedArbiter: ConflictArbiter {
    let decision: ConflictDecision?
    func arbitrate(operation id: UUID, conflicts: [FileConflict]) async -> [URL: ConflictDecision]? {
        guard let decision else { return nil }
        print("冲突 \(conflicts.count) 项，策略: \(decision)")
        return Dictionary(uniqueKeysWithValues: conflicts.map { ($0.source, decision) })
    }
}

func runCopy(_ args: [String]) async {
    var paths: [URL] = []
    var move = false
    var decision: ConflictDecision? = .keepBoth
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--move": move = true
        case "--on-conflict":
            i += 1
            guard i < args.count else { usage() }
            switch args[i] {
            case "skip": decision = .skip
            case "replace": decision = .replace
            case "keepBoth": decision = .keepBoth
            case "merge": decision = .mergeFolders
            case "cancel": decision = nil
            default: fail("--on-conflict 取值: skip|replace|keepBoth|merge|cancel")
            }
        default:
            paths.append(URL(fileURLWithPath: (args[i] as NSString).expandingTildeInPath))
        }
        i += 1
    }
    guard paths.count >= 2 else { usage() }
    let dest = paths.removeLast()

    let kernel = OperationKernel()
    await kernel.register(TransferNode(), for: [.copy, .move, .duplicate])
    await kernel.setArbiter(FixedArbiter(decision: decision))

    let spec = OperationSpec(kind: move ? .move : .copy, sources: paths, destination: dest)
    let id = await kernel.submit(spec)

    for await p in await kernel.projections() where p.id == id {
        let pct = p.bytesTotal > 0 ? Int(Double(p.bytesDone) / Double(p.bytesTotal) * 100) : 0
        print("[\(stateName(p.state))] \(p.filesDone)/\(p.filesTotal) 文件, \(p.bytesDone)/\(p.bytesTotal) 字节 (\(pct)%) \(p.currentPath ?? "")")
        if p.state.isTerminal {
            switch p.state {
            case .completed: print("✓ 完成"); exit(0)
            case .cancelled: print("已取消"); exit(3)
            case let .failed(message, cls): fail("✗ 失败(\(cls)): \(message)")
            default: break
            }
        }
    }
}

func stateName(_ s: RunState) -> String {
    switch s {
    case .pending: "排队"
    case .scanning: "扫描"
    case .awaitingConflict: "等待裁决"
    case .running: "传输"
    case .completed: "完成"
    case .cancelled: "取消"
    case .failed: "失败"
    }
}

import Foundation
import CoreGraphics
import NSpaceContracts
import NSpaceKernel
import DirectoryReader
import Transfer
import DirectoryWatch
import FolderSize
import IconThumb
import ArchiveEngine

// CLI-First 探针：绕过 UI 编排单独驱动每个胶囊节点（L-readonly / L-irreversible）。
// 不进 .app、不进生产二进制。每接入一个胶囊就加一个子命令。

let args = Array(CommandLine.arguments.dropFirst())

func usage() -> Never {
    print("""
    nspace-probe — NSpace 胶囊节点活体探针
    用法:
      nspace-probe list <目录> [--hidden] [--sort name|dateModified|size|kind] [--desc]   # L-readonly: DirectoryReader
      nspace-probe copy <源…> <目标目录> [--move] [--on-conflict skip|replace|keepBoth|merge]  # L-irreversible: Transfer(经内核全链路)
      nspace-probe watch <目录>                    # L-readonly: DirectoryWatch(监听打印信号, 10 秒后退出)
      nspace-probe size <目录>                     # L-readonly: FolderSize(递归大小 + 耗时)
      nspace-probe thumb <文件> [--size 128]       # L-readonly: IconThumb(缩略图像素宽高)
      nspace-probe compress <源…> [--format zip|tar.gz] [--into <目录>]   # L-irreversible: ArchiveEngine(经内核全链路)
      nspace-probe extract <压缩包…> [--into <目录>] [--no-wrapper]        # L-irreversible: ArchiveEngine
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
case "watch":
    await runWatch(rest)
case "size":
    await runSize(rest)
case "thumb":
    await runThumb(rest)
case "compress":
    await runCompress(rest)
case "extract":
    await runExtract(rest)
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

// MARK: - compress / extract（活体不可逆：走 内核→ArchiveEngine 全链路）

func driveArchive(_ kernel: OperationKernel, _ spec: OperationSpec) async {
    let id = await kernel.submit(spec)
    for await p in await kernel.projections() where p.id == id {
        let pct = p.bytesTotal > 0 ? Int(Double(p.bytesDone) / Double(p.bytesTotal) * 100) : 0
        print("[\(stateName(p.state))] \(p.filesDone)/\(p.filesTotal) 文件, \(p.bytesDone)/\(p.bytesTotal) 字节 (\(pct)%) \(p.currentPath ?? "")")
        guard p.state.isTerminal else { continue }
        switch p.state {
        case .completed:
            if let r = await kernel.receipt(id) {
                for u in r.createdURLs { print("→ \(u.path)") }
            }
            print("✓ 完成"); exit(0)
        case .cancelled: print("已取消"); exit(3)
        case let .failed(message, cls): fail("✗ 失败(\(cls)): \(message)")
        default: break
        }
    }
}

func runCompress(_ args: [String]) async {
    var sources: [URL] = []
    var format = "zip"
    var into: URL?
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--format":
            i += 1
            guard i < args.count, ["zip", "tar.gz"].contains(args[i]) else { fail("--format 取值: zip|tar.gz") }
            format = args[i]
        case "--into":
            i += 1
            guard i < args.count else { usage() }
            into = URL(fileURLWithPath: (args[i] as NSString).expandingTildeInPath)
        default:
            sources.append(URL(fileURLWithPath: (args[i] as NSString).expandingTildeInPath))
        }
        i += 1
    }
    guard !sources.isEmpty else { usage() }

    let kernel = OperationKernel()
    await kernel.register(ArchiveEngineNode(), for: [.compress, .extract])
    await driveArchive(kernel, OperationSpec(kind: .compress, sources: sources, destination: into,
                                             archiveOptions: ArchiveOptions(format: format)))
}

func runExtract(_ args: [String]) async {
    var sources: [URL] = []
    var into: URL?
    var wrapper = true
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--into":
            i += 1
            guard i < args.count else { usage() }
            into = URL(fileURLWithPath: (args[i] as NSString).expandingTildeInPath)
        case "--no-wrapper": wrapper = false
        default:
            sources.append(URL(fileURLWithPath: (args[i] as NSString).expandingTildeInPath))
        }
        i += 1
    }
    guard !sources.isEmpty else { usage() }

    let kernel = OperationKernel()
    await kernel.register(ArchiveEngineNode(), for: [.compress, .extract])
    await driveArchive(kernel, OperationSpec(kind: .extract, sources: sources,
                                             archiveOptions: ArchiveOptions(extractInto: into, createWrapper: wrapper)))
}

// MARK: - watch（活体只读：FSEvents 监听真实目录，10 秒后退出）

func runWatch(_ args: [String]) async {
    guard let first = args.first else { usage() }
    let dir = URL(fileURLWithPath: (first as NSString).expandingTildeInPath)

    let watcher = DirectoryWatch().watch(dir)
    if let err = watcher.startupError {
        fail("监听启动失败(\(err.errorClass)): \(err.localizedDescription)")
    }
    print("监听 \(dir.path) …（10 秒后自动退出；在别处 touch 该目录以触发信号）")

    await withTaskGroup(of: Void.self) { group in
        group.addTask {
            var n = 0
            for await _ in watcher.signals {
                n += 1
                print("· 变化信号 #\(n)")
            }
        }
        group.addTask {
            try? await Task.sleep(for: .seconds(10))
        }
        // 任一子任务先结束（10 秒计时到）即收尾
        await group.next()
        watcher.stop()
        group.cancelAll()
    }
    print("停止监听")
}

// MARK: - size（活体只读：FolderSize 递归求和真实目录）

func runSize(_ args: [String]) async {
    guard let first = args.first else { usage() }
    let dir = URL(fileURLWithPath: (first as NSString).expandingTildeInPath)

    do {
        let t0 = Date()
        let bytes = try await FolderSize().size(of: dir)
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        print("\(dir.path)\n  \(bytes) 字节 (\(byteString(bytes)))，耗时 \(ms)ms")
    } catch {
        fail("计算失败: \(error.localizedDescription)")
    }
}

func byteString(_ b: Int64) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .file
    return f.string(fromByteCount: b)
}

// MARK: - thumb（活体只读：IconThumb 生成真实文件缩略图）

func runThumb(_ args: [String]) async {
    var file: URL?
    var size: CGFloat = 128
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--size":
            i += 1
            guard i < args.count, let v = Double(args[i]) else { fail("--size 需正数") }
            size = CGFloat(v)
        default:
            file = URL(fileURLWithPath: (args[i] as NSString).expandingTildeInPath)
        }
        i += 1
    }
    guard let file else { usage() }

    let t0 = Date()
    let image = await IconThumb().thumbnail(for: file, size: size)
    let ms = Int(Date().timeIntervalSince(t0) * 1000)
    if let image {
        print("缩略图 \(image.width)×\(image.height) 像素（请求 size=\(Int(size)), scale=2），耗时 \(ms)ms")
    } else {
        fail("无缩略图（不支持类型/文件不存在/生成失败），耗时 \(ms)ms")
    }
}

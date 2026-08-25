import Foundation
import NSpaceContracts

// 私有关注点：compress / extract 的物理实现。
// 关键设计——"暂存目录"落地：一切产物先写入目标目录内的隐藏暂存目录（同卷→原子 rename），
// 成功后再搬到最终落点；取消/出错只需删暂存目录，天然"不留半成品"（呼应铁律"取消清理半成品"）。

extension ArchiveEngineNode {

    // MARK: 压缩

    func compress(_ spec: OperationSpec, context: NodeContext, started: Date) async throws -> OperationReceipt {
        let fm = FileManager.default
        guard !spec.sources.isEmpty else {
            throw ArchiveError(.logic, "compress 需要至少一个源")
        }
        for src in spec.sources where !fm.fileExists(atPath: src.path) {
            throw ArchiveError(.external, "源不存在: \(src.lastPathComponent)", path: src.path)
        }
        let options = spec.archiveOptions ?? ArchiveOptions()
        let isTarGz = options.format.lowercased() == "tar.gz"
        let ext = isTarGz ? "tar.gz" : "zip"

        // 全部选中项共享同一父目录（文件管理器选中恒来自单一目录），作为 zip/tar 的相对根
        let sourcesParent = spec.sources[0].deletingLastPathComponent()
        let outputDir = spec.destination ?? sourcesParent
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: outputDir.path, isDirectory: &isDir), isDir.boolValue else {
            throw ArchiveError(.external, "输出目录不可用: \(outputDir.lastPathComponent)", path: outputDir.path)
        }

        // 归档基名：显式 newName 优先；单源省扩展名取名；多源取共同父目录名（退化时兜底 Archive）
        let baseName: String
        if let n = spec.newName, !n.isEmpty {
            baseName = n
        } else if spec.sources.count == 1 {
            baseName = spec.sources[0].deletingPathExtension().lastPathComponent
        } else {
            let parentName = sourcesParent.lastPathComponent
            baseName = (parentName.isEmpty || parentName == "/") ? "Archive" : parentName
        }
        let finalName = uniqueArchiveName(base: baseName, ext: ext, in: outputDir)

        let inputBytes = spec.sources.reduce(Int64(0)) { $0 + Self.treeSize($1) }
        context.report(.scanTotals(files: 1, bytes: inputBytes))
        context.report(.progress(filesDone: 0, bytesDone: 0, currentPath: finalName))

        // 暂存目录（目标目录内隐藏，同卷）；产物先落此处，成功再原子搬出
        let staging = outputDir.appendingPathComponent(".nspace-archive-\(UUID().uuidString)")
        try Self.makeDir(staging)
        defer { try? fm.removeItem(at: staging) }
        let stagedArchive = staging.appendingPathComponent(finalName)

        let names = spec.sources.map(\.lastPathComponent)
        do {
            if isTarGz {
                // tar 无内建加密：口令被忽略（Contract 已注明）
                try await runArchiveTool(Tools.tar,
                    ["-czf", stagedArchive.path, "-C", sourcesParent.path] + names)
            } else {
                var args = ["-r", "-q"]
                if let pw = options.password, !pw.isEmpty { args += ["-P", pw] }  // ZipCrypto 弱加密
                args += [stagedArchive.path] + names
                // cwd = 共同父目录 → 归档内为相对路径（不含绝对前缀）
                try await runArchiveTool(Tools.zip, args, cwd: sourcesParent)
            }
        } catch is CancellationError {
            throw CancellationError()   // defer 清理暂存目录（含 zip 的 zi* 临时文件），最终名从未出现
        }

        // 成功：把归档搬到最终落点（搬前复检唯一名，防并发新建撞名）
        let landedName = uniqueArchiveName(base: baseName, ext: ext, in: outputDir)
        let landed = outputDir.appendingPathComponent(landedName)
        do {
            try fm.moveItem(at: stagedArchive, to: landed)
        } catch {
            throw ArchiveError(.external, "归档落地失败: \(error.localizedDescription)", path: landed.path)
        }
        // 进度以"已处理输入字节"为分子分母（Process 无细粒度，压缩后到达 100%）；归档实体见 createdURLs
        context.report(.progress(filesDone: 1, bytesDone: inputBytes, currentPath: landedName))
        return OperationReceipt(id: context.operationID, filesDone: 1, bytesDone: inputBytes,
                                duration: Date().timeIntervalSince(started), createdURLs: [landed])
    }

    // MARK: 解压

    func extract(_ spec: OperationSpec, context: NodeContext, started: Date) async throws -> OperationReceipt {
        let fm = FileManager.default
        guard !spec.sources.isEmpty else {
            throw ArchiveError(.logic, "extract 需要至少一个源")
        }
        let options = spec.archiveOptions ?? ArchiveOptions()

        // 预检：全部源存在且格式可识别（否则 logic：调用方不该派进不支持的类型）
        for src in spec.sources {
            guard fm.fileExists(atPath: src.path) else {
                throw ArchiveError(.external, "压缩包不存在: \(src.lastPathComponent)", path: src.path)
            }
            guard ArchiveFormat.detect(src) != nil else {
                throw ArchiveError(.logic, "无法识别的归档格式: \(src.lastPathComponent)", path: src.path)
            }
        }

        let totalBytes = spec.sources.reduce(Int64(0)) { $0 + Self.fileSize($1) }
        context.report(.scanTotals(files: spec.sources.count, bytes: totalBytes))

        var created: [URL] = []
        var done = 0
        var bytesDone: Int64 = 0
        for src in spec.sources {
            context.report(.progress(filesDone: done, bytesDone: bytesDone, currentPath: src.lastPathComponent))
            let landed = try await extractOne(src, options: options)
            created.append(contentsOf: landed)
            done += 1
            bytesDone += Self.fileSize(src)
            context.report(.progress(filesDone: done, bytesDone: bytesDone, currentPath: src.lastPathComponent))
        }
        return OperationReceipt(id: context.operationID, filesDone: done, bytesDone: bytesDone,
                                duration: Date().timeIntervalSince(started), createdURLs: created)
    }

    /// 解一个压缩包，返回落地的顶层 URL 列表（供 UI 选中）。暂存目录保证取消/出错不留半成品。
    private func extractOne(_ archive: URL, options: ArchiveOptions) async throws -> [URL] {
        let fm = FileManager.default
        guard let format = ArchiveFormat.detect(archive) else {
            throw ArchiveError(.logic, "无法识别的归档格式: \(archive.lastPathComponent)", path: archive.path)
        }
        let targetBaseDir = options.extractInto ?? archive.deletingLastPathComponent()
        try Self.makeDir(targetBaseDir)  // extractInto 可能尚不存在

        let staging = targetBaseDir.appendingPathComponent(".nspace-extract-\(UUID().uuidString)")
        try Self.makeDir(staging)
        var stagingAlive = true
        defer { if stagingAlive { try? fm.removeItem(at: staging) } }

        // 落地到暂存目录
        do {
            switch format {
            case .zip:
                var args = ["-o", "-q"]
                if let pw = options.password, !pw.isEmpty { args += ["-P", pw] }
                args += [archive.path, "-d", staging.path]
                try await runArchiveTool(Tools.unzip, args)
            case .tarGz:
                try await runArchiveTool(Tools.tar, ["-xzf", archive.path, "-C", staging.path])
            case .tarBz2:
                try await runArchiveTool(Tools.tar, ["-xjf", archive.path, "-C", staging.path])
            case .tarXz:
                try await runArchiveTool(Tools.tar, ["-xJf", archive.path, "-C", staging.path])
            case .tar:
                try await runArchiveTool(Tools.tar, ["-xf", archive.path, "-C", staging.path])
            case .gzip, .bzip2, .xz:
                try await extractSingleStream(archive, format: format, into: staging)
            }
        } catch is CancellationError {
            throw CancellationError()   // defer 清理暂存目录
        }

        // 暂存目录内的顶层条目 = 真实解出的顶层（比预读列表更可靠）
        let children = (try? fm.contentsOfDirectory(at: staging,
            includingPropertiesForKeys: nil, options: [])) ?? []
        let topCount = children.count

        var landed: [URL] = []
        if options.createWrapper && topCount > 1 {
            // 包裹语义：顶层多于一个 → 先建同名包裹文件夹（即把整个暂存目录改名为包裹目录）
            let stem = Self.archiveStemName(archive, format: format)
            let wrapperName = uniqueArchiveName(base: stem, ext: "", in: targetBaseDir)
            let wrapper = targetBaseDir.appendingPathComponent(wrapperName)
            try fm.moveItem(at: staging, to: wrapper)
            stagingAlive = false   // 暂存目录已被改名为包裹目录，defer 不再删
            landed = [wrapper]
        } else {
            // 只有一个条目（或不要包裹）→ 忽略包裹，逐个搬到目标目录（同名覆盖，呼应 unzip -o 语义）
            for child in children {
                let dest = targetBaseDir.appendingPathComponent(child.lastPathComponent)
                if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
                try fm.moveItem(at: child, to: dest)
                landed.append(dest)
            }
        }
        return landed
    }

    /// 单流压缩（.gz/.bz2/.xz/.Z）：解压到暂存目录内的单个输出文件（stdout 重定向）
    private func extractSingleStream(_ archive: URL, format: ArchiveFormat, into staging: URL) async throws {
        let fm = FileManager.default
        let outName = ArchiveFormat.singleStreamOutputName(for: archive)
        let outURL = staging.appendingPathComponent(outName)
        guard fm.createFile(atPath: outURL.path, contents: Data()) else {
            throw ArchiveError(.external, "无法创建解压输出: \(outName)", path: outURL.path)
        }
        let handle = try FileHandle(forWritingTo: outURL)
        defer { try? handle.close() }
        switch format {
        case .gzip: try await runArchiveTool(Tools.gunzip, ["-c", archive.path], stdoutTo: handle)
        case .bzip2: try await runArchiveTool(Tools.bunzip2, ["-c", archive.path], stdoutTo: handle)
        case .xz: try await runArchiveTool(Tools.xz, ["-dc", archive.path], stdoutTo: handle)
        default: break
        }
    }

    // MARK: 工具调用（退码分类）

    /// 运行归档工具并把退码归类：0=成功；取消=CancellationError；非0=external(带 stderr 摘要)
    private func runArchiveTool(_ tool: String, _ args: [String], cwd: URL? = nil,
                               stdoutTo: FileHandle? = nil) async throws {
        let result = try await runTool(tool, args, cwd: cwd, stdoutTo: stdoutTo)
        if Task.isCancelled { throw CancellationError() }
        if result.status != 0 {
            let summary = Self.stderrSummary(result.stderr)
            let tail = summary.isEmpty ? "退出码 \(result.status)" : summary
            throw ArchiveError(.external, "\(URL(fileURLWithPath: tool).lastPathComponent) 失败: \(tail)")
        }
    }

    // MARK: 工具函数

    static func makeDir(_ url: URL) throws {
        do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        catch { throw ArchiveError(.external, "无法创建目录: \(url.lastPathComponent)", path: url.path) }
    }

    /// 单文件字节大小（失败按 0）
    static func fileSize(_ url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? Int64) ?? 0
    }

    /// 递归字节大小（压缩进度分母；失败按 0，装饰性不伤主链）
    static func treeSize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            return ((try? fm.attributesOfItem(atPath: url.path)[.size]) as? Int64) ?? 0
        }
        var total: Int64 = 0
        if let e = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
            for case let f as URL in e {
                let v = try? f.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                if v?.isRegularFile == true { total += Int64(v?.fileSize ?? 0) }
            }
        }
        return total
    }

    /// 归档"主干名"（去掉归档后缀，保留原大小写）——包裹文件夹命名用
    static func archiveStemName(_ url: URL, format: ArchiveFormat) -> String {
        let name = url.lastPathComponent
        let lower = name.lowercased()
        let suffixes: [String]
        switch format {
        case .zip: suffixes = [".zip"]
        case .tarGz: suffixes = [".tar.gz", ".tgz"]
        case .tarBz2: suffixes = [".tar.bz2", ".tbz2", ".tbz"]
        case .tarXz: suffixes = [".tar.xz", ".txz"]
        case .tar: suffixes = [".tar"]
        case .gzip: suffixes = [".gz", ".z"]
        case .bzip2: suffixes = [".bz2"]
        case .xz: suffixes = [".xz"]
        }
        for s in suffixes where lower.hasSuffix(s) {
            return String(name.dropLast(s.count))
        }
        return name
    }
}

import Testing
import Foundation
import ArchiveEngine
import NSpaceContracts

/// 黑盒验收：只经 Contract 公开面；真实物理 I/O 于临时夹具树（系统工具 zip/tar/unzip/gunzip 实测）。
/// 缺工具的路径不伪造（诚实跳过），本机四件套齐备故往返测试全跑。
@Suite struct ArchiveEngineTests {
    static func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nspace-ar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func ctx() -> NodeContext {
        NodeContext(operationID: UUID(), report: { _ in }, resolveConflicts: { _ in [:] })
    }

    static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url)
    }

    // MARK: 纯逻辑（Oracle：无需文件系统）

    @Test func topLevelCountingCollapsesCommonRoot() {
        // 同一顶层目录下多个条目 → 顶层数 1（包裹应忽略）
        #expect(topLevelEntryCount(["tree/", "tree/a.txt", "tree/nested/inner.txt"]) == 1)
        // 不同顶层 → 顶层数 2（需包裹）
        #expect(topLevelEntryCount(["a.txt", "b.txt"]) == 2)
        // "./" 前缀归一 + 尾斜杠
        #expect(topLevelEntryCount(["./x/1", "./x/2", "x/3"]) == 1)
        #expect(topLevelEntryCount([]) == 0)
    }

    @Test func uniqueNamingAppendsIndexKeepingFullSuffix() {
        let dir = URL(fileURLWithPath: "/tmp/x")
        let existing: Set<String> = ["foo.zip", "foo 2.zip"]
        #expect(uniqueArchiveName(base: "foo", ext: "zip", in: dir,
                                  exists: { existing.contains($0.lastPathComponent) }) == "foo 3.zip")
        // tar.gz 全后缀完整，编号只加 base
        let ex2: Set<String> = ["bar.tar.gz"]
        #expect(uniqueArchiveName(base: "bar", ext: "tar.gz", in: dir,
                                  exists: { ex2.contains($0.lastPathComponent) }) == "bar 2.tar.gz")
    }

    @Test func formatDetectionByExtension() {
        #expect(ArchiveFormat.detect(URL(fileURLWithPath: "/a/x.zip")) == .zip)
        #expect(ArchiveFormat.detect(URL(fileURLWithPath: "/a/x.tar.gz")) == .tarGz)
        #expect(ArchiveFormat.detect(URL(fileURLWithPath: "/a/x.tgz")) == .tarGz)
        #expect(ArchiveFormat.detect(URL(fileURLWithPath: "/a/x.tar.bz2")) == .tarBz2)
        #expect(ArchiveFormat.detect(URL(fileURLWithPath: "/a/x.txz")) == .tarXz)
        #expect(ArchiveFormat.detect(URL(fileURLWithPath: "/a/x.tar")) == .tar)
        #expect(ArchiveFormat.detect(URL(fileURLWithPath: "/a/x.gz")) == .gzip)
        #expect(ArchiveFormat.detect(URL(fileURLWithPath: "/a/README")) == nil)
    }

    @Test func supportedExtensionsIncludesZipAndTar() {
        let exts = ArchiveEngineNode.supportedExtensions()
        #expect(exts.contains("zip"))
        #expect(exts.contains("tar.gz"))
        #expect(ArchiveEngineNode.isSupportedArchive(URL(fileURLWithPath: "/a/b.zip")))
        #expect(!ArchiveEngineNode.isSupportedArchive(URL(fileURLWithPath: "/a/b.txt")))
    }

    // MARK: zip 往返：字节一致（单目录源 → 顶层单条目 → 忽略包裹）

    @Test func zipRoundTripSingleDirByteIdentical() async throws {
        let work = try Self.tempDir(); let out = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: work); try? FileManager.default.removeItem(at: out) }
        let payload = Data((0..<120_000).map { UInt8($0 % 251) })
        try Self.write(payload, to: work.appendingPathComponent("tree/big.bin"))
        try Self.write(Data("inner".utf8), to: work.appendingPathComponent("tree/nested/inner.txt"))

        // 压缩单个目录 tree（destination=work → 归档落在 work/tree.zip）
        let cr = try await ArchiveEngineNode().execute(
            OperationSpec(kind: .compress, sources: [work.appendingPathComponent("tree")],
                          archiveOptions: ArchiveOptions(format: "zip")),
            context: Self.ctx())
        let archive = try #require(cr.createdURLs.first)
        #expect(archive.lastPathComponent == "tree.zip")
        #expect(FileManager.default.fileExists(atPath: archive.path))

        // 解压到 out（顶层单条目 tree → 无包裹）
        let er = try await ArchiveEngineNode().execute(
            OperationSpec(kind: .extract, sources: [archive],
                          archiveOptions: ArchiveOptions(extractInto: out, createWrapper: true)),
            context: Self.ctx())
        #expect(er.createdURLs.contains { $0.lastPathComponent == "tree" })
        // 无多余 tree/tree 嵌套
        #expect(!FileManager.default.fileExists(atPath: out.appendingPathComponent("tree/tree").path))
        let big = try Data(contentsOf: out.appendingPathComponent("tree/big.bin"))
        #expect(big == payload)   // 物理证据：逐字节一致
        let inner = try Data(contentsOf: out.appendingPathComponent("tree/nested/inner.txt"))
        #expect(inner == Data("inner".utf8))
        // 暂存目录已清（无 .nspace-* 残留）
        try Self.assertNoStaging(in: out)
    }

    // MARK: tar.gz 往返

    @Test func tarGzRoundTripByteIdentical() async throws {
        let work = try Self.tempDir(); let out = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: work); try? FileManager.default.removeItem(at: out) }
        let payload = Data((0..<90_000).map { UInt8(($0 * 7) % 251) })
        try Self.write(payload, to: work.appendingPathComponent("d/data.bin"))
        try Self.write(Data("t".utf8), to: work.appendingPathComponent("d/t.txt"))

        let cr = try await ArchiveEngineNode().execute(
            OperationSpec(kind: .compress, sources: [work.appendingPathComponent("d")],
                          archiveOptions: ArchiveOptions(format: "tar.gz")),
            context: Self.ctx())
        let archive = try #require(cr.createdURLs.first)
        #expect(archive.lastPathComponent == "d.tar.gz")

        _ = try await ArchiveEngineNode().execute(
            OperationSpec(kind: .extract, sources: [archive],
                          archiveOptions: ArchiveOptions(extractInto: out, createWrapper: true)),
            context: Self.ctx())
        let round = try Data(contentsOf: out.appendingPathComponent("d/data.bin"))
        #expect(round == payload)
    }

    // MARK: 包裹语义两分支——多条目建包裹 / 只有一个则忽略

    @Test func extractWrapsWhenMultipleTopLevelEntries() async throws {
        let work = try Self.tempDir(); let out = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: work); try? FileManager.default.removeItem(at: out) }
        try Self.write(Data("A".utf8), to: work.appendingPathComponent("a.txt"))
        try Self.write(Data("B".utf8), to: work.appendingPathComponent("b.txt"))

        // 多源压缩：baseName = 共同父目录名 = work 目录名
        let cr = try await ArchiveEngineNode().execute(
            OperationSpec(kind: .compress,
                          sources: [work.appendingPathComponent("a.txt"), work.appendingPathComponent("b.txt")],
                          archiveOptions: ArchiveOptions(format: "zip")),
            context: Self.ctx())
        let archive = try #require(cr.createdURLs.first)

        // createWrapper=true 且顶层 2 条目 → 建同名包裹文件夹
        let er = try await ArchiveEngineNode().execute(
            OperationSpec(kind: .extract, sources: [archive],
                          archiveOptions: ArchiveOptions(extractInto: out, createWrapper: true)),
            context: Self.ctx())
        let wrapper = try #require(er.createdURLs.first)
        let stem = archive.deletingPathExtension().lastPathComponent  // 归档主干名
        #expect(wrapper.lastPathComponent == stem)
        #expect(try Data(contentsOf: wrapper.appendingPathComponent("a.txt")) == Data("A".utf8))
        #expect(try Data(contentsOf: wrapper.appendingPathComponent("b.txt")) == Data("B".utf8))
    }

    @Test func extractNoWrapperWhenDisabledEvenIfMultiple() async throws {
        let work = try Self.tempDir(); let out = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: work); try? FileManager.default.removeItem(at: out) }
        try Self.write(Data("A".utf8), to: work.appendingPathComponent("a.txt"))
        try Self.write(Data("B".utf8), to: work.appendingPathComponent("b.txt"))
        let cr = try await ArchiveEngineNode().execute(
            OperationSpec(kind: .compress,
                          sources: [work.appendingPathComponent("a.txt"), work.appendingPathComponent("b.txt")],
                          archiveOptions: ArchiveOptions(format: "zip")),
            context: Self.ctx())
        let archive = try #require(cr.createdURLs.first)

        // createWrapper=false → 直接铺进 out（不建包裹文件夹）
        _ = try await ArchiveEngineNode().execute(
            OperationSpec(kind: .extract, sources: [archive],
                          archiveOptions: ArchiveOptions(extractInto: out, createWrapper: false)),
            context: Self.ctx())
        #expect(try Data(contentsOf: out.appendingPathComponent("a.txt")) == Data("A".utf8))
        #expect(try Data(contentsOf: out.appendingPathComponent("b.txt")) == Data("B".utf8))
    }

    // MARK: 取消不留半成品

    @Test func cancelledCompressLeavesNoFinalArchive() async throws {
        let work = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: work) }
        // 稍大输入让压缩有耗时，提高取消命中率
        let big = Data((0..<4_000_000).map { UInt8(($0 &* 131) % 251) })
        try Self.write(big, to: work.appendingPathComponent("tree/big.bin"))

        let task = Task {
            try await ArchiveEngineNode().execute(
                OperationSpec(kind: .compress, sources: [work.appendingPathComponent("tree")],
                              archiveOptions: ArchiveOptions(format: "zip")),
                context: Self.ctx())
        }
        task.cancel()
        do {
            let r = try await task.value
            // 竞态：取消生效前已完成也合法——但归档必须完整可解
            let archive = try #require(r.createdURLs.first)
            #expect(FileManager.default.fileExists(atPath: archive.path))
        } catch is CancellationError {
            // 取消：最终归档从未出现，且无暂存残留
            #expect(!FileManager.default.fileExists(atPath: work.appendingPathComponent("tree.zip").path))
            try Self.assertNoStaging(in: work)
        }
    }

    // MARK: 错误分类

    @Test func emptySourcesIsLogicError() async {
        do {
            _ = try await ArchiveEngineNode().execute(
                OperationSpec(kind: .compress, sources: []), context: Self.ctx())
            Issue.record("应当抛错")
        } catch let e as any ClassifiedError {
            #expect(e.errorClass == .logic)
        } catch { Issue.record("错误未分类(违反 P6.4): \(error)") }
    }

    @Test func unknownExtractFormatIsLogicError() async throws {
        let work = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: work) }
        try Self.write(Data("x".utf8), to: work.appendingPathComponent("note.txt"))
        do {
            _ = try await ArchiveEngineNode().execute(
                OperationSpec(kind: .extract, sources: [work.appendingPathComponent("note.txt")]),
                context: Self.ctx())
            Issue.record("应当抛错")
        } catch let e as any ClassifiedError {
            #expect(e.errorClass == .logic)
        } catch { Issue.record("错误未分类: \(error)") }
    }

    // MARK: 助手

    static func assertNoStaging(in dir: URL) throws {
        let children = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(!children.contains { $0.hasPrefix(".nspace-") })
    }
}

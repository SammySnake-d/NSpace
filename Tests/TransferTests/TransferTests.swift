import Testing
import Foundation
import Transfer
import NSpaceContracts

/// 黑盒验收：只经 Contract 公开面；真实物理 I/O 于 /tmp 夹具树（无 Fake Mock）
@Suite struct TransferTests {
    static func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nspace-tr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func makeContext(onConflict: @escaping @Sendable ([FileConflict]) async -> [URL: ConflictDecision]? = { _ in [:] })
        -> NodeContext {
        NodeContext(operationID: UUID(), report: { _ in }, resolveConflicts: onConflict)
    }

    // MARK: keepBothName 纯逻辑（Oracle：无需文件系统）

    @Test func keepBothNamingSkipsExisting() {
        let dir = URL(fileURLWithPath: "/tmp/x")
        let existing = Set(["file 2.txt", "file 3.txt"])
        let name = keepBothName(for: URL(fileURLWithPath: "/src/file.txt"), in: dir,
                                existsCheck: { existing.contains($0.lastPathComponent) })
        #expect(name == "file 4.txt")
        let noExt = keepBothName(for: URL(fileURLWithPath: "/src/Makefile"), in: dir,
                                 existsCheck: { _ in false })
        #expect(noExt == "Makefile 2")
    }

    // MARK: 复制：字节一致（真实终态 Witness）

    @Test func copyTreeByteIdentical() async throws {
        let src = try Self.tempDir(), dst = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }
        let payload = Data((0..<200_000).map { UInt8($0 % 251) })
        try FileManager.default.createDirectory(at: src.appendingPathComponent("nested"),
                                                withIntermediateDirectories: true)
        try payload.write(to: src.appendingPathComponent("big.bin"))
        try Data("inner".utf8).write(to: src.appendingPathComponent("nested/inner.txt"))

        let spec = OperationSpec(kind: .copy, sources: [src.appendingPathComponent("big.bin"),
                                                        src.appendingPathComponent("nested")],
                                 destination: dst)
        let receipt = try await TransferNode().execute(spec, context: Self.makeContext())

        let copied = try Data(contentsOf: dst.appendingPathComponent("big.bin"))
        #expect(copied == payload)  // 物理证据：逐字节一致
        let inner = try Data(contentsOf: dst.appendingPathComponent("nested/inner.txt"))
        #expect(inner == Data("inner".utf8))
        #expect(receipt.filesDone == 2)
        #expect(receipt.bytesDone >= Int64(payload.count))
    }

    // MARK: 冲突四选项

    @Test func conflictKeepBothRenames() async throws {
        let src = try Self.tempDir(), dst = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }
        try Data("new".utf8).write(to: src.appendingPathComponent("f.txt"))
        try Data("old".utf8).write(to: dst.appendingPathComponent("f.txt"))

        let ctx = Self.makeContext { conflicts in
            Dictionary(uniqueKeysWithValues: conflicts.map { ($0.source, ConflictDecision.keepBoth) })
        }
        _ = try await TransferNode().execute(
            OperationSpec(kind: .copy, sources: [src.appendingPathComponent("f.txt")], destination: dst),
            context: ctx)
        #expect(try Data(contentsOf: dst.appendingPathComponent("f.txt")) == Data("old".utf8))
        #expect(try Data(contentsOf: dst.appendingPathComponent("f 2.txt")) == Data("new".utf8))
    }

    @Test func conflictReplaceOverwrites() async throws {
        let src = try Self.tempDir(), dst = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }
        try Data("new".utf8).write(to: src.appendingPathComponent("f.txt"))
        try Data("old".utf8).write(to: dst.appendingPathComponent("f.txt"))
        let ctx = Self.makeContext { c in
            Dictionary(uniqueKeysWithValues: c.map { ($0.source, ConflictDecision.replace) })
        }
        _ = try await TransferNode().execute(
            OperationSpec(kind: .copy, sources: [src.appendingPathComponent("f.txt")], destination: dst),
            context: ctx)
        #expect(try Data(contentsOf: dst.appendingPathComponent("f.txt")) == Data("new".utf8))
    }

    @Test func conflictSkipLeavesTarget() async throws {
        let src = try Self.tempDir(), dst = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }
        try Data("new".utf8).write(to: src.appendingPathComponent("f.txt"))
        try Data("old".utf8).write(to: dst.appendingPathComponent("f.txt"))
        let ctx = Self.makeContext { c in
            Dictionary(uniqueKeysWithValues: c.map { ($0.source, ConflictDecision.skip) })
        }
        let receipt = try await TransferNode().execute(
            OperationSpec(kind: .copy, sources: [src.appendingPathComponent("f.txt")], destination: dst),
            context: ctx)
        #expect(try Data(contentsOf: dst.appendingPathComponent("f.txt")) == Data("old".utf8))
        #expect(receipt.filesDone == 0)
    }

    @Test func conflictMergeUnionsFolders() async throws {
        let src = try Self.tempDir(), dst = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }
        try FileManager.default.createDirectory(at: src.appendingPathComponent("d"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dst.appendingPathComponent("d"), withIntermediateDirectories: true)
        try Data("fromSrc".utf8).write(to: src.appendingPathComponent("d/s.txt"))
        try Data("same-src".utf8).write(to: src.appendingPathComponent("d/both.txt"))
        try Data("fromDst".utf8).write(to: dst.appendingPathComponent("d/t.txt"))
        try Data("same-dst".utf8).write(to: dst.appendingPathComponent("d/both.txt"))
        let ctx = Self.makeContext { c in
            Dictionary(uniqueKeysWithValues: c.map { ($0.source, ConflictDecision.mergeFolders) })
        }
        _ = try await TransferNode().execute(
            OperationSpec(kind: .copy, sources: [src.appendingPathComponent("d")], destination: dst),
            context: ctx)
        // 并集 + 同名源覆盖（契约承诺）
        #expect(try Data(contentsOf: dst.appendingPathComponent("d/s.txt")) == Data("fromSrc".utf8))
        #expect(try Data(contentsOf: dst.appendingPathComponent("d/t.txt")) == Data("fromDst".utf8))
        #expect(try Data(contentsOf: dst.appendingPathComponent("d/both.txt")) == Data("same-src".utf8))
    }

    // MARK: 移动（同卷 rename）与制作副本

    @Test func moveSameVolumeRenames() async throws {
        let src = try Self.tempDir(), dst = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }
        try Data("m".utf8).write(to: src.appendingPathComponent("f.txt"))
        _ = try await TransferNode().execute(
            OperationSpec(kind: .move, sources: [src.appendingPathComponent("f.txt")], destination: dst),
            context: Self.makeContext())
        #expect(!FileManager.default.fileExists(atPath: src.appendingPathComponent("f.txt").path))
        #expect(FileManager.default.fileExists(atPath: dst.appendingPathComponent("f.txt").path))
    }

    @Test func duplicateNeverConflicts() async throws {
        let src = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: src) }
        try Data("dup".utf8).write(to: src.appendingPathComponent("f.txt"))
        // 裁决回调若被触发即违约（duplicate 恒 keepBoth 命名，不产生冲突）
        let ctx = Self.makeContext { _ in
            Issue.record("duplicate 不应触发冲突裁决")
            return nil
        }
        _ = try await TransferNode().execute(
            OperationSpec(kind: .duplicate, sources: [src.appendingPathComponent("f.txt")]),
            context: ctx)
        #expect(try Data(contentsOf: src.appendingPathComponent("f 2.txt")) == Data("dup".utf8))
    }

    // MARK: 取消与错误分类

    @Test func cancelledTaskThrowsCancellation() async throws {
        let src = try Self.tempDir(), dst = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }
        try Data("c".utf8).write(to: src.appendingPathComponent("f.txt"))
        let task = Task {
            try await TransferNode().execute(
                OperationSpec(kind: .copy, sources: [src.appendingPathComponent("f.txt")], destination: dst),
                context: Self.makeContext())
        }
        task.cancel()
        do {
            _ = try await task.value
            // 竞态：若在取消生效前已完成也算合法终态——但目标必须完整
            let d = try Data(contentsOf: dst.appendingPathComponent("f.txt"))
            #expect(d == Data("c".utf8))
        } catch is CancellationError {
            // 取消后不留半成品
            #expect(!FileManager.default.fileExists(atPath: dst.appendingPathComponent("f.txt").path))
        }
    }

    @Test func invalidSpecIsLogicError() async {
        do {
            _ = try await TransferNode().execute(
                OperationSpec(kind: .copy, sources: [], destination: nil),
                context: Self.makeContext())
            Issue.record("应当抛错")
        } catch let e as any ClassifiedError {
            #expect(e.errorClass == .logic)
        } catch {
            Issue.record("错误未分类(违反 P6.4): \(error)")
        }
    }
}

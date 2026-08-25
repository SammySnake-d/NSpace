import Testing
import Foundation
import LocalOps
import NSpaceContracts

/// 黑盒验收：只经 Contract 公开面；真实物理 I/O 于临时夹具树（无 Fake Mock）
@Suite struct LocalOpsTests {
    static func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nspace-lo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func context() -> NodeContext {
        NodeContext(operationID: UUID(), report: { _ in }, resolveConflicts: { _ in [:] })
    }

    // MARK: uniqueName 纯逻辑（Oracle：无需文件系统）

    @Test func uniqueNameAppendsSequence() {
        let dir = URL(fileURLWithPath: "/tmp/x")
        let existing = Set(["未命名文件夹", "未命名文件夹 2"])
        let name = uniqueName(base: "未命名文件夹", ext: "", in: dir,
                              existsCheck: { existing.contains($0.lastPathComponent) })
        #expect(name == "未命名文件夹 3")
        let free = uniqueName(base: "报告", ext: "txt", in: dir, existsCheck: { _ in false })
        #expect(free == "报告.txt")
    }

    // MARK: 新建文件夹（首个 + 重名序号）

    @Test func newFolderCreatesAndSequences() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let r1 = try await LocalOpsNode().execute(
            OperationSpec(kind: .newFolder, sources: [], destination: dir, newName: "未命名文件夹"),
            context: Self.context())
        #expect(r1.createdURLs.first?.lastPathComponent == "未命名文件夹")
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: r1.createdURLs[0].path, isDirectory: &isDir))
        #expect(isDir.boolValue)

        let r2 = try await LocalOpsNode().execute(
            OperationSpec(kind: .newFolder, sources: [], destination: dir, newName: "未命名文件夹"),
            context: Self.context())
        #expect(r2.createdURLs.first?.lastPathComponent == "未命名文件夹 2")
    }

    // MARK: 新建文件

    @Test func newFileCreatesEmpty() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try await LocalOpsNode().execute(
            OperationSpec(kind: .newFile, sources: [], destination: dir, newName: "未命名"),
            context: Self.context())
        let url = try #require(r.createdURLs.first)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try Data(contentsOf: url).isEmpty)
    }

    // MARK: 重命名（成功 + 结果 URL）

    @Test func renameMovesInPlace() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("old.txt")
        try Data("x".utf8).write(to: src)
        let r = try await LocalOpsNode().execute(
            OperationSpec(kind: .rename, sources: [src], newName: "new.txt"),
            context: Self.context())
        #expect(!FileManager.default.fileExists(atPath: src.path))
        let dst = dir.appendingPathComponent("new.txt")
        #expect(FileManager.default.fileExists(atPath: dst.path))
        #expect(r.createdURLs.first == dst)
    }

    // MARK: 重命名冲突 → external 分类

    @Test func renameOntoExistingIsExternalError() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.txt")
        let b = dir.appendingPathComponent("b.txt")
        try Data("a".utf8).write(to: a)
        try Data("b".utf8).write(to: b)
        do {
            _ = try await LocalOpsNode().execute(
                OperationSpec(kind: .rename, sources: [a], newName: "b.txt"),
                context: Self.context())
            Issue.record("应当抛错")
        } catch let e as any ClassifiedError {
            #expect(e.errorClass == .external)
        }
    }

    // MARK: 非法规格 → logic 分类

    @Test func emptyNameIsLogicError() async {
        do {
            _ = try await LocalOpsNode().execute(
                OperationSpec(kind: .rename, sources: [URL(fileURLWithPath: "/tmp/x")], newName: ""),
                context: Self.context())
            Issue.record("应当抛错")
        } catch let e as any ClassifiedError {
            #expect(e.errorClass == .logic)
        } catch {
            Issue.record("错误未分类(违反 P6.4): \(error)")
        }
    }

    // MARK: 移到废纸篓（记录 原→回收站 对，可撤销搬回）

    @Test func trashRecordsPairsAndRemovesSource() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("doomed.txt")
        try Data("bye".utf8).write(to: src)

        let r = try await LocalOpsNode().execute(
            OperationSpec(kind: .trash, sources: [src]),
            context: Self.context())
        #expect(!FileManager.default.fileExists(atPath: src.path))
        let pair = try #require(r.trashedItems.first)
        #expect(pair.original == src)
        #expect(FileManager.default.fileExists(atPath: pair.trashed.path))
        // 撤销语义验证：把回收站落点搬回原位可完全还原
        try FileManager.default.moveItem(at: pair.trashed, to: pair.original)
        #expect(try Data(contentsOf: src) == Data("bye".utf8))
    }
}

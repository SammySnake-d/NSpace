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
    // MARK: 部分失败（对抗审查抓到的既有缺陷，v0.19.18）

    /// 混选里有一项动不了时，旧实现在中途 `throw`：**前面已经真删掉的那些随 throw 一起丢**——
    /// 内核只在成功路径存回执，于是 coordinator 拿到 nil，既不注册撤销、也不弹吐司、也不报错。
    /// 用户的文件真进了废纸篓，而他撤不回来、也不知道发生了什么。
    /// 废纸篓可浏览之后这条路更好走了（篓里的项本身就动不了），所以必须修。
    @Test func partialTrashFailureStillReportsWhatLanded() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("lands.txt")
        try Data("x".utf8).write(to: real)
        let ghost = dir.appendingPathComponent("ghost-never-existed.txt")   // 必然失败的一项

        let r = try await LocalOpsNode().execute(
            OperationSpec(kind: .trash, sources: [real, ghost]),
            context: Self.context())

        // 真落地的那一项必须回报（撤销全靠它）
        #expect(r.trashedItems.count == 1, "实得 \(r.trashedItems.count) 项")
        #expect(r.trashedItems.first?.original == real)
        #expect(!FileManager.default.fileExists(atPath: real.path))
        // 失败的那一项必须如实回报，不许静默
        #expect(r.failures.count == 1, "实得 \(r.failures.count) 条失败")
        #expect(r.failures.first?.url == ghost)
        #expect(r.failures.first?.message.isEmpty == false)
        #expect(r.filesDone == 1)                       // 计数说真话：1 成 1 败
        // 清理落进真实废纸篓的项
        if let t = r.trashedItems.first?.trashed { try? FileManager.default.removeItem(at: t) }
    }

    /// 但**全都失败**仍必须 throw：部分成功语义不许把"一件都没做成"也粉饰成完成
    @Test func totalTrashFailureStillThrows() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ghost = dir.appendingPathComponent("ghost-never-existed.txt")
        await #expect(throws: (any Error).self) {
            _ = try await LocalOpsNode().execute(
                OperationSpec(kind: .trash, sources: [ghost]),
                context: Self.context())
        }
    }
    // MARK: newFile 带内容（⌘V 把剪贴板内容粘成新文件，v0.19.20）

    @Test func newFileWritesProvidedContents() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let payload = Data("hello from clipboard".utf8)
        let r = try await LocalOpsNode().execute(
            OperationSpec(kind: .newFile, sources: [], destination: dir,
                          newName: "粘贴的文本.txt", contents: payload),
            context: Self.context())
        let url = try #require(r.createdURLs.first)
        #expect(url.lastPathComponent == "粘贴的文本.txt")
        #expect(try Data(contentsOf: url) == payload)
        #expect(r.bytesDone == Int64(payload.count))
    }

    /// 重名时必须在**扩展名之前**加序号：`粘贴的文本 2.txt`，不是 `粘贴的文本.txt 2`
    @Test func newFileWithContentsDedupesBeforeExtension() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let payload = Data("x".utf8)
        let spec = OperationSpec(kind: .newFile, sources: [], destination: dir,
                                 newName: "粘贴的文本.txt", contents: payload)
        let first = try await LocalOpsNode().execute(spec, context: Self.context())
        let second = try await LocalOpsNode().execute(spec, context: Self.context())
        #expect(first.createdURLs.first?.lastPathComponent == "粘贴的文本.txt")
        #expect(second.createdURLs.first?.lastPathComponent == "粘贴的文本 2.txt",
                "实得 \(second.createdURLs.first?.lastPathComponent ?? "nil")")
    }

    /// 不带内容时命名口径**一分不变**（既有 newFile 行为不许被这次改动带偏）
    @Test func newFileWithoutContentsKeepsLegacyNaming() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try await LocalOpsNode().execute(
            OperationSpec(kind: .newFile, sources: [], destination: dir, newName: "未命名"),
            context: Self.context())
        #expect(r.createdURLs.first?.lastPathComponent == "未命名")
        #expect(r.bytesDone == 0)
        #expect(try Data(contentsOf: r.createdURLs[0]).isEmpty)
    }
}

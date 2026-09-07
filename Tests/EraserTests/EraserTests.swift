import Testing
import Foundation
import Eraser
import NSpaceContracts

/// 黑盒验收：真实物理 I/O 于临时夹具（无 Fake Mock）。
/// 永久删除是本仓唯一不可逆操作，所以**守卫**的测试比"能删"的测试更重要。
@Suite struct EraserTests {
    static func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nspace-er-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static func context() -> NodeContext {
        NodeContext(operationID: UUID(), report: { _ in }, resolveConflicts: { _ in [:] })
    }

    // MARK: 围栏守卫（爆炸半径）——纯逻辑，Oracle 不需要文件系统

    @Test func fenceAcceptsInsideRejectsOutsideAndRootItself() {
        let fence = URL(fileURLWithPath: "/tmp/fence")
        #expect(EraserLimits.isFenced(URL(fileURLWithPath: "/tmp/fence/a.txt"), by: fence))
        #expect(EraserLimits.isFenced(URL(fileURLWithPath: "/tmp/fence/sub/deep.txt"), by: fence))
        #expect(!EraserLimits.isFenced(URL(fileURLWithPath: "/tmp/fence"), by: fence))       // 围栏自身
        #expect(!EraserLimits.isFenced(URL(fileURLWithPath: "/tmp/other/a.txt"), by: fence))
        // 前缀相似但不同目录：/tmp/fence-evil 绝不许被 /tmp/fence 的围栏放行
        #expect(!EraserLimits.isFenced(URL(fileURLWithPath: "/tmp/fence-evil/a.txt"), by: fence))
        // 路径穿越写法经 standardized 归一后仍在围栏外
        #expect(!EraserLimits.isFenced(URL(fileURLWithPath: "/tmp/fence/../other/a.txt"), by: fence))
    }

    @Test func refusesSourcesOutsideTheFence() async throws {
        let dir = try Self.tempDir()
        let outside = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: outside) }
        let inside = dir.appendingPathComponent("in.txt")
        let stray = outside.appendingPathComponent("out.txt")
        try Data("x".utf8).write(to: inside)
        try Data("x".utf8).write(to: stray)

        await #expect(throws: (any Error).self) {
            _ = try await EraserNode().execute(
                OperationSpec(kind: .delete, sources: [inside, stray], destination: dir),
                context: Self.context())
        }
        // 整批拒绝：围栏内那一项也**不许**被删（不做"删一半"）
        #expect(FileManager.default.fileExists(atPath: inside.path))
        #expect(FileManager.default.fileExists(atPath: stray.path))
    }

    @Test func refusesWithoutFence() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("in.txt")
        try Data("x".utf8).write(to: f)
        await #expect(throws: (any Error).self) {
            _ = try await EraserNode().execute(
                OperationSpec(kind: .delete, sources: [f]),   // 无 destination
                context: Self.context())
        }
        #expect(FileManager.default.fileExists(atPath: f.path))
    }

    // MARK: 真删 + 部分失败如实回报

    @Test func erasesFilesAndDirectoriesInsideFence() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("gone.txt")
        let sub = dir.appendingPathComponent("gonedir")
        try Data("x".utf8).write(to: file)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("y".utf8).write(to: sub.appendingPathComponent("nested.txt"))

        let r = try await EraserNode().execute(
            OperationSpec(kind: .delete, sources: [file, sub], destination: dir),
            context: Self.context())
        #expect(r.filesDone == 2)
        #expect(r.failures.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(!FileManager.default.fileExists(atPath: sub.path))
        #expect(r.trashedItems.isEmpty)      // 永久删除没有可撤销的落点，不许假装有
    }

    @Test func partialFailureReportsWhatWasErased() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("real.txt")
        try Data("x".utf8).write(to: real)
        let ghost = dir.appendingPathComponent("ghost.txt")     // 不存在 → 必然失败

        let r = try await EraserNode().execute(
            OperationSpec(kind: .delete, sources: [real, ghost], destination: dir),
            context: Self.context())
        #expect(r.filesDone == 1)
        #expect(r.failures.count == 1)
        #expect(r.failures.first?.url == ghost)
        #expect(!FileManager.default.fileExists(atPath: real.path))
    }

    @Test func totalFailureThrows() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        await #expect(throws: (any Error).self) {
            _ = try await EraserNode().execute(
                OperationSpec(kind: .delete,
                              sources: [dir.appendingPathComponent("ghost.txt")], destination: dir),
                context: Self.context())
        }
    }
}

import Testing
import Foundation
import TrashLedger
import NSpaceContracts

/// 黑盒验收：真实临时目录 + 真实落盘（无 Fake Mock）
@Suite struct TrashLedgerTests {
    static func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nspace-tl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func recordsAndReadsBackOrigin() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let trashed = dir.appendingPathComponent("in-trash.txt")
        try Data("x".utf8).write(to: trashed)              // 必须真存在（自净会丢弃不存在的条目）
        let original = dir.appendingPathComponent("orig/in-trash.txt")

        let led = TrashLedger(directory: dir)
        await led.record([(original: original, trashed: trashed)])
        let got = await led.origin(of: trashed)
        #expect(got?.standardizedFileURL.path == original.standardizedFileURL.path)
        #expect(await led.count() == 1)
    }

    @Test func survivesRestartViaDisk() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let trashed = dir.appendingPathComponent("t.txt")
        try Data("x".utf8).write(to: trashed)
        let original = dir.appendingPathComponent("o/t.txt")

        await TrashLedger(directory: dir).record([(original: original, trashed: trashed)])
        // 全新实例 = 模拟重启，只能从盘上读
        let fresh = TrashLedger(directory: dir)
        #expect(await fresh.origin(of: trashed) != nil)
    }

    @Test func selfPrunesEntriesWhoseTrashedItemIsGone() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let alive = dir.appendingPathComponent("alive.txt")
        let vanished = dir.appendingPathComponent("vanished.txt")
        try Data("x".utf8).write(to: alive)
        try Data("x".utf8).write(to: vanished)
        await TrashLedger(directory: dir).record([
            (original: dir.appendingPathComponent("o/alive.txt"), trashed: alive),
            (original: dir.appendingPathComponent("o/vanished.txt"), trashed: vanished),
        ])
        // 废纸篓里那一项没了（被清空/被别的应用删掉）→ 条目必须作废，不许把过期事实交出去
        try FileManager.default.removeItem(at: vanished)
        let fresh = TrashLedger(directory: dir)
        #expect(await fresh.origin(of: vanished) == nil)
        #expect(await fresh.origin(of: alive) != nil)
        #expect(await fresh.count() == 1)
    }

    @Test func forgetRemovesEntry() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let t = dir.appendingPathComponent("t.txt")
        try Data("x".utf8).write(to: t)
        let led = TrashLedger(directory: dir)
        await led.record([(original: dir.appendingPathComponent("o/t.txt"), trashed: t)])
        await led.forget([t])
        #expect(await led.origin(of: t) == nil)
        #expect(await led.count() == 0)
    }

    @Test func unknownItemHasNoOrigin() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let led = TrashLedger(directory: dir)
        // 别的应用删掉的项：没有记录 → 必须诚实返回 nil，调用方据此置灰
        #expect(await led.origin(of: dir.appendingPathComponent("stranger.txt")) == nil)
        let many = await led.origins(of: [dir.appendingPathComponent("a"), dir.appendingPathComponent("b")])
        #expect(many.isEmpty)
    }
}

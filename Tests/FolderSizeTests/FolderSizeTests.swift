import Testing
import Foundation
import FolderSize
import NSpaceContracts

/// 黑盒验收：只经 Contract 公开面，对真实临时夹具树断言（无 Fake Mock）。
/// 断言口径：totalFileAllocatedSize 是块对齐的真实占用 ≥ 逻辑字节，故用下界断言而非恒等。
@Suite struct FolderSizeTests {
    static func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nspace-fs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func sumsNestedTreeAtLeastLogicalBytes() async throws {
        let root = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("a/b"),
                                                withIntermediateDirectories: true)
        try Data(count: 100_000).write(to: root.appendingPathComponent("top.bin"))
        try Data(count: 50_000).write(to: root.appendingPathComponent("a/mid.bin"))
        try Data(count: 25_000).write(to: root.appendingPathComponent("a/b/deep.bin"))

        let total = try await FolderSize().size(of: root)
        #expect(total >= 175_000)                    // 占用 ≥ 逻辑字节
        #expect(total < 175_000 + 3 * 1_048_576)     // 且不离谱（3 文件的块对齐余量内）
    }

    @Test func singleRegularFileReturnsItsSize() async throws {
        let root = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let f = root.appendingPathComponent("one.bin")
        try Data(count: 4096).write(to: f)
        let total = try await FolderSize().size(of: f)
        #expect(total >= 4096)
    }

    @Test func emptyFolderIsZero() async throws {
        let root = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try await FolderSize().size(of: root) == 0)
    }

    @Test func cacheServesStaleUntilInvalidated() async throws {
        let root = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(count: 10_000).write(to: root.appendingPathComponent("f1.bin"))

        let node = FolderSize()
        let first = try await node.size(of: root)

        // 树变大但未失效 → 缓存命中返回旧值（派生缓存契约）
        try Data(count: 200_000).write(to: root.appendingPathComponent("f2.bin"))
        #expect(try await node.size(of: root) == first)

        // 失效后重算 → 看到新文件
        await node.invalidate(root)
        let refreshed = try await node.size(of: root)
        #expect(refreshed >= first + 200_000)
    }

    @Test func hiddenFilesAreCounted() async throws {
        let root = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(count: 30_000).write(to: root.appendingPathComponent(".hidden.bin"))
        #expect(try await FolderSize().size(of: root) >= 30_000)
    }

    @Test func missingPathThrowsClassified() async {
        let bogus = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        do {
            _ = try await FolderSize().size(of: bogus)
            Issue.record("应当抛错")
        } catch let e as any ClassifiedError {
            #expect(e.errorClass == .external || e.errorClass == .transient)
        } catch {
            Issue.record("错误未分类(违反 P6.4): \(error)")
        }
    }

    @Test func cancellationStopsEnumeration() async throws {
        let root = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        // 铺一棵有点规模的树，让取消有机会赶在完成之前
        for i in 0..<40 {
            let d = root.appendingPathComponent("d\(i)")
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            for j in 0..<25 {
                try Data(count: 64).write(to: d.appendingPathComponent("f\(j)"))
            }
        }
        let node = FolderSize()
        let task = Task { try await node.size(of: root) }
        task.cancel()
        do {
            // 竞态：取消生效前已算完也是合法终态，此时结果必须完整
            let total = try await task.value
            #expect(total >= 40 * 25 * 64)
        } catch is CancellationError {
            // 协作式取消生效：合法
        } catch {
            Issue.record("取消应抛 CancellationError，实际: \(error)")
        }
    }
}

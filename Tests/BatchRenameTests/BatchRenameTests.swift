import Foundation
import Testing
import BatchRename
import NSpaceContracts

@Suite struct BatchRenameTests {
    static func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nspace-br-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func context() -> NodeContext {
        NodeContext(operationID: UUID(), report: { _ in }, resolveConflicts: { _ in [:] })
    }

    @Test func plannerPreviewCoversAllRulesAndCollisionDetection() {
        let dir = URL(fileURLWithPath: "/tmp/br-mock")
        let files = [dir.appendingPathComponent("alpha.txt"), dir.appendingPathComponent("beta.TXT")]

        let numbered = BatchRenamePlanner.preview(
            sources: files,
            rule: .numberSequence(base: "shot_", start: 1, step: 1, padding: 3, position: .replace),
            extMode: .lowercase,
            externalExists: { _, _ in false }
        )
        #expect(numbered.map(\.newName) == ["shot_001.txt", "shot_002.txt"])
        #expect(numbered.allSatisfy { $0.isValid })

        let collided = BatchRenamePlanner.preview(
            sources: files,
            rule: .replaceText(find: "alpha", replacement: "beta", matchCase: true, useRegex: false, applyToExtension: false),
            extMode: .lowercase,
            externalExists: { _, _ in false }
        )
        #expect(collided.allSatisfy { !$0.isValid })
        #expect(collided[0].issue == "批次内名称冲突")
    }

    @Test func batchRenameExecutesSwapsAndChainsAtomically() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let a = dir.appendingPathComponent("a.txt")
        let b = dir.appendingPathComponent("b.txt")
        try Data("fromA".utf8).write(to: a)
        try Data("fromB".utf8).write(to: b)

        let receipt = try await BatchRenameNode().execute(
            OperationSpec(
                kind: .batchRename,
                sources: [a, b],
                renamePairs: [
                    RenamePair(source: a, newName: "b.txt"),
                    RenamePair(source: b, newName: "a.txt")
                ]
            ),
            context: Self.context()
        )

        #expect(receipt.filesDone == 2)
        #expect(receipt.renamedItems.count == 2)
        #expect(try String(data: Data(contentsOf: a), encoding: .utf8) == "fromB")
        #expect(try String(data: Data(contentsOf: b), encoding: .utf8) == "fromA")
    }

    @Test func batchRenameRollbackOnInvalidTargetName() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let a = dir.appendingPathComponent("a.txt")
        let b = dir.appendingPathComponent("b.txt")
        try Data("1".utf8).write(to: a)
        try Data("2".utf8).write(to: b)

        await #expect(throws: (any Error).self) {
            _ = try await BatchRenameNode().execute(
                OperationSpec(
                    kind: .batchRename,
                    sources: [a, b],
                    renamePairs: [
                        RenamePair(source: a, newName: "c.txt"),
                        RenamePair(source: b, newName: "bad/name.txt")
                    ]
                ),
                context: Self.context()
            )
        }
        #expect(FileManager.default.fileExists(atPath: a.path))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("c.txt").path))
    }
}

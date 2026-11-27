import Foundation
import Testing
import FileHash
import NSpaceContracts

@Suite struct FileHashTests {
    static func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nspace-fh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func computesExactKnownMD5AndSHA256() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("sample.bin")
        try Data("abc".utf8).write(to: file)

        // Chunk size smaller than payload won't shrink below 4096 inside FileHasher, still verifies streaming
        let digest = try await FileHasher.computeDigests(for: file, chunkSize: 1)
        #expect(digest.byteCount == 3)
        #expect(digest.md5 == "900150983cd24fb0d6963f7d28e17f72")
        #expect(digest.sha256 == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func rejectsDirectoryWithLogicError() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        do {
            _ = try await FileHasher.computeDigests(for: dir)
            Issue.record("文件夹应当报错")
        } catch let e as any ClassifiedError {
            #expect(e.errorClass == .logic)
        }
    }
}

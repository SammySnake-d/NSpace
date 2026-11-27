import Foundation
import NSpaceContracts

// FileHash 胶囊唯一对外契约面（Axiom 3）

public struct FileHashError: ClassifiedError {
    public let errorClass: ErrorClass
    public let localizedDescription: String
    public let path: String?

    public init(_ cls: ErrorClass, _ message: String, path: String? = nil) {
        self.errorClass = cls
        self.localizedDescription = message
        self.path = path
    }
}

public struct FileDigestResult: Sendable, Equatable {
    public let md5: String
    public let sha256: String
    public let byteCount: Int64

    public init(md5: String, sha256: String, byteCount: Int64) {
        self.md5 = md5
        self.sha256 = sha256
        self.byteCount = byteCount
    }
}

public protocol FileHashService: Sendable {
    static func computeDigests(for url: URL, chunkSize: Int) async throws -> FileDigestResult
}

import Foundation
import NSpaceContracts

// StashStore 胶囊唯一对外契约面（Axiom 3）：暂存架内容的唯一 Commit Owner

public struct StashItem: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    /// URL bookmark Data：目标被移动/改名后仍可解析（spec 数据契约）
    public var bookmarkData: Data

    public init(id: UUID = UUID(), bookmarkData: Data) {
        self.id = id
        self.bookmarkData = bookmarkData
    }
}

public struct StashError: ClassifiedError {
    public let errorClass: ErrorClass
    public let localizedDescription: String

    init(_ cls: ErrorClass, _ message: String) {
        self.errorClass = cls
        self.localizedDescription = message
    }
}

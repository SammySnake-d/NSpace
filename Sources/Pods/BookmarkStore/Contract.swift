import Foundation
import NSpaceContracts

// BookmarkStore 胶囊唯一对外契约面（Axiom 3）：自定义书签的唯一 Commit Owner

public struct BookmarkItem: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    public var name: String
    /// URL bookmark Data：目标被移动/改名后仍可解析（spec 数据契约）
    public var bookmarkData: Data

    public init(id: UUID = UUID(), name: String, bookmarkData: Data) {
        self.id = id
        self.name = name
        self.bookmarkData = bookmarkData
    }
}

public struct BookmarkError: ClassifiedError {
    public let errorClass: ErrorClass
    public let localizedDescription: String

    init(_ cls: ErrorClass, _ message: String) {
        self.errorClass = cls
        self.localizedDescription = message
    }
}

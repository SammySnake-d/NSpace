import Foundation
import NSpaceContracts

// DirectoryReader 胶囊唯一对外契约面（Axiom 3）：目录 URL → 不可变 DirectorySnapshot

public struct ReadRequest: Sendable {
    public let directory: URL
    public let includeHidden: Bool
    public let sort: SortSpec

    public init(directory: URL, includeHidden: Bool = false, sort: SortSpec = SortSpec()) {
        self.directory = directory
        self.includeHidden = includeHidden
        self.sort = sort
    }
}

public struct DirectoryReadError: ClassifiedError {
    public let errorClass: ErrorClass
    public let localizedDescription: String
    public let underlying: (any Error)?

    init(_ cls: ErrorClass, _ message: String, underlying: (any Error)? = nil) {
        self.errorClass = cls
        self.localizedDescription = message
        self.underlying = underlying
    }
}

/// 目录读取节点：每次 load 分配单调递增 generation；
/// 调用方比较 generation 丢弃过期结果（spec 3.2 代际防覆盖）
public protocol DirectoryReading: Sendable {
    func load(_ request: ReadRequest) async throws -> DirectorySnapshot
}

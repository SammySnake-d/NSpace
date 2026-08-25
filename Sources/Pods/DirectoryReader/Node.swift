import Foundation
import NSpaceContracts

/// 构造工厂 + 入口（Axiom 2：无全局状态，依赖经构造注入）
public actor DirectoryReader: DirectoryReading {
    private var generation: UInt64 = 0

    public init() {}

    public func load(_ request: ReadRequest) async throws -> DirectorySnapshot {
        generation += 1
        let gen = generation
        var items = try scanDirectory(request)
        sortItems(&items, by: request.sort)
        try Task.checkCancellation()
        return DirectorySnapshot(directory: request.directory, generation: gen, items: items)
    }
}

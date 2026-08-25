import Foundation
import NSpaceContracts

/// 归档节点（compress / extract）。构造零参注入（Axiom 2：无全局可变状态）。
public struct ArchiveEngineNode: OperationNode {
    public init() {}

    public func execute(_ spec: OperationSpec, context: NodeContext) async throws -> OperationReceipt {
        let started = Date()
        switch spec.kind {
        case .compress:
            return try await compress(spec, context: context, started: started)
        case .extract:
            return try await extract(spec, context: context, started: started)
        default:
            throw ArchiveError(.logic, "ArchiveEngineNode 不处理 \(spec.kind.rawValue)")
        }
    }
}

import Foundation
import NSpaceContracts

/// 本地操作节点（rename / newFolder / newFile / trash）。构造零参注入（Axiom 2：无全局可变状态）。
public struct LocalOpsNode: OperationNode {
    public init() {}

    public func execute(_ spec: OperationSpec, context: NodeContext) async throws -> OperationReceipt {
        let started = Date()
        switch spec.kind {
        case .rename:
            return try renameEntry(spec, context: context, started: started)
        case .newFolder:
            return try createEntry(spec, context: context, isDirectory: true,
                                   defaultBase: "未命名文件夹", started: started)
        case .newFile:
            return try createEntry(spec, context: context, isDirectory: false,
                                   defaultBase: "未命名", started: started)
        case .trash:
            return try trashEntries(spec, context: context, started: started)
        default:
            throw LocalOpsError(.logic, "LocalOpsNode 不处理 \(spec.kind.rawValue)")
        }
    }
}

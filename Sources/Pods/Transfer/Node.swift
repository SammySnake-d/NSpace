import Foundation
import NSpaceContracts

/// 传输节点（copy / move / duplicate）。构造零参注入（Axiom 2：无全局可变状态）。
public struct TransferNode: OperationNode {
    public init() {}

    public func execute(_ spec: OperationSpec, context: NodeContext) async throws -> OperationReceipt {
        let started = Date()
        let plan = try makePlan(spec)

        // 微步 1：预扫描总量（进度分母）
        let scan = try preScan(sources: plan.entries.map(\.source))
        context.report(.scanTotals(files: scan.total.files, bytes: scan.total.bytes))

        // 微步 2：冲突检测 + 挂起裁决
        let resolved = try await resolveConflicts(plan: plan, context: context)

        // 微步 3：逐文件传输（协作式取消经 CancelFlag 透传进 copyfile 回调）
        let flag = CancelFlag()
        let progress = ProgressAggregator(report: context.report)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            for entry in resolved {
                try await transferEntry(entry, mode: plan.mode, flag: flag, progress: progress,
                                        entryTotals: scan.perSource[entry.source] ?? ScanTotals())
            }
            return OperationReceipt(id: context.operationID,
                                    filesDone: progress.snapshotFiles(),
                                    bytesDone: progress.snapshotBytes(),
                                    duration: Date().timeIntervalSince(started))
        } onCancel: {
            flag.set()
        }
    }
}

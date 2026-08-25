import Foundation
import NSpaceContracts

/// 聚焦搜索引擎（Axiom 2：无全局可变状态；每次 search 产出独立会话，互不干扰）。
public struct SearchEngine: Sendable {
    public init() {}

    /// 双通道搜索：通道A Spotlight（名称/内容）+ 通道B 隐藏文件名称递归扫描（includeHidden）。
    /// 结果按 url 去重合并，增量批推（≥50 条或 300ms 节流）；
    /// 流终止（消费方取消/中断迭代）即停两通道（NSMetadataQuery.stop + 扫描 Task 取消）。
    @MainActor
    public func search(_ request: SearchRequest) -> AsyncStream<[SearchHit]> {
        AsyncStream { continuation in
            let session = SearchSession(request: request, continuation: continuation)
            session.start()
            continuation.onTermination = { _ in session.stop() }
        }
    }
}

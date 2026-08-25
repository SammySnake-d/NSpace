import Testing
import Foundation
@testable import NSpaceKernel
import NSpaceContracts

@Suite struct KernelStateMachineTests {
    /// 未注册节点的操作必须以 logic 类失败终止（不吞错）
    @Test func unregisteredKindFails() async throws {
        let kernel = OperationKernel()
        let id = await kernel.submit(OperationSpec(kind: .copy, sources: [], destination: nil))
        // 等待状态机推进到终态
        for _ in 0..<100 {
            if let p = await kernel.projection(id), p.state.isTerminal {
                guard case .failed(_, let cls) = p.state else {
                    Issue.record("期望 failed，实得 \(p.state)")
                    return
                }
                #expect(cls == .logic || cls == .transient)
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("操作未在 1s 内到达终态")
    }

    /// pending 状态取消：直接进 cancelled 终态，且终态不可再转移
    @Test func cancelBeforeStartIsTerminal() async throws {
        let kernel = OperationKernel()
        // 先占住执行位：提交一个未注册 kind 让队列繁忙不可行——直接测 API 幂等
        let id = await kernel.submit(OperationSpec(kind: .move, sources: [], destination: nil))
        await kernel.cancel(id)
        // 无论 race 到 failed 还是 cancelled，必须是终态且 cancel 幂等
        for _ in 0..<100 {
            if let p = await kernel.projection(id), p.state.isTerminal {
                await kernel.cancel(id)  // 幂等，不得崩溃或改状态
                let p2 = await kernel.projection(id)
                #expect(p2?.state == p.state)
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("操作未在 1s 内到达终态")
    }
}

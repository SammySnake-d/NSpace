import Testing
import Foundation
import DirectoryWatch

/// 黑盒验收：只经 Contract 公开面 + 真实临时目录 + 真实 touch（无 Fake Mock）。
/// `.serialized`：FSEvents 对系统 FS 活动敏感，并行跑会互相干扰，本套串行执行。
@Suite(.serialized) struct DirectoryWatchTests {

    private func makeTempDir() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nspace-dw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func touch(_ dir: URL) throws {
        let f = dir.appendingPathComponent("f-\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: f)
    }

    /// 轮询等待计数超过 baseline，最多 timeoutMS；命中返回 true。
    private func waitForIncrease(_ counter: SignalCounter, over baseline: Int,
                                 timeoutMS: Int) async -> Bool {
        for _ in 0..<(timeoutMS / 50) {
            try? await Task.sleep(for: .milliseconds(50))
            if await counter.value > baseline { return true }
        }
        return false
    }

    @Test func receivesSignalAfterTouch() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let watcher = DirectoryWatch().watch(dir)
        defer { watcher.stop() }
        #expect(watcher.startupError == nil)

        let counter = SignalCounter()
        let consumer = Task { for await _ in watcher.signals { await counter.bump() } }
        defer { consumer.cancel() }

        try await Task.sleep(for: .milliseconds(200))   // 让 FSEventStream 完成调度
        try touch(dir)
        #expect(await waitForIncrease(counter, over: 0, timeoutMS: 1500))
    }

    @Test func stopSilencesFurtherChanges() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let watcher = DirectoryWatch().watch(dir)
        let counter = SignalCounter()
        let consumer = Task { for await _ in watcher.signals { await counter.bump() } }
        defer { consumer.cancel() }

        // 先证明监听活着
        try await Task.sleep(for: .milliseconds(200))
        try touch(dir)
        #expect(await waitForIncrease(counter, over: 0, timeoutMS: 1500))

        // stop 后收尾信号流；给消费者时间排空并结束循环，再定基线
        watcher.stop()
        try await Task.sleep(for: .milliseconds(400))
        let baseline = await counter.value

        try touch(dir)
        try await Task.sleep(for: .milliseconds(1000))
        #expect(await counter.value == baseline)   // stop 之后不再有任何新信号
    }

    @Test func suspendThenResume() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let watcher = DirectoryWatch().watch(dir)
        defer { watcher.stop() }
        let counter = SignalCounter()
        let consumer = Task { for await _ in watcher.signals { await counter.bump() } }
        defer { consumer.cancel() }

        // 先证明监听活着
        try await Task.sleep(for: .milliseconds(200))
        try touch(dir)
        #expect(await waitForIncrease(counter, over: 0, timeoutMS: 1500))

        // 挂起并排空 latency 窗口内的在途事件，再定基线（后台零功耗）
        watcher.suspend()
        try await Task.sleep(for: .milliseconds(500))
        let baseline = await counter.value

        try touch(dir)
        try await Task.sleep(for: .milliseconds(800))
        #expect(await counter.value == baseline)   // 挂起期间变化不产生信号

        // 恢复后新变化重新可感知
        watcher.resume()
        try await Task.sleep(for: .milliseconds(200))
        try touch(dir)
        #expect(await waitForIncrease(counter, over: baseline, timeoutMS: 1500))
    }
}

/// 单消费者信号计数器（AsyncStream 单消费者约束下跨阶段判读）。
private actor SignalCounter {
    private(set) var value = 0
    func bump() { value += 1 }
}

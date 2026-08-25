import Foundation
import NSpaceContracts

/// 会话权威状态唯一 Commit Owner（actor）：防抖 1s 原子落盘 session.json（spec 五、数据契约）。
/// 存储目录构造注入（Axiom 2）。
public actor SessionStore {
    private let fileURL: URL
    private var pendingSaveTask: Task<Void, Never>?
    private var latest: SessionSnapshot?

    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("session.json")
    }

    /// 启动恢复：无文件/损坏返回 nil（回退默认布局，容错矩阵：不崩不弹窗）
    public func load() -> SessionSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(SessionSnapshot.self, from: data)
    }

    /// 状态变化随手调用：1s 防抖合并（频繁切标签不写盘风暴）
    public func save(_ snapshot: SessionSnapshot) {
        latest = snapshot
        pendingSaveTask?.cancel()
        pendingSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    /// 退出前强制落盘（跳过防抖）
    public func flush() {
        guard let snapshot = latest else { return }
        pendingSaveTask?.cancel()
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // 落盘失败保内存态，下次 save 防抖重试（容错矩阵）
        }
    }
}

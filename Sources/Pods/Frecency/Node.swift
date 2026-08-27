import Foundation
import NSpaceContracts

/// frecency 权威状态唯一 Commit Owner（actor 串行提交，BG-5/BG-8 单进程定界）。
/// 记录"用户在整个 App 里打开/进入过哪些路径、多频繁、多新近"，供聚焦搜索按使用习惯排序（M28）。
/// 存储目录构造注入（Axiom 2，无全局单例）：App 传 Application Support，测试传临时目录。
public actor FrecencyStore {
    private let fileURL: URL
    private var entries: [String: FrecencyEntry] = [:]
    private var loaded = false
    /// 容量上限：超限按当前 score 淘汰最低的一批（防无限膨胀；日常远达不到）
    private let maxEntries: Int

    public init(directory: URL, maxEntries: Int = 5000) {
        self.fileURL = directory.appendingPathComponent("frecency.json")
        self.maxEntries = maxEntries
    }

    // MARK: 记账（打开文件/进入文件夹/搜索定位都经此）

    /// 记一次访问：path 归一（standardized）后计数 +1、刷新 lastAccess。now 注入以便确定性测试。
    public func record(_ url: URL, now: Date = Date()) {
        ensureLoaded()
        let key = url.standardizedFileURL.path
        var e = entries[key] ?? FrecencyEntry(count: 0, lastAccess: now)
        e.count += 1
        e.lastAccess = now
        entries[key] = e
        pruneIfNeeded(now: now)
        persist()
    }

    // MARK: 查询（搜索排序用）

    /// 排序快照：一次取全量 entries，UI 侧据此同步给每条命中打分（搜索期内 frecency 稳定）。
    public func snapshot() -> [String: FrecencyEntry] {
        ensureLoaded()
        return entries
    }

    /// 单路径当前 frecency 分（便捷；等价 SearchRanking.frecencyScore(snapshot[path])）。
    public func score(forPath path: String, now: Date = Date()) -> Double {
        ensureLoaded()
        guard let e = entries[path] else { return 0 }
        return SearchRanking.frecencyScore(e, now: now)
    }

    public func count() -> Int {
        ensureLoaded()
        return entries.count
    }

    // MARK: 私有：加载 / 淘汰 / 原子落盘

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: FrecencyEntry].self, from: data) else { return }
        entries = decoded
    }

    private func pruneIfNeeded(now: Date) {
        guard entries.count > maxEntries else { return }
        // 按 score 升序，淘汰最低的直到回到上限的 90%（一次性清一批，避免每次记账都排序）
        let target = maxEntries * 9 / 10
        let ranked = entries.sorted { SearchRanking.frecencyScore($0.value, now: now) < SearchRanking.frecencyScore($1.value, now: now) }
        for (k, _) in ranked.prefix(entries.count - target) { entries.removeValue(forKey: k) }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 原子替换：崩溃安全（落盘失败保内存态，下次记账再试；frecency 非关键数据，静默降级）
        try? data.write(to: fileURL, options: .atomic)
    }
}

import Foundation
import NSpaceContracts

/// 「放回原处」台账的唯一 Commit Owner（actor 串行提交 + 原子落盘，BG-5/BG-8）。
/// 存储目录构造注入（Axiom 2）：App 传 Application Support，测试传临时目录。
///
/// 自净：读取时丢弃「废纸篓里已经不存在那一项」的陈旧条目，落盘随之收缩。
/// 一份不会发现自己过期的台账，比没有台账更坏——它会把后来被推翻的事当既成事实交出去。
public actor TrashLedger {
    private let fileURL: URL
    private var entries: [String: TrashLedgerEntry] = [:]   // trashedPath → entry
    private var loaded = false

    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("trash-ledger.json")
    }

    // MARK: 查询

    /// 该废纸篓项的原路径（无记录 = nil，调用方据此置灰菜单）
    public func origin(of trashedURL: URL) async -> URL? {
        await ensureLoaded()
        guard let e = entries[Self.key(trashedURL)] else { return nil }
        return URL(fileURLWithPath: e.originalPath)
    }

    /// 批量查（菜单校验用：全部有记录才允许「放回原处」）
    public func origins(of trashedURLs: [URL]) async -> [URL: URL] {
        await ensureLoaded()
        var out: [URL: URL] = [:]
        for u in trashedURLs {
            if let e = entries[Self.key(u)] { out[u] = URL(fileURLWithPath: e.originalPath) }
        }
        return out
    }

    public func count() async -> Int {
        await ensureLoaded()
        return entries.count
    }

    // MARK: 变更

    /// 记一批「原路径 → 废纸篓落点」。同落点重复记账以最新为准。
    public func record(_ pairs: [(original: URL, trashed: URL)], now: Date = Date()) async {
        guard !pairs.isEmpty else { return }
        await ensureLoaded()
        for p in pairs {
            let k = Self.key(p.trashed)
            entries[k] = TrashLedgerEntry(trashedPath: k,
                                          originalPath: p.original.standardizedFileURL.path,
                                          recordedAt: now)
        }
        persist()
    }

    /// 忘掉这些落点（放回成功、或被永久删除后调用）
    public func forget(_ trashedURLs: [URL]) async {
        guard !trashedURLs.isEmpty else { return }
        await ensureLoaded()
        var changed = false
        for u in trashedURLs where entries.removeValue(forKey: Self.key(u)) != nil { changed = true }
        if changed { persist() }
    }

    // MARK: 内部

    private static func key(_ url: URL) -> String { url.standardizedFileURL.path }

    private func ensureLoaded() async {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([TrashLedgerEntry].self, from: data) else { return }
        let fm = FileManager.default
        var kept: [String: TrashLedgerEntry] = [:]
        var dropped = false
        for e in list {
            // 自净：废纸篓里已经没有这一项了（被清空/被别的应用删掉/被放回过），条目作废
            if fm.fileExists(atPath: e.trashedPath) { kept[e.trashedPath] = e } else { dropped = true }
        }
        entries = kept
        if dropped { persist() }
    }

    /// 原子落盘（先写临时文件再替换；写失败不伤内存态，下次变更再试）
    private func persist() {
        let list = entries.values.sorted { $0.recordedAt < $1.recordedAt }
        guard let data = try? JSONEncoder().encode(list) else { return }
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = fileURL.appendingPathExtension("tmp-\(UUID().uuidString)")
        guard (try? data.write(to: tmp, options: .atomic)) != nil else { return }
        if (try? FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)) == nil {
            // 目标还不存在时 replaceItemAt 会失败，退化为直接搬过去
            try? FileManager.default.moveItem(at: tmp, to: fileURL)
        }
    }
}

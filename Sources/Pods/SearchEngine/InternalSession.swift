import Foundation
import UniformTypeIdentifiers
import NSpaceContracts

/// 单次搜索会话：通道A（Spotlight/NSMetadataQuery）+ 通道B（隐藏文件递归扫描）→ 按 url 去重合并批推。
///
/// 线程不变量（@unchecked Sendable 的成立依据）：全部可变状态只在主线程触碰——
/// 通道A 的通知经 query.operationQueue = .main 投递；通道B 后台扫描经 DispatchQueue.main 回灌；
/// start() 由主线程调用（引擎 API @MainActor）；stop() 内部自行跳主线程。
final class SearchSession: NSObject, @unchecked Sendable {
    private let request: SearchRequest
    private let continuation: AsyncStream<[SearchHit]>.Continuation

    // ---- 以下全部主线程态 ----
    private var query: NSMetadataQuery?
    private var scanTask: Task<Void, Never>?
    private var buffer: [SearchHit] = []
    private var seenPaths: Set<String> = []
    /// 未完成通道数；归零 = 会话自然收尾
    private var pendingChannels = 0
    private var flushScheduled = false
    private var finished = false
    /// 已保留（去重后）命中数——达 SearchLimits.maxResults 即停两通道，杜绝主线程读全量卡死
    private var keptCount = 0
    /// Spotlight 增量读游标（gathering progress 只读新到达段）
    private var spotlightReadIndex = 0

    init(request: SearchRequest, continuation: AsyncStream<[SearchHit]>.Continuation) {
        self.request = request
        self.continuation = continuation
    }

    // MARK: 生命周期

    /// 主线程调用
    func start() {
        let wantsSpotlight = request.searchNames || request.searchContents
        // 内容搜索只走通道A；通道B 只承担按名搜（诚实：无自建全文索引）
        let wantsScan = request.includeHidden && request.searchNames
        guard !request.query.isEmpty, wantsSpotlight || wantsScan else {
            finished = true
            continuation.finish()
            return
        }
        if wantsSpotlight { startSpotlight() }
        if wantsScan { startScan() }
    }

    /// 任意线程可调（onTermination 回调）；实际拆除在主线程
    func stop() {
        if Thread.isMainThread {
            teardown()
        } else {
            DispatchQueue.main.async { self.teardown() }
        }
    }

    private func teardown() {
        guard !finished else { return }
        finished = true
        scanTask?.cancel()
        scanTask = nil
        if let query {
            NotificationCenter.default.removeObserver(self, name: nil, object: query)
            query.stop()
            self.query = nil
        }
        continuation.finish()
    }

    // MARK: 通道A —— Spotlight（NSMetadataQuery，ObjC 遗产包裹为通知→批次）

    private func startSpotlight() {
        pendingChannels += 1
        let q = NSMetadataQuery()
        var predicates: [NSPredicate] = []
        if request.searchNames {
            predicates.append(NSPredicate(format: "%K CONTAINS[cd] %@",
                                          NSMetadataItemFSNameKey, request.query))
        }
        if request.searchContents {
            predicates.append(NSPredicate(format: "%K CONTAINS[cd] %@",
                                          NSMetadataItemTextContentKey, request.query))
        }
        // NSMetadataQuery 拒绝单子式的 OR 复合谓词：单条件直用，多条件才 OR
        q.predicate = predicates.count == 1
            ? predicates[0]
            : NSCompoundPredicate(orPredicateWithSubpredicates: predicates)
        switch request.scope {
        case .global:
            q.searchScopes = [NSMetadataQueryLocalComputerScope]
        case .directory(let url):
            q.searchScopes = [url]
        }
        q.operationQueue = .main  // 通知投递与结果访问全在主线程（线程不变量）
        q.notificationBatchingInterval = 0.3
        NotificationCenter.default.addObserver(self, selector: #selector(spotlightProgressed(_:)),
                                               name: .NSMetadataQueryGatheringProgress, object: q)
        NotificationCenter.default.addObserver(self, selector: #selector(spotlightFinished(_:)),
                                               name: .NSMetadataQueryDidFinishGathering, object: q)
        query = q
        q.start()
    }

    @objc private func spotlightProgressed(_ note: Notification) {
        drainSpotlight(final: false)
    }

    @objc private func spotlightFinished(_ note: Notification) {
        drainSpotlight(final: true)
    }

    /// 主线程（operationQueue = .main 保证）
    private func drainSpotlight(final: Bool) {
        guard let query, !finished else { return }
        query.disableUpdates()
        let count = query.resultCount
        var hits: [SearchHit] = []
        // 硬上限：本次 drain 最多再读 (maxResults - keptCount) 条，绝不在主线程读全量十万级结果
        let readBudget = max(0, SearchLimits.maxResults - keptCount)
        while spotlightReadIndex < count, hits.count < readBudget {
            if let item = query.result(at: spotlightReadIndex) as? NSMetadataItem,
               let hit = Self.hit(from: item) {
                hits.append(hit)
            }
            spotlightReadIndex += 1
        }
        query.enableUpdates()
        append(hits)
        if final {
            NotificationCenter.default.removeObserver(self, name: nil, object: query)
            query.stop()
            self.query = nil
            channelDone()
        }
    }

    /// 展示属性直接取自元数据（零补 stat）
    private static func hit(from item: NSMetadataItem) -> SearchHit? {
        guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { return nil }
        let url = URL(fileURLWithPath: path)
        let typeID = item.value(forAttribute: NSMetadataItemContentTypeKey) as? String
        let isDirectory = typeID.flatMap { UTType($0)?.conforms(to: .directory) } ?? false
        return SearchHit(
            url: url,
            name: (item.value(forAttribute: NSMetadataItemFSNameKey) as? String) ?? url.lastPathComponent,
            isDirectory: isDirectory,
            size: (item.value(forAttribute: NSMetadataItemFSSizeKey) as? NSNumber)?.int64Value,
            modified: item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date,
            contentTypeID: typeID)
    }

    // MARK: 通道B —— 隐藏文件递归扫描（超越 Spotlight：不依赖索引、不跳过隐藏项）

    private func startScan() {
        pendingChannels += 1
        let request = self.request
        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            for root in Self.scanRoots(for: request.scope) {
                guard !Task.isCancelled else { break }
                Self.scan(root: root, request: request) { batch in
                    DispatchQueue.main.async { self?.append(batch) }
                }
            }
            DispatchQueue.main.async { self?.channelDone() }
        }
    }

    /// 全局范围 = 家目录 + 外挂卷根（严禁扫 "/"——会卷入 /System 海量只读内容）
    private static func scanRoots(for scope: SearchRequest.Scope) -> [URL] {
        switch scope {
        case .directory(let url):
            return [url]
        case .global:
            var roots = [FileManager.default.homeDirectoryForCurrentUser]
            let volumes = FileManager.default.mountedVolumeURLs(
                includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
            roots += volumes.filter { $0.path != "/" }
            return roots
        }
    }

    /// 后台线程：不带 skipsHiddenFiles 的枚举 + 文件名大小写不敏感包含匹配；
    /// 跳过配置的巨坑目录；≥50 条一批经回调发出；协作式取消（每项查 isCancelled）
    private static func scan(root: URL, request: SearchRequest, emit: ([SearchHit]) -> Void) {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey,
                                         .contentModificationDateKey, .contentTypeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: Array(keys), options: []) else { return }
        var batch: [SearchHit] = []
        while let url = enumerator.nextObject() as? URL {
            if Task.isCancelled { return }
            let name = url.lastPathComponent
            if request.skippedDirectoryNames.contains(name),
               (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                enumerator.skipDescendants()
                continue
            }
            guard name.localizedCaseInsensitiveContains(request.query) else { continue }
            let rv = try? url.resourceValues(forKeys: keys)  // 命中才补属性
            batch.append(SearchHit(
                url: url, name: name,
                isDirectory: rv?.isDirectory ?? false,
                size: (rv?.fileSize).map(Int64.init),
                modified: rv?.contentModificationDate,
                contentTypeID: rv?.contentType?.identifier))
            if batch.count >= 50 {
                emit(batch)
                batch = []
            }
        }
        if !batch.isEmpty { emit(batch) }
    }

    // MARK: 去重合并 + 节流批推（主线程）

    private func append(_ hits: [SearchHit]) {
        guard !finished, !hits.isEmpty else { return }
        for hit in hits where seenPaths.insert(hit.url.path).inserted {
            buffer.append(hit)
            keptCount += 1
        }
        // 达结果硬上限：立刻 flush 并停两通道（NSMetadataQuery.stop + 扫描 Task 取消），CPU 立即回落
        if keptCount >= SearchLimits.maxResults {
            flushNow()
            teardown()
            return
        }
        if buffer.count >= 50 {
            flushNow()
        } else if !flushScheduled, !buffer.isEmpty {
            // 用 dispatch 定时而非 RunLoop Timer：无 RunLoop 模式依赖（测试环境同样可靠）
            flushScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self else { return }
                self.flushScheduled = false
                self.flushNow()
            }
        }
    }

    private func flushNow() {
        guard !finished, !buffer.isEmpty else { return }
        continuation.yield(buffer)
        buffer = []
    }

    private func channelDone() {
        guard !finished else { return }
        pendingChannels -= 1
        flushNow()
        if pendingChannels <= 0 {
            teardown()
        }
    }
}

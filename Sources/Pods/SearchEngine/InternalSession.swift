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
    /// 通道B 是否仍在跑——通道A 据此给通道B 预留名额（见 SearchLimits.scanReserve）
    private var scanRunning = false

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
        scanRunning = false
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
        // 硬上限 + 通道B 预留：绝不在主线程读全量十万级结果，也绝不把名额一次吃干把通道B 饿死
        // `!final` 是必须的：收尾那一次 drain 之后 query 就 stop+释放了，没有下一次机会。
        // 若此时仍替通道B 预留，那 500 个名额里的 Spotlight 结果**永久丢失**且用户看不到
        // "仅显示前 N 条"提示——审查抓到的真 bug，不是想象出来的。
        let readBudget = SearchLimits.spotlightReadBudget(kept: keptCount,
                                                          scanAlive: scanRunning && !final)
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
        scanRunning = true
        let request = self.request
        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            for root in Self.scanRoots(for: request.scope) {
                guard !Task.isCancelled else { break }
                Self.scan(root: root, request: request) { batch in
                    DispatchQueue.main.async { self?.append(batch) }
                }
            }
            DispatchQueue.main.async {
                self?.scanRunning = false     // 通道B 收工后通道A 不再需要预留
                self?.channelDone()
            }
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

    /// 后台线程：层序（BFS）遍历 + 文件名大小写不敏感包含匹配。
    /// 两条发射条件缺一不可（都由真红引出，见 CHANGELOG v0.19.17）：
    ///   ① `batch.count >= 50`——原有的，只够高命中率查询用；
    ///   ② **距上次发射 ≥ flushInterval**——低命中率查询（如 ".claude"，~ 下 135 条/198 万项）
    ///      光靠 ① 要等第 50 条,实测 17.9s;靠"扫完"要 45s。
    /// 时钟只在 batch 非空时才读（短路），所以 2M 次迭代里几乎不付这个钱
    /// （`DispatchTime.now().uptimeNanoseconds` 实测 10ns/次）。
    static let flushInterval: UInt64 = 150_000_000   // 150ms

    /// internal 而非 private：胶囊自测要直接驱动它、精确测「发射时机」，
    /// 不能被 append() 的 300ms 节流糊住（@testable import 只暴露 internal）。
    /// `flushInterval` 带默认值入参而非可变静态量：生产调用点不变，测试可传 1ms
    /// 用小夹具做确定性断言，且不引入跨测试共享的可变状态。
    static func scan(root: URL, request: SearchRequest,
                     flushInterval: UInt64 = SearchSession.flushInterval,
                     emit: ([SearchHit]) -> Void) {
        // 命中才补的展示属性（未命中项一个 stat 都不多花）
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey,
                                         .contentModificationDateKey, .contentTypeKey]
        var batch: [SearchHit] = []
        var lastEmit = DispatchTime.now().uptimeNanoseconds

        func flush() {
            guard !batch.isEmpty else { return }
            emit(batch)
            batch = []
            lastEmit = DispatchTime.now().uptimeNanoseconds
        }
        /// batch 非空且已过节流窗 → 发射（时钟读取被 !isEmpty 短路挡在绝大多数迭代之外）
        func flushIfDue() {
            guard !batch.isEmpty,
                  DispatchTime.now().uptimeNanoseconds - lastEmit >= flushInterval else { return }
            flush()
        }

        LevelOrderWalk.walk(root: root,
                            skipDirectoryNames: request.skippedDirectoryNames,
                            shouldContinue: { !Task.isCancelled }) { url, _, isDir in
            let name = url.lastPathComponent
            guard name.localizedCaseInsensitiveContains(request.query) else {
                flushIfDue()          // 未命中也要推进时间发射，否则孤零零一条命中会被压到扫完
                return
            }
            let rv = try? url.resourceValues(forKeys: keys)
            batch.append(SearchHit(
                url: url, name: name,
                isDirectory: rv?.isDirectory ?? isDir,
                size: (rv?.fileSize).map(Int64.init),
                modified: rv?.contentModificationDate,
                contentTypeID: rv?.contentType?.identifier))
            if batch.count >= 50 { flush() } else { flushIfDue() }
        }
        flush()
    }

    // MARK: 去重合并 + 节流批推（主线程）

    /// internal 而非 private：封顶逻辑在这里，自测要直接喂**不对齐**的批次
    /// （端到端夹具的命中都在同一目录、批次恒为 50，keptCount 本来就正好落在上限，
    ///  验不出"越顶"——第一版就是这么假绿的）
    func append(_ hits: [SearchHit]) {
        guard !finished, !hits.isEmpty else { return }
        for hit in hits {
            // 硬上限逐条守：改前批次恒为 50，keptCount 正好落在 2000；
            // 加了时间发射后批次大小不定，越顶后才发现会多留最多 49 条。
            // 注意先判上限再 insert——反过来会把没留下的路径标成"已见过"。
            guard keptCount < SearchLimits.maxResults else { break }
            guard seenPaths.insert(hit.url.path).inserted else { continue }
            buffer.append(hit)
            keptCount += 1
        }
        // 达结果硬上限：立刻 flush 并停两通道（NSMetadataQuery.stop + 扫描 Task 取消），CPU 立即回落
        if keptCount >= SearchLimits.maxResults {
            flushNow()
            teardown()
            return
        }
        // 首批不吃节流：稀疏查询下 150ms 的扫描发射窗后再压 300ms，
        // 首个结果上屏要 450ms。第一批直接推出去，后续才节流。
        if !hasYielded {
            flushNow()
        } else if buffer.count >= 50 {
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

    /// 是否已推出过至少一批（用于让首批免于 300ms 节流）
    private var hasYielded = false

    private func flushNow() {
        guard !finished, !buffer.isEmpty else { return }
        continuation.yield(buffer)
        hasYielded = true
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

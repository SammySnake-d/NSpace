import AppKit
import UniformTypeIdentifiers
import SearchEngine
import Frecency

/// 种类过滤（客户端过滤结果，不重发搜索）
private enum SearchKindFilter: Int, CaseIterable {
    case all, folder, image, document, movie, audio, archive

    var titleKey: String {
        switch self {
        case .all: "search.kind.all"
        case .folder: "search.kind.folder"
        case .image: "search.kind.image"
        case .document: "search.kind.document"
        case .movie: "search.kind.movie"
        case .audio: "search.kind.audio"
        case .archive: "search.kind.archive"
        }
    }

    func matches(_ hit: SearchHit) -> Bool {
        switch self {
        case .all: true
        case .folder: hit.isDirectory
        case .image: conforms(hit, to: .image)
        case .document: conforms(hit, to: .text) || conforms(hit, to: .pdf)
        case .movie: conforms(hit, to: .movie)
        case .audio: conforms(hit, to: .audio)
        case .archive: conforms(hit, to: .archive)
        }
    }

    private func conforms(_ hit: SearchHit, to type: UTType) -> Bool {
        guard let id = hit.contentTypeID, let t = UTType(id) else { return false }
        return t.conforms(to: type)
    }
}

/// 可成为 key 的无边框面板（borderless 默认拒绝 key，输入框需要）
@MainActor
private final class SearchPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// 结果表：Return=定位、Esc=关面板、右键=上下文菜单（其余交默认：方向键/双击）
@MainActor
private final class SearchResultTableView: NSTableView {
    var onReturn: (() -> Void)?
    var onEscape: (() -> Void)?
    /// 右键菜单提供者：入参为点击行（-1 表示空白区，返回 nil 不弹菜单）
    var menuProvider: ((Int) -> NSMenu?)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onReturn?()   // Return / Enter
        case 53: onEscape?()       // Esc
        default: super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        // 右击未选中行 → 先把它设为唯一选中（Finder 语义）
        if row >= 0, !selectedRowIndexes.contains(row) {
            selectRowIndexes([row], byExtendingSelection: false)
        }
        return menuProvider?(row)
    }
}

/// 聚焦搜索面板（QSpace 式浮层）：无边框浮窗居中于主窗口上方。
/// 只读消费 SearchEngine 流（BG-1：本层零写型文件 API）；
/// 回车定位经回调上抛 MainWindowController 导航；双击走系统默认打开。
@MainActor
final class SearchPanelController: NSObject {
    static let shared = SearchPanelController()

    private let panel: SearchPanel
    private let field = NSTextField()
    private let scopePopup = NSPopUpButton()
    private let spinner = NSProgressIndicator()
    private let nameCheck = NSButton(checkboxWithTitle: L10n.t("search.names"), target: nil, action: nil)
    private let contentCheck = NSButton(checkboxWithTitle: L10n.t("search.contents"), target: nil, action: nil)
    private let hiddenCheck = NSButton(checkboxWithTitle: L10n.t("search.includeHidden"), target: nil, action: nil)
    private let kindPopup = NSPopUpButton()
    private let tableView = SearchResultTableView()
    private let emptyLabel = NSTextField(labelWithString: L10n.t("search.empty"))
    /// 结果达上限提示（"仅显示前 N 条，请细化关键词"）——引擎在此上限停两通道，杜绝卡死
    private let truncationLabel = NSTextField(labelWithString: "")

    private let engine = SearchEngine()
    /// 全量命中（流式累积）与过滤后展示集
    private var allHits: [SearchHit] = []
    private var hits: [SearchHit] = []
    private var searchTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var isSearching = false
    /// I-40：局部范围的搜索根（按"离根近者优先"排序用；全局搜索为 nil 保持到达顺序）
    private var searchRoot: URL?
    /// 根的两种前缀表示：原样 + 解析符号链接后——Spotlight 通道回报解析后路径
    /// （/tmp⟷/private/tmp 等），单一未解析前缀会让主通道整体判为"根外"沉底
    private var rootPrefixes: [String] = []
    /// 每命中深度只算一次（键=url.path）；批次归并/过滤重排复用，不做全量重算
    private var depthCache: [String: Int] = [:]

    /// M28 使用习惯学习排序：注入的 frecency 载体（AppDelegate 设一次，与全应用记账同一实例）
    var frecencyStore: FrecencyStore?
    /// 本次搜索的 frecency 快照（搜索任务开头 await 一次；搜索期内稳定，per-hit 同步打分）
    private var frecencySnapshot: [String: FrecencyEntry] = [:]
    /// 本次搜索是否走智能排序（偏好开且有查询词）——搜索期内固定
    private var smartSortActive = false
    /// 本次查询词（智能匹配打分用）
    private var currentQuery = ""
    /// 每命中融合分只算一次（键=url.path）
    private var scoreCache: [String: Double] = [:]

    /// 打开时捕获的"当前文件夹"与定位回调（每次 show 重新注入）
    private var currentDirectory: URL?
    private var onReveal: ((URL) -> Void)?
    /// 加入暂存架回调（MainWindowController 经 StashShelfController 注入；nil=不可达则菜单省该项，FG-1）
    private var onStash: (([URL]) -> Void)?

    override private init() {
        panel = SearchPanel(contentRect: NSRect(x: 0, y: 0, width: 880, height: 460),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = true
        panel.onCancel = { [weak self] in self?.closePanel() }
        buildContent()
        // 失焦（点击面板外部）自动关闭
        NotificationCenter.default.addObserver(self, selector: #selector(panelResignedKey(_:)),
                                               name: NSWindow.didResignKeyNotification, object: panel)
    }

    // MARK: 打开 / 关闭

    /// ⌘F：scopeGlobal=false（当前文件夹）；⌥⌘F：scopeGlobal=true（全局）
    func show(scopeGlobal: Bool, currentDirectory: URL, attachedTo window: NSWindow?,
              onReveal: @escaping (URL) -> Void,
              onStash: (([URL]) -> Void)? = nil) {
        self.currentDirectory = currentDirectory
        self.onReveal = onReveal
        self.onStash = onStash
        scopePopup.selectItem(at: scopeGlobal ? 0 : 1)
        position(over: window)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        // 带着已有关键词切范围重开 → 立即按新范围重搜
        restartSearch()
    }

    private func position(over window: NSWindow?) {
        let ref = window?.frame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let size = panel.frame.size
        let origin = NSPoint(x: ref.midX - size.width / 2,
                             y: ref.maxY - size.height - 96)
        panel.setFrameOrigin(origin)
    }

    private func closePanel() {
        searchTask?.cancel()
        debounceTask?.cancel()
        spinner.stopAnimation(nil)
        isSearching = false
        panel.orderOut(nil)
    }

    @objc private func panelResignedKey(_ note: Notification) {
        closePanel()
    }

    // MARK: 搜索执行（即输即搜，300ms 防抖；流式追加）

    private func scheduleSearch() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.restartSearch()
        }
    }

    private func restartSearch() {
        searchTask?.cancel()
        allHits = []
        hits = []
        tableView.reloadData()
        emptyLabel.isHidden = true
        let query = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            spinner.stopAnimation(nil)
            isSearching = false
            return
        }
        isSearching = true
        spinner.startAnimation(nil)
        currentQuery = query
        smartSortActive = Preferences.searchSmartSort
        scoreCache = [:]
        let scope: SearchRequest.Scope = scopePopup.indexOfSelectedItem == 0
            ? .global
            : .directory(currentDirectory ?? FileManager.default.homeDirectoryForCurrentUser)
        setSearchRoot(scopePopup.indexOfSelectedItem == 0
            ? nil
            : (currentDirectory ?? FileManager.default.homeDirectoryForCurrentUser))
        let request = SearchRequest(query: query, scope: scope,
                                    searchNames: nameCheck.state == .on,
                                    searchContents: contentCheck.state == .on,
                                    includeHidden: hiddenCheck.state == .on)
        searchTask = Task { [weak self] in
            guard let self else { return }
            // M28：搜索排序前取一次 frecency 快照（放在流之前 → 首批命中即按习惯排序，期内稳定）
            self.frecencySnapshot = await self.frecencyStore?.snapshot() ?? [:]
            guard !Task.isCancelled else { return }
            for await batch in engine.search(request) {
                guard !Task.isCancelled else { return }
                self.appendResults(batch)
            }
            guard !Task.isCancelled else { return }
            self.finishSearch()
        }
    }

    private func appendResults(_ batch: [SearchHit]) {
        allHits.append(contentsOf: batch)
        let filter = selectedKindFilter
        let visible = filter == .all ? batch : batch.filter { filter.matches($0) }
        guard !visible.isEmpty else { return }
        // 选中记忆（I-38）：变更前按 URL 记住当前选中
        let selectedURL = tableView.selectedRow >= 0 && tableView.selectedRow < hits.count
            ? hits[tableView.selectedRow].url : nil
        // 智能排序（M28）或局部根近序：新批排序后线性归并（O(n) 摊销，避免全量重拼）。
        // 全局 + 智能关：到达序原地追加（O(1)）。
        if smartSortActive || searchRoot != nil {
            hits = merged(hits, visible.sorted(by: rankLess))
        } else {
            hits.append(contentsOf: visible)
        }
        tableView.reloadData()
        restoreSelection(selectedURL)
        updateTruncationHint()
    }

    /// I-38：重载后按 URL 还原选中并保持可见（流式批次此前每批 reloadData 直接清掉用户选中）
    private func restoreSelection(_ url: URL?) {
        guard let url, let row = hits.firstIndex(where: { $0.url == url }) else { return }
        tableView.selectRowIndexes([row], byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    /// 结果集整体替换（kindChanged / 测试探针用）——保持选中
    private func setHits(_ newHits: [SearchHit]) {
        let selectedURL = tableView.selectedRow >= 0 && tableView.selectedRow < hits.count
            ? hits[tableView.selectedRow].url : nil
        hits = newHits
        tableView.reloadData()
        restoreSelection(selectedURL)
        updateTruncationHint()
    }

    /// 达结果硬上限时提示"仅显示前 N 条，请细化关键词"（引擎已在此上限停两通道，CPU 恒有界）
    private func updateTruncationHint() {
        truncationLabel.isHidden = allHits.count < SearchLimits.maxResults
    }

    // MARK: I-40 局部排序（离根近者优先：根直接子级最先、逐层下推，同层按路径字典序）

    /// 换根：重置前缀表示与深度缓存（restartSearch / 测试探针共用）
    private func setSearchRoot(_ root: URL?) {
        searchRoot = root
        depthCache = [:]
        guard let root else {
            rootPrefixes = []
            return
        }
        let raw = root.standardizedFileURL.path
        let resolved = root.resolvingSymlinksInPath().standardizedFileURL.path
        rootPrefixes = raw == resolved
            ? [dirPrefix(raw)]
            : [dirPrefix(raw), dirPrefix(resolved)]
    }

    private func dirPrefix(_ path: String) -> String { path == "/" ? "/" : path + "/" }

    /// 命中相对根的层深（直接子级=1）；两种根表示都不匹配 → 根外沉底（.max）
    private func depth(of hit: SearchHit) -> Int {
        let key = hit.url.path
        if let cached = depthCache[key] { return cached }
        let p = hit.url.standardizedFileURL.path
        var d = Int.max
        for prefix in rootPrefixes where p.hasPrefix(prefix) {
            d = p.dropFirst(prefix.count).split(separator: "/").count
            break
        }
        depthCache[key] = d
        return d
    }

    private func inRankOrder(_ a: SearchHit, _ b: SearchHit) -> Bool {
        let da = depth(of: a), db = depth(of: b)
        return da != db
            ? da < db
            : a.url.path.localizedStandardCompare(b.url.path) == .orderedAscending
    }

    // MARK: M28 智能排序（frecency + 匹配质量融合；偏好开时接管全局与局部）

    /// 融合分（每命中只算一次，缓存）：匹配质量 + frecency（快照，搜索期内稳定）。
    private func smartScore(of hit: SearchHit) -> Double {
        let key = hit.url.path
        if let c = scoreCache[key] { return c }
        let match = SearchRanking.matchScore(query: currentQuery, name: hit.name, path: hit.url.path) ?? 0
        let frec = frecencySnapshot[hit.url.standardizedFileURL.path]
            .map { SearchRanking.frecencyScore($0, now: Date()) } ?? 0
        let s = SearchRanking.fused(match: match, frecency: frec, queryLen: currentQuery.count)
        scoreCache[key] = s
        return s
    }

    /// 排序比较器：智能开 → 融合分降序（局部再按离根近、否则字典序 tiebreak）；智能关 → 原 inRankOrder。
    private func rankLess(_ a: SearchHit, _ b: SearchHit) -> Bool {
        guard smartSortActive else { return inRankOrder(a, b) }
        let sa = smartScore(of: a), sb = smartScore(of: b)
        if sa != sb { return sa > sb }
        if searchRoot != nil {
            let da = depth(of: a), db = depth(of: b)
            if da != db { return da < db }
        }
        return a.url.path.localizedStandardCompare(b.url.path) == .orderedAscending
    }

    /// 两个已序数组线性归并（hits 不变式：智能/局部时恒按 rankLess 有序）
    private func merged(_ a: [SearchHit], _ b: [SearchHit]) -> [SearchHit] {
        var out: [SearchHit] = []
        out.reserveCapacity(a.count + b.count)
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if rankLess(b[j], a[i]) {
                out.append(b[j]); j += 1
            } else {
                out.append(a[i]); i += 1
            }
        }
        out.append(contentsOf: a[i...])
        out.append(contentsOf: b[j...])
        return out
    }

    private func finishSearch() {
        isSearching = false
        spinner.stopAnimation(nil)
        updateEmptyState()
    }

    private func updateEmptyState() {
        let query = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        emptyLabel.isHidden = isSearching || hits.isEmpty == false || query.isEmpty
    }

    private var selectedKindFilter: SearchKindFilter {
        SearchKindFilter(rawValue: kindPopup.indexOfSelectedItem) ?? .all
    }

    // MARK: 控件动作

    @objc private func scopeChanged(_ sender: Any?) { restartSearch() }

    @objc private func channelChanged(_ sender: NSButton) {
        // 名称/内容不得双关（FG：不留必然空结果的死状态）
        if nameCheck.state == .off, contentCheck.state == .off {
            sender.state = .on
            NSSound.beep()
            return
        }
        restartSearch()
    }

    @objc private func hiddenChanged(_ sender: Any?) { restartSearch() }

    @objc private func kindChanged(_ sender: Any?) {
        let filter = selectedKindFilter
        let base = filter == .all ? allHits : allHits.filter { filter.matches($0) }
        // 过滤切换是显式用户动作：单次全排可接受（深度/融合分已缓存，仅比较成本）
        setHits((smartSortActive || searchRoot != nil) ? base.sorted(by: rankLess) : base)
        updateEmptyState()
    }

    /// 双击：目录（非包）在当前窗口活动窗格内进入（I-18——不再经 LS 绕一圈弹新窗口）；
    /// 文件/包保持系统默认程序打开
    @objc private func didDoubleClick(_ sender: Any?) {
        let row = tableView.clickedRow
        guard row >= 0, row < hits.count else { return }
        let url = hits[row].url
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        let isPackage = (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false
        if exists, isDir.boolValue, !isPackage {
            closePanel()
            onReveal?(url)
        } else {
            if let store = frecencyStore { Task { await store.record(url) } }   // M28：搜索结果打开=记账
            NSWorkspace.shared.open(url)
        }
    }

    /// 回车 = 在活动窗格导航到所在目录并选中
    private func revealSelection() {
        let row = tableView.selectedRow >= 0 ? tableView.selectedRow : (hits.isEmpty ? -1 : 0)
        guard row >= 0, row < hits.count else { NSSound.beep(); return }
        let url = hits[row].url
        closePanel()
        onReveal?(url)
    }

    // MARK: 结果行右键菜单（I-31——按搜索上下文裁剪：持有 hits[URL] 而非 model；无 coordinator 依赖项一律省，FG-1 不留假项）

    /// 点击行 → 命中，构造菜单（-1 或越界返回 nil：搜索面板无空白区目录菜单）
    private func buildMenu(clickedRow row: Int) -> NSMenu? {
        guard row >= 0, row < hits.count else { return nil }
        return menu(for: hits[row])
    }

    /// 结果行上下文菜单。最小集：打开 / 在 NSpace 中定位 / 拷贝路径 / 加入暂存架(可达时) / 显示简介。
    /// 每项 representedObject 携带该命中 URL；action 目标即本控制器（暴露供 UISelfTest 直接构造断言）。
    func menu(for hit: SearchHit) -> NSMenu {
        let menu = NSMenu()
        let url = hit.url

        addMenuItem(menu, "menu.open", #selector(openHit(_:)), url: url,
                    symbol: hit.isDirectory ? "arrow.forward.square" : "arrow.up.forward.app")
        // 在 NSpace 中定位：经 onReveal 链（show 时注入）；不可达则省（FG-1）
        if onReveal != nil {
            addMenuItem(menu, "search.reveal", #selector(revealHit(_:)), url: url,
                        symbol: "scope")
        }
        menu.addItem(.separator())

        addMenuItem(menu, "menu.copyPath", #selector(copyHitPath(_:)), url: url,
                    symbol: "link")
        // 加入暂存架：仅 StashShelfController 可达时提供（onStash 由 MainWindowController 注入）
        if onStash != nil {
            addMenuItem(menu, "search.addToStash", #selector(stashHit(_:)), url: url,
                        symbol: "tray.and.arrow.down")
        }
        menu.addItem(.separator())

        // 显示简介：InfoPanel 直接可复用
        addMenuItem(menu, "menu.getInfo", #selector(getInfoForHit(_:)), url: url,
                    symbol: "info.circle")
        return menu
    }

    @discardableResult
    private func addMenuItem(_ menu: NSMenu, _ key: String, _ action: Selector,
                             url: URL, symbol: String) -> NSMenuItem {
        let item = NSMenuItem(title: L10n.t(key), action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = url
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        menu.addItem(item)
        return item
    }

    /// 打开：目录（非包）在 NSpace 内定位进入；文件/包走系统默认程序（与双击同语义）
    @objc private func openHit(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        let isPackage = (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false
        if exists, isDir.boolValue, !isPackage, onReveal != nil {
            closePanel()
            onReveal?(url)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// 在 NSpace 中定位：经 onReveal 链上抛 MainWindowController 导航并选中
    @objc private func revealHit(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        closePanel()
        onReveal?(url)
    }

    /// 拷贝路径：写入通用剪贴板（真实效果——NSPasteboard 内容==该路径）
    @objc private func copyHitPath(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(url.path, forType: .string)
        Toast.show(L10n.t("toast.copiedPath"), in: panel)
    }

    /// 加入暂存架：经注入的 onStash（StashShelfController.add）落地
    @objc private func stashHit(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        onStash?([url])
    }

    /// 显示简介：复用 InfoPanel
    @objc private func getInfoForHit(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        InfoPanel.show(for: url)
    }

    // MARK: UISelfTest 探针（I-38 流式不打断选中 / I-40 根近排序+路径列；不触真实搜索引擎）

    /// 重置结果集并注入搜索根（夹具驱动，绕过引擎）
    func uiTestReset(root: URL?) {
        searchTask?.cancel()
        debounceTask?.cancel()
        setSearchRoot(root)
        allHits = []
        hits = []
        tableView.reloadData()
    }
    /// 走真实 appendResults 链注入一批结果（排序/选中保持逻辑全生效）
    func uiTestAppend(_ batch: [SearchHit]) { appendResults(batch) }
    func uiTestSelectRow(_ row: Int) { tableView.selectRowIndexes([row], byExtendingSelection: false) }
    var uiTestSelectedPath: String? {
        tableView.selectedRow >= 0 && tableView.selectedRow < hits.count
            ? hits[tableView.selectedRow].url.path : nil
    }
    var uiTestResultPaths: [String] { hits.map(\.url.path) }
    /// M28：注入智能排序状态（查询词 + frecency 快照 + 开关），配合 uiTestAppend 确定性验证融合排序
    func uiTestConfigureSmart(query: String, snapshot: [String: FrecencyEntry], active: Bool) {
        currentQuery = query
        frecencySnapshot = snapshot
        smartSortActive = active
        scoreCache = [:]
    }
    var uiTestTruncationVisible: Bool { !truncationLabel.isHidden }
    var uiTestResultCount: Int { hits.count }
    /// 首行路径列单元格实渲染文本（真实效果断言：路径真的显示了，不是 tooltip）
    var uiTestFirstRowPathCellText: String? {
        guard !hits.isEmpty,
              let col = tableView.tableColumns.first(where: { $0.identifier.rawValue == "path" })
        else { return nil }
        return (tableView(tableView, viewFor: col, row: 0) as? TextCellView)?.textField?.stringValue
    }

    // MARK: 构建 UI（4pt 网格）

    private func buildContent() {
        let root = NSVisualEffectView()
        root.material = .popover
        root.blendingMode = .behindWindow
        root.state = .active
        root.wantsLayer = true
        root.layer?.cornerRadius = 12
        root.layer?.masksToBounds = true
        root.layer?.borderWidth = 1
        root.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.4).cgColor

        // —— 第一行：icon + 大搜索框 + spinner + 范围切换 ——
        let icon = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass",
                                              accessibilityDescription: L10n.t("search.placeholder"))!)
        icon.symbolConfiguration = .init(pointSize: 18, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor

        field.font = .systemFont(ofSize: 18)
        field.placeholderString = L10n.t("search.placeholder")
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        scopePopup.addItems(withTitles: [L10n.t("search.scopeGlobal"), L10n.t("search.scopeCurrent")])
        scopePopup.font = .systemFont(ofSize: 11)
        scopePopup.controlSize = .small
        scopePopup.target = self
        scopePopup.action = #selector(scopeChanged(_:))

        // —— 第二行：通道勾选 + 种类过滤 ——
        for check in [nameCheck, contentCheck] {
            check.target = self
            check.action = #selector(channelChanged(_:))
            check.font = .systemFont(ofSize: 12)
        }
        nameCheck.state = .on
        contentCheck.state = .off
        hiddenCheck.state = .off
        hiddenCheck.font = .systemFont(ofSize: 12)
        hiddenCheck.target = self
        hiddenCheck.action = #selector(hiddenChanged(_:))
        hiddenCheck.toolTip = L10n.t("search.hiddenTooltip")  // 超越 QSpace 的卖点开关

        for filter in SearchKindFilter.allCases {
            kindPopup.addItem(withTitle: L10n.t(filter.titleKey))
        }
        kindPopup.font = .systemFont(ofSize: 11)
        kindPopup.controlSize = .small
        kindPopup.target = self
        kindPopup.action = #selector(kindChanged(_:))

        // —— 结果表 ——
        tableView.style = .plain
        tableView.rowHeight = 24
        tableView.intercellSpacing = NSSize(width: 8, height: 0)
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(didDoubleClick(_:))
        tableView.onReturn = { [weak self] in self?.revealSelection() }
        tableView.onEscape = { [weak self] in self?.closePanel() }
        tableView.menuProvider = { [weak self] row in self?.buildMenu(clickedRow: row) }
        for (id, width) in [("name", CGFloat(320)), ("path", 292), ("size", 72), ("dateModified", 148)] {
            let col = NSTableColumn(identifier: .init(id))
            col.width = width
            tableView.addTableColumn(col)
        }

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true

        truncationLabel.stringValue = L10n.f("search.truncated", SearchLimits.maxResults)
        truncationLabel.font = .systemFont(ofSize: 11)
        truncationLabel.textColor = .secondaryLabelColor
        truncationLabel.alignment = .center
        truncationLabel.isHidden = true
        truncationLabel.wantsLayer = true
        truncationLabel.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor

        let sep1 = NSBox(); sep1.boxType = .separator
        let sep2 = NSBox(); sep2.boxType = .separator

        for sub in [icon, field, spinner, scopePopup, sep1,
                    nameCheck, contentCheck, hiddenCheck, kindPopup, sep2,
                    scroll, emptyLabel, truncationLabel] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(sub)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            icon.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            field.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            spinner.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 8),
            spinner.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            scopePopup.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 8),
            scopePopup.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            scopePopup.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            scopePopup.widthAnchor.constraint(equalToConstant: 120),

            sep1.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 12),
            sep1.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sep1.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            nameCheck.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            nameCheck.topAnchor.constraint(equalTo: sep1.bottomAnchor, constant: 8),
            contentCheck.leadingAnchor.constraint(equalTo: nameCheck.trailingAnchor, constant: 16),
            contentCheck.centerYAnchor.constraint(equalTo: nameCheck.centerYAnchor),
            hiddenCheck.leadingAnchor.constraint(equalTo: contentCheck.trailingAnchor, constant: 16),
            hiddenCheck.centerYAnchor.constraint(equalTo: nameCheck.centerYAnchor),
            kindPopup.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            kindPopup.centerYAnchor.constraint(equalTo: nameCheck.centerYAnchor),
            kindPopup.widthAnchor.constraint(equalToConstant: 108),

            sep2.topAnchor.constraint(equalTo: nameCheck.bottomAnchor, constant: 8),
            sep2.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sep2.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            scroll.topAnchor.constraint(equalTo: sep2.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            // 上限提示：贴结果区底部整条（细条 overlay，不挤占列表布局）
            truncationLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            truncationLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            truncationLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            truncationLabel.heightAnchor.constraint(equalToConstant: 20),
        ])
        panel.contentView = root
    }
}

// MARK: - 搜索框委托（防抖触发 + 键路由）

extension SearchPanelController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        scheduleSearch()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            revealSelection()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            closePanel()
            return true
        case #selector(NSResponder.moveDown(_:)):
            // ↓ 把焦点交给结果表
            guard !hits.isEmpty else { return true }
            panel.makeFirstResponder(tableView)
            tableView.selectRowIndexes([0], byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
            return true
        default:
            return false
        }
    }
}

// MARK: - 结果表数据源/委托（复用 NameCellView/TextCellView/Formatters）

extension SearchPanelController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { hits.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let colID = tableColumn?.identifier.rawValue, row < hits.count else { return nil }
        let hit = hits[row]
        if colID == "name" {
            let cell = tableView.makeView(withIdentifier: .init("searchName"), owner: nil) as? NameCellView
                ?? NameCellView(identifier: .init("searchName"))
            let icon = NSWorkspace.shared.icon(forFile: hit.url.path)
            icon.size = NSSize(width: 16, height: 16)
            cell.configure(icon: icon, name: hit.name, dimmed: false)
            cell.toolTip = hit.url.path  // 同名结果靠路径区分
            return cell
        }
        let cell = tableView.makeView(withIdentifier: .init("searchText"), owner: nil) as? TextCellView
            ?? TextCellView(identifier: .init("searchText"))
        switch colID {
        case "path":
            // I-40：常驻路径列（同名结果不再只靠悬浮区分）——中部省略保根与最近父级两头
            let parent = hit.url.deletingLastPathComponent().path
            cell.configure((parent as NSString).abbreviatingWithTildeInPath, alignment: .left)
            cell.textField?.lineBreakMode = .byTruncatingMiddle
            cell.toolTip = parent
        case "size":
            cell.configure(hit.size.map { Formatters.size.string(fromByteCount: $0) } ?? "—", alignment: .right)
            cell.textField?.lineBreakMode = .byTruncatingTail   // 复用格重置（可能上轮是路径列）
            cell.toolTip = nil
        case "dateModified":
            cell.configure(hit.modified.map { Formatters.relativeDate($0) } ?? "—", alignment: .left)
            cell.textField?.lineBreakMode = .byTruncatingTail
            cell.toolTip = nil
        default:
            cell.configure("", alignment: .left)
        }
        return cell
    }
}

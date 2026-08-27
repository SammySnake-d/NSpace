import AppKit
import QuickLookUI
import UniformTypeIdentifiers
import NSpaceContracts
import ArchiveEngine
import FolderSize
import IconThumb

/// 列表视图（性能核心）：view-based NSTableView、固定行高、行复用、可排序列。
/// 只读消费 DirectoryViewModel（BG-1：本层无任何写型文件 API）；
/// 文件变更意图一律经 FileOpsCoordinator 构造 OperationSpec 交内核执行。
/// 装饰异步链（FolderSize/IconThumb）只对可见行发请求，滚出即取消——北极星零浪费。
@MainActor
final class FileListViewController: NSViewController, FileRevealTarget {
    let model: DirectoryViewModel
    /// 文件操作桥（由窗格注入）
    weak var coordinator: FileOpsCoordinator?
    /// 导航意图上抛（由 Pane 历史协调）
    var onNavigate: ((URL) -> Void)?
    /// 返回上一步意图上抛（Backspace=back 时；交 Pane 走 browser 历史）
    var onNavigateBack: (() -> Void)?
    /// 用户交互上抛（窗格焦点协调）
    var onInteract: (() -> Void)?
    /// 选中变化上抛（状态栏"已选 M 项"）
    var onSelectionChange: (() -> Void)?
    /// 快照应用后上抛（状态栏"N 项"）
    var onContentChange: (() -> Void)?

    let tableView = FocusReportingTableView()   // internal：UISelfTest I-26 列头排序断言需驱动 sortDescriptors
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "")

    /// 操作完成后待显露（选中/进入重命名）的目标
    private var pendingReveal: (url: URL, rename: Bool)?

    /// 选中态 URL 缓存（I-32）：随选中变更实时记账。applySnapshot 时 model.items 已换新，
    /// 用现行 selectedRowIndexes 反查会把旧行号错映到位移后的新项（删除后选中"漂移"到顶行的真凶）——
    /// 故以此缓存为真源，reloadData 后按 URL 精确匹配恢复；被删项无匹配即显式清空。
    private var selectionURLCache: Set<URL> = []

    /// spring-loaded 状态：拖拽悬停的文件夹行 + 触发计时器
    private var springLoad: (row: Int, timer: Timer)?

    // MARK: 分组（M26）——行号↔item 映射的唯一真源

    /// 展示行序列（分组开启时 = [组头, 项...] 交织；关闭时 = 每项一行）。
    /// 严禁在别处散落 index 算术：所有「行号→item」「item→行号」换算一律走本数组的 helper。
    private enum ListRow {
        case group(key: String, title: String, count: Int, collapsed: Bool)
        case item(Int)   // 下标指向 model.items
    }
    private var listRows: [ListRow] = []
    /// 已折叠组键集合（重组时据此决定是否铺开组内项）
    private var collapsedGroups: Set<String> = []
    /// 组过滤：非 nil 时仅展示该组（「仅显示此组」）；nil = 全部组
    private var groupFilterKey: String?
    /// 过滤态提示药丸（FG-1：过滤态不留悬疑，可一键还原）
    private let filterPill = FilterPillButton()

    // 装饰状态（派生显示层，可随时丢弃）：已回填的目录大小 / 已升级的缩略图 / 在飞请求
    private var sizeOverlay: [URL: Int64] = [:]
    private var thumbOverlay: [URL: NSImage] = [:]
    private var sizeTasks: [URL: Task<Void, Never>] = [:]
    private var thumbTasks: [URL: Task<Void, Never>] = [:]
    /// 缩略图资格按 UTType 缓存（滚动路径零重复 conforms 计算）
    private static var thumbEligible: [String: Bool] = [:]

    /// 键盘焦点落点（PaneGrid 激活时 makeFirstResponder 此视图）
    var focusTarget: NSView { tableView }

    /// 当前目录（新建/粘贴/终端打开的落点）
    var currentDirectory: URL { model.directory }

    init(model: DirectoryViewModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        model.addOnUpdate { [weak self] in self?.applySnapshot() }
        model.addOnError { [weak self] message in self?.showEmptyState(message) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建 UI，无 xib") }

    override func loadView() {
        tableView.onInteract = { [weak self] in self?.onInteract?() }
        tableView.menuProvider = { [weak self] row in self?.buildMenu(clickedRow: row) }
        tableView.onReturn = { [weak self] in self?.beginRenameSelected() }
        tableView.onOpenSelected = { [weak self] in self?.openSelected(nil) }
        tableView.onBackspaceAction = { [weak self] in self?.handleBackspace() }
        tableView.onSpace = { [weak self] in self?.toggleQuickLook(nil) }
        tableView.onDragExited = { [weak self] in self?.cancelSpringLoad() }
        tableView.isGroupRowProvider = { [weak self] row in self?.isGroupRow(row) ?? false }
        tableView.onGroupRowClick = { [weak self] row in self?.handleGroupRowClick(row) }
        tableView.style = .plain  // 紧凑密度：去 inset 大留白（QSpace 式）
        tableView.intercellSpacing = NSSize(width: 8, height: 0)
        tableView.rowHeight = Self.rowHeight(for: Formatters.listFontSize)
        tableView.usesAutomaticRowHeights = false
        tableView.allowsMultipleSelection = true
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.floatsGroupRows = true   // M26：组头悬浮
        // 名称列弹性吃剩余宽、其余窄固定（QSpace/Finder 语义）——窄窗格四列俱全
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(didDoubleClick(_:))
        // 拖拽：拖出可达 Finder/其他 App/另一窗格/侧边栏/暂存架；拖入收 fileURL
        tableView.registerForDraggedTypes([.fileURL])
        tableView.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        tableView.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: false)

        addColumn(id: "name", title: L10n.t("column.name"), width: 280, min: 110, sortable: true)
        rebuildOptionalColumns()
        // 列头右键：QSpace 式可选列勾选
        let headerMenu = NSMenu()
        headerMenu.delegate = self
        tableView.headerView?.menu = headerMenu

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        // 滚动/尺寸变化 → 重算可见行装饰请求（只对可见行发请求，滚出取消）
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrollBoundsChanged(_:)),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        // 列显隐 / 列表字号变更广播：重建可选列（含 reloadData）并按字号同步行高——即时生效
        NotificationCenter.default.addObserver(
            self, selector: #selector(columnsOrFontChanged(_:)),
            name: .nspaceColumnsChanged, object: nil)
        // 分组开关变更广播：重组行序即时生效
        NotificationCenter.default.addObserver(
            self, selector: #selector(groupingChanged(_:)),
            name: .nspaceGroupingChanged, object: nil)

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(scrollView)
        root.addSubview(emptyLabel)
        // 过滤态药丸（FG-1）：悬浮在列表右上（列头附近），常态隐藏，过滤时显现，点击还原
        filterPill.isHidden = true
        filterPill.target = self
        filterPill.action = #selector(filterPillClicked(_:))
        filterPill.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(filterPill)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 20),
            filterPill.topAnchor.constraint(equalTo: root.topAnchor, constant: 4),
            filterPill.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            filterPill.heightAnchor.constraint(equalToConstant: 20),
        ])
        view = root
        model.reload()
    }

    /// 可选列注册表（名称恒在；I-26：全列可点击列头排序，id 与 SortSpec.Key 原始值一一对应）
    static let optionalColumns: [(id: String, titleKey: String, width: CGFloat, min: CGFloat, right: Bool, sortable: Bool)] = [
        ("dateModified", "column.dateModified", 128, 88, false, true),
        ("created", "column.created", 128, 88, false, true),
        ("added", "column.added", 128, 88, false, true),
        ("size", "column.size", 68, 52, true, true),
        ("kind", "column.kind", 92, 64, false, true),
    ]

    private func addColumn(id: String, title: String, width: CGFloat, min: CGFloat,
                           rightAlign: Bool = false, sortable: Bool = false) {
        let col = NSTableColumn(identifier: .init(id))
        col.title = title
        col.width = width
        col.minWidth = min
        col.resizingMask = [.userResizingMask, .autoresizingMask]
        if sortable { col.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true) }
        if rightAlign { col.headerCell.alignment = .right }
        tableView.addTableColumn(col)
    }

    /// 按偏好重建可选列（列头勾选变化时调用）
    private func rebuildOptionalColumns() {
        for col in tableView.tableColumns where col.identifier.rawValue != "name" {
            tableView.removeTableColumn(col)
        }
        let visible = Preferences.visibleColumns
        for c in Self.optionalColumns where visible.contains(c.id) {
            addColumn(id: c.id, title: L10n.t(c.titleKey), width: c.width, min: c.min,
                      rightAlign: c.right, sortable: c.sortable)
        }
        tableView.reloadData()
    }

    /// 行高随字号（大字号给更高行高避免裁切）：>=13 用 24，否则 22
    private static func rowHeight(for fontSize: CGFloat) -> CGFloat {
        fontSize >= 13 ? 24 : 22
    }

    /// 列显隐/字号变更广播处理：重建列（含 reloadData 令单元格重取字号）+ 同步行高
    @objc private func columnsOrFontChanged(_ note: Notification) {
        tableView.rowHeight = Self.rowHeight(for: Formatters.listFontSize)
        rebuildOptionalColumns()
    }

    @objc private func toggleColumn(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        var visible = Preferences.visibleColumns
        if let i = visible.firstIndex(of: id) { visible.remove(at: i) } else { visible.append(id) }
        Preferences.visibleColumns = visible
        // 广播：所有窗格列表同步重建（简化：本窗格即时，其他窗格下次快照时也一致——
        // 列集合在 viewFor 里按当前列渲染，直接全部通知）
        NotificationCenter.default.post(name: .nspaceColumnsChanged, object: nil)
    }

    private var lastSnapshotDirectory: URL?

    private func applySnapshot() {
        // 目录切换：取消所有在飞装饰请求，清空回填结果（跨目录 URL 不复用）
        if lastSnapshotDirectory != model.directory {
            lastSnapshotDirectory = model.directory
            cancelDecorationWork()
            sizeOverlay.removeAll()
        }
        // 同目录刷新也清缩略图覆盖层：文件可能已改内容（IconThumb 缓存键含 mtime，重取要么命中要么重生成）
        thumbOverlay.removeAll()
        emptyLabel.isHidden = true
        // FSEvents 自动刷新绝不吞掉用户选中：reloadData 前记 URL、后按 URL 恢复（含多选）。
        // I-32：选中真源用 selectionURLCache（选中变更时记账，反映"删除前"实际选中），
        // 不用此刻的 selectedURLs——model.items 已换新，旧行号会错映到位移后的新项造成"漂移"。
        let selectedBefore = selectionURLCache
        rebuildListRows()          // M26：重组行序（分组时 [组头,项...]；否则每项一行）
        tableView.reloadData()
        var rows = IndexSet()
        for url in selectedBefore {
            if let r = row(forURL: url) { rows.insert(r) }
        }
        // 精确匹配集即恢复；空集（如选中项全被删）也显式 select 清空——绝不留 reloadData 的按行号残留
        tableView.selectRowIndexes(rows, byExtendingSelection: false)
        if model.items.isEmpty, !model.isLoading {
            showEmptyState(L10n.t("empty.folder"))
        }
        revealPendingIfPossible()
        refreshVisibleDecorations()
        onContentChange?()
    }

    private func showEmptyState(_ message: String) {
        emptyLabel.stringValue = message
        emptyLabel.isHidden = false
    }

    /// 仅重绘（剪切灰显变化时由协调器调用）
    func redraw() { tableView.reloadData() }

    // MARK: 分组换算（M26）——组键/桶划分委托 FileGrouping（列表/图标共用真源）；本层只管展示行序与视图态

    /// 分组是否生效：偏好开 且 当前排序键为日期类
    private var groupingActive: Bool {
        FileGrouping.active(model.sort)
    }

    static func isDateKey(_ k: SortSpec.Key) -> Bool { FileGrouping.isDateKey(k) }

    /// 依当前 model.items（reader 已按 sort 排序）重建展示行序列。
    /// 组顺序 = 组在已排序项中的首次出现顺序（排序方向天然决定组顺序）；组内保持项的相对顺序。
    private func rebuildListRows() {
        listRows.removeAll(keepingCapacity: true)
        guard groupingActive else {
            for i in model.items.indices { listRows.append(.item(i)) }
            filterPill.isHidden = true
            return
        }
        let groups = FileGrouping.buckets(model.items, key: model.sort.key)
        var titles: [String: String] = [:]
        for g in groups { titles[g.key] = g.title }
        // 过滤态失效自愈：被过滤组已不存在（换目录/排序键）→ 清过滤
        if let only = groupFilterKey, !groups.contains(where: { $0.key == only }) { groupFilterKey = nil }
        for g in groups where groupFilterKey == nil || groupFilterKey == g.key {
            let collapsed = collapsedGroups.contains(g.key)
            listRows.append(.group(key: g.key, title: g.title, count: g.indices.count, collapsed: collapsed))
            if !collapsed { for i in g.indices { listRows.append(.item(i)) } }
        }
        updateFilterPill(titles: titles)
    }

    private func updateFilterPill(titles: [String: String]) {
        if let only = groupFilterKey {
            filterPill.title = L10n.f("group.filter.pill", titles[only] ?? only)
            filterPill.isHidden = false
        } else {
            filterPill.isHidden = true
        }
    }

    /// 行号 → model.items 下标（组头行/越界 → nil）
    func itemIndex(forRow row: Int) -> Int? {
        guard listRows.indices.contains(row) else { return nil }
        if case .item(let i) = listRows[row] { return i }
        return nil
    }

    /// 行号 → FileItem（组头行/越界 → nil）
    func item(atRow row: Int) -> FileItem? {
        guard let i = itemIndex(forRow: row), model.items.indices.contains(i) else { return nil }
        return model.items[i]
    }

    /// model.items 下标 → 行号（项在折叠组内 → nil）
    func row(forItemIndex idx: Int) -> Int? {
        for (r, lr) in listRows.enumerated() {
            if case .item(let i) = lr, i == idx { return r }
        }
        return nil
    }

    /// URL → 行号（未载入/在折叠组内 → nil）
    func row(forURL url: URL) -> Int? {
        // 标准化路径比较：目录条目 URL 带尾斜杠、导航/搜索来源的不带，URL 精确相等会错配（I-39）
        let p = url.standardizedFileURL.path
        guard let idx = model.items.firstIndex(where: { $0.url.standardizedFileURL.path == p })
        else { return nil }
        return row(forItemIndex: idx)
    }

    /// 该行是否组头行
    func isGroupRow(_ row: Int) -> Bool {
        guard listRows.indices.contains(row) else { return false }
        if case .group = listRows[row] { return true }
        return false
    }

    /// 组头行点击：切换该组折叠（重组行序 + 保选中）
    private func handleGroupRowClick(_ row: Int) {
        guard listRows.indices.contains(row), case .group(let key, _, _, _) = listRows[row] else { return }
        toggleGroup(key: key)
    }

    /// 切换某组折叠态并重建（保 URL 选中）
    func toggleGroup(key: String) {
        if collapsedGroups.contains(key) { collapsedGroups.remove(key) }
        else { collapsedGroups.insert(key) }
        rebuildRowsPreservingSelection()
    }

    /// 应用组过滤（「仅显示此组」）
    func applyGroupFilter(key: String) {
        groupFilterKey = key
        rebuildRowsPreservingSelection()
    }

    /// 清除组过滤（「显示全部组」/ 药丸点击）
    func clearGroupFilter() {
        groupFilterKey = nil
        rebuildRowsPreservingSelection()
    }

    @objc private func filterPillClicked(_ sender: Any?) { clearGroupFilter() }

    /// 不触发 model reload 的重组：重建行序、reloadData、按 selectionURLCache 精确恢复选中
    private func rebuildRowsPreservingSelection() {
        let selectedBefore = selectionURLCache
        rebuildListRows()
        tableView.reloadData()
        var rows = IndexSet()
        for url in selectedBefore {
            if let r = row(forURL: url) { rows.insert(r) }
        }
        tableView.selectRowIndexes(rows, byExtendingSelection: false)
        refreshVisibleDecorations()
    }

    /// 分组开关变更广播：重组即时生效（所有列表窗格）
    @objc private func groupingChanged(_ note: Notification) {
        rebuildRowsPreservingSelection()
    }


    // MARK: 按需装饰（FolderSize 目录大小 + IconThumb 缩略图，只对可见行、滚出取消）

    @objc private func scrollBoundsChanged(_ note: Notification) {
        refreshVisibleDecorations()
    }

    /// 取消全部在飞装饰请求（标签/窗格挂起、目录切换时调用；已回填结果保留）
    func cancelDecorationWork() {
        sizeTasks.values.forEach { $0.cancel() }
        sizeTasks.removeAll()
        thumbTasks.values.forEach { $0.cancel() }
        thumbTasks.removeAll()
    }

    /// 对当前可见行发起缺失的装饰请求；不再可见的在飞请求全部取消
    func refreshVisibleDecorations() {
        guard view.window != nil, !model.items.isEmpty else { return }
        let range = tableView.rows(in: tableView.visibleRect)
        var wantedSizes = Set<URL>()
        var wantedThumbs = Set<URL>()
        if range.length > 0 {
            for row in range.location..<(range.location + range.length) {
                guard let item = item(atRow: row) else { continue }   // 组头行跳过
                if item.isDirectory, item.size == nil, sizeOverlay[item.url] == nil {
                    wantedSizes.insert(item.url)
                    requestFolderSize(item.url)
                }
                if thumbOverlay[item.url] == nil, wantsThumbnail(item) {
                    wantedThumbs.insert(item.url)
                    requestThumbnail(item.url)
                }
            }
        }
        for (url, task) in sizeTasks where !wantedSizes.contains(url) {
            task.cancel(); sizeTasks[url] = nil
        }
        for (url, task) in thumbTasks where !wantedThumbs.contains(url) {
            task.cancel(); thumbTasks[url] = nil
        }
    }

    /// 有内容缩略图价值的类型：图片/影音/PDF；目录与应用包用现有图标（不发 QuickLook 请求）
    private func wantsThumbnail(_ item: FileItem) -> Bool {
        guard !item.isDirectory, !item.isPackage, let id = item.contentTypeID else { return false }
        if let cached = Self.thumbEligible[id] { return cached }
        let type = UTType(id)
        let ok = type?.conforms(to: .image) == true
            || type?.conforms(to: .audiovisualContent) == true
            || type?.conforms(to: .pdf) == true
        Self.thumbEligible[id] = ok
        return ok
    }

    private func requestFolderSize(_ url: URL) {
        guard sizeTasks[url] == nil else { return }
        sizeTasks[url] = Task { [weak self] in
            let size = try? await Engines.folderSize.size(of: url)
            guard let self, !Task.isCancelled else { return }
            self.sizeTasks[url] = nil
            guard let size else { return }
            self.sizeOverlay[url] = size
            // 仅当该行仍代表同一 URL 时刷新该行的大小列
            guard let row = self.row(forURL: url) else { return }
            let col = self.tableView.column(withIdentifier: .init("size"))
            guard col >= 0 else { return }
            self.tableView.reloadData(forRowIndexes: [row], columnIndexes: [col])
        }
    }

    private func requestThumbnail(_ url: URL) {
        guard thumbTasks[url] == nil else { return }
        thumbTasks[url] = Task { [weak self] in
            let cg = await Engines.iconThumb.thumbnail(for: url, size: 32)
            guard let self, !Task.isCancelled else { return }
            self.thumbTasks[url] = nil
            guard let cg else { return }
            let image = NSImage(cgImage: cg, size: NSSize(width: 16, height: 16))
            self.thumbOverlay[url] = image
            // 直接换图不 reload 行：避免打断可能进行中的行内重命名
            guard let row = self.row(forURL: url),
                  let cell = self.tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
                    as? NameCellView else { return }
            cell.imageView?.image = image
        }
    }

    // MARK: 选中态

    var selectedItems: [FileItem] {
        tableView.selectedRowIndexes.compactMap { item(atRow: $0) }
    }
    var selectedURLs: [URL] { selectedItems.map(\.url) }

    /// 按 URL 集恢复选中（视图模式切换时选中迁移用）；标准化路径匹配（尾斜杠跨源差异，I-39）
    func select(urls: [URL]) {
        let wanted = Set(urls.map { $0.standardizedFileURL.path })
        var indexes = IndexSet()
        for (i, item) in model.items.enumerated()
        where wanted.contains(item.url.standardizedFileURL.path) {
            if let r = row(forItemIndex: i) { indexes.insert(r) }
        }
        tableView.selectRowIndexes(indexes, byExtendingSelection: false)
        if let first = indexes.first { tableView.scrollRowToVisible(first) }
    }

    // MARK: 显露（新建后选中并进入重命名）

    func prepareReveal(_ url: URL, rename: Bool) { pendingReveal = (url, rename) }

    private func revealPendingIfPossible() {
        guard let pending = pendingReveal,
              let row = row(forURL: pending.url) else { return }
        pendingReveal = nil
        tableView.selectRowIndexes([row], byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
        if pending.rename { beginRename(row: row) }
    }

    // MARK: 打开行为（spec 功能 9：文件走系统默认 App；文件夹窗格内导航）

    @objc private func didDoubleClick(_ sender: Any?) {
        let row = tableView.clickedRow
        // 双击空白（clickedRow<0）：按使用习惯前往上层文件夹
        if row < 0 {
            if Preferences.doubleClickBlank { goUp() }
            return
        }
        guard let item = item(atRow: row) else { return }   // 组头行双击无操作
        open(item)
    }

    func open(_ item: FileItem) {
        if item.isDirectory && !item.isPackage {
            onNavigate?(item.url)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    /// 前往上层文件夹（双击空白 / Backspace=up 共用；已在根目录则不动）
    private func goUp() {
        let parent = currentDirectory.deletingLastPathComponent().standardizedFileURL
        guard parent.path != currentDirectory.standardizedFileURL.path else { return }
        onNavigate?(parent)
    }

    /// Backspace 键分发（使用习惯：忽略/返回/移废纸篓/上层）
    private func handleBackspace() {
        switch Preferences.backspaceAction {
        case "back": onNavigateBack?()
        case "delete": coordinator?.moveToTrash(selectedURLs)
        case "up": goUp()
        default: break  // ignore：不拦截
        }
    }

    // MARK: 右键菜单

    private func buildMenu(clickedRow row: Int) -> NSMenu {
        // 组头行右键：组过滤菜单（仅显示此组 / 显示全部组）
        if isGroupRow(row), case .group(let key, _, _, _) = listRows[row] {
            return buildGroupMenu(key: key)
        }
        return FileContextMenuBuilder.menu(selection: selectedItems, directory: currentDirectory, target: self)
    }

    /// 组头右键菜单（FG-3：仅显示此组 / 显示全部组）
    private func buildGroupMenu(key: String) -> NSMenu {
        let menu = NSMenu()
        let only = menu.addItem(withTitle: L10n.t("group.filter.only"),
                                action: #selector(groupFilterOnly(_:)), keyEquivalent: "")
        only.target = self
        only.representedObject = key
        let all = menu.addItem(withTitle: L10n.t("group.filter.all"),
                               action: #selector(groupFilterAll(_:)), keyEquivalent: "")
        all.target = self
        all.isEnabled = (groupFilterKey != nil)
        return menu
    }

    @objc private func groupFilterOnly(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        applyGroupFilter(key: key)
    }

    @objc private func groupFilterAll(_ sender: Any?) { clearGroupFilter() }

    // MARK: 行内重命名（FG-6：失败原子回滚旧名 + beep + 原位红字 2s）

    private func beginRenameSelected() {
        let rows = tableView.selectedRowIndexes
        guard rows.count == 1, let row = rows.first else { NSSound.beep(); return }
        beginRename(row: row)
    }

    func beginRename(row: Int) {
        guard let item = item(atRow: row),
              let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? NameCellView
        else { return }
        cell.onRenameCommit = { [weak self] newName in self?.submitRename(item, newName: newName, row: row) }
        cell.onRenameCancel = { }
        cell.beginRename()
    }

    private func submitRename(_ item: FileItem, newName: String, row: Int) {
        coordinator?.rename(item.url, to: newName) { [weak self] ok in
            if !ok { self?.flashRenameError(row: row) }
            // 成功：coordinator 已 reload；失败：未 reload，label 仍显旧名（原子回滚）
        }
    }

    /// FG-6 就地错误：beep + 行上红字 2s，不跳页不白屏
    private func flashRenameError(row: Int) {
        NSSound.beep()
        guard item(atRow: row) != nil else { return }
        let rect = tableView.rect(ofRow: row)
        let banner = NSTextField(labelWithString: L10n.t("rename.failed"))
        banner.textColor = .systemRed
        banner.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.9)
        banner.drawsBackground = true
        banner.font = .systemFont(ofSize: 11)
        banner.frame = NSRect(x: rect.minX + 24, y: rect.minY + 2, width: 240, height: 20)
        tableView.addSubview(banner)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            banner.removeFromSuperview()
        }
    }

    // MARK: 菜单命令（响应链）

    @objc func toggleHiddenFiles(_ sender: Any?) { model.includeHidden.toggle() }
    @objc func refresh(_ sender: Any?) { model.reload() }

    /// 使用分组开关（显示菜单）：翻转偏好并广播，所有列表窗格重组即时生效
    @objc func toggleGrouping(_ sender: Any?) {
        Preferences.listGrouping.toggle()
        NotificationCenter.default.post(name: .nspaceGroupingChanged, object: nil)
    }

    // 复制/剪切/粘贴/拷贝路径（Edit 菜单 ⌘C/⌘X/⌘V/⌘⇧C 与右键菜单共用）
    @objc func copyItems(_ sender: Any?) { coordinator?.copy(selectedURLs) }
    @objc func cutItems(_ sender: Any?) { coordinator?.cut(selectedURLs) }
    @objc func pasteItems(_ sender: Any?) { coordinator?.paste(into: currentDirectory) }
    @objc func copyPath(_ sender: Any?) { coordinator?.copyPaths(selectedURLs) }
    // NSText 标准选择器转发（当表视图为第一响应者时 ⌘C/⌘X/⌘V 生效）
    @objc func copy(_ sender: Any?) { copyItems(sender) }
    @objc func cut(_ sender: Any?) { cutItems(sender) }
    @objc func paste(_ sender: Any?) { pasteItems(sender) }

    @objc func duplicateItems(_ sender: Any?) { coordinator?.duplicate(selectedURLs) }
    @objc func moveToTrash(_ sender: Any?) { coordinator?.moveToTrash(selectedURLs) }

    // 归档：压缩任意选中；解压支持的归档（into=nil 同目录 / 选目录）
    @objc func compressItems(_ sender: Any?) { coordinator?.compress(selectedURLs) }
    @objc func extractItems(_ sender: Any?) { coordinator?.extract(selectedArchiveURLs, into: nil) }
    @objc func extractItemsTo(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.t("menu.extractTo.prompt")
        panel.directoryURL = currentDirectory
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        coordinator?.extract(selectedArchiveURLs, into: dir)
    }

    /// 选中项里可解压的归档 URL（右键"解压"据此过滤）
    private var selectedArchiveURLs: [URL] {
        selectedItems.filter { ArchiveEngineNode.isSupportedArchive($0.url) }.map(\.url)
    }
    @objc func newFolderHere(_ sender: Any?) { coordinator?.newFolder(in: currentDirectory, revealIn: self) }
    @objc func newFileHere(_ sender: Any?) { coordinator?.newFile(in: currentDirectory, revealIn: self) }
    @objc func renameSelected(_ sender: Any?) { beginRenameSelected() }
    @objc func copyToOtherPane(_ sender: Any?) { coordinator?.copyToOtherPane(selectedURLs) }
    @objc func moveToOtherPane(_ sender: Any?) { coordinator?.moveToOtherPane(selectedURLs) }

    @objc func openSelected(_ sender: Any?) { selectedItems.forEach { open($0) } }

    @objc func openWithApp(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, let app = item.representedObject as? URL else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(selectedURLs, withApplicationAt: app, configuration: cfg)
    }

    @objc func openWithOther(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let app = panel.url else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(selectedURLs, withApplicationAt: app, configuration: cfg)
    }

    /// AirDrop 选中项（工具栏图标入口；失败 beep 不弹窗）
    @objc func airdropSelected(_ sender: Any?) {
        let urls = selectedURLs
        guard !urls.isEmpty,
              let service = NSSharingService(named: .sendViaAirDrop),
              service.canPerform(withItems: urls) else { NSSound.beep(); return }
        service.perform(withItems: urls)
    }

    @objc func getInfo(_ sender: Any?) {
        let target = selectedURLs.first ?? currentDirectory
        InfoPanel.show(for: target)
    }

    @objc func openInTerminal(_ sender: Any?) {
        // 选中文件夹则进其内，否则用当前目录
        let dir: URL = selectedItems.first(where: { $0.isDirectory })?.url ?? currentDirectory
        let ws = NSWorkspace.shared
        // 终端选择走设置（auto=iTerm 优先回退 Terminal）
        let choice = Preferences.terminalChoice
        let terminal: URL? = choice == "auto"
            ? (ws.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2")
               ?? ws.urlForApplication(withBundleIdentifier: "com.apple.Terminal"))
            : ws.urlForApplication(withBundleIdentifier: choice)
        guard let terminal else { NSSound.beep(); return }
        ws.open([dir], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: Quick Look（空格开关；方向键经 selectionDidChange 连续预览）

    /// I-45：收起走淡出而非"缩到图标"（用户嫌缩放突兀）——收起前置位，sourceFrame 返回 .zero
    /// 令 QL 用淡出（直接消失）；开启时复位以保留从图标放大的进入手感。QL 关闭时会重查 sourceFrame。
    private var quickLookDismissing = false

    @objc func toggleQuickLook(_ sender: Any?) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            quickLookDismissing = true
            panel.orderOut(nil)
        } else if !selectedItems.isEmpty {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        quickLookDismissing = false
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    @objc func showPackageContents(_ sender: Any?) {
        guard let pkg = selectedItems.first(where: { $0.isPackage }) else { return }
        onNavigate?(pkg.url)
    }

    /// UITEST 专用（I-45）：验证 QL 收起态 sourceFrame 退化为 .zero（→ 淡出/直接消失），
    /// 开启态为行内图标矩形（→ 从图标放大）。QL 面板动画本身无法无头断言，此处只验分支逻辑。
    func uiTestQLSourceFrame(dismissing: Bool, for url: URL) -> NSRect {
        quickLookDismissing = dismissing
        let r = previewPanel(nil, sourceFrameOnScreenFor: url as NSURL)
        quickLookDismissing = false
        return r
    }
}

// MARK: - 菜单校验（按选中态启用/禁用）

extension FileListViewController: @preconcurrency NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let hasSelection = !tableView.selectedRowIndexes.isEmpty
        let single = tableView.selectedRowIndexes.count == 1
        switch menuItem.action {
        case #selector(copyItems(_:)), #selector(cutItems(_:)), #selector(copyPath(_:)),
             #selector(duplicateItems(_:)), #selector(moveToTrash(_:)), #selector(openSelected(_:)),
             #selector(copyToOtherPane(_:)), #selector(moveToOtherPane(_:)),
             #selector(copy(_:)), #selector(cut(_:)), #selector(airdropSelected(_:)),
             #selector(compressItems(_:)):
            return hasSelection
        case #selector(extractItems(_:)), #selector(extractItemsTo(_:)):
            return !selectedArchiveURLs.isEmpty
        case #selector(renameSelected(_:)):
            return single
        case #selector(toggleGrouping(_:)):
            menuItem.state = Preferences.listGrouping ? .on : .off
            return true
        case #selector(pasteItems(_:)), #selector(paste(_:)):
            return pasteboardHasFiles
        default:
            return true
        }
    }

    private var pasteboardHasFiles: Bool {
        NSPasteboard.general.canReadObject(forClasses: [NSURL.self],
                                           options: [.urlReadingFileURLsOnly: true])
    }
}

// MARK: - 列头右键菜单（可选列勾选，QSpace 式）

extension FileListViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let visible = Preferences.visibleColumns
        for c in Self.optionalColumns {
            let item = menu.addItem(withTitle: L10n.t(c.titleKey),
                                    action: #selector(toggleColumn(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = c.id
            item.state = visible.contains(c.id) ? .on : .off
        }
        menu.addItem(.separator())
        let reset = menu.addItem(withTitle: L10n.t("column.reset"),
                                 action: #selector(resetColumns(_:)), keyEquivalent: "")
        reset.target = self
    }

    @objc private func resetColumns(_ sender: Any?) {
        Preferences.visibleColumns = ["dateModified", "size", "kind"]
        NotificationCenter.default.post(name: .nspaceColumnsChanged, object: nil)
    }
}

extension Notification.Name {
    static let nspaceColumnsChanged = Notification.Name("nspaceColumnsChanged")
    /// 分组开关变更（显示菜单「使用分组」/ 设置项）：所有列表窗格重建行序即时生效
    static let nspaceGroupingChanged = Notification.Name("nspaceGroupingChanged")
}

// MARK: - 数据源 / 委托

extension FileListViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        listRows.count
    }

    // MARK: 组行机制（M26）：isGroupRow + 组头不可选 + 组头行高 24

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        isGroupRow(row)
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        !isGroupRow(row)
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        isGroupRow(row) ? 24 : Self.rowHeight(for: Formatters.listFontSize)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        // 组头行：整行铺满的组头视图（仅首列构建一次，其余列返回 nil）
        if isGroupRow(row) {
            guard tableColumn == nil || tableColumn == tableView.tableColumns.first else { return nil }
            guard case .group(_, let title, let count, let collapsed) = listRows[row] else { return nil }
            let cell = tableView.makeView(withIdentifier: .init("groupHeader"), owner: nil) as? GroupHeaderView
                ?? GroupHeaderView(identifier: .init("groupHeader"))
            cell.configure(title: title, count: count, collapsed: collapsed)
            return cell
        }
        guard let colID = tableColumn?.identifier.rawValue, let item = item(atRow: row) else { return nil }

        if colID == "name" {
            let cell = tableView.makeView(withIdentifier: .init("nameCell"), owner: nil) as? NameCellView
                ?? NameCellView(identifier: .init("nameCell"))
            let cut = coordinator?.isCut(item.url) ?? false
            // 快路径先出类型图标；已到货的内容缩略图直接用（升级路径见 requestThumbnail）
            cell.configure(icon: thumbOverlay[item.url] ?? Formatters.icon(for: item),
                           name: item.name, dimmed: item.isHidden || cut)
            return cell
        }

        let cell = tableView.makeView(withIdentifier: .init("textCell"), owner: nil) as? TextCellView
            ?? TextCellView(identifier: .init("textCell"))
        switch colID {
        case "dateModified":
            cell.configure(item.modified.map { Formatters.relativeDate($0) } ?? "—", alignment: .left, monospacedDigits: true)
        case "created":
            cell.configure(item.created.map { Formatters.relativeDate($0) } ?? "—", alignment: .left, monospacedDigits: true)
        case "added":
            cell.configure(item.added.map { Formatters.relativeDate($0) } ?? "—", alignment: .left, monospacedDigits: true)
        case "size":
            // 文件用快照字节数；目录快照为 nil → 已回填的 FolderSize 结果，否则占位"—"
            if let bytes = item.size ?? sizeOverlay[item.url] {
                let parts = Formatters.sizeParts(fromByteCount: bytes)
                cell.configureSize(value: parts.value, unit: parts.unit, alignment: .right)
            } else {
                cell.configure("—", alignment: .right, monospacedDigits: true)
            }
        case "kind":
            cell.configure(Formatters.kind(forTypeID: item.contentTypeID, isDirectory: item.isDirectory), alignment: .left)
        default:
            cell.configure("", alignment: .left)
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let d = tableView.sortDescriptors.first, let key = d.key,
              let sortKey = SortSpec.Key(rawValue: key) else { return }
        model.sort = SortSpec(key: sortKey, ascending: d.ascending, foldersFirst: model.sort.foldersFirst)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        // I-32：选中真源记账（用户点选/程序化 select 都经此；reloadData 本身不触发，故缓存保留删除前值）
        selectionURLCache = Set(selectedURLs)
        onSelectionChange?()
        if QLPreviewPanel.sharedPreviewPanelExists(),
           let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.reloadData()
        }
    }

    // MARK: 拖拽源（可拖到 Finder/其他 App/另一窗格/侧边栏书签/暂存架）

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard let item = item(atRow: row) else { return nil }   // 组头行不可拖
        return item.url as NSURL
    }

    // MARK: 投放目标（BG-1：落点只发意图，kind 判定与提交在 coordinator）

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        guard let urls = Self.draggedFileURLs(info), !urls.isEmpty else {
            cancelSpringLoad(); return []
        }
        // 落点归一：目录行=投进该文件夹；文件行/组头/空白=投进当前目录
        var targetRow = -1
        if op == .on, let it = item(atRow: row), it.isDirectory, !it.isPackage {
            targetRow = row
        }
        let target = targetRow >= 0 ? (item(atRow: targetRow)?.url ?? currentDirectory) : currentDirectory
        // 拒绝把目录投进它自己/子孙
        guard urls.allSatisfy({ !FileOpsCoordinator.isSelfOrDescendant(destination: target, ofSource: $0) }) else {
            cancelSpringLoad(); return []
        }
        // ⌥ 按下时 AppKit 已把源掩码过滤为 .copy
        let optionCopy = info.draggingSourceOperationMask == .copy
        // 落点是移动还是复制：按拖放偏好 + ⌥ 统一判定（视觉反馈与实际提交共用同一逻辑）
        let willMove = FileOpsCoordinator.effectiveMove(urls: urls, into: target, optionCopy: optionCopy)
        // 移动落在同目录是无操作 → 拒绝（复制放行，语义=制作副本）
        let destPath = target.standardizedFileURL.path
        if willMove, urls.allSatisfy({ $0.standardizedFileURL.deletingLastPathComponent().path == destPath }) {
            cancelSpringLoad(); return []
        }
        if targetRow >= 0 {
            tableView.setDropRow(targetRow, dropOperation: .on)
            scheduleSpringLoad(row: targetRow, url: target)
        } else {
            tableView.setDropRow(-1, dropOperation: .on)  // 整表高亮 = 投进当前目录
            cancelSpringLoad()
        }
        // 光标反馈与实际提交一致（同卷移动 / 跨卷复制 / 偏好覆盖）
        return willMove ? .move : .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo,
                   row: Int, dropOperation op: NSTableView.DropOperation) -> Bool {
        cancelSpringLoad()
        guard let urls = Self.draggedFileURLs(info), !urls.isEmpty else { return false }
        var target = currentDirectory
        if op == .on, let it = item(atRow: row), it.isDirectory, !it.isPackage {
            target = it.url
        }
        coordinator?.dropTransfer(urls: urls, into: target,
                                  forceCopy: info.draggingSourceOperationMask == .copy)
        return true
    }

    private static func draggedFileURLs(_ info: any NSDraggingInfo) -> [URL]? {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                            options: [.urlReadingFileURLsOnly: true]) as? [URL]
    }

    // MARK: spring-loaded：拖拽悬停文件夹行 ~0.8s 自动导航进入（计时器实现，简单可靠优先）

    private func scheduleSpringLoad(row: Int, url: URL) {
        guard springLoad?.row != row else { return }
        cancelSpringLoad()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.cancelSpringLoad()
                self.onNavigate?(url)
            }
        }
        springLoad = (row, timer)
    }

    func cancelSpringLoad() {
        springLoad?.timer.invalidate()
        springLoad = nil
    }
}

// MARK: - Quick Look 数据源/委托（多选预览；面板内方向键翻页由 QL 自持）

extension FileListViewController: @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        selectedItems.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        let urls = selectedURLs
        guard index >= 0, index < urls.count else { return nil }
        return urls[index] as NSURL
    }

    /// 面板收到键盘事件先转回表（空格关面板由面板自己处理；方向键落回列表推进选中）
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown, event.keyCode == 125 || event.keyCode == 126 else { return false }
        focusTarget.keyDown(with: event)
        return true
    }

    /// 缩放动画起点=行内图标位置（Finder 手感）；收起时返回 .zero → QL 淡出（I-45 不再缩到图标）
    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: (any QLPreviewItem)!) -> NSRect {
        if quickLookDismissing { return .zero }
        guard let url = (item as? NSURL) as URL?,
              let row = row(forURL: url),
              let window = view.window else { return .zero }
        let rect = focusTarget.convert(NSRect(x: 4, y: 0, width: 22, height: 22)
            .offsetBy(dx: 0, dy: (focusTarget as! NSTableView).rect(ofRow: row).minY), to: nil)
        return window.convertToScreen(rect)
    }
}

// MARK: - 过滤态药丸（FG-1：10% 药丸，克制样式，深浅色自适应重解析）

@MainActor
final class FilterPillButton: NSButton {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        isBordered = false
        bezelStyle = .inline
        font = .systemFont(ofSize: 11)
        contentTintColor = .secondaryLabelColor
        imagePosition = .imageRight
        imageHugsTitle = true
        image = NSImage.officialSymbol("xmark.circle.fill", accessibility: L10n.t("group.filter.all"))
        symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建 UI，无 xib") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let base = NSColor.controlBackgroundColor
            let bg = base.blended(withFraction: 0.10, of: Theme.accent) ?? base   // 10% 药丸
            layer?.backgroundColor = bg.cgColor
            layer?.cornerRadius = 8
        }
    }
}

// MARK: - UISelfTest 探针（M26：只读断言入口，非产品路径）

extension FileListViewController {
    /// 组头行数（分组断言用）
    var uiTestGroupHeaderCount: Int {
        listRows.reduce(0) { if case .group = $1 { return $0 + 1 }; return $0 }
    }
    /// 组头标题串（按行序）
    var uiTestGroupTitles: [String] {
        listRows.compactMap { if case .group(_, let t, _, _) = $0 { return t }; return nil }
    }
    /// 组头（标题, 项数, 折叠）三元组（按行序）
    var uiTestGroups: [(title: String, count: Int, collapsed: Bool)] {
        listRows.compactMap {
            if case .group(_, let t, let c, let col) = $0 { return (t, c, col) }
            return nil
        }
    }
    /// 组键（稳定键，按行序）
    var uiTestGroupKeys: [String] {
        listRows.compactMap { if case .group(let k, _, _, _) = $0 { return k }; return nil }
    }
    /// 当前展示行总数
    var uiTestRowCount: Int { listRows.count }
    /// 项行数（非组头行）
    var uiTestItemRowCount: Int {
        listRows.reduce(0) { if case .item = $1 { return $0 + 1 }; return $0 }
    }
    /// 过滤态药丸是否可见
    var uiTestFilterPillVisible: Bool { !filterPill.isHidden }
    /// 分组是否生效（偏好开 + 日期排序键）
    var uiTestGroupingActive: Bool { groupingActive }
    /// 驱动组头点击折叠（真实处理路径）
    func uiTestClickGroupRow(_ row: Int) { handleGroupRowClick(row) }
    /// 首个非组头（项）行的表行号
    var uiTestFirstItemRow: Int? {
        for (r, lr) in listRows.enumerated() { if case .item = lr { return r } }
        return nil
    }
}

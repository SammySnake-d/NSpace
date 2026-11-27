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
final class FileListViewController: NSViewController, FilePaneContent, FilePaneExtendedActions {
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
    private let scrollView = BlankAreaScrollView()
    /// 列表底部恒留的空白高度（4pt 阶梯）：专门接"空白处右键"
    static let blankTailHeight: CGFloat = 40
    private let emptyLabel = NSTextField(labelWithString: "")

    /// 操作完成后待显露（选中/进入重命名/是否抢焦点）的目标
    private var pendingReveal: (url: URL, rename: Bool, focus: Bool)?

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
        case group(key: String, title: String, count: Int)
        case item(Int)   // 下标指向 model.items
    }
    private var listRows: [ListRow] = []
    /// 已折叠组键集合（重组时据此决定是否铺开组内项）
    // 折叠已取消（用户要求：分组头印在背景条上，不是可伸缩控件）。
    // 不留恒空集合——那会留下"看着能折其实不能"的半截实现。
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
    private let renameCoordinator = InlineRenameCoordinator()
    private let qlBridge = FileQuickLookBridge()
    var isPaneActiveProvider: (() -> Bool)?
    var onFocusBreadcrumb: (() -> Void)?
    var isEditingName: Bool { renameCoordinator.isEditing }
    var hasOtherPane: Bool { (coordinator?.grid?.visiblePaneCount ?? 1) > 1 }
    var isGrouped: Bool { Preferences.listGrouping }
    func focusFileView() { view.window?.makeFirstResponder(tableView) }
    func selectAllItems() { tableView.selectAll(nil) }
    func renameSelection() { beginRenameSelected() }

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
        // 单击已选中项 → 重命名（用户报告：只有 Enter 能触发）。谓词与延迟在表视图里，
        // 这里只接落点；废纸篓里不给改名（改了也只是改废纸篓里那份，没意义）
        tableView.onSingleClickRename = { [weak self] row in
            guard let self, !TrashLocation.isInsideTrash(self.currentDirectory) else { return }
            self.beginRename(row: row)
        }
        tableView.isPaneActiveProvider = { [weak self] in
            self?.isPaneActiveProvider?() ?? true
        }
        tableView.itemURLProvider = { [weak self] row in
            self?.item(atRow: row)?.url
        }
        tableView.rowForURLProvider = { [weak self] url in
            self?.row(forURL: url)
        }
        tableView.onOpenSelected = { [weak self] in self?.openSelected(nil) }
        tableView.onBackspaceAction = { [weak self] in self?.handleBackspace() }
        tableView.onSpace = { [weak self] in self?.toggleQuickLook(nil) }
        tableView.onDragExited = { [weak self] in self?.cancelSpringLoad() }
        tableView.isGroupRowProvider = { [weak self] row in self?.isGroupRow(row) ?? false }
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

        addColumn(id: "name", title: L10n.t("column.name"), width: 216, min: 110, sortable: true)
        rebuildOptionalColumns()
        // 列头右键：QSpace 式可选列勾选
        let headerMenu = NSMenu()
        headerMenu.delegate = self
        tableView.headerView?.menu = headerMenu

        scrollView.documentView = tableView
        // 底部恒留一块可右键的空白（用户报告：内容铺满时「没有留出空白的位置，我没有地方点」）。
        // 走 contentInsets 而不是加假行：表的数据源不被污染，且这块区域落在 clip view 上，
        // 由 BlankAreaScrollView.menu(for:) 出目录级菜单。
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: Self.blankTailHeight, right: 0)
        scrollView.onBlankMenu = { [weak self] in self?.buildMenu(clickedRow: -1) }
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
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
        syncSortIndicatorFromModel()   // I-58：首次装载即挂上指示器（新窗格不再显示成"名称"）
        model.reload()
    }

    /// 可选列注册表（名称恒在；I-26：全列可点击列头排序，id 与 SortSpec.Key 原始值一一对应）
    static let optionalColumns: [(id: String, titleKey: String, width: CGFloat, min: CGFloat, right: Bool, sortable: Bool)] = [
        ("dateModified", "column.dateModified", 108, 84, false, true),
        ("created", "column.created", 108, 84, false, true),
        ("added", "column.added", 108, 84, false, true),
        ("size", "column.size", 64, 48, true, true),
        ("kind", "column.kind", 84, 60, false, true),
    ]

    private var isRebuildingColumns = false

    private func addColumn(id: String, title: String, width: CGFloat, min: CGFloat,
                           rightAlign: Bool = false, sortable: Bool = false) {
        let col = NSTableColumn(identifier: .init(id))
        col.title = title
        let saved = Preferences.columnWidths[id]
        col.width = max(min, saved ?? width)
        col.minWidth = min
        col.resizingMask = [.userResizingMask, .autoresizingMask]
        if sortable { col.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true) }
        if rightAlign { col.headerCell.alignment = .right }
        tableView.addTableColumn(col)
    }

    /// 按偏好重建可选列（列头勾选变化时调用）
    private func rebuildOptionalColumns() {
        isRebuildingColumns = true
        for col in tableView.tableColumns where col.identifier.rawValue != "name" {
            tableView.removeTableColumn(col)
        }
        let visible = Preferences.visibleColumns
        for c in Self.optionalColumns where visible.contains(c.id) {
            addColumn(id: c.id, title: L10n.t(c.titleKey), width: c.width, min: c.min,
                      rightAlign: c.right, sortable: c.sortable)
        }
        isRebuildingColumns = false
        syncSortIndicatorFromModel()   // I-58：列被移除再加回，指示器会丢，须重挂
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
        _ = renameCoordinator.runOrDefer { [weak self] in
            self?.performApplySnapshot()
        }
    }

    private func performApplySnapshot() {
        // 目录切换：取消所有在飞装饰请求，清空回填结果（跨目录 URL 不复用）
        if lastSnapshotDirectory != model.directory {
            lastSnapshotDirectory = model.directory
            cancelDecorationWork()
            sizeOverlay.removeAll()
        }
        // 同目录刷新也清缩略图覆盖层：文件可能已改内容（IconThumb 缓存键含 mtime，重取要么命中要么重生成）
        thumbOverlay.removeAll()
        emptyLabel.isHidden = true
        syncSortIndicatorFromModel()   // I-58：列头箭头跟上 model.sort（恢复/切目录后不再停在"名称"）
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
            showEmptyState(L10n.t(model.isFiltering ? "filter.empty" : "empty.folder"))
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
    /// 仅重绘（剪切灰显变化）。
    /// **不能用 reloadData()**：它会把选中清空，而"重绘"语义里行没变、选中就不该变
    /// （用户报告：⌘C 之后选中框消失）。按行/列重载会保留选中。
    func redraw() {
        guard tableView.numberOfRows > 0, tableView.numberOfColumns > 0 else { return }
        tableView.reloadData(forRowIndexes: IndexSet(integersIn: 0..<tableView.numberOfRows),
                             columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns))
    }

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
        let groups = FileGrouping.buckets(model.items, key: model.sort.key, ascending: model.sort.ascending)
        var titles: [String: String] = [:]
        for g in groups { titles[g.key] = g.title }
        // 过滤态失效自愈：被过滤组已不存在（换目录/排序键）→ 清过滤
        if let only = groupFilterKey, !groups.contains(where: { $0.key == only }) { groupFilterKey = nil }
        for g in groups where groupFilterKey == nil || groupFilterKey == g.key {
            listRows.append(.group(key: g.key, title: g.title, count: g.indices.count))
            for i in g.indices { listRows.append(.item(i)) }
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
        // 标准化路径比较 + 大小写兜底，判据统一在 model.itemIndex(forURL:)（I-39/I-55）
        guard let idx = model.itemIndex(forURL: url) else { return nil }
        return row(forItemIndex: idx)
    }

    /// 该行是否组头行
    func isGroupRow(_ row: Int) -> Bool {
        guard listRows.indices.contains(row) else { return false }
        if case .group = listRows[row] { return true }
        return false
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
            guard col >= 0,
                  let cell = self.tableView.view(atColumn: col, row: row, makeIfNecessary: false) as? TextCellView else { return }
            let parts = Formatters.sizeParts(fromByteCount: size)
            cell.configureSize(value: parts.value, unit: parts.unit, alignment: .right)
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
            let nameCol = max(0, self.tableView.column(withIdentifier: .init("name")))
            guard let row = self.row(forURL: url),
                  let cell = self.tableView.view(atColumn: nameCol, row: row, makeIfNecessary: false)
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

    func prepareReveal(_ url: URL, rename: Bool, focus: Bool) {
        pendingReveal = (url, rename, focus)
    }

    func takePendingReveal() -> (url: URL, rename: Bool)? {
        defer { pendingReveal = nil }
        guard let pendingReveal else { return nil }
        return (pendingReveal.url, pendingReveal.rename)
    }

    /// UISelfTest（I-55）：是否还挂着待定位目标——用于验证落空的 pending 会被就地作废，
    /// 不会留成日后突然"幽灵跳选"并抢键盘焦点的定时炸弹
    var uiTestHasPendingReveal: Bool { pendingReveal != nil }

    func computedSize(for url: URL) -> Int64? { sizeOverlay[url] }

    private func revealPendingIfPossible() {
        guard let pending = pendingReveal else { return }
        guard let row = row(forURL: pending.url) else {
            if model.isLoadedDirectory(forParentOf: pending.url) { pendingReveal = nil }
            return
        }
        pendingReveal = nil
        tableView.selectRowIndexes([row], byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
        if pending.focus && !pending.rename { view.window?.makeFirstResponder(tableView) }
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
            coordinator?.recordAccess(item.url)   // M28：打开文件 = 一次使用记账
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
        if isGroupRow(row), case .group(let key, _, _) = listRows[row] {
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
        guard !TrashLocation.isInsideTrash(currentDirectory),
              let item = item(atRow: row) else { return }
        let nameCol = max(0, tableView.column(withIdentifier: .init("name")))
        tableView.scrollRowToVisible(row)
        guard let cell = tableView.view(atColumn: nameCol, row: row, makeIfNecessary: true) as? NameCellView
        else { return }
        cell.beginRename(
            for: item,
            using: renameCoordinator,
            hostView: tableView,
            prepareVisibleFrame: { [weak self] in
                self?.tableView.scrollRowToVisible(row)
            },
            onCommit: { [weak self] newName in
                await self?.submitRenameAndAwaitURL(item, newName: newName, fallbackRow: row)
            },
            onFinish: { [weak self] renamedURL, restoreFocus in
                guard let self else { return }
                if let renamedURL {
                    self.prepareReveal(renamedURL, rename: false, focus: restoreFocus)
                    self.model.reload()
                } else if restoreFocus {
                    self.view.window?.makeFirstResponder(self.tableView)
                }
            },
            onTabStep: { [weak self] anchorURL, forward in
                self?.beginRenameAdjacent(from: anchorURL, forward: forward)
            }
        )
    }

    private func beginRenameAdjacent(from anchorURL: URL, forward: Bool) {
        guard let curIdx = model.itemIndex(forURL: anchorURL) else { return }
        let nextIdx = forward ? curIdx + 1 : curIdx - 1
        guard nextIdx >= 0, nextIdx < model.items.count else { return }
        let nextURL = model.items[nextIdx].url
        guard let row = row(forURL: nextURL) else { return }
        tableView.selectRowIndexes([row], byExtendingSelection: false)
        beginRename(row: row)
    }

    private func submitRenameAndAwaitURL(_ item: FileItem, newName: String, fallbackRow: Int) async -> URL? {
        guard let coordinator else { return nil }
        return await withCheckedContinuation { continuation in
            coordinator.rename(item.url, to: newName) { [weak self] ok in
                if !ok {
                    if let r = self?.row(forURL: item.url)
                        ?? (fallbackRow < (self?.tableView.numberOfRows ?? 0) ? fallbackRow : nil) {
                        self?.flashRenameError(row: r)
                    }
                    continuation.resume(returning: nil)
                } else {
                    let renamed = item.url.deletingLastPathComponent().appendingPathComponent(newName)
                    continuation.resume(returning: renamed)
                }
            }
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

    // 复制/剪切/粘贴/拷贝路径/批量操作（统一委托 FileViewActions）
    @objc func copyItems(_ sender: Any?) { FileViewActions.copyItems(pane: self) }
    @objc func cutItems(_ sender: Any?) { FileViewActions.cutItems(pane: self) }
    @objc func putBackItems(_ sender: Any?) { FileViewActions.putBackItems(pane: self) }

    // ---- 自测通道（I-65）----
    var uiTestBottomInset: CGFloat { scrollView.contentInsets.bottom }
    func uiTestBlankAreaMenu() -> NSMenu? { scrollView.onBlankMenu?() }

    @objc func pasteItems(_ sender: Any?) { FileViewActions.pasteItems(pane: self) }
    @objc func moveItemsHere(_ sender: Any?) { FileViewActions.moveItemsHere(pane: self) }
    @objc func copyPath(_ sender: Any?) { copyPath(to: .general) }

    /// 自测注入私有 pasteboard 用（产品路径恒走 .general）
    func copyPath(to pasteboard: NSPasteboard) {
        FileViewActions.copyPath(pane: self, to: pasteboard)
    }
    @objc func copyNames(_ sender: Any?) { FileViewActions.copyNames(pane: self) }
    @objc func copy(_ sender: Any?) { copyItems(sender) }
    @objc func cut(_ sender: Any?) { cutItems(sender) }
    @objc func paste(_ sender: Any?) { pasteItems(sender) }

    @objc func duplicateItems(_ sender: Any?) { FileViewActions.duplicateItems(pane: self) }
    @objc func moveToTrash(_ sender: Any?) { FileViewActions.moveToTrash(pane: self) }
    @objc func deleteImmediately(_ sender: Any?) { FileViewActions.deleteImmediately(pane: self) }
    @objc func newFolderWithSelection(_ sender: Any?) { FileViewActions.newFolderWithSelection(pane: self) }
    @objc func batchRenameItems(_ sender: Any?) { FileViewActions.batchRenameItems(pane: self) }
    @objc func compressItems(_ sender: Any?) { FileViewActions.compressItems(pane: self) }
    @objc func extractItems(_ sender: Any?) { FileViewActions.extractItems(pane: self) }
    @objc func extractItemsTo(_ sender: Any?) { FileViewActions.extractItemsTo(pane: self) }

    /// 选中项里可解压的归档 URL（右键"解压"据此过滤）
    private var selectedArchiveURLs: [URL] {
        selectedItems.filter(\.isArchive).map(\.url)
    }
    @objc func newFolderHere(_ sender: Any?) { FileViewActions.newFolderHere(pane: self) }
    @objc func newFileHere(_ sender: Any?) { FileViewActions.newFileHere(pane: self) }
    @objc func renameSelected(_ sender: Any?) { beginRenameSelected() }
    @objc func copyToOtherPane(_ sender: Any?) { coordinator?.copyToOtherPane(selectedURLs) }
    @objc func moveToOtherPane(_ sender: Any?) { coordinator?.moveToOtherPane(selectedURLs) }

    @objc func openSelected(_ sender: Any?) { FileViewActions.openSelected(pane: self) }
    @objc func openWithApp(_ sender: Any?) { FileViewActions.openWithApp(pane: self, sender: sender) }
    @objc func openWithOther(_ sender: Any?) { FileViewActions.openWithOther(pane: self) }
    @objc func airdropSelected(_ sender: Any?) { FileViewActions.airdropSelected(pane: self) }
    @objc func getInfo(_ sender: Any?) { FileViewActions.getInfo(pane: self) }
    @objc func openInTerminal(_ sender: Any?) { FileViewActions.openInTerminal(pane: self) }

    // MARK: Quick Look（空格开关；方向键经 selectionDidChange 连续预览）

    @objc func toggleQuickLook(_ sender: Any?) {
        qlBridge.toggle(urls: selectedURLs) { [weak self] url in
            self?.iconScreenRect(for: url) ?? .zero
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            qlBridge.quickLookDismissing = false
            panel.dataSource = self
            panel.delegate = self
            qlBridge.updateIfVisible(urls: selectedURLs) { [weak self] url in
                self?.iconScreenRect(for: url) ?? .zero
            }
        }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
        }
    }

    @objc func showPackageContents(_ sender: Any?) { FileViewActions.showPackageContents(pane: self) }

    /// UITEST 专用（I-45）：验证 QL 收起态 sourceFrame 退化为 .zero（→ 淡出/直接消失），
    /// 开启态为行内图标矩形（→ 从图标放大）。QL 面板动画本身无法无头断言，此处只验分支逻辑。
    func uiTestQLSourceFrame(dismissing: Bool, for url: URL) -> NSRect {
        qlBridge.quickLookDismissing = dismissing
        let r = previewPanel(nil, sourceFrameOnScreenFor: url as NSURL)
        qlBridge.quickLookDismissing = false
        return r
    }
}

// MARK: - 菜单校验（按选中态启用/禁用）

extension FileListViewController: @preconcurrency NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        FileViewActions.validateMenuItem(menuItem, pane: self)
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
        Preferences.columnWidths = [:]
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
            guard case .group(_, let title, let count) = listRows[row] else { return nil }
            let cell = tableView.makeView(withIdentifier: .init("groupHeader"), owner: nil) as? GroupHeaderView
                ?? GroupHeaderView(identifier: .init("groupHeader"))
            cell.configure(title: title, count: count)
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
        // I-50：改排序即落盘（否则排序只在干净退出才保存，非干净退出重启回退到旧排序）——同 I-47 导航即落盘
        (NSApp.delegate as? AppDelegate)?.noteStateChanged()
    }

    /// 把 model.sort 反向同步到列头指示器（I-58）。
    /// 此前数据流是**单向**的：只有「用户点列头 → sortDescriptorsDidChange → model.sort」，
    /// 没有反向。于是会话恢复、新建窗格/标签、重建可选列之后，数据按 model.sort 排对了，
    /// 列头的排序箭头却停在默认的「名称」上——用户看到的就是「排序状态丢了」。
    /// 列 id 与 SortSpec.Key.rawValue 一一对应（addColumn 用同一 id 建 sortDescriptorPrototype）。
    private func syncSortIndicatorFromModel() {
        let wanted = NSSortDescriptor(key: model.sort.key.rawValue, ascending: model.sort.ascending)
        let current = tableView.sortDescriptors.first
        // 已一致就别赋值：赋值会回调 sortDescriptorsDidChange，白白触发一次落盘
        guard current?.key != wanted.key || current?.ascending != wanted.ascending else { return }
        tableView.sortDescriptors = [wanted]
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        // I-32：选中真源记账（用户点选/程序化 select 都经此；reloadData 本身不触发，故缓存保留删除前值）
        selectionURLCache = Set(selectedURLs)
        onSelectionChange?()
        qlBridge.updateIfVisible(urls: selectedURLs) { [weak self] url in
            self?.iconScreenRect(for: url) ?? .zero
        }
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        item(atRow: row)?.name
    }

    func tableViewColumnDidResize(_ notification: Notification) {
        guard !isRebuildingColumns, tableView.inLiveResize,
              let col = notification.userInfo?["NSTableColumn"] as? NSTableColumn else { return }
        var widths = Preferences.columnWidths
        widths[col.identifier.rawValue] = col.width
        Preferences.columnWidths = widths
    }

    private func iconScreenRect(for url: URL) -> NSRect {
        guard let row = row(forURL: url), let window = view.window else { return .zero }
        let nameCol = max(0, tableView.column(withIdentifier: .init("name")))
        let cellRect = tableView.frameOfCell(atColumn: nameCol, row: row)
        let iconRect = NSRect(x: cellRect.minX + 4, y: cellRect.minY + 2, width: 16, height: 16)
        return window.convertToScreen(tableView.convert(iconRect, to: nil))
    }

    // MARK: 拖拽源（可拖到 Finder/其他 App/另一窗格/侧边栏书签/暂存架）

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        // I-43：AppKit 起拖时才调本方法——置位供 mouseDown 区分"拖拽"与"纯单击已选中行"
        (tableView as? FocusReportingTableView)?.dragInitiated = true
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
        qlBridge.count()
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        qlBridge.item(at: index)
    }

    /// 面板收到键盘事件先转回表（空格关面板由面板自己处理；方向键落回列表推进选中）
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown, event.keyCode == 125 || event.keyCode == 126 else { return false }
        focusTarget.keyDown(with: event)
        return true
    }

    /// 缩放动画起点=行内图标位置（Finder 手感）；收起时返回 .zero → QL 淡出（I-45 不再缩到图标）
    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: (any QLPreviewItem)!) -> NSRect {
        qlBridge.sourceFrame(on: panel, for: item) { [weak self] url in
            self?.iconScreenRect(for: url) ?? .zero
        }
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
        listRows.compactMap { if case .group(_, let t, _) = $0 { return t }; return nil }
    }
    /// 组头（标题, 项数）二元组（按行序）。折叠已取消，所以不再有第三项。
    var uiTestGroups: [(title: String, count: Int)] {
        listRows.compactMap {
            if case .group(_, let t, let c) = $0 { return (t, c) }
            return nil
        }
    }
    /// 组键（稳定键，按行序）
    var uiTestGroupKeys: [String] {
        listRows.compactMap { if case .group(let k, _, _) = $0 { return k }; return nil }
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
    /// 走表视图**真实** mouseDown 分支点组头（不复刻判定：接线断了这条才会红）
    func uiTestClickGroupRowRaw(_ row: Int) {
        let rect = tableView.rect(ofRow: row)
        guard let win = view.window,
              let ev = NSEvent.mouseEvent(with: .leftMouseDown,
                                          location: tableView.convert(NSPoint(x: rect.midX, y: rect.midY),
                                                                      to: nil),
                                          modifierFlags: [],
                                          timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: win.windowNumber, context: nil,
                                          eventNumber: 0, clickCount: 1, pressure: 1) else { return }
        tableView.mouseDown(with: ev)
    }
    /// 选中第一个项行（组头不可选，所以要跳过组头）
    /// 按 URL 集选中（走真实选中变更链）
    func uiTestSelect(urls: [URL]) {
        let wanted = Set(urls.map(\.standardizedFileURL.path))
        var idx = IndexSet()
        for (r, lr) in listRows.enumerated() {
            guard case .item(let i) = lr, model.items.indices.contains(i) else { continue }
            if wanted.contains(model.items[i].url.standardizedFileURL.path) { idx.insert(r) }
        }
        tableView.selectRowIndexes(idx, byExtendingSelection: false)
    }
    /// 视图层**原始**选中行数（直查 tableView，不经任何缓存——
    /// reloadData 清空选中这类问题只有直查才看得见）
    var uiTestRawSelectionCount: Int { tableView.selectedRowIndexes.count }

    func uiTestSelectFirstItem() {
        guard let r = uiTestFirstItemRow else { return }
        tableView.selectRowIndexes([r], byExtendingSelection: false)
    }
    /// 组头单元格真有底色（"印在背景条上"验的是这个，不是验没崩）
    var uiTestGroupHeaderIsBackgroundBar: Bool {
        guard let r = listRows.firstIndex(where: { if case .group = $0 { return true }; return false }),
              let cell = tableView.view(atColumn: 0, row: r, makeIfNecessary: true) as? GroupHeaderView,
              let bg = cell.layer?.backgroundColor else { return false }
        return bg.alpha > 0.01
    }

    /// 首个非组头（项）行的表行号
    var uiTestFirstItemRow: Int? {
        for (r, lr) in listRows.enumerated() { if case .item = lr { return r } }
        return nil
    }
}

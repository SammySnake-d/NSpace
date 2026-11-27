import AppKit
import QuickLookUI
import NSpaceContracts
import DirectoryReader
import IconThumb

/// Miller 分栏视图（M9 ⌘3，QSpace/Finder 式）：水平滚动 NSStackView 排多列，
/// 每列 = 一个单列 NSTableView（图标+名，行高 22，列宽 220 固定 v1）。
/// 点选目录 → 右侧展开子列（截断其右所有列）；点选文件 → 最右简单预览列。
/// 导航联动（QSpace 语义）：下钻经 onNavigate 上抛改地址栏；showDirectory 回流按
/// 路径前缀判断"沿当前列链下钻原地扩列"或"跳转重建列链"。
/// 列加载自管：每列局部 DirectoryReader 实例、加载在 Task 中，列销毁/挂起即取消——
/// 不动共享 model 的数据源语义（切回列表零成本），窗格挂起时列加载一并停（北极星）。
@MainActor
final class FileColumnViewController: NSViewController, FilePaneContent, FilePaneExtendedActions {
    /// 只读消费共享 model 的配置（includeHidden/sort/filterQuery）与 FSEvents 联动；列内容不经它
    let model: DirectoryViewModel
    weak var coordinator: FileOpsCoordinator?
    var onNavigate: ((URL) -> Void)?
    var onInteract: (() -> Void)?
    var onSelectionChange: (() -> Void)?
    var isPaneActiveProvider: (() -> Bool)?

    private let hScroll = NSScrollView()
    private let stack = NSStackView()
    private(set) var columns: [ColumnUnit] = []   // setter 私有；UISelfTest 内容级断言需读
    private var preview: PreviewColumnView?
    private var focusedColumnIndex = 0
    private let renameCoordinator = InlineRenameCoordinator()
    private let qlBridge = FileQuickLookBridge()
    private var pendingReveal: (url: URL, rename: Bool, focus: Bool)?

    /// 挂起态：置位期间列加载全取消、showDirectory 只记 pending（恢复时重建）
    private var suspended = false
    private var pendingDirectory: URL?

    var focusTarget: NSView {
        columns.indices.contains(focusedColumnIndex) ? columns[focusedColumnIndex].tableView : view
    }
    var isEditingName: Bool { renameCoordinator.isEditing }
    var hasOtherPane: Bool { (coordinator?.grid?.visiblePaneCount ?? 1) > 1 }
    var isGrouped: Bool { false }
    func focusFileView() { view.window?.makeFirstResponder(focusTarget) }
    func selectAllItems() { (focusTarget as? NSTableView)?.selectAll(nil) }
    func renameSelection() { beginRenameSelected() }

    /// 状态栏计数（焦点列语义：N 项 / 已选 M 项）
    var statusCounts: (items: Int, selected: Int) {
        guard columns.indices.contains(focusedColumnIndex) else { return (0, 0) }
        let col = columns[focusedColumnIndex]
        return (col.items.count, col.selectedItems.count)
    }

    var selectedItems: [FileItem] {
        columns.indices.contains(focusedColumnIndex) ? columns[focusedColumnIndex].selectedItems : []
    }
    var selectedURLs: [URL] { selectedItems.map(\.url) }

    /// UISelfTest（I-32）：焦点列视图层原始选中行数（直查 tableView）——验删除后真清空
    var uiTestFocusedRawSelectionCount: Int {
        columns.indices.contains(focusedColumnIndex)
            ? columns[focusedColumnIndex].tableView.selectedRowIndexes.count : 0
    }

    /// UISelfTest（I-32）：在焦点列按 URL 集选中（模拟用户多选；走真实选中变更链）
    func uiTestSelectInFocusedColumn(_ urls: [URL]) {
        guard columns.indices.contains(focusedColumnIndex) else { return }
        let col = columns[focusedColumnIndex]
        let wanted = Set(urls)
        var idx = IndexSet()
        for (i, item) in col.items.enumerated() where wanted.contains(item.url) { idx.insert(i) }
        col.tableView.selectRowIndexes(idx, byExtendingSelection: false)
    }

    /// UISelfTest（I-32）：焦点列当前项 URL（供测试取真实 URL，避免 symlink 路径不匹配）
    var uiTestFocusedColumnItemURLs: [URL] {
        columns.indices.contains(focusedColumnIndex) ? columns[focusedColumnIndex].items.map(\.url) : []
    }

    /// 焦点列所在目录（粘贴/新建/空白右键的落点）
    var currentDirectory: URL {
        columns.indices.contains(focusedColumnIndex) ? columns[focusedColumnIndex].directory : model.directory
    }

    init(model: DirectoryViewModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        // FSEvents 与过滤联动：活动列或当前目录列刷新（加载中或重命名中不打扰）
        model.addOnUpdate { [weak self] in
            guard let self, !self.suspended, self.view.window != nil else { return }
            let focusDir = self.currentDirectory.standardizedFileURL.path
            for col in self.columns where (col.directory.path == self.model.directory.path || col.directory.standardizedFileURL.path == focusDir) {
                if !col.isLoading { col.reload() }
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建 UI，无 xib") }

    override func loadView() {
        stack.orientation = .horizontal
        stack.spacing = 0
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false

        hScroll.documentView = stack
        hScroll.hasHorizontalScroller = true
        hScroll.hasVerticalScroller = false
        hScroll.autohidesScrollers = true

        // 横向滚动 NSStackView：stack 钉 clip 的 top/leading + 高度铺满视口；宽度铺满约束用 .defaultLow。
        // 宽度铺满若为 required，会把单列内容宽（220）经 required 反推、defeat PaneViewController 挂载
        // 内容视图用的 999 铺满边约束 → 列宽坍缩（M23 断言实锤 220×…）。降为 .defaultLow 即可少列铺满
        // 又不与 999 抢。（纵向坍缩另有真凶：ColumnUnit 竖分隔线 NSBox 的伪固有高度，见下方修复。）
        let clip = hScroll.contentView
        let fillW = stack.widthAnchor.constraint(greaterThanOrEqualTo: clip.widthAnchor)
        fillW.priority = .defaultLow
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: clip.topAnchor),
            stack.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            stack.heightAnchor.constraint(equalTo: clip.heightAnchor),
            fillW,
        ])

        let root = NSView()
        hScroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(hScroll)
        NSLayoutConstraint.activate([
            hScroll.topAnchor.constraint(equalTo: root.topAnchor),
            hScroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            hScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            hScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        view = root
    }

    // MARK: 挂起/恢复（窗格切走/布局切换时由 PaneViewController 调用——北极星零后台功耗）

    /// 挂起时也中止进行中的重命名并取消列加载
    func suspend() {
        guard !suspended else { return }
        suspended = true
        renameCoordinator.cancelIfNeeded()
        columns.forEach { $0.cancelLoad() }
        preview?.cancelThumb()
    }

    /// 恢复并对齐当前目录：沿链则刷新列链，否则重建
    func wake(at url: URL) {
        suspended = false
        if let pending = pendingDirectory {
            pendingDirectory = nil
            showDirectory(pending)
        } else if columns.contains(where: { $0.directory.path == url.standardizedFileURL.path }) {
            reloadAllColumns()
        } else {
            showDirectory(url)
        }
    }

    // MARK: 列链管理（沿链下钻原地扩列；跳转重建）

    /// 呈现目录（Pane 导航唯一回流入口）：
    /// 已有该目录列 → 截其右；父目录在链上 → 原地扩列；否则重建列链
    func showDirectory(_ url: URL) {
        let std = url.standardizedFileURL
        if suspended { pendingDirectory = std; return }
        if let k = columns.firstIndex(where: { $0.directory.path == std.path }) {
            truncateColumns(after: k)
            removePreview()
        } else if let p = columns.firstIndex(where: { $0.directory.path == std.deletingLastPathComponent().path }) {
            truncateColumns(after: p)
            removePreview()
            columns[p].highlight(url: std)   // 程序化选中链行（不触发再下钻）
            appendColumn(for: std)
        } else {
            rebuild(root: std)
        }
        scrollToTrailing()
        onSelectionChange?()
    }

    /// 操作后刷新（coordinator reload 路径）：全列重读（每列一次 readdir，列数有限）
    func reloadAllColumns() {
        guard !suspended else { return }
        columns.forEach { $0.reload() }
    }

    /// 仅重绘（剪切灰显变化）
    /// 仅重绘（剪切灰显变化）。
    /// **不能用 reloadData()**：它会把选中清空，而"重绘"语义里行没变、选中就不该变
    /// （用户报告：⌘C 之后选中框消失）。按行/列重载会保留选中。
    func redraw() {
        for col in columns {
            let tv = col.tableView
            guard tv.numberOfRows > 0, tv.numberOfColumns > 0 else { continue }
            tv.reloadData(forRowIndexes: IndexSet(integersIn: 0..<tv.numberOfRows),
                          columnIndexes: IndexSet(integersIn: 0..<tv.numberOfColumns))
        }
    }

    /// 按 URL 集恢复选中（视图模式切换迁移）：落在叶列，装载完成后应用
    func select(urls: [URL]) {
        guard let leaf = columns.last else { return }
        leaf.desiredSelection = Set(urls)
        leaf.applyDesiredSelectionIfLoaded()
        view.window?.makeFirstResponder(leaf.tableView)   // I-48：聚焦叶列，选中显蓝色强调（非 first responder 时未强调灰几乎不可见）
    }

    func prepareReveal(_ url: URL, rename: Bool, focus: Bool) {
        pendingReveal = (url, rename, focus)
        let parent = url.deletingLastPathComponent().standardizedFileURL.path
        if let col = columns.first(where: { $0.directory.standardizedFileURL.path == parent }) {
            col.desiredSelection = [url]
            handlePendingRevealIfNeeded(in: col)
        }
    }

    /// 取走并清空待定位目标（切视图模式搬家用，语义同 FileRevealTarget.takePendingReveal）
    func takePendingReveal() -> (url: URL, rename: Bool)? {
        if let p = pendingReveal {
            pendingReveal = nil
            return (p.url, p.rename)
        }
        guard let leaf = columns.last, let url = leaf.desiredSelection.first else { return nil }
        leaf.desiredSelection = []
        return (url, false)
    }

    func runOrDeferColumnReload(_ block: @escaping () -> Void) {
        _ = renameCoordinator.runOrDefer(block)
    }

    func handlePendingRevealIfNeeded(in column: ColumnUnit) {
        guard let p = pendingReveal else { return }
        let parent = p.url.deletingLastPathComponent().standardizedFileURL.path
        guard column.directory.standardizedFileURL.path == parent else { return }
        let targetPath = p.url.standardizedFileURL.path
        guard let row = column.items.firstIndex(where: {
            $0.url.standardizedFileURL.path == targetPath
                || $0.url.standardizedFileURL.path.compare(targetPath, options: .caseInsensitive) == .orderedSame
        }) else {
            if !column.isLoading { pendingReveal = nil }
            return
        }
        pendingReveal = nil
        if let colIndex = columns.firstIndex(where: { $0 === column }) {
            focusedColumnIndex = colIndex
        }
        column.highlight(url: column.items[row].url)
        if p.focus && !p.rename {
            view.window?.makeFirstResponder(column.tableView)
        }
        if p.rename {
            beginRename(in: column, row: row)
        }
    }

    private func rebuild(root: URL) {
        truncateColumns(after: -1)
        removePreview()
        appendColumn(for: root)
        focusedColumnIndex = 0
    }

    /// 移除 index 之后的所有列（-1 = 全部），取消其在飞加载
    private func truncateColumns(after index: Int) {
        guard index < columns.count - 1 else { return }
        for col in columns[(index + 1)...] {
            col.cancelLoad()
            stack.removeArrangedSubview(col)
            col.removeFromSuperview()
        }
        columns.removeLast(columns.count - index - 1)
        if focusedColumnIndex > index { focusedColumnIndex = max(0, index) }
    }

    private func appendColumn(for directory: URL) {
        let col = ColumnUnit(directory: directory, owner: self)
        columns.append(col)
        stack.addArrangedSubview(col)
        col.heightAnchor.constraint(equalTo: stack.heightAnchor).isActive = true
        col.reload()
    }

    private func removePreview() {
        guard let p = preview else { return }
        p.cancelThumb()
        stack.removeArrangedSubview(p)
        p.removeFromSuperview()
        preview = nil
    }

    private func showPreview(for item: FileItem) {
        removePreview()
        let p = PreviewColumnView()
        preview = p
        stack.addArrangedSubview(p)
        p.heightAnchor.constraint(equalTo: stack.heightAnchor).isActive = true
        p.show(item)
        scrollToTrailing()
    }

    private func scrollToTrailing() {
        view.layoutSubtreeIfNeeded()
        let clip = hScroll.contentView
        let x = max(0, stack.fittingSize.width - clip.bounds.width)
        clip.scroll(to: NSPoint(x: x, y: clip.bounds.origin.y))
        hScroll.reflectScrolledClipView(clip)
    }

    // MARK: 列回调（ColumnUnit → 语义裁决在此）

    func columnInteracted(_ column: ColumnUnit) {
        if let i = columns.firstIndex(where: { $0 === column }) { focusedColumnIndex = i }
        onInteract?()
    }

    /// 用户级选中变化：单选目录=下钻（经 Pane 同步地址栏）；单选文件=预览列；多选/清选=截右列
    func selectionChanged(in column: ColumnUnit) {
        guard columns.contains(where: { $0 === column }) else { return }
        let sel = column.selectedItems
        if sel.count == 1, let item = sel.first {
            if item.isDirectory && !item.isPackage {
                onNavigate?(item.url)
            } else {
                onNavigate?(column.directory)
                showPreview(for: item)
            }
        } else {
            onNavigate?(column.directory)
            removePreview()
        }
        onSelectionChange?()
        if QLPreviewPanel.sharedPreviewPanelExists(),
           let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.reloadData()
        }
    }

    func columnContentChanged(_ column: ColumnUnit) {
        onSelectionChange?()   // 计数刷新（状态栏经 Pane 读 statusCounts）
    }

    func doubleClicked(in column: ColumnUnit) {
        let row = column.tableView.clickedRow
        guard row >= 0, row < column.items.count else { return }
        let item = column.items[row]
        // 目录已由单击下钻；文件/包 = 系统默认 App 打开
        if !item.isDirectory || item.isPackage {
            coordinator?.recordAccess(item.url)   // M28：打开文件 = 一次使用记账
            NSWorkspace.shared.open(item.url)
        }
    }

    /// ←/→ 列间移动：← 聚焦父列；→ 聚焦子列（无选中则选第一行触发下钻/预览）
    func moveFocus(from column: ColumnUnit, direction: Int) {
        guard let i = columns.firstIndex(where: { $0 === column }) else { return }
        let target = i + direction
        guard columns.indices.contains(target) else { NSSound.beep(); return }
        let t = columns[target]
        focusedColumnIndex = target
        view.window?.makeFirstResponder(t.tableView)
        if direction > 0, t.tableView.selectedRowIndexes.isEmpty, !t.items.isEmpty {
            t.tableView.selectRowIndexes([0], byExtendingSelection: false)
            t.tableView.scrollRowToVisible(0)
        }
        onSelectionChange?()
    }

    func menu(for column: ColumnUnit) -> NSMenu {
        if let i = columns.firstIndex(where: { $0 === column }) { focusedColumnIndex = i }
        return FileContextMenuBuilder.menu(selection: column.selectedItems,
                                           directory: column.directory, target: self)
    }

    func isCut(_ url: URL) -> Bool { coordinator?.isCut(url) ?? false }

    func open(_ item: FileItem) {
        if item.isDirectory && !item.isPackage {
            onNavigate?(item.url)
        } else {
            coordinator?.recordAccess(item.url)
            NSWorkspace.shared.open(item.url)
        }
    }

    func beginRenameSelected(in targetColumn: ColumnUnit? = nil) {
        let col = targetColumn ?? (columns.indices.contains(focusedColumnIndex) ? columns[focusedColumnIndex] : nil)
        guard let col else { NSSound.beep(); return }
        let rows = col.tableView.selectedRowIndexes
        guard rows.count == 1, let row = rows.first else { NSSound.beep(); return }
        beginRename(in: col, row: row)
    }

    func beginRename(in column: ColumnUnit, row: Int) {
        guard !TrashLocation.isInsideTrash(column.directory),
              column.items.indices.contains(row) else { return }
        let item = column.items[row]
        if let idx = columns.firstIndex(where: { $0 === column }) {
            focusedColumnIndex = idx
        }
        column.tableView.scrollRowToVisible(row)
        guard let cell = column.tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? NameCellView else { return }
        cell.beginRename(
            for: item,
            using: renameCoordinator,
            hostView: column.tableView,
            prepareVisibleFrame: { [weak column] in
                column?.tableView.scrollRowToVisible(row)
            },
            onCommit: { [weak self, weak column] newName in
                guard let self, let column else { return nil }
                return await self.submitRenameAndAwaitURL(item, newName: newName, in: column, fallbackRow: row)
            },
            onFinish: { [weak self, weak column] renamedURL, restoreFocus in
                guard let self else { return }
                if let renamedURL, let column {
                    self.prepareReveal(renamedURL, rename: false, focus: restoreFocus)
                    column.reload()
                } else if restoreFocus, let column {
                    self.view.window?.makeFirstResponder(column.tableView)
                }
            },
            onTabStep: { [weak self, weak column] anchorURL, forward in
                guard let self, let column else { return }
                self.beginRenameAdjacent(in: column, from: anchorURL, forward: forward)
            }
        )
    }

    private func beginRenameAdjacent(in column: ColumnUnit, from anchorURL: URL, forward: Bool) {
        let path = anchorURL.standardizedFileURL.path
        guard let idx = column.items.firstIndex(where: {
            $0.url.standardizedFileURL.path.compare(path, options: .caseInsensitive) == .orderedSame
        }) else { return }
        let next = forward ? idx + 1 : idx - 1
        guard column.items.indices.contains(next) else { return }
        column.highlight(url: column.items[next].url)
        beginRename(in: column, row: next)
    }

    private func submitRenameAndAwaitURL(_ item: FileItem, newName: String,
                                         in column: ColumnUnit, fallbackRow: Int) async -> URL? {
        guard let coordinator else { return nil }
        return await withCheckedContinuation { continuation in
            coordinator.rename(item.url, to: newName) { [weak self, weak column] ok in
                if !ok {
                    if let column {
                        self?.flashRenameError(in: column, row: fallbackRow)
                    }
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: item.url.deletingLastPathComponent().appendingPathComponent(newName))
                }
            }
        }
    }

    private func flashRenameError(in column: ColumnUnit, row: Int) {
        NSSound.beep()
        guard column.items.indices.contains(row) else { return }
        let rect = column.tableView.rect(ofRow: row)
        let banner = NSTextField(labelWithString: L10n.t("rename.failed"))
        banner.textColor = .systemRed
        banner.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.9)
        banner.drawsBackground = true
        banner.font = .systemFont(ofSize: 11)
        banner.frame = NSRect(x: rect.minX + 20, y: rect.minY + 2, width: 180, height: 20)
        column.tableView.addSubview(banner)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            banner.removeFromSuperview()
        }
    }

    // MARK: 投放语义（统一委托 FileDropPolicy）

    func validateDrop(in column: ColumnUnit, info: any NSDraggingInfo,
                      proposedRow row: Int, operation op: NSTableView.DropOperation) -> NSDragOperation {
        let folderTarget: FileItem?
        if op == .on, column.items.indices.contains(row),
           column.items[row].isDirectory, !column.items[row].isPackage {
            folderTarget = column.items[row]
            column.tableView.setDropRow(row, dropOperation: .on)
        } else {
            folderTarget = nil
            column.tableView.setDropRow(-1, dropOperation: .on)
        }
        return FileDropPolicy.dragOperation(for: info, targetDirectory: column.directory, targetItem: folderTarget)
    }

    func acceptDrop(in column: ColumnUnit, info: any NSDraggingInfo,
                    row: Int, operation op: NSTableView.DropOperation) -> Bool {
        let folderTarget: FileItem?
        if op == .on, column.items.indices.contains(row),
           column.items[row].isDirectory, !column.items[row].isPackage {
            folderTarget = column.items[row]
        } else {
            folderTarget = nil
        }
        return FileDropPolicy.acceptDrop(info, targetDirectory: column.directory,
                                         targetItem: folderTarget, coordinator: coordinator)
    }

    // MARK: 菜单命令（响应链；作用于焦点列；三视图语义完全统一）

    @objc func toggleHiddenFiles(_ sender: Any?) {
        model.includeHidden.toggle()
        reloadAllColumns()
    }

    @objc func refresh(_ sender: Any?) {
        model.reload()
        reloadAllColumns()
    }

    @objc func copyItems(_ sender: Any?) { FileViewActions.copyItems(pane: self) }
    @objc func cutItems(_ sender: Any?) { FileViewActions.cutItems(pane: self) }
    @objc func putBackItems(_ sender: Any?) { FileViewActions.putBackItems(pane: self) }
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
    @objc func renameSelected(_ sender: Any?) { beginRenameSelected() }
    @objc func batchRenameItems(_ sender: Any?) { FileViewActions.batchRenameItems(pane: self) }
    @objc func moveToTrash(_ sender: Any?) { FileViewActions.moveToTrash(pane: self) }
    @objc func deleteImmediately(_ sender: Any?) { FileViewActions.deleteImmediately(pane: self) }
    @objc func newFolderHere(_ sender: Any?) { FileViewActions.newFolderHere(pane: self) }
    @objc func newFileHere(_ sender: Any?) { FileViewActions.newFileHere(pane: self) }
    @objc func newFolderWithSelection(_ sender: Any?) { FileViewActions.newFolderWithSelection(pane: self) }
    @objc func compressItems(_ sender: Any?) { FileViewActions.compressItems(pane: self) }
    @objc func extractItems(_ sender: Any?) { FileViewActions.extractItems(pane: self) }
    @objc func extractItemsTo(_ sender: Any?) { FileViewActions.extractItemsTo(pane: self) }
    @objc func copyToOtherPane(_ sender: Any?) { coordinator?.copyToOtherPane(selectedURLs) }
    @objc func moveToOtherPane(_ sender: Any?) { coordinator?.moveToOtherPane(selectedURLs) }

    @objc func openSelected(_ sender: Any?) { FileViewActions.openSelected(pane: self) }
    @objc func openWithApp(_ sender: Any?) { FileViewActions.openWithApp(pane: self, sender: sender) }
    @objc func openWithOther(_ sender: Any?) { FileViewActions.openWithOther(pane: self) }
    @objc func airdropSelected(_ sender: Any?) { FileViewActions.airdropSelected(pane: self) }
    @objc func getInfo(_ sender: Any?) { FileViewActions.getInfo(pane: self) }
    @objc func openInTerminal(_ sender: Any?) { FileViewActions.openInTerminal(pane: self) }
    @objc func showPackageContents(_ sender: Any?) { FileViewActions.showPackageContents(pane: self) }

    // MARK: Quick Look（空格开关；数据源=焦点列选中集）

    @objc func toggleQuickLook(_ sender: Any?) {
        qlBridge.toggle(urls: selectedURLs) { [weak self] url in
            self?.rowScreenRect(for: url) ?? .zero
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            qlBridge.quickLookDismissing = false
            panel.dataSource = self
            panel.delegate = self
            qlBridge.updateIfVisible(urls: selectedURLs) { [weak self] url in
                self?.rowScreenRect(for: url) ?? .zero
            }
        }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
        }
    }
}

// MARK: - 菜单校验（按焦点列选中态统一委托 FileViewActions）

extension FileColumnViewController: @preconcurrency NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        FileViewActions.validateMenuItem(menuItem, pane: self)
    }
}

// MARK: - Quick Look 数据源/委托

extension FileColumnViewController: @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        qlBridge.count()
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        qlBridge.item(at: index)
    }

    /// 面板收到方向键先转回焦点列（↑↓ 推进行、←→ 移列）
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown, (123...126).contains(Int(event.keyCode)) else { return false }
        (focusTarget as? NSTableView)?.keyDown(with: event)
        return true
    }

    /// 缩放动画起点=焦点列该行图标位置
    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: (any QLPreviewItem)!) -> NSRect {
        qlBridge.sourceFrame(on: panel, for: item) { [weak self] url in
            self?.rowScreenRect(for: url) ?? .zero
        }
    }

    private func rowScreenRect(for url: URL) -> NSRect {
        guard columns.indices.contains(focusedColumnIndex), let window = view.window else { return .zero }
        let col = columns[focusedColumnIndex]
        guard let row = col.items.firstIndex(where: { $0.url == url }) else { return .zero }
        let rect = col.tableView.convert(NSRect(x: 4, y: 0, width: 22, height: 22)
            .offsetBy(dx: 0, dy: col.tableView.rect(ofRow: row).minY), to: nil)
        return window.convertToScreen(rect)
    }
}

// MARK: - 单列（列宽 220 固定 v1）：自管加载（局部 DirectoryReader），销毁/挂起即取消

@MainActor
final class ColumnUnit: NSView, NSTableViewDataSource, NSTableViewDelegate {
    let directory: URL
    private(set) var items: [FileItem] = []
    private(set) var isLoading = false
    let tableView = FocusReportingTableView()
    private let scroll = NSScrollView()
    private weak var owner: FileColumnViewController?

    /// 列私有读取器：列是临时视图，直接局部实例（不动共享 model）
    private let reader = DirectoryReader()
    private var loadTask: Task<Void, Never>?

    /// 程序化选中防回环（链行高亮/选中恢复不得触发再下钻）
    private var isProgrammaticSelection = false
    /// 装载完成后要应用的选中集（模式切换迁移/链行高亮）
    var desiredSelection: Set<URL> = []

    init(directory: URL, owner: FileColumnViewController) {
        self.directory = directory
        self.owner = owner
        super.init(frame: .zero)

        tableView.onInteract = { [weak self] in
            guard let self else { return }
            self.owner?.columnInteracted(self)
        }
        tableView.menuProvider = { [weak self] _ in
            guard let self else { return nil }
            return self.owner?.menu(for: self)
        }
        tableView.onReturn = { [weak self] in
            guard let self else { return }
            self.owner?.beginRenameSelected(in: self)
        }
        tableView.onOpenSelected = { [weak self] in
            self?.owner?.openSelected(nil)
        }
        tableView.onSingleClickRename = { [weak self] row in
            guard let self else { return }
            self.owner?.beginRename(in: self, row: row)
        }
        tableView.isPaneActiveProvider = { [weak self] in
            self?.owner?.isPaneActiveProvider?() ?? true
        }
        tableView.itemURLProvider = { [weak self] row in
            guard let self, self.items.indices.contains(row) else { return nil }
            return self.items[row].url
        }
        tableView.rowForURLProvider = { [weak self] url in
            guard let self else { return nil }
            let target = url.standardizedFileURL.path
            return self.items.firstIndex {
                $0.url.standardizedFileURL.path == target
                    || $0.url.standardizedFileURL.path.compare(target, options: .caseInsensitive) == .orderedSame
            }
        }
        tableView.onSpace = { [weak self] in self?.owner?.toggleQuickLook(nil) }
        tableView.onArrowLeft = { [weak self] in
            guard let self else { return }
            self.owner?.moveFocus(from: self, direction: -1)
        }
        tableView.onArrowRight = { [weak self] in
            guard let self else { return }
            self.owner?.moveFocus(from: self, direction: 1)
        }
        tableView.style = .plain
        tableView.headerView = nil
        tableView.rowHeight = 22
        tableView.usesAutomaticRowHeights = false
        tableView.allowsMultipleSelection = true
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(didDoubleClick(_:))
        tableView.registerForDraggedTypes([.fileURL])
        tableView.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        tableView.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: false)

        let col = NSTableColumn(identifier: .init("name"))
        col.width = 204
        tableView.addTableColumn(col)

        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        // 竖向分隔线：NSBox separator 的固有内容尺寸默认为「横线（高=1）」，会经 required 约束链
        // （separator↔ColumnUnit↔stack↔clip↔scrollView↔列根↔contentContainer）把整列纵向拉塌成 1pt
        // （M23 断言 + 约束转储实锤 NSContentSizeLayoutConstraint: NSBox.height==1）。把它的纵向
        // hugging/抗压降到最低，由 top/bottom 约束定高，消除这条伪高度诉求。
        separator.setContentHuggingPriority(.init(1), for: .vertical)
        separator.setContentCompressionResistancePriority(.init(1), for: .vertical)

        addSubview(scroll)
        addSubview(separator)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 220),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: separator.leadingAnchor),
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            // I-24b：竖分隔线必须钉死宽 1——无宽度约束时横向歧义会被解成"分隔线 219/滚动区 0"，
            // 内容全被 0 宽裁剪层裁掉（纵向坍缩修复后暴露；层链转储实锤 NSClipView 0x393）
            separator.widthAnchor.constraint(equalToConstant: 1),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建 UI，无 xib") }

    // MARK: 加载（列私有 Task；取消即停）

    func reload() {
        loadTask?.cancel()
        isLoading = true
        let request = ReadRequest(directory: directory,
                                  includeHidden: owner?.model.includeHidden ?? false,
                                  sort: owner?.model.sort ?? SortSpec())
        loadTask = Task { [weak self, reader] in
            let snap = try? await reader.load(request)
            guard let self, !Task.isCancelled else { return }
            self.isLoading = false
            let rawItems = snap?.items ?? []
            self.owner?.runOrDeferColumnReload { [weak self] in
                guard let self else { return }
                // 刷新前保留现有选中（FSEvents/操作后重读不丢选中）
                if self.desiredSelection.isEmpty {
                    self.desiredSelection = Set(self.selectedItems.map(\.url))
                }
                if let owner = self.owner, owner.model.isFiltering,
                   self.directory.standardizedFileURL.path == owner.currentDirectory.standardizedFileURL.path {
                    self.items = DirectoryViewModel.filterItems(rawItems, query: owner.model.filterQuery)
                } else {
                    self.items = rawItems   // 读取失败 → 空列原位呈现（不弹窗）
                }
                self.isProgrammaticSelection = true
                self.tableView.reloadData()
                self.isProgrammaticSelection = false
                self.applyDesiredSelectionIfLoaded()
                self.owner?.handlePendingRevealIfNeeded(in: self)
                self.owner?.columnContentChanged(self)
            }
        }
    }

    func cancelLoad() {
        loadTask?.cancel()
        loadTask = nil
        isLoading = false
    }

    // MARK: 选中

    var selectedItems: [FileItem] {
        tableView.selectedRowIndexes.compactMap { items.indices.contains($0) ? items[$0] : nil }
    }

    /// 程序化高亮链行（下钻后父列保持选中子目录；不触发再下钻）
    func highlight(url: URL) {
        desiredSelection = [url]
        applyDesiredSelectionIfLoaded()
    }

    func applyDesiredSelectionIfLoaded() {
        guard !items.isEmpty else { return }          // 空列无行可选；desiredSelection 保留待后续载入
        guard !desiredSelection.isEmpty else { return } // 无待恢复选中：不动现状
        var indexes = IndexSet()
        // 标准化路径比较 + 大小写兜底（大小写不敏感卷上用户给的大小写常与盘上不同）——I-39/I-55 同病同修
        let wantedPaths = Set(desiredSelection.map { $0.standardizedFileURL.path })
        for (i, item) in items.enumerated() {
            let p = item.url.standardizedFileURL.path
            if wantedPaths.contains(p)
                || wantedPaths.contains(where: { $0.compare(p, options: .caseInsensitive) == .orderedSame }) {
                indexes.insert(i)
            }
        }
        // 一个都没匹配上时，只有在「本列确实就是这些目标所在的目录」时才认定为"真的不存在"并消费掉。
        // 否则列里装的还是上一个目录的陈旧内容——照旧清空就把待选中吃掉，正确内容载入后再也不会选中，
        // 表现为粘贴文件路径后分栏模式什么都没选中（I-55）。
        let ownsTargets = desiredSelection.allSatisfy {
            $0.deletingLastPathComponent().standardizedFileURL.path
                == directory.standardizedFileURL.path
        }
        guard !indexes.isEmpty || ownsTargets else { return }
        desiredSelection = []
        // I-32：精确匹配集即恢复；空集（选中项全被删）也显式 select 清空——
        // 不再 `guard !indexes.isEmpty else { return }` 留 reloadData 的按行号残留（删除后选中"漂移"真凶）
        isProgrammaticSelection = true
        tableView.selectRowIndexes(indexes, byExtendingSelection: false)
        isProgrammaticSelection = false
        if let first = indexes.first { tableView.scrollRowToVisible(first) }
    }

    // MARK: 表数据源/委托

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard items.indices.contains(row) else { return nil }
        let item = items[row]
        let cell = tableView.makeView(withIdentifier: .init("colNameCell"), owner: nil) as? NameCellView
            ?? NameCellView(identifier: .init("colNameCell"))
        let cut = owner?.isCut(item.url) ?? false
        cell.configure(icon: Formatters.icon(for: item), name: item.name,
                       dimmed: item.isHidden || cut)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isProgrammaticSelection else { return }
        owner?.selectionChanged(in: self)
    }

    @objc private func didDoubleClick(_ sender: Any?) {
        owner?.doubleClicked(in: self)
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        items.indices.contains(row) ? items[row].name : nil
    }

    // MARK: 拖拽源 / 投放目标（语义裁决在 owner，与列表一致）

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        (tableView as? FocusReportingTableView)?.dragInitiated = true
        guard items.indices.contains(row) else { return nil }
        return items[row].url as NSURL
    }

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        owner?.validateDrop(in: self, info: info, proposedRow: row, operation: op) ?? []
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo,
                   row: Int, dropOperation op: NSTableView.DropOperation) -> Bool {
        owner?.acceptDrop(in: self, info: info, row: row, operation: op) ?? false
    }
}

// MARK: - 文件预览列（点选文件时出现在最右：大图 + 名称 + 种类/大小/日期）

@MainActor
final class PreviewColumnView: NSView {
    private let bigIcon = NSImageView()
    private let nameLabel = NSTextField(wrappingLabelWithString: "")
    private let infoLabel = NSTextField(wrappingLabelWithString: "")
    private var thumbTask: Task<Void, Never>?

    init() {
        super.init(frame: .zero)
        bigIcon.imageScaling = .scaleProportionallyUpOrDown

        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.alignment = .center
        nameLabel.maximumNumberOfLines = 3
        nameLabel.lineBreakMode = .byTruncatingMiddle

        infoLabel.font = .systemFont(ofSize: 11)
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.alignment = .center
        infoLabel.maximumNumberOfLines = 4

        for sub in [bigIcon, nameLabel, infoLabel] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            addSubview(sub)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 220),
            bigIcon.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            bigIcon.centerXAnchor.constraint(equalTo: centerXAnchor),
            bigIcon.widthAnchor.constraint(equalToConstant: 128),
            bigIcon.heightAnchor.constraint(equalToConstant: 128),
            nameLabel.topAnchor.constraint(equalTo: bigIcon.bottomAnchor, constant: 12),
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            infoLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 8),
            infoLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            infoLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建 UI，无 xib") }

    func show(_ item: FileItem) {
        cancelThumb()
        bigIcon.image = Formatters.fullIcon(for: item)   // 快路径类型图标先出
        nameLabel.stringValue = item.name
        var lines: [String] = [Formatters.kind(forTypeID: item.contentTypeID, isDirectory: item.isDirectory)]
        if let size = item.size {
            lines.append(Formatters.size.string(fromByteCount: size))
        }
        if let modified = item.modified {
            lines.append(Formatters.relativeDate(modified))
        }
        infoLabel.stringValue = lines.joined(separator: "\n")
        // QLThumbnail 大图异步升级（失败保持类型图标——BG-7 装饰失败不伤主链）
        let url = item.url
        thumbTask = Task { [weak self] in
            let cg = await Engines.iconThumb.thumbnail(for: url, size: 128)
            guard let self, !Task.isCancelled, let cg else { return }
            self.bigIcon.image = NSImage(cgImage: cg, size: NSSize(width: 128, height: 128))
        }
    }

    func cancelThumb() {
        thumbTask?.cancel()
        thumbTask = nil
    }
}

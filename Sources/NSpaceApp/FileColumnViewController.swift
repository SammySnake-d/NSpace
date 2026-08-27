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
final class FileColumnViewController: NSViewController {
    /// 只读消费共享 model 的配置（includeHidden/sort）与 FSEvents 联动；列内容不经它
    let model: DirectoryViewModel
    weak var coordinator: FileOpsCoordinator?
    var onNavigate: ((URL) -> Void)?
    var onInteract: (() -> Void)?
    var onSelectionChange: (() -> Void)?

    private let hScroll = NSScrollView()
    private let stack = NSStackView()
    private(set) var columns: [ColumnUnit] = []   // setter 私有；UISelfTest 内容级断言需读
    private var preview: PreviewColumnView?
    private var focusedColumnIndex = 0

    /// 挂起态：置位期间列加载全取消、showDirectory 只记 pending（恢复时重建）
    private var suspended = false
    private var pendingDirectory: URL?

    var focusTarget: NSView {
        columns.indices.contains(focusedColumnIndex) ? columns[focusedColumnIndex].tableView : view
    }

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
        // FSEvents 联动：活动目录内容变化 → 刷新对应列（加载中的列不打扰，避免 navigate 双读）
        model.addOnUpdate { [weak self] in
            guard let self, !self.suspended, self.view.window != nil else { return }
            if let col = self.columns.first(where: { $0.directory.path == self.model.directory.path }),
               !col.isLoading {
                col.reload()
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

    /// 取消全部在飞列加载与预览缩略图；后续 showDirectory 只记 pending
    func suspend() {
        guard !suspended else { return }
        suspended = true
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
    func redraw() {
        columns.forEach { $0.tableView.reloadData() }
    }

    /// 按 URL 集恢复选中（视图模式切换迁移）：落在叶列，装载完成后应用
    func select(urls: [URL]) {
        guard let leaf = columns.last else { return }
        leaf.desiredSelection = Set(urls)
        leaf.applyDesiredSelectionIfLoaded()
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

    // MARK: 投放语义（与列表一致：目录行=投进该文件夹；空白/文件行=投进列目录；⌥ 复制）

    func validateDrop(in column: ColumnUnit, info: any NSDraggingInfo,
                      proposedRow row: Int, operation op: NSTableView.DropOperation) -> NSDragOperation {
        guard let urls = Self.draggedFileURLs(info), !urls.isEmpty else { return [] }
        var targetRow = -1
        if op == .on, row >= 0, row < column.items.count,
           column.items[row].isDirectory, !column.items[row].isPackage {
            targetRow = row
        }
        let target = targetRow >= 0 ? column.items[targetRow].url : column.directory
        guard urls.allSatisfy({ !FileOpsCoordinator.isSelfOrDescendant(destination: target, ofSource: $0) }) else {
            return []
        }
        let forceCopy = info.draggingSourceOperationMask == .copy
        let destPath = target.standardizedFileURL.path
        if !forceCopy, urls.allSatisfy({ $0.standardizedFileURL.deletingLastPathComponent().path == destPath }) {
            return []
        }
        if targetRow >= 0 {
            column.tableView.setDropRow(targetRow, dropOperation: .on)
        } else {
            column.tableView.setDropRow(-1, dropOperation: .on)   // 整列高亮 = 投进列目录
        }
        if forceCopy { return .copy }
        return urls.allSatisfy({ FileOpsCoordinator.isSameVolume($0, target) }) ? .move : .copy
    }

    func acceptDrop(in column: ColumnUnit, info: any NSDraggingInfo,
                    row: Int, operation op: NSTableView.DropOperation) -> Bool {
        guard let urls = Self.draggedFileURLs(info), !urls.isEmpty else { return false }
        var target = column.directory
        if op == .on, row >= 0, row < column.items.count,
           column.items[row].isDirectory, !column.items[row].isPackage {
            target = column.items[row].url
        }
        coordinator?.dropTransfer(urls: urls, into: target,
                                  forceCopy: info.draggingSourceOperationMask == .copy)
        return true
    }

    private static func draggedFileURLs(_ info: any NSDraggingInfo) -> [URL]? {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                            options: [.urlReadingFileURLsOnly: true]) as? [URL]
    }

    // MARK: 菜单命令（响应链；作用于焦点列；重命名未实现 → 不响应即诚实灰显）

    @objc func toggleHiddenFiles(_ sender: Any?) {
        model.includeHidden.toggle()
        reloadAllColumns()
    }

    @objc func refresh(_ sender: Any?) {
        model.reload()
        reloadAllColumns()
    }

    @objc func copyItems(_ sender: Any?) { coordinator?.copy(selectedURLs) }
    @objc func cutItems(_ sender: Any?) { coordinator?.cut(selectedURLs) }
    @objc func pasteItems(_ sender: Any?) { coordinator?.paste(into: currentDirectory) }
    @objc func copyPath(_ sender: Any?) { coordinator?.copyPaths(selectedURLs) }
    @objc func copy(_ sender: Any?) { copyItems(sender) }
    @objc func cut(_ sender: Any?) { cutItems(sender) }
    @objc func paste(_ sender: Any?) { pasteItems(sender) }

    @objc func duplicateItems(_ sender: Any?) { coordinator?.duplicate(selectedURLs) }
    @objc func moveToTrash(_ sender: Any?) { coordinator?.moveToTrash(selectedURLs) }
    @objc func newFolderHere(_ sender: Any?) { coordinator?.newFolder(in: currentDirectory, revealIn: nil) }
    @objc func newFileHere(_ sender: Any?) { coordinator?.newFile(in: currentDirectory, revealIn: nil) }
    @objc func copyToOtherPane(_ sender: Any?) { coordinator?.copyToOtherPane(selectedURLs) }
    @objc func moveToOtherPane(_ sender: Any?) { coordinator?.moveToOtherPane(selectedURLs) }

    @objc func openSelected(_ sender: Any?) {
        for item in selectedItems {
            if item.isDirectory && !item.isPackage {
                onNavigate?(item.url)
            } else {
                NSWorkspace.shared.open(item.url)
            }
        }
    }

    @objc func openWithApp(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, let app = item.representedObject as? URL else { return }
        NSWorkspace.shared.open(selectedURLs, withApplicationAt: app,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    @objc func openWithOther(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let app = panel.url else { return }
        NSWorkspace.shared.open(selectedURLs, withApplicationAt: app,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    @objc func getInfo(_ sender: Any?) {
        let target = selectedURLs.first ?? currentDirectory
        InfoPanel.show(for: target)
    }

    @objc func openInTerminal(_ sender: Any?) {
        let dir: URL = selectedItems.first(where: { $0.isDirectory })?.url ?? currentDirectory
        let ws = NSWorkspace.shared
        let terminal = ws.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
            ?? ws.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2")
        guard let terminal else { NSSound.beep(); return }
        ws.open([dir], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc func showPackageContents(_ sender: Any?) {
        guard let pkg = selectedItems.first(where: { $0.isPackage }) else { return }
        onNavigate?(pkg.url)
    }

    // MARK: Quick Look（空格开关；数据源=焦点列选中集）

    /// I-45：收起走淡出而非"缩到图标"（同列表视图，sourceFrame 收起态返回 .zero）
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
}

// MARK: - 菜单校验（按焦点列选中态启用/禁用）

extension FileColumnViewController: @preconcurrency NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let hasSelection = !selectedItems.isEmpty
        switch menuItem.action {
        case #selector(copyItems(_:)), #selector(cutItems(_:)), #selector(copyPath(_:)),
             #selector(duplicateItems(_:)), #selector(moveToTrash(_:)), #selector(openSelected(_:)),
             #selector(copyToOtherPane(_:)), #selector(moveToOtherPane(_:)),
             #selector(copy(_:)), #selector(cut(_:)):
            return hasSelection
        case #selector(pasteItems(_:)), #selector(paste(_:)):
            return NSPasteboard.general.canReadObject(forClasses: [NSURL.self],
                                                      options: [.urlReadingFileURLsOnly: true])
        default:
            return true
        }
    }
}

// MARK: - Quick Look 数据源/委托

extension FileColumnViewController: @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        selectedItems.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        let urls = selectedURLs
        guard index >= 0, index < urls.count else { return nil }
        return urls[index] as NSURL
    }

    /// 面板收到方向键先转回焦点列（↑↓ 推进行、←→ 移列）
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown, (123...126).contains(Int(event.keyCode)) else { return false }
        (focusTarget as? NSTableView)?.keyDown(with: event)
        return true
    }

    /// 缩放动画起点=焦点列该行图标位置
    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: (any QLPreviewItem)!) -> NSRect {
        if quickLookDismissing { return .zero }
        guard let url = (item as? NSURL) as URL?,
              columns.indices.contains(focusedColumnIndex),
              let window = view.window else { return .zero }
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
        tableView.onReturn = { NSSound.beep() }   // 分栏不支持行内重命名（诚实反馈）
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
            // 刷新前保留现有选中（FSEvents/操作后重读不丢选中）
            if self.desiredSelection.isEmpty {
                self.desiredSelection = Set(self.selectedItems.map(\.url))
            }
            self.items = snap?.items ?? []   // 读取失败 → 空列原位呈现（不弹窗）
            self.isProgrammaticSelection = true
            self.tableView.reloadData()
            self.isProgrammaticSelection = false
            self.applyDesiredSelectionIfLoaded()
            self.owner?.columnContentChanged(self)
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
        // 标准化路径比较：外部注入的 URL 可能无尾斜杠、列内条目带尾斜杠（I-39 同病同修）
        let wantedPaths = Set(desiredSelection.map { $0.standardizedFileURL.path })
        for (i, item) in items.enumerated()
        where wantedPaths.contains(item.url.standardizedFileURL.path) {
            indexes.insert(i)
        }
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

    // MARK: 拖拽源 / 投放目标（语义裁决在 owner，与列表一致）

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
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

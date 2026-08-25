import AppKit
import NSpaceContracts

/// 列表视图（性能核心）：view-based NSTableView、固定行高、行复用、可排序列。
/// 只读消费 DirectoryViewModel（BG-1：本层无任何写型文件 API）；
/// 文件变更意图一律经 FileOpsCoordinator 构造 OperationSpec 交内核执行。
@MainActor
final class FileListViewController: NSViewController {
    let model: DirectoryViewModel
    /// 文件操作桥（由窗格注入）
    weak var coordinator: FileOpsCoordinator?
    /// 导航意图上抛（由 Pane 历史协调）
    var onNavigate: ((URL) -> Void)?
    /// 用户交互上抛（窗格焦点协调）
    var onInteract: (() -> Void)?

    private let tableView = FocusReportingTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "")

    /// 操作完成后待显露（选中/进入重命名）的目标
    private var pendingReveal: (url: URL, rename: Bool)?

    /// spring-loaded 状态：拖拽悬停的文件夹行 + 触发计时器
    private var springLoad: (row: Int, timer: Timer)?

    /// 键盘焦点落点（PaneGrid 激活时 makeFirstResponder 此视图）
    var focusTarget: NSView { tableView }

    /// 当前目录（新建/粘贴/终端打开的落点）
    var currentDirectory: URL { model.directory }

    init(model: DirectoryViewModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        model.onUpdate = { [weak self] in self?.applySnapshot() }
        model.onError = { [weak self] message in self?.showEmptyState(message) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建 UI，无 xib") }

    override func loadView() {
        tableView.onInteract = { [weak self] in self?.onInteract?() }
        tableView.menuProvider = { [weak self] row in self?.buildMenu(clickedRow: row) }
        tableView.onReturn = { [weak self] in self?.beginRenameSelected() }
        tableView.onDragExited = { [weak self] in self?.cancelSpringLoad() }
        tableView.style = .plain  // 紧凑密度：去 inset 大留白（QSpace 式）
        tableView.intercellSpacing = NSSize(width: 8, height: 0)
        tableView.rowHeight = 22
        tableView.usesAutomaticRowHeights = false
        tableView.allowsMultipleSelection = true
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(didDoubleClick(_:))
        // 拖拽：拖出可达 Finder/其他 App/另一窗格/侧边栏/暂存架；拖入收 fileURL
        tableView.registerForDraggedTypes([.fileURL])
        tableView.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        tableView.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: false)

        addColumn(id: "name", title: L10n.t("column.name"), width: 280, min: 140)
        addColumn(id: "dateModified", title: L10n.t("column.dateModified"), width: 140, min: 90)
        addColumn(id: "size", title: L10n.t("column.size"), width: 76, min: 56, rightAlign: true)
        addColumn(id: "kind", title: L10n.t("column.kind"), width: 110, min: 70)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(scrollView)
        root.addSubview(emptyLabel)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 20),
        ])
        view = root
        model.reload()
    }

    private func addColumn(id: String, title: String, width: CGFloat, min: CGFloat, rightAlign: Bool = false) {
        let col = NSTableColumn(identifier: .init(id))
        col.title = title
        col.width = width
        col.minWidth = min
        col.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
        if rightAlign { col.headerCell.alignment = .right }
        tableView.addTableColumn(col)
    }

    private func applySnapshot() {
        emptyLabel.isHidden = true
        tableView.reloadData()
        if model.items.isEmpty, !model.isLoading {
            showEmptyState(L10n.t("empty.folder"))
        }
        revealPendingIfPossible()
    }

    private func showEmptyState(_ message: String) {
        emptyLabel.stringValue = message
        emptyLabel.isHidden = false
    }

    /// 仅重绘（剪切灰显变化时由协调器调用）
    func redraw() { tableView.reloadData() }

    // MARK: 选中态

    var selectedItems: [FileItem] {
        tableView.selectedRowIndexes.compactMap { model.items.indices.contains($0) ? model.items[$0] : nil }
    }
    var selectedURLs: [URL] { selectedItems.map(\.url) }

    // MARK: 显露（新建后选中并进入重命名）

    func prepareReveal(_ url: URL, rename: Bool) { pendingReveal = (url, rename) }

    private func revealPendingIfPossible() {
        guard let pending = pendingReveal,
              let row = model.items.firstIndex(where: { $0.url == pending.url }) else { return }
        pendingReveal = nil
        tableView.selectRowIndexes([row], byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
        if pending.rename { beginRename(row: row) }
    }

    // MARK: 打开行为（spec 功能 9：文件走系统默认 App；文件夹窗格内导航）

    @objc private func didDoubleClick(_ sender: Any?) {
        let row = tableView.clickedRow
        guard row >= 0, row < model.items.count else { return }
        open(model.items[row])
    }

    func open(_ item: FileItem) {
        if item.isDirectory && !item.isPackage {
            onNavigate?(item.url)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    // MARK: 右键菜单

    private func buildMenu(clickedRow row: Int) -> NSMenu {
        FileContextMenuBuilder.menu(selection: selectedItems, directory: currentDirectory, target: self)
    }

    // MARK: 行内重命名（FG-6：失败原子回滚旧名 + beep + 原位红字 2s）

    private func beginRenameSelected() {
        let rows = tableView.selectedRowIndexes
        guard rows.count == 1, let row = rows.first else { NSSound.beep(); return }
        beginRename(row: row)
    }

    func beginRename(row: Int) {
        guard row >= 0, row < model.items.count,
              let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? NameCellView
        else { return }
        let item = model.items[row]
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
        guard row >= 0, row < model.items.count else { return }
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

    @objc func getInfo(_ sender: Any?) {
        let target = selectedURLs.first ?? currentDirectory
        InfoPanel.show(for: target)
    }

    @objc func openInTerminal(_ sender: Any?) {
        // 选中文件夹则进其内，否则用当前目录
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
             #selector(copy(_:)), #selector(cut(_:)):
            return hasSelection
        case #selector(renameSelected(_:)):
            return single
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

// MARK: - 数据源 / 委托

extension FileListViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        model.items.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let colID = tableColumn?.identifier.rawValue, row < model.items.count else { return nil }
        let item = model.items[row]

        if colID == "name" {
            let cell = tableView.makeView(withIdentifier: .init("nameCell"), owner: nil) as? NameCellView
                ?? NameCellView(identifier: .init("nameCell"))
            let cut = coordinator?.isCut(item.url) ?? false
            cell.configure(icon: Formatters.icon(for: item),
                           name: item.name, dimmed: item.isHidden || cut)
            return cell
        }

        let cell = tableView.makeView(withIdentifier: .init("textCell"), owner: nil) as? TextCellView
            ?? TextCellView(identifier: .init("textCell"))
        switch colID {
        case "dateModified":
            cell.configure(item.modified.map { Formatters.date.string(from: $0) } ?? "—", alignment: .left)
        case "size":
            cell.configure(item.size.map { Formatters.size.string(fromByteCount: $0) } ?? "—", alignment: .right)
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

    // MARK: 拖拽源（可拖到 Finder/其他 App/另一窗格/侧边栏书签/暂存架）

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard row >= 0, row < model.items.count else { return nil }
        return model.items[row].url as NSURL
    }

    // MARK: 投放目标（BG-1：落点只发意图，kind 判定与提交在 coordinator）

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        guard let urls = Self.draggedFileURLs(info), !urls.isEmpty else {
            cancelSpringLoad(); return []
        }
        // 落点归一：目录行=投进该文件夹；文件行/空白=投进当前目录
        var targetRow = -1
        if op == .on, row >= 0, row < model.items.count,
           model.items[row].isDirectory, !model.items[row].isPackage {
            targetRow = row
        }
        let target = targetRow >= 0 ? model.items[targetRow].url : currentDirectory
        // 拒绝把目录投进它自己/子孙
        guard urls.allSatisfy({ !FileOpsCoordinator.isSelfOrDescendant(destination: target, ofSource: $0) }) else {
            cancelSpringLoad(); return []
        }
        // ⌥ 按下时 AppKit 已把源掩码过滤为 .copy → 强制复制
        let forceCopy = info.draggingSourceOperationMask == .copy
        // 全部来源已在目标目录：移动是无操作 → 拒绝（⌥ 复制放行，语义=制作副本）
        let destPath = target.standardizedFileURL.path
        if !forceCopy, urls.allSatisfy({ $0.standardizedFileURL.deletingLastPathComponent().path == destPath }) {
            cancelSpringLoad(); return []
        }
        if targetRow >= 0 {
            tableView.setDropRow(targetRow, dropOperation: .on)
            scheduleSpringLoad(row: targetRow, url: target)
        } else {
            tableView.setDropRow(-1, dropOperation: .on)  // 整表高亮 = 投进当前目录
            cancelSpringLoad()
        }
        if forceCopy { return .copy }
        // Finder 惯例：同卷=移动、跨卷=复制（光标反馈与实际提交一致）
        return urls.allSatisfy({ FileOpsCoordinator.isSameVolume($0, target) }) ? .move : .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo,
                   row: Int, dropOperation op: NSTableView.DropOperation) -> Bool {
        cancelSpringLoad()
        guard let urls = Self.draggedFileURLs(info), !urls.isEmpty else { return false }
        var target = currentDirectory
        if op == .on, row >= 0, row < model.items.count,
           model.items[row].isDirectory, !model.items[row].isPackage {
            target = model.items[row].url
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

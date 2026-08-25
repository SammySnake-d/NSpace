import AppKit
import NSpaceContracts

/// 列表视图（性能核心）：view-based NSTableView、固定行高、行复用、可排序列。
/// 只读消费 DirectoryViewModel（BG-1：本层无任何写型文件 API）。
@MainActor
final class FileListViewController: NSViewController {
    let model: DirectoryViewModel
    /// 导航意图上抛（由 Pane 历史协调）
    var onNavigate: ((URL) -> Void)?
    /// 用户交互上抛（窗格焦点协调）
    var onInteract: (() -> Void)?

    private let tableView = FocusReportingTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "")

    /// 键盘焦点落点（PaneGrid 激活时 makeFirstResponder 此视图）
    var focusTarget: NSView { tableView }

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
        tableView.style = .inset
        tableView.rowHeight = 24
        tableView.usesAutomaticRowHeights = false
        tableView.allowsMultipleSelection = true
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(didDoubleClick(_:))

        addColumn(id: "name", title: L10n.t("column.name"), width: 340, min: 160)
        addColumn(id: "dateModified", title: L10n.t("column.dateModified"), width: 170, min: 100)
        addColumn(id: "size", title: L10n.t("column.size"), width: 90, min: 60, rightAlign: true)
        addColumn(id: "kind", title: L10n.t("column.kind"), width: 160, min: 80)

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
    }

    private func showEmptyState(_ message: String) {
        emptyLabel.stringValue = message
        emptyLabel.isHidden = false
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

    // MARK: 菜单命令（响应链）

    @objc func toggleHiddenFiles(_ sender: Any?) {
        model.includeHidden.toggle()
    }

    @objc func refresh(_ sender: Any?) {
        model.reload()
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
            cell.configure(icon: Formatters.icon(forTypeID: item.contentTypeID, isDirectory: item.isDirectory),
                           name: item.name, dimmed: item.isHidden)
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
}

import AppKit
import UniformTypeIdentifiers
import SearchEngine

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

/// 结果表：Return=定位、Esc=关面板（其余交默认：方向键/双击）
@MainActor
private final class SearchResultTableView: NSTableView {
    var onReturn: (() -> Void)?
    var onEscape: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onReturn?()   // Return / Enter
        case 53: onEscape?()       // Esc
        default: super.keyDown(with: event)
        }
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

    private let engine = SearchEngine()
    /// 全量命中（流式累积）与过滤后展示集
    private var allHits: [SearchHit] = []
    private var hits: [SearchHit] = []
    private var searchTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var isSearching = false

    /// 打开时捕获的"当前文件夹"与定位回调（每次 show 重新注入）
    private var currentDirectory: URL?
    private var onReveal: ((URL) -> Void)?

    override private init() {
        panel = SearchPanel(contentRect: NSRect(x: 0, y: 0, width: 700, height: 460),
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
              onReveal: @escaping (URL) -> Void) {
        self.currentDirectory = currentDirectory
        self.onReveal = onReveal
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
        let scope: SearchRequest.Scope = scopePopup.indexOfSelectedItem == 0
            ? .global
            : .directory(currentDirectory ?? FileManager.default.homeDirectoryForCurrentUser)
        let request = SearchRequest(query: query, scope: scope,
                                    searchNames: nameCheck.state == .on,
                                    searchContents: contentCheck.state == .on,
                                    includeHidden: hiddenCheck.state == .on)
        searchTask = Task { [weak self] in
            guard let self else { return }
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
        hits.append(contentsOf: visible)
        tableView.reloadData()
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
        hits = filter == .all ? allHits : allHits.filter { filter.matches($0) }
        tableView.reloadData()
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
        for (id, width) in [("name", CGFloat(400)), ("size", 80), ("dateModified", 150)] {
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

        let sep1 = NSBox(); sep1.boxType = .separator
        let sep2 = NSBox(); sep2.boxType = .separator

        for sub in [icon, field, spinner, scopePopup, sep1,
                    nameCheck, contentCheck, hiddenCheck, kindPopup, sep2,
                    scroll, emptyLabel] {
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
        case "size":
            cell.configure(hit.size.map { Formatters.size.string(fromByteCount: $0) } ?? "—", alignment: .right)
        case "dateModified":
            cell.configure(hit.modified.map { Formatters.date.string(from: $0) } ?? "—", alignment: .left)
        default:
            cell.configure("", alignment: .left)
        }
        return cell
    }
}

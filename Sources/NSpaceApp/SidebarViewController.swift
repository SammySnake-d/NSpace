import AppKit
import NSpaceContracts
import VolumeInfo
import BookmarkStore

/// 左侧边栏：source list 三分组（起始位置/书签/位置）。
/// 只读+发导航意图（BG-1）；书签增删改经 BookmarkStore 胶囊提交。
@MainActor
final class SidebarViewController: NSViewController {
    let model: SidebarModel
    var onNavigate: ((URL) -> Void)?

    private let outline = NSOutlineView()
    private let scroll = NSScrollView()
    private let banner = NSTextField(labelWithString: "")
    private var bannerTimer: Timer?
    /// 书签内部重排的拖拽类型
    private static let reorderType = NSPasteboard.PasteboardType("com.nspace.sidebar.bookmark")

    init(model: SidebarModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        model.onChange = { [weak self] in self?.reload() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建 UI，无 xib") }

    override func loadView() {
        let column = NSTableColumn(identifier: .init("main"))
        column.isEditable = false
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.floatsGroupRows = false
        outline.rowSizeStyle = .default
        outline.dataSource = self
        outline.delegate = self
        outline.registerForDraggedTypes([.fileURL, Self.reorderType])
        outline.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        outline.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: false)
        outline.menu = NSMenu()
        outline.menu?.delegate = self

        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        // 推出失败等错误的原位横幅（3s 自动隐退，严禁模态弹窗）
        banner.isHidden = true
        banner.font = .systemFont(ofSize: 11)
        banner.textColor = .systemRed
        banner.lineBreakMode = .byTruncatingTail
        banner.maximumNumberOfLines = 2

        let root = NSView()
        for sub in [scroll, banner] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(sub)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: banner.topAnchor),
            banner.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            banner.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            banner.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
        ])
        view = root

        model.start()
    }

    private func reload() {
        // 暂存架错误（AirDrop 不可用/落盘失败等）原位横幅（幂等重挂，stash 注入晚于 loadView）
        model.stash?.onError = { [weak self] message in self?.showBanner(message) }
        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)
    }

    private func showBanner(_ message: String) {
        banner.stringValue = message
        banner.isHidden = false
        bannerTimer?.invalidate()
        bannerTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.banner.isHidden = true }
        }
    }

    // MARK: 推出

    @objc private func ejectClicked(_ sender: NSButton) {
        let row = outline.row(for: sender)
        guard row >= 0, let leaf = outline.item(atRow: row) as? SidebarLeafNode,
              case let .volume(vol) = leaf.payload else { return }
        do {
            try model.eject(vol)
        } catch {
            showBanner(String(format: L10n.t("sidebar.ejectFailed"), vol.name, error.localizedDescription))
        }
    }

    // MARK: 书签操作

    @objc private func renameBookmark(_ sender: NSMenuItem) {
        guard let leaf = sender.representedObject as? SidebarLeafNode else { return }
        let row = outline.row(forItem: leaf)
        guard row >= 0,
              let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView,
              let field = cell.textField else { return }
        field.isEditable = true
        field.delegate = self
        outline.window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    @objc private func removeBookmark(_ sender: NSMenuItem) {
        guard let leaf = sender.representedObject as? SidebarLeafNode,
              case let .bookmark(item) = leaf.payload else { return }
        Task {
            try? await model.bookmarkStore.remove(item.id)
            model.rebuild()
        }
    }

    // MARK: 暂存架操作（增删清经 StashStore 胶囊提交）

    @objc private func removeStashItem(_ sender: NSMenuItem) {
        guard let leaf = sender.representedObject as? SidebarLeafNode,
              case let .stash(item) = leaf.payload else { return }
        model.stash?.remove(ids: [item.id])
    }

    @objc private func clearStash(_ sender: NSMenuItem) {
        model.stash?.clearAll()
    }
}

// MARK: - 数据源

extension SidebarViewController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return model.groups.count }
        return (item as? SidebarGroupNode)?.children.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return model.groups[index] }
        return (item as! SidebarGroupNode).children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is SidebarGroupNode
    }

    // 拖出：书签=重排源；暂存项=resolve 后真实 URL（可投放到任何 fileURL 目标）
    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        guard let leaf = item as? SidebarLeafNode else { return nil }
        switch leaf.payload {
        case .bookmark:
            guard let group = model.groups.first(where: { $0.kind == .bookmarks }),
                  let index = group.children.firstIndex(where: { $0 === leaf }) else { return nil }
            let pb = NSPasteboardItem()
            pb.setString(String(index), forType: Self.reorderType)
            return pb
        case .stash:
            return leaf.url.map { $0 as NSURL }
        default:
            return nil
        }
    }

    /// 投放落点归一：命中暂存架分组本体或其行 → 暂存架分组
    private func stashDropGroup(for item: Any?) -> SidebarGroupNode? {
        let stashGroup = model.groups.first { $0.kind == .stash }
        if let group = item as? SidebarGroupNode, group.kind == .stash { return stashGroup }
        if let leaf = item as? SidebarLeafNode,
           stashGroup?.children.contains(where: { $0 === leaf }) == true { return stashGroup }
        return nil
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo,
                     proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        let isBookmarkGroup = (item as? SidebarGroupNode)?.kind == .bookmarks
        if info.draggingPasteboard.types?.contains(Self.reorderType) == true {
            return isBookmarkGroup && index >= 0 ? .move : []
        }
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        guard !urls.isEmpty else { return [] }
        // 拖到暂存架分组：文件与目录都收（与书签组只收目录不同）
        if let stashGroup = stashDropGroup(for: item) {
            outlineView.setDropItem(stashGroup, dropChildIndex: NSOutlineViewDropOnItemIndex)
            return .copy
        }
        // 外部文件拖入书签：只收目录，落点强制书签分组
        guard isBookmarkGroup || item == nil else { return [] }
        let allDirs = urls.allSatisfy {
            var d: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0.path, isDirectory: &d) && d.boolValue
        }
        if allDirs {
            outlineView.setDropItem(model.groups.first { $0.kind == .bookmarks }, dropChildIndex: NSOutlineViewDropOnItemIndex)
            return .copy
        }
        return []
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo,
                     item: Any?, childIndex index: Int) -> Bool {
        if let str = info.draggingPasteboard.string(forType: Self.reorderType), let from = Int(str) {
            let to = index > from ? index - 1 : index
            Task {
                try? await model.bookmarkStore.move(from: from, to: to)
                model.rebuild()
            }
            return true
        }
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        // 投进暂存架分组 = 加入暂存（StashStore 去重）
        if (item as? SidebarGroupNode)?.kind == .stash {
            model.stash?.add(urls)
            return true
        }
        Task {
            for url in urls {
                try? await model.bookmarkStore.add(url)
            }
            model.rebuild()
        }
        return true
    }
}

// MARK: - 委托

extension SidebarViewController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        item is SidebarGroupNode
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let leaf = item as? SidebarLeafNode else { return false }
        switch leaf.payload {
        case .stashAction(let action):
            // 操作行不进入选中态：鼠标点击即触发（键盘走查经过时不得误触发文件操作）
            if let event = NSApp.currentEvent,
               event.type == .leftMouseDown || event.type == .leftMouseUp {
                model.stash?.perform(action)
            }
            return false
        case .stash, .stashHint:
            // 暂存行是"架"不是导航项：不选中（拖出/右键仍可用）
            return false
        default:
            return leaf.url != nil
        }
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let group = item as? SidebarGroupNode {
            let cell = outlineView.makeView(withIdentifier: .init("group"), owner: nil) as? NSTableCellView
                ?? makeGroupCell()
            cell.textField?.stringValue = group.title
            return cell
        }
        guard let leaf = item as? SidebarLeafNode else { return nil }
        let cell = outlineView.makeView(withIdentifier: .init("leaf"), owner: nil) as? SidebarLeafCell
            ?? SidebarLeafCell(identifier: .init("leaf"))
        var ejectable = false
        if case let .volume(vol) = leaf.payload { ejectable = vol.isEjectable && !vol.isRoot }
        cell.configure(leaf: leaf, ejectable: ejectable,
                       ejectTarget: self, ejectAction: #selector(ejectClicked(_:)))
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let leaf = outline.item(atRow: outline.selectedRow) as? SidebarLeafNode,
              let url = leaf.url else { return }
        onNavigate?(url)
    }

    private func makeGroupCell() -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = .init("group")
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}

// MARK: - 右键菜单（书签：重命名/移除；暂存架：移除/清空）

extension SidebarViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outline.clickedRow
        guard row >= 0 else { return }
        let clicked = outline.item(atRow: row)
        // 暂存架分组标题：给"清空暂存架"（有暂存项时）
        if let group = clicked as? SidebarGroupNode, group.kind == .stash {
            addClearStashItem(to: menu)
            return
        }
        guard let leaf = clicked as? SidebarLeafNode else { return }
        switch leaf.payload {
        case .bookmark:
            let rename = menu.addItem(withTitle: L10n.t("sidebar.rename"),
                                      action: #selector(renameBookmark(_:)), keyEquivalent: "")
            rename.target = self
            rename.representedObject = leaf
            let remove = menu.addItem(withTitle: L10n.t("sidebar.remove"),
                                      action: #selector(removeBookmark(_:)), keyEquivalent: "")
            remove.target = self
            remove.representedObject = leaf
        case .stash:
            let remove = menu.addItem(withTitle: L10n.t("stash.remove"),
                                      action: #selector(removeStashItem(_:)), keyEquivalent: "")
            remove.target = self
            remove.representedObject = leaf
            addClearStashItem(to: menu)
        default:
            break
        }
    }

    private func addClearStashItem(to menu: NSMenu) {
        guard model.stash?.items.isEmpty == false else { return }
        let clear = menu.addItem(withTitle: L10n.t("stash.clear"),
                                 action: #selector(clearStash(_:)), keyEquivalent: "")
        clear.target = self
    }
}

// MARK: - 书签行内重命名提交

extension SidebarViewController: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        field.isEditable = false
        let row = outline.row(for: field)
        guard row >= 0, let leaf = outline.item(atRow: row) as? SidebarLeafNode,
              case let .bookmark(item) = leaf.payload else { return }
        let newName = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !newName.isEmpty, newName != item.name else {
            field.stringValue = item.name  // FG-6：无效输入回滚旧名
            return
        }
        Task {
            try? await model.bookmarkStore.rename(item.id, to: newName)
            model.rebuild()
        }
    }
}

/// 侧栏叶子行：图标+标题（+容量副标题）（+推出钮）
@MainActor
final class SidebarLeafCell: NSTableCellView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let eject = NSButton()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        title.font = .systemFont(ofSize: 13)
        title.lineBreakMode = .byTruncatingTail
        subtitle.font = .systemFont(ofSize: 10)
        subtitle.textColor = .tertiaryLabelColor
        eject.image = NSImage(systemSymbolName: "eject.fill", accessibilityDescription: L10n.t("sidebar.eject"))
        eject.symbolConfiguration = .init(pointSize: 10, weight: .regular)
        eject.isBordered = false
        eject.contentTintColor = .secondaryLabelColor
        eject.toolTip = L10n.t("sidebar.eject")
        for sub in [icon, title, subtitle, eject] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            addSubview(sub)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            title.trailingAnchor.constraint(lessThanOrEqualTo: eject.leadingAnchor, constant: -4),
            title.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -1),
            subtitle.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 6),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: eject.leadingAnchor, constant: -4),
            subtitle.centerYAnchor.constraint(equalTo: centerYAnchor),
            eject.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            eject.centerYAnchor.constraint(equalTo: centerYAnchor),
            eject.widthAnchor.constraint(equalToConstant: 18),
        ])
        imageView = icon
        textField = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建 UI，无 xib") }

    func configure(leaf: SidebarLeafNode, ejectable: Bool, ejectTarget: AnyObject, ejectAction: Selector) {
        icon.image = leaf.icon
        title.stringValue = leaf.title
        // 标题色：显式覆盖优先（暂存操作行/丢失项）；否则目标丢失置灰
        title.textColor = leaf.titleColor ?? (leaf.url == nil ? .tertiaryLabelColor : .labelColor)
        subtitle.stringValue = leaf.subtitle ?? ""
        subtitle.isHidden = leaf.subtitle == nil
        eject.isHidden = !ejectable
        eject.target = ejectTarget
        eject.action = ejectAction
    }
}

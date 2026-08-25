import AppKit
import NSpaceContracts
import VolumeInfo
import BookmarkStore

/// 左侧边栏：source list 分组（书签/iCloud/位置，可拖动标题行重排）。
/// 只读+发导航意图（BG-1）；书签增删改经 BookmarkStore 胶囊提交。
@MainActor
final class SidebarViewController: NSViewController {
    let model: SidebarModel
    var onNavigate: ((URL) -> Void)?

    private let stashView = StashShelfView()
    /// 暂存架专区视图（UISelfTest I-07 居中度量入口；M17 §5）
    var stashShelfView: StashShelfView { stashView }
    private let outline = NSOutlineView()
    private let scroll = NSScrollView()
    private let banner = NSTextField(labelWithString: "")
    private var bannerTimer: Timer?
    /// 书签内部重排的拖拽类型
    private static let reorderType = NSPasteboard.PasteboardType("com.nspace.sidebar.bookmark")
    /// 分组标题行重排的拖拽类型（用户点名：书签可拖到最前）
    private static let groupType = NSPasteboard.PasteboardType("com.nspace.sidebar.group")

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
        outline.rowSizeStyle = .small  // QSpace 式紧凑行高
        outline.dataSource = self
        outline.delegate = self
        outline.registerForDraggedTypes([.fileURL, Self.reorderType, Self.groupType])
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
        let stashSeparator = NSBox()
        stashSeparator.boxType = .separator
        for sub in [stashView, stashSeparator, scroll, banner] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(sub)
        }
        NSLayoutConstraint.activate([
            // QSpace 式顶格：侧栏直通窗口顶，仅留红绿灯行高度（不锚 safeArea/不被工具栏推下）
            stashView.topAnchor.constraint(equalTo: root.topAnchor, constant: 36),
            stashView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stashView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stashSeparator.topAnchor.constraint(equalTo: stashView.bottomAnchor),
            stashSeparator.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            stashSeparator.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: stashSeparator.bottomAnchor, constant: 4),
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
        // 暂存架专区注入（幂等；stash 注入晚于 loadView）+ 错误原位横幅
        if let stash = model.stash {
            stash.onError = { [weak self] message in self?.showBanner(message) }
            stashView.attach(stash)
        }
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

    // 拖出：分组标题=组重排源；书签=重排源；暂存项=resolve 后真实 URL（可投放到任何 fileURL 目标）
    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        if let group = item as? SidebarGroupNode {
            let pb = NSPasteboardItem()
            pb.setString(group.kind.rawValue, forType: Self.groupType)
            return pb
        }
        guard let leaf = item as? SidebarLeafNode else { return nil }
        guard case .bookmark = leaf.payload,
              let group = model.groups.first(where: { $0.kind == .bookmarks }),
              let index = group.children.firstIndex(where: { $0 === leaf }) else { return nil }
        let pb = NSPasteboardItem()
        pb.setString(String(index), forType: Self.reorderType)
        return pb
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo,
                     proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        // 分组重排：仅允许组拖到根级（item==nil）分组之间（index>=0，非落在某行正中）
        if info.draggingPasteboard.types?.contains(Self.groupType) == true {
            if item == nil && index >= 0 { return .move }
            // 悬停在某分组/条目上 → 重定向到根级缝隙（不接收落在正中）
            outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
            return []
        }
        let isBookmarkGroup = (item as? SidebarGroupNode)?.kind == .bookmarks
        if info.draggingPasteboard.types?.contains(Self.reorderType) == true {
            return isBookmarkGroup && index >= 0 ? .move : []
        }
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        guard !urls.isEmpty else { return [] }
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
        // 分组重排：重排 Preferences.sidebarGroupOrder 并 rebuild
        if let kindStr = info.draggingPasteboard.string(forType: Self.groupType) {
            reorderGroups(movingKind: kindStr, toVisibleIndex: index)
            return true
        }
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
        Task {
            for url in urls {
                try? await model.bookmarkStore.add(url)
            }
            model.rebuild()
        }
        return true
    }

    /// 组重排：把可见分组顺序按拖放落点重算，合并回持久化全序（隐藏的空 iCloud 组置尾不影响呈现）
    private func reorderGroups(movingKind kindStr: String, toVisibleIndex index: Int) {
        let visible = model.groups.map { $0.kind.rawValue }
        guard let from = visible.firstIndex(of: kindStr) else { return }
        var newVisible = visible
        let moved = newVisible.remove(at: from)
        let dest = from < index ? index - 1 : index
        newVisible.insert(moved, at: min(max(dest, 0), newVisible.count))
        // 合并进持久化全序：补齐三键 → 隐藏键（不在可见列表）追尾，可见键按新序在前
        var full = Preferences.sidebarGroupOrder
        for key in [SidebarGroupNode.Kind.bookmarks.rawValue,
                    SidebarGroupNode.Kind.icloud.rawValue,
                    SidebarGroupNode.Kind.volumes.rawValue] where !full.contains(key) {
            full.append(key)
        }
        let hidden = full.filter { !newVisible.contains($0) }
        Preferences.sidebarGroupOrder = newVisible + hidden
        model.rebuild()
    }
}

// MARK: - 委托

extension SidebarViewController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        item is SidebarGroupNode
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? SidebarLeafNode)?.url != nil
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
        guard let leaf = outline.item(atRow: row) as? SidebarLeafNode,
              case .bookmark = leaf.payload else { return }
        let rename = menu.addItem(withTitle: L10n.t("sidebar.rename"),
                                  action: #selector(renameBookmark(_:)), keyEquivalent: "")
        rename.target = self
        rename.representedObject = leaf
        let remove = menu.addItem(withTitle: L10n.t("sidebar.remove"),
                                  action: #selector(removeBookmark(_:)), keyEquivalent: "")
        remove.target = self
        remove.representedObject = leaf
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
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            title.trailingAnchor.constraint(lessThanOrEqualTo: eject.leadingAnchor, constant: -4),
            title.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -1),
            subtitle.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 8),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: eject.leadingAnchor, constant: -4),
            subtitle.centerYAnchor.constraint(equalTo: centerYAnchor),
            eject.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            eject.centerYAnchor.constraint(equalTo: centerYAnchor),
            eject.widthAnchor.constraint(equalToConstant: 20),
        ])
        imageView = icon
        textField = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建 UI，无 xib") }

    func configure(leaf: SidebarLeafNode, ejectable: Bool, ejectTarget: AnyObject, ejectAction: Selector) {
        icon.image = leaf.icon
        icon.contentTintColor = leaf.tint  // Finder 式蓝色收藏（nil=原色）
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

import AppKit
import QuickLookUI
import UniformTypeIdentifiers
import NSpaceContracts
import IconThumb

/// 交互上报的图标网格集合视图：点击即请求激活所属窗格；右键菜单钩子；
/// 空格 Quick Look、双击打开；Return 不支持重命名（诚实 beep，不装）
@MainActor
final class IconGridCollectionView: NSCollectionView {
    var onInteract: (() -> Void)?
    /// 右键菜单提供者：入参为点击到的条目（nil 表示空白区，走目录级菜单）
    var menuProvider: ((IndexPath?) -> NSMenu?)?
    var onSpace: (() -> Void)?
    var onDoubleClick: ((IndexPath) -> Void)?

    override func mouseDown(with event: NSEvent) {
        onInteract?()
        super.mouseDown(with: event)
        // 双击：selection 已由 super 处理，再派发打开
        if event.clickCount == 2 {
            let point = convert(event.locationInWindow, from: nil)
            if let ip = indexPathForItem(at: point) { onDoubleClick?(ip) }
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onInteract?()
        super.rightMouseDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        onInteract?()
        return super.becomeFirstResponder()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        onInteract?()
        let point = convert(event.locationInWindow, from: nil)
        let ip = indexPathForItem(at: point)
        // 右击未选中条目 → 先把它设为唯一选中（Finder 语义）
        if let ip, !selectionIndexPaths.contains(ip) {
            deselectAll(nil)
            selectItems(at: [ip], scrollPosition: [])
        }
        return menuProvider?(ip)
    }

    override func keyDown(with event: NSEvent) {
        // 纯 ⌘↑/⌘↓ 落到网格 = 导航菜单未接（禁用态）——吞掉，不让默认选中跳变顶替导航语义（I-39）；
        // 带 ⇧/⌥/⌃ 的组合不吞，保持系统行为
        if event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
           event.keyCode == 125 || event.keyCode == 126 { return }
        // 空格（49）Quick Look；Return（36/76）图标视图不支持行内重命名——诚实 beep
        if event.keyCode == 49, let onSpace {
            onSpace()
            return
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            NSSound.beep()
            return
        }
        super.keyDown(with: event)
    }
}

/// 图标网格单元：图标（尺寸随滑块）+ 两行截断文件名 + 圆角选中底
@MainActor
final class FileIconItem: NSCollectionViewItem {
    static let reuseID = NSUserInterfaceItemIdentifier("fileIconItem")

    private let backdrop = NSView()
    private let icon = NSImageView()
    private let label = NSTextField(wrappingLabelWithString: "")

    override func loadView() {
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 6
        backdrop.translatesAutoresizingMaskIntoConstraints = false

        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false

        label.font = .systemFont(ofSize: 11)
        label.alignment = .center
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let root = NSView()
        root.addSubview(backdrop)
        root.addSubview(icon)
        root.addSubview(label)
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: root.topAnchor, constant: 2),
            backdrop.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -2),
            backdrop.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 2),
            backdrop.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -2),
            // 图标区：左右 16 内边距成正方形（itemSize = 图标边长 + 32）
            icon.topAnchor.constraint(equalTo: root.topAnchor, constant: 4),
            icon.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            icon.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            icon.heightAnchor.constraint(equalTo: icon.widthAnchor),
            label.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 4),
            label.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -4),
            label.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -4),
        ])
        view = root
        imageView = icon
        textField = label
    }

    override var isSelected: Bool { didSet { updateSelection() } }
    override var highlightState: NSCollectionViewItem.HighlightState { didSet { updateSelection() } }

    private func updateSelection() {
        let active = isSelected || highlightState == .forSelection
        backdrop.layer?.backgroundColor = active
            ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.30).cgColor
            : NSColor.clear.cgColor
    }

    func configure(icon image: NSImage, name: String, dimmed: Bool) {
        icon.image = image
        icon.alphaValue = dimmed ? 0.5 : 1.0
        label.stringValue = name
        label.textColor = dimmed ? .secondaryLabelColor : .labelColor
    }

    /// 缩略图到货：只换图不重建（不打断选中态）
    func setIcon(_ image: NSImage) {
        icon.image = image
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        icon.image = nil
        icon.alphaValue = 1.0
        label.stringValue = ""
    }
}

/// 图标网格视图（M9 ⌘1）：NSCollectionView + FlowLayout，图标 48~128 可调（滑块，App 层偏好）。
/// 与列表共享同一 DirectoryViewModel（onUpdate 多播）——本层只读消费（BG-1 零写型文件 API）；
/// 缩略图只对可见项异步请求、滚出/挂起即取消（北极星零浪费）；语义与列表一致：
/// 双击打开、右键菜单复用 builder、拖出/投放同判卷规则、空格 Quick Look。
/// 行内重命名本期不支持（菜单项诚实灰显，不装假）。
@MainActor
final class FileIconGridViewController: NSViewController, FileRevealTarget {
    let model: DirectoryViewModel
    weak var coordinator: FileOpsCoordinator?
    var onNavigate: ((URL) -> Void)?
    var onInteract: (() -> Void)?
    var onSelectionChange: (() -> Void)?
    var onContentChange: (() -> Void)?

    private let collectionView = IconGridCollectionView()
    private let flowLayout = NSCollectionViewFlowLayout()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let sizeSlider = NSSlider()

    /// 操作完成后待显露（选中）的目标；图标视图不支持行内重命名，rename 标志忽略
    private var pendingReveal: (url: URL, rename: Bool)?

    /// 选中态 URL 缓存（I-32）：随选中变更记账，作 applySnapshot 恢复选中的真源。
    /// 直接用 selectionIndexPaths 反查会错映（model.items 已换新），造成删除后选中"漂移"到顶项。
    private var selectionURLCache: Set<URL> = []

    // 分组视图态（M26 v2）：section↔model 下标映射的唯一真源，别处严禁散落 index 算术。
    // 不分组时为单 section 全量（identity 映射）；分组时每 section 一组。
    private var sections: [FileGrouping.Group] = []
    private var collapsedGroups: Set<String> = []
    private var groupFilterKey: String?
    private let filterPill = FilterPillButton(frame: .zero)

    // 装饰状态（派生显示层，可随时丢弃）
    private var thumbOverlay: [URL: NSImage] = [:]
    private var thumbTasks: [URL: Task<Void, Never>] = [:]
    /// 缩略图资格按 UTType 缓存（滚动路径零重复 conforms 计算）
    private static var thumbEligible: [String: Bool] = [:]

    /// 图标大小（App 层偏好，所有窗格网格共用；出现时对齐最新值）
    static var preferredIconSize: CGFloat {
        get {
            let v = UserDefaults.standard.double(forKey: "iconGridSize")
            return (48...128).contains(v) ? CGFloat(v) : 80
        }
        set { UserDefaults.standard.set(Double(newValue), forKey: "iconGridSize") }
    }
    private var iconSize: CGFloat = FileIconGridViewController.preferredIconSize

    var focusTarget: NSView { collectionView }

    init(model: DirectoryViewModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        model.addOnUpdate { [weak self] in self?.applySnapshot() }
        model.addOnError { [weak self] message in self?.showEmptyState(message) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建 UI，无 xib") }

    override func loadView() {
        flowLayout.minimumInteritemSpacing = 8
        flowLayout.minimumLineSpacing = 8
        flowLayout.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        flowLayout.sectionHeadersPinToVisibleBounds = true   // M26 v2：组头悬浮（对齐列表 floatsGroupRows）

        collectionView.collectionViewLayout = flowLayout
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(FileIconItem.self, forItemWithIdentifier: FileIconItem.reuseID)
        collectionView.register(IconGroupHeaderView.self,
                                forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                                withIdentifier: IconGroupHeaderView.reuseID)
        collectionView.onInteract = { [weak self] in self?.onInteract?() }
        collectionView.menuProvider = { [weak self] _ in self?.buildMenu() }
        collectionView.onSpace = { [weak self] in self?.toggleQuickLook(nil) }
        collectionView.onDoubleClick = { [weak self] ip in
            guard let self, let file = self.fileItem(at: ip) else { return }
            self.open(file)
        }
        // 拖拽：语义与列表一致（拖出 NSURL；投放到目录项或空白=当前目录，⌥ 复制）
        collectionView.registerForDraggedTypes([.fileURL])
        collectionView.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        collectionView.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: false)

        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        // 滚动/尺寸变化 → 重算可见项缩略图请求（只对可见项发请求，滚出取消）
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrollBoundsChanged(_:)),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        // 分组开关变更广播：重建 section 即时生效（与列表共用同一通知）
        NotificationCenter.default.addObserver(
            self, selector: #selector(groupingChanged(_:)),
            name: Notification.Name.nspaceGroupingChanged, object: nil)

        // 底部工具条：图标大小滑块（4pt 网格：高 24、右缘 8）
        let separator = NSBox()
        separator.boxType = .separator
        let bottomBar = NSView()
        sizeSlider.minValue = 48
        sizeSlider.maxValue = 128
        sizeSlider.doubleValue = Double(iconSize)
        sizeSlider.isContinuous = true
        sizeSlider.controlSize = .small
        sizeSlider.target = self
        sizeSlider.action = #selector(sliderChanged(_:))
        sizeSlider.toolTip = L10n.t("iconGrid.sizeTooltip")
        filterPill.target = self
        filterPill.action = #selector(clearGroupFilter(_:))
        filterPill.isHidden = true
        for sub in [separator, sizeSlider, filterPill] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            bottomBar.addSubview(sub)
        }
        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: bottomBar.topAnchor),
            separator.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor),
            sizeSlider.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -8),
            sizeSlider.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            sizeSlider.widthAnchor.constraint(equalToConstant: 120),
            filterPill.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 8),
            filterPill.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
        ])

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true

        let root = NSView()
        for sub in [scrollView, bottomBar, emptyLabel] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(sub)
        }
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),
            bottomBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: 24),
            emptyLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 20),
        ])
        view = root
        applyIconSize()
        applySnapshot()   // 共享 model 通常已有快照（列表先行加载），直接呈现
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // 其他窗格可能改过 App 层图标大小偏好：出现时对齐
        let preferred = Self.preferredIconSize
        if preferred != iconSize {
            iconSize = preferred
            sizeSlider.doubleValue = Double(preferred)
            applyIconSize()
        }
    }

    // MARK: 图标大小（滑块，UserDefaults App 层）

    @objc private func sliderChanged(_ sender: NSSlider) {
        let size = CGFloat(sender.doubleValue.rounded())
        guard size != iconSize else { return }
        iconSize = size
        Self.preferredIconSize = size
        applyIconSize()
    }

    private func applyIconSize() {
        flowLayout.itemSize = NSSize(width: iconSize + 32, height: iconSize + 42)
        flowLayout.invalidateLayout()
    }

    // MARK: 快照呈现

    private var lastSnapshotDirectory: URL?

    private func applySnapshot() {
        if lastSnapshotDirectory != model.directory {
            lastSnapshotDirectory = model.directory
            cancelDecorationWork()
        }
        // 同目录刷新也清缩略图覆盖层：文件可能已改内容（IconThumb 缓存键含 mtime）
        thumbOverlay.removeAll()
        emptyLabel.isHidden = true
        let kept = selectionURLCache   // I-32：删除前实际选中的真源（不用位移后的 selectionIndexPaths）
        rebuildSections()              // M26 v2：分组时重建 section↔model 映射（reloadData 前）
        collectionView.reloadData()
        select(urls: Array(kept), scroll: false)   // 空集也走 → deselectAll 显式清空（被删项不"漂移"到新项）
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

    /// 仅重绘可见项（剪切灰显变化，无需重建/重新读盘）
    func redraw() {
        for ip in collectionView.indexPathsForVisibleItems() {
            guard let cell = collectionView.item(at: ip) as? FileIconItem,
                  let file = fileItem(at: ip) else { continue }
            let cut = coordinator?.isCut(file.url) ?? false
            cell.configure(icon: thumbOverlay[file.url] ?? Formatters.fullIcon(for: file),
                           name: file.name, dimmed: file.isHidden || cut)
        }
    }

    // MARK: 分组换算（M26 v2）——section↔model 下标映射唯一真源

    private var groupingActive: Bool { FileGrouping.active(model.sort) }

    /// 依当前 model.items（reader 已排序）重建 section 序列 + 刷过滤药丸。
    private func rebuildSections() {
        if groupingActive {
            var gs = FileGrouping.buckets(model.items, key: model.sort.key)
            if let only = groupFilterKey, !gs.contains(where: { $0.key == only }) { groupFilterKey = nil }
            if let only = groupFilterKey { gs = gs.filter { $0.key == only } }
            sections = gs
        } else {
            sections = [FileGrouping.Group(key: "__all__", title: "", indices: Array(model.items.indices))]
            groupFilterKey = nil
        }
        updateFilterPill()
        flowLayout.headerReferenceSize = groupingActive ? NSSize(width: 100, height: 28) : .zero
        flowLayout.invalidateLayout()
    }

    /// section+item 下标 → model.items 下标（折叠 section 无可见项 → nil）
    private func modelIndex(at ip: IndexPath) -> Int? {
        guard sections.indices.contains(ip.section) else { return nil }
        let sec = sections[ip.section]
        if groupingActive, collapsedGroups.contains(sec.key) { return nil }
        guard sec.indices.indices.contains(ip.item) else { return nil }
        return sec.indices[ip.item]
    }

    private func fileItem(at ip: IndexPath) -> FileItem? {
        guard let i = modelIndex(at: ip), model.items.indices.contains(i) else { return nil }
        return model.items[i]
    }

    /// model 下标 → indexPath（在折叠/被过滤 section 内 → nil）
    private func indexPath(forModelIndex idx: Int) -> IndexPath? {
        for (s, sec) in sections.enumerated() {
            if groupingActive, collapsedGroups.contains(sec.key) { continue }
            if let pos = sec.indices.firstIndex(of: idx) { return IndexPath(item: pos, section: s) }
        }
        return nil
    }

    private func updateFilterPill() {
        if let only = groupFilterKey, let g = sections.first(where: { $0.key == only }) {
            filterPill.title = L10n.f("group.filter.pill", g.title)
            filterPill.isHidden = false
        } else {
            filterPill.isHidden = true
        }
    }

    /// 重建 section + reload（保 URL 选中）——折叠/过滤/开关变更共用
    private func rebuildAndReloadPreservingSelection() {
        let kept = selectionURLCache
        rebuildSections()
        collectionView.reloadData()
        select(urls: Array(kept), scroll: false)
    }

    @objc func toggleGrouping(_ sender: Any?) {
        Preferences.listGrouping.toggle()
        NotificationCenter.default.post(name: Notification.Name.nspaceGroupingChanged, object: nil)
    }

    @objc private func groupingChanged(_ note: Notification) {
        rebuildAndReloadPreservingSelection()
    }

    private func toggleGroup(key: String) {
        if collapsedGroups.contains(key) { collapsedGroups.remove(key) } else { collapsedGroups.insert(key) }
        rebuildAndReloadPreservingSelection()
    }

    private func applyGroupFilter(key: String) { groupFilterKey = key; rebuildAndReloadPreservingSelection() }
    @objc private func clearGroupFilter(_ sender: Any?) { groupFilterKey = nil; rebuildAndReloadPreservingSelection() }
    @objc private func groupFilterOnly(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        applyGroupFilter(key: key)
    }
    @objc private func groupFilterAll(_ sender: Any?) { groupFilterKey = nil; rebuildAndReloadPreservingSelection() }

    /// UISelfTest（M26 v2）：可见 section 数（分组开=组数；关=1）
    var uiTestSectionCount: Int { sections.count }
    var uiTestGroupTitles: [String] { sections.map(\.title) }
    var uiTestCollapsedCount: Int { collapsedGroups.count }
    func uiTestToggleFirstGroup() { if let k = sections.first?.key { toggleGroup(key: k) } }
    func uiTestFilterFirstGroup() { if let k = sections.first?.key { applyGroupFilter(key: k) } }
    func uiTestClearFilter() { groupFilterKey = nil; rebuildAndReloadPreservingSelection() }
    var uiTestFilterPillVisible: Bool { !filterPill.isHidden }

    // MARK: 按需缩略图（只对可见项、滚出取消——北极星零浪费）

    @objc private func scrollBoundsChanged(_ note: Notification) {
        refreshVisibleDecorations()
    }

    /// 取消全部在飞缩略图请求（标签/窗格挂起、目录切换时调用；已回填结果保留）
    func cancelDecorationWork() {
        thumbTasks.values.forEach { $0.cancel() }
        thumbTasks.removeAll()
    }

    /// 对当前可见项发起缺失的缩略图请求；不再可见的在飞请求全部取消
    func refreshVisibleDecorations() {
        guard view.window != nil, !model.items.isEmpty else { return }
        var wanted = Set<URL>()
        for ip in collectionView.indexPathsForVisibleItems() {
            guard let item = fileItem(at: ip) else { continue }
            if thumbOverlay[item.url] == nil, wantsThumbnail(item) {
                wanted.insert(item.url)
                requestThumbnail(item.url)
            }
        }
        for (url, task) in thumbTasks where !wanted.contains(url) {
            task.cancel(); thumbTasks[url] = nil
        }
    }

    /// 有内容缩略图价值的类型：图片/影音/PDF；目录与应用包用类型图标（不发 QuickLook 请求）
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

    private func requestThumbnail(_ url: URL) {
        guard thumbTasks[url] == nil else { return }
        // 统一按 128pt 上限请求（内部 x2 像素）：滑块缩放只影响显示端，不反复重新生成
        thumbTasks[url] = Task { [weak self] in
            let cg = await Engines.iconThumb.thumbnail(for: url, size: 128)
            guard let self, !Task.isCancelled else { return }
            self.thumbTasks[url] = nil
            guard let cg else { return }
            let image = NSImage(cgImage: cg, size: NSSize(width: 128, height: 128))
            self.thumbOverlay[url] = image
            guard let idx = self.model.items.firstIndex(where: { $0.url == url }),
                  let ip = self.indexPath(forModelIndex: idx),
                  let cell = self.collectionView.item(at: ip) as? FileIconItem
            else { return }
            cell.setIcon(image)
        }
    }

    // MARK: 选中态

    var selectedItems: [FileItem] {
        collectionView.selectionIndexPaths.sorted().compactMap { fileItem(at: $0) }
    }
    var selectedURLs: [URL] { selectedItems.map(\.url) }

    /// UISelfTest（I-32）：视图层原始选中数（直查 collectionView，不经 model 映射）——验删除后真清空
    var uiTestRawSelectionCount: Int { collectionView.selectionIndexPaths.count }

    /// 按 URL 集恢复选中（视图模式切换迁移 / FSEvents 刷新保留）；标准化路径匹配（尾斜杠跨源差异，I-39）；
    /// 经 indexPath(forModelIndex:) 走分组映射（折叠/过滤组内的项自然落选）。
    func select(urls: [URL], scroll: Bool = true) {
        let wanted = Set(urls.map { $0.standardizedFileURL.path })
        var paths = Set<IndexPath>()
        for (i, item) in model.items.enumerated()
        where wanted.contains(item.url.standardizedFileURL.path) {
            if let ip = indexPath(forModelIndex: i) { paths.insert(ip) }
        }
        collectionView.deselectAll(nil)
        if !paths.isEmpty {
            collectionView.selectItems(at: paths, scrollPosition: scroll ? .nearestHorizontalEdge : [])
        }
        // 程序化 select/deselect 不触发 delegate → 手动同步缓存为"实得的精确匹配集"（空即空）
        selectionURLCache = Set(paths.compactMap { fileItem(at: $0)?.url })
    }

    // MARK: 显露（新建后选中；图标视图不支持行内重命名，rename 忽略——诚实不装）

    func prepareReveal(_ url: URL, rename: Bool) { pendingReveal = (url, rename) }

    private func revealPendingIfPossible() {
        // 标准化路径比较：目录条目 URL 带尾斜杠、导航/新建来源的不带（I-39 同病同修）
        guard let pending = pendingReveal else { return }
        let p = pending.url.standardizedFileURL.path
        guard let idx = model.items.firstIndex(where: { $0.url.standardizedFileURL.path == p }),
              let ip = indexPath(forModelIndex: idx)
        else { return }
        pendingReveal = nil
        collectionView.deselectAll(nil)
        collectionView.selectItems(at: [ip], scrollPosition: .nearestHorizontalEdge)
        selectionURLCache = [pending.url]   // I-32：程序化选中同步缓存真源
        onSelectionChange?()
    }

    // MARK: 打开行为（语义同列表：文件走系统默认 App；文件夹窗格内导航）

    private func open(_ item: FileItem) {
        if item.isDirectory && !item.isPackage {
            onNavigate?(item.url)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    // MARK: 右键菜单（复用 builder；未实现的动作自动灰显）

    private func buildMenu() -> NSMenu {
        FileContextMenuBuilder.menu(selection: selectedItems, directory: model.directory, target: self)
    }

    // MARK: 菜单命令（响应链；语义与列表一致）

    @objc func toggleHiddenFiles(_ sender: Any?) { model.includeHidden.toggle() }
    @objc func refresh(_ sender: Any?) { model.reload() }

    @objc func copyItems(_ sender: Any?) { coordinator?.copy(selectedURLs) }
    @objc func cutItems(_ sender: Any?) { coordinator?.cut(selectedURLs) }
    @objc func pasteItems(_ sender: Any?) { coordinator?.paste(into: model.directory) }
    @objc func copyPath(_ sender: Any?) { coordinator?.copyPaths(selectedURLs) }
    @objc func copy(_ sender: Any?) { copyItems(sender) }
    @objc func cut(_ sender: Any?) { cutItems(sender) }
    @objc func paste(_ sender: Any?) { pasteItems(sender) }

    @objc func duplicateItems(_ sender: Any?) { coordinator?.duplicate(selectedURLs) }
    @objc func moveToTrash(_ sender: Any?) { coordinator?.moveToTrash(selectedURLs) }
    @objc func newFolderHere(_ sender: Any?) { coordinator?.newFolder(in: model.directory, revealIn: self) }
    @objc func newFileHere(_ sender: Any?) { coordinator?.newFile(in: model.directory, revealIn: self) }
    @objc func copyToOtherPane(_ sender: Any?) { coordinator?.copyToOtherPane(selectedURLs) }
    @objc func moveToOtherPane(_ sender: Any?) { coordinator?.moveToOtherPane(selectedURLs) }

    @objc func openSelected(_ sender: Any?) { selectedItems.forEach { open($0) } }

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
        let target = selectedURLs.first ?? model.directory
        InfoPanel.show(for: target)
    }

    @objc func openInTerminal(_ sender: Any?) {
        let dir: URL = selectedItems.first(where: { $0.isDirectory })?.url ?? model.directory
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

    // MARK: Quick Look（空格开关；与列表同款响应链面板控制）

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

// MARK: - 菜单校验（按选中态启用/禁用；重命名未实现 → 不响应即自动灰显）

extension FileIconGridViewController: @preconcurrency NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let hasSelection = !collectionView.selectionIndexPaths.isEmpty
        switch menuItem.action {
        case #selector(copyItems(_:)), #selector(cutItems(_:)), #selector(copyPath(_:)),
             #selector(duplicateItems(_:)), #selector(moveToTrash(_:)), #selector(openSelected(_:)),
             #selector(copyToOtherPane(_:)), #selector(moveToOtherPane(_:)),
             #selector(copy(_:)), #selector(cut(_:)):
            return hasSelection
        case #selector(pasteItems(_:)), #selector(paste(_:)):
            return NSPasteboard.general.canReadObject(forClasses: [NSURL.self],
                                                      options: [.urlReadingFileURLsOnly: true])
        case #selector(toggleGrouping(_:)):
            menuItem.state = Preferences.listGrouping ? .on : .off
            return true
        default:
            return true
        }
    }
}

// MARK: - 数据源 / 委托

extension FileIconGridViewController: NSCollectionViewDataSource, NSCollectionViewDelegate {
    func numberOfSections(in collectionView: NSCollectionView) -> Int { sections.count }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        guard sections.indices.contains(section) else { return 0 }
        if groupingActive, collapsedGroups.contains(sections[section].key) { return 0 }
        return sections[section].indices.count
    }

    func collectionView(_ collectionView: NSCollectionView,
                        itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: FileIconItem.reuseID, for: indexPath)
        guard let cell = item as? FileIconItem, let file = fileItem(at: indexPath) else { return item }
        let cut = coordinator?.isCut(file.url) ?? false
        // 快路径先出类型图标；已到货的内容缩略图直接用（升级路径见 requestThumbnail）
        cell.configure(icon: thumbOverlay[file.url] ?? Formatters.fullIcon(for: file),
                       name: file.name, dimmed: file.isHidden || cut)
        return item
    }

    /// 分组组头（悬浮 section header）：折叠三角 + 「2026年8月」 + 项数；点击折叠、右键过滤（M26 v2）
    func collectionView(_ collectionView: NSCollectionView,
                        viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
                        at indexPath: IndexPath) -> NSView {
        let header = collectionView.makeSupplementaryView(
            ofKind: kind, withIdentifier: IconGroupHeaderView.reuseID, for: indexPath) as! IconGroupHeaderView
        guard groupingActive, sections.indices.contains(indexPath.section) else {
            header.configure(title: "", count: 0, collapsed: false); return header
        }
        let g = sections[indexPath.section]
        header.configure(title: g.title, count: g.indices.count, collapsed: collapsedGroups.contains(g.key))
        header.onToggle = { [weak self] in self?.toggleGroup(key: g.key) }
        header.menuProvider = { [weak self] in self?.buildGroupMenu(key: g.key) }
        return header
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

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        selectionDidChange()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        selectionDidChange()
    }

    private func selectionDidChange() {
        // I-32：用户点选经此（didSelect/didDeselect）→ 记账真源
        selectionURLCache = Set(selectedURLs)
        onSelectionChange?()
        if QLPreviewPanel.sharedPreviewPanelExists(),
           let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.reloadData()
        }
    }

    // MARK: 拖拽源（可拖到 Finder/其他 App/另一窗格/侧边栏书签/暂存架）

    func collectionView(_ collectionView: NSCollectionView,
                        pasteboardWriterForItemAt indexPath: IndexPath) -> (any NSPasteboardWriting)? {
        fileItem(at: indexPath)?.url as NSURL?
    }

    // MARK: 投放目标（BG-1：落点只发意图，kind 判定与提交在 coordinator）

    func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: any NSDraggingInfo,
                        proposedIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        guard let urls = Self.draggedFileURLs(draggingInfo), !urls.isEmpty else { return [] }
        // 落点归一：目录项=投进该文件夹；文件项/空白=投进当前目录
        var target = model.directory
        let dropItem = fileItem(at: proposedIndexPath.pointee as IndexPath)
        if dropOperation.pointee == .on, let f = dropItem, f.isDirectory, !f.isPackage {
            target = f.url
        } else {
            dropOperation.pointee = .before
        }
        // 拒绝把目录投进它自己/子孙
        guard urls.allSatisfy({ !FileOpsCoordinator.isSelfOrDescendant(destination: target, ofSource: $0) }) else {
            return []
        }
        let forceCopy = draggingInfo.draggingSourceOperationMask == .copy
        // 全部来源已在目标目录：移动是无操作 → 拒绝（⌥ 复制放行，语义=制作副本）
        let destPath = target.standardizedFileURL.path
        if !forceCopy, urls.allSatisfy({ $0.standardizedFileURL.deletingLastPathComponent().path == destPath }) {
            return []
        }
        if forceCopy { return .copy }
        // Finder 惯例：同卷=移动、跨卷=复制
        return urls.allSatisfy({ FileOpsCoordinator.isSameVolume($0, target) }) ? .move : .copy
    }

    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: any NSDraggingInfo,
                        indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        guard let urls = Self.draggedFileURLs(draggingInfo), !urls.isEmpty else { return false }
        var target = model.directory
        if dropOperation == .on, let f = fileItem(at: indexPath), f.isDirectory, !f.isPackage {
            target = f.url
        }
        coordinator?.dropTransfer(urls: urls, into: target,
                                  forceCopy: draggingInfo.draggingSourceOperationMask == .copy)
        return true
    }

    private static func draggedFileURLs(_ info: any NSDraggingInfo) -> [URL]? {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                            options: [.urlReadingFileURLsOnly: true]) as? [URL]
    }
}

// MARK: - Quick Look 数据源/委托（多选预览；缩放动画锚条目图标区）

extension FileIconGridViewController: @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        selectedItems.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        let urls = selectedURLs
        guard index >= 0, index < urls.count else { return nil }
        return urls[index] as NSURL
    }

    /// 面板收到方向键先转回网格（四向皆推进选中，Finder 手感）
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown, (123...126).contains(Int(event.keyCode)) else { return false }
        collectionView.keyDown(with: event)
        return true
    }

    /// 缩放动画起点=条目图标区
    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: (any QLPreviewItem)!) -> NSRect {
        if quickLookDismissing { return .zero }
        guard let url = (item as? NSURL) as URL?,
              let idx = model.items.firstIndex(where: { $0.url == url }),
              let ip = indexPath(forModelIndex: idx),
              let attrs = collectionView.layoutAttributesForItem(at: ip),
              let window = view.window else { return .zero }
        let rect = collectionView.convert(attrs.frame, to: nil)
        return window.convertToScreen(rect)
    }
}

/// 图标视图分组组头（NSCollectionView section header，M26 v2）：折叠三角 + 「2026年8月」 + 项数。
/// 整块可点击切折叠（onToggle）；右键出「仅显示此组/显示全部组」过滤菜单（menuProvider）。
@MainActor
final class IconGroupHeaderView: NSView {
    static let reuseID = NSUserInterfaceItemIdentifier("iconGroupHeader")

    var onToggle: (() -> Void)?
    var menuProvider: (() -> NSMenu?)?

    private let chevron = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        chevron.contentTintColor = .secondaryLabelColor
        chevron.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)  // tabular-nums
        countLabel.textColor = .secondaryLabelColor
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        for v in [chevron, titleLabel, countLabel] { addSubview(v) }
        NSLayoutConstraint.activate([
            chevron.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 12),
            chevron.heightAnchor.constraint(equalToConstant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            countLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            countLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建 UI，无 xib") }

    func configure(title: String, count: Int, collapsed: Bool) {
        chevron.image = NSImage.officialSymbol(collapsed ? "chevron.right" : "chevron.down",
                                               fallback: collapsed ? "arrowtriangle.right.fill"
                                                                    : "arrowtriangle.down.fill",
                                               accessibility: title)
        titleLabel.stringValue = title
        countLabel.stringValue = L10n.f("group.count", count)
    }

    override func mouseDown(with event: NSEvent) { onToggle?() }
    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }
}

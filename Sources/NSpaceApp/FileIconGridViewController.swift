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

        collectionView.collectionViewLayout = flowLayout
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(FileIconItem.self, forItemWithIdentifier: FileIconItem.reuseID)
        collectionView.onInteract = { [weak self] in self?.onInteract?() }
        collectionView.menuProvider = { [weak self] _ in self?.buildMenu() }
        collectionView.onSpace = { [weak self] in self?.toggleQuickLook(nil) }
        collectionView.onDoubleClick = { [weak self] ip in
            guard let self, self.model.items.indices.contains(ip.item) else { return }
            self.open(self.model.items[ip.item])
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
        for sub in [separator, sizeSlider] {
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
                  model.items.indices.contains(ip.item) else { continue }
            let file = model.items[ip.item]
            let cut = coordinator?.isCut(file.url) ?? false
            cell.configure(icon: thumbOverlay[file.url] ?? Formatters.fullIcon(for: file),
                           name: file.name, dimmed: file.isHidden || cut)
        }
    }

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
            guard model.items.indices.contains(ip.item) else { continue }
            let item = model.items[ip.item]
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
                  let cell = self.collectionView.item(at: IndexPath(item: idx, section: 0)) as? FileIconItem
            else { return }
            cell.setIcon(image)
        }
    }

    // MARK: 选中态

    var selectedItems: [FileItem] {
        collectionView.selectionIndexPaths.sorted().compactMap {
            model.items.indices.contains($0.item) ? model.items[$0.item] : nil
        }
    }
    var selectedURLs: [URL] { selectedItems.map(\.url) }

    /// UISelfTest（I-32）：视图层原始选中数（直查 collectionView，不经 model 映射）——验删除后真清空
    var uiTestRawSelectionCount: Int { collectionView.selectionIndexPaths.count }

    /// 按 URL 集恢复选中（视图模式切换迁移 / FSEvents 刷新保留）；标准化路径匹配（尾斜杠跨源差异，I-39）
    func select(urls: [URL], scroll: Bool = true) {
        let wanted = Set(urls.map { $0.standardizedFileURL.path })
        var paths = Set<IndexPath>()
        for (i, item) in model.items.enumerated()
        where wanted.contains(item.url.standardizedFileURL.path) {
            paths.insert(IndexPath(item: i, section: 0))
        }
        collectionView.deselectAll(nil)
        if !paths.isEmpty {
            collectionView.selectItems(at: paths, scrollPosition: scroll ? .nearestHorizontalEdge : [])
        }
        // 程序化 select/deselect 不触发 delegate → 手动同步缓存为"实得的精确匹配集"（空即空）
        selectionURLCache = Set(paths.compactMap {
            model.items.indices.contains($0.item) ? model.items[$0.item].url : nil
        })
    }

    // MARK: 显露（新建后选中；图标视图不支持行内重命名，rename 忽略——诚实不装）

    func prepareReveal(_ url: URL, rename: Bool) { pendingReveal = (url, rename) }

    private func revealPendingIfPossible() {
        // 标准化路径比较：目录条目 URL 带尾斜杠、导航/新建来源的不带（I-39 同病同修）
        guard let pending = pendingReveal else { return }
        let p = pending.url.standardizedFileURL.path
        guard let idx = model.items.firstIndex(where: { $0.url.standardizedFileURL.path == p })
        else { return }
        pendingReveal = nil
        collectionView.deselectAll(nil)
        collectionView.selectItems(at: [IndexPath(item: idx, section: 0)],
                                   scrollPosition: .nearestHorizontalEdge)
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

    @objc func toggleQuickLook(_ sender: Any?) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.orderOut(nil)
        } else if !selectedItems.isEmpty {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
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
        default:
            return true
        }
    }
}

// MARK: - 数据源 / 委托

extension FileIconGridViewController: NSCollectionViewDataSource, NSCollectionViewDelegate {
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        model.items.count
    }

    func collectionView(_ collectionView: NSCollectionView,
                        itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: FileIconItem.reuseID, for: indexPath)
        guard let cell = item as? FileIconItem, model.items.indices.contains(indexPath.item) else { return item }
        let file = model.items[indexPath.item]
        let cut = coordinator?.isCut(file.url) ?? false
        // 快路径先出类型图标；已到货的内容缩略图直接用（升级路径见 requestThumbnail）
        cell.configure(icon: thumbOverlay[file.url] ?? Formatters.fullIcon(for: file),
                       name: file.name, dimmed: file.isHidden || cut)
        return item
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
        guard model.items.indices.contains(indexPath.item) else { return nil }
        return model.items[indexPath.item].url as NSURL
    }

    // MARK: 投放目标（BG-1：落点只发意图，kind 判定与提交在 coordinator）

    func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: any NSDraggingInfo,
                        proposedIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        guard let urls = Self.draggedFileURLs(draggingInfo), !urls.isEmpty else { return [] }
        // 落点归一：目录项=投进该文件夹；文件项/空白=投进当前目录
        var target = model.directory
        let idx = proposedIndexPath.pointee.item
        if dropOperation.pointee == .on, model.items.indices.contains(idx),
           model.items[idx].isDirectory, !model.items[idx].isPackage {
            target = model.items[idx].url
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
        if dropOperation == .on, model.items.indices.contains(indexPath.item),
           model.items[indexPath.item].isDirectory, !model.items[indexPath.item].isPackage {
            target = model.items[indexPath.item].url
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
        guard let url = (item as? NSURL) as URL?,
              let idx = model.items.firstIndex(where: { $0.url == url }),
              let attrs = collectionView.layoutAttributesForItem(at: IndexPath(item: idx, section: 0)),
              let window = view.window else { return .zero }
        let rect = collectionView.convert(attrs.frame, to: nil)
        return window.convertToScreen(rect)
    }
}

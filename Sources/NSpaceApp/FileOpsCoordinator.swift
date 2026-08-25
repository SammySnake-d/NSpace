import AppKit
import NSpaceKernel
import NSpaceContracts
import ArchiveEngine

/// 操作后显露落点（新建完成 → 选中并按需进入重命名）；列表/图标视图各自实现（分栏传 nil）
@MainActor
protocol FileRevealTarget: AnyObject {
    func prepareReveal(_ url: URL, rename: Bool)
}

/// UI → 内核桥（每窗口一个）：把用户意图翻译成 OperationSpec 交给 OperationKernel，
/// 由胶囊节点执行（BG-1：本层零写型文件 API）。负责剪贴板、撤销注册、操作后刷新窗格。
@MainActor
final class FileOpsCoordinator {
    let kernel: OperationKernel
    private(set) weak var grid: PaneGridController?
    /// 本窗口的撤销栈（经 MainWindowController.windowWillReturnUndoManager 接入 ⌘Z）
    let undoManager = UndoManager()

    /// 剪切态 URL 集：被剪切的行灰显；粘贴或复制后清空
    private var cutURLs: Set<URL> = []

    init(kernel: OperationKernel, grid: PaneGridController) {
        self.kernel = kernel
        self.grid = grid
    }

    // MARK: 剪贴板状态查询（列表按此灰显剪切项）

    func isCut(_ url: URL) -> Bool { cutURLs.contains(url) }

    // MARK: 复制 / 剪切 / 粘贴 / 拷贝路径

    func copy(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        writeToPasteboard(urls)
        cutURLs = []
        redrawLists()
        Toast.show(String(format: L10n.t("toast.copied"), urls.count), in: grid?.view.window)
    }

    func cut(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        writeToPasteboard(urls)
        cutURLs = Set(urls)
        redrawLists()
        Toast.show(String(format: L10n.t("toast.cutN"), urls.count), in: grid?.view.window)
    }

    func paste(into directory: URL) {
        let urls = readPasteboardURLs()
        guard !urls.isEmpty else { NSSound.beep(); return }
        // 剪切态且粘贴项恰为被剪切集 → 移动；否则复制
        let isMove = !cutURLs.isEmpty && urls.allSatisfy { cutURLs.contains($0) }
        // 同目录复制无意义（源即目标）——退化为制作副本语义交给 Transfer.duplicate
        if !isMove, urls.allSatisfy({ $0.deletingLastPathComponent() == directory }) {
            duplicate(urls); return
        }
        let spec = OperationSpec(kind: isMove ? .move : .copy, sources: urls, destination: directory)
        run(spec) { [weak self] _ in
            if isMove { self?.cutURLs = []; self?.redrawLists() }
        }
    }

    func copyPaths(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
        Toast.show(urls.count == 1 ? L10n.t("toast.copiedPath")
                   : String(format: L10n.t("toast.copiedPaths"), urls.count),
                   in: grid?.view.window)
    }

    // MARK: 内核操作

    func moveToTrash(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        run(OperationSpec(kind: .trash, sources: urls)) { [weak self] receipt in
            guard let self, let items = receipt?.trashedItems, !items.isEmpty else { return }
            self.registerRestoreUndo(items)
        }
    }

    func duplicate(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        run(OperationSpec(kind: .duplicate, sources: urls))
    }

    // MARK: 归档（压缩 / 解压；ArchiveEngine 胶囊，读 Preferences 归档默认值构造 ArchiveOptions）

    /// 压缩选中项为一个归档包（格式取设置；多源用本地化默认基名，单源节点从名字推导）
    func compress(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let keepOriginal = Preferences.archiveKeepOriginal
        let options = ArchiveOptions(format: Preferences.archiveFormat, password: nil,
                                     keepOriginal: keepOriginal)
        // 多源归档基名用本地化"归档"（节点在共同父目录下打包）；单源交由节点省扩展名命名
        let baseName = urls.count > 1 ? L10n.t("archive.defaultName") : nil
        run(OperationSpec(kind: .compress, sources: urls, newName: baseName, archiveOptions: options)) { [weak self] receipt in
            guard let self, receipt != nil else { return }
            Toast.show(L10n.t("toast.compressed"), in: self.grid?.view.window)
            // 保留原文件=false → 打包成功后把原文件移到废纸篓（复用 trash + 撤销路径）
            if !keepOriginal { self.moveToTrash(urls) }
        }
    }

    /// 解压选中的归档（into=nil 表示解到压缩包同目录；含"解压到…"时传目标目录）
    func extract(_ urls: [URL], into directory: URL?) {
        let archives = urls.filter { ArchiveEngineNode.isSupportedArchive($0) }
        guard !archives.isEmpty else { NSSound.beep(); return }
        let keepArchive = Preferences.extractKeepArchive
        let options = ArchiveOptions(password: nil, keepOriginal: true, extractInto: directory,
                                     createWrapper: Preferences.extractCreateWrapper)
        run(OperationSpec(kind: .extract, sources: archives, archiveOptions: options)) { [weak self] receipt in
            guard let self, receipt != nil else { return }
            Toast.show(L10n.t("toast.extracted"), in: self.grid?.view.window)
            // 保留压缩包=false → 解压成功后把压缩包移到废纸篓
            if !keepArchive { self.moveToTrash(archives) }
        }
    }

    func newFolder(in directory: URL, revealIn list: FileRevealTarget?) {
        run(OperationSpec(kind: .newFolder, sources: [], destination: directory,
                          newName: L10n.t("newItem.folder"))) { receipt in
            if let url = receipt?.createdURLs.first { list?.prepareReveal(url, rename: true) }
        }
    }

    func newFile(in directory: URL, revealIn list: FileRevealTarget?) {
        run(OperationSpec(kind: .newFile, sources: [], destination: directory,
                          newName: L10n.t("newItem.file"))) { receipt in
            if let url = receipt?.createdURLs.first { list?.prepareReveal(url, rename: true) }
        }
    }

    /// 行内重命名提交（FG-6：失败由调用方原子回滚旧名 + 原位红字）
    func rename(_ url: URL, to newName: String, completion: @escaping @MainActor (Bool) -> Void) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != url.lastPathComponent else { completion(true); return }
        Task { @MainActor in
            let id = await kernel.submit(OperationSpec(kind: .rename, sources: [url], newName: trimmed))
            let ok = await waitTerminal(id)
            if ok { reloadLists() }
            completion(ok)
        }
    }

    // MARK: F5 复制 / F6 移动 到另一窗格

    func copyToOtherPane(_ urls: [URL]) { transferToOtherPane(urls, move: false) }
    func moveToOtherPane(_ urls: [URL]) { transferToOtherPane(urls, move: true) }

    private func transferToOtherPane(_ urls: [URL], move: Bool) {
        guard !urls.isEmpty else { return }
        guard let dir = otherPaneDirectory() else { NSSound.beep(); return }
        // 与拖拽/暂存架共用同一提交路径（不重复实现）
        transfer(urls: urls, into: dir, move: move)
    }

    private func otherPaneDirectory() -> URL? {
        guard let grid else { return nil }
        let panes = grid.visiblePanes
        guard panes.count > 1 else { return nil }
        let next = panes[(grid.activePaneIndex + 1) % panes.count]
        return next.activeTab.browser.current
    }

    // MARK: 拖拽投放（列表/面包屑/暂存架共用；Finder 惯例：同卷移动、跨卷复制、⌥ 强制复制）

    /// 拖拽落点提交：内部判卷决定 kind（默认同卷=移动、跨卷=复制；forceCopy=⌥ 强制复制）
    func dropTransfer(urls: [URL], into destination: URL, forceCopy: Bool,
                      onComplete: (@MainActor (Bool) -> Void)? = nil) {
        guard !urls.isEmpty else { onComplete?(false); return }
        let sameVolume = urls.allSatisfy { Self.isSameVolume($0, destination) }
        transfer(urls: urls, into: destination, move: !forceCopy && sameVolume, onComplete: onComplete)
    }

    /// 显式复制/移动到目录（暂存架批量操作用；onComplete(true) 表示操作完成）
    func transfer(urls: [URL], into destination: URL, move: Bool,
                  onComplete: (@MainActor (Bool) -> Void)? = nil) {
        guard !urls.isEmpty else { onComplete?(false); return }
        let dest = destination.standardizedFileURL
        // 防御复检：目录严禁投进它自己或子孙（UI 层 validateDrop 已挡，此处兜底）
        guard urls.allSatisfy({ !Self.isSelfOrDescendant(destination: dest, ofSource: $0) }) else {
            NSSound.beep(); onComplete?(false); return
        }
        // 全部已在目标目录：原地移动无意义；原地复制退化为制作副本（与粘贴语义一致）
        if urls.allSatisfy({ $0.standardizedFileURL.deletingLastPathComponent().path == dest.path }) {
            if !move { duplicate(urls) }
            onComplete?(false)
            return
        }
        run(OperationSpec(kind: move ? .move : .copy, sources: urls, destination: dest)) { receipt in
            onComplete?(receipt != nil)
        }
    }

    /// destination 是否为 source 自身或其子孙（拒绝把目录投进它自己）
    nonisolated static func isSelfOrDescendant(destination: URL, ofSource source: URL) -> Bool {
        let src = source.standardizedFileURL.path
        let dst = destination.standardizedFileURL.path
        return dst == src || dst.hasPrefix(src.hasSuffix("/") ? src : src + "/")
    }

    /// 同卷判断（未知按跨卷处理 → 复制，避免误移动）
    nonisolated static func isSameVolume(_ a: URL, _ b: URL) -> Bool {
        guard let va = try? a.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier,
              let vb = try? b.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        else { return false }
        return va.isEqual(vb)
    }

    // MARK: 撤销废纸篓（把 trashed 搬回 original；复用 move/rename 语义，内核零业务分支）

    private func registerRestoreUndo(_ items: [TrashedItem]) {
        undoManager.registerUndo(withTarget: self) { coord in
            MainActor.assumeIsolated { coord.restore(items) }
        }
        undoManager.setActionName(L10n.t("undo.trash"))
    }

    private func restore(_ items: [TrashedItem]) {
        // 注册重做：再次移到废纸篓（撤销/重做循环）
        undoManager.registerUndo(withTarget: self) { coord in
            MainActor.assumeIsolated { coord.moveToTrash(items.map(\.original)) }
        }
        undoManager.setActionName(L10n.t("undo.trash"))
        for item in items {
            let parent = item.original.deletingLastPathComponent()
            run(OperationSpec(kind: .move, sources: [item.trashed], destination: parent)) { [weak self] _ in
                // 回收站曾因重名改名 → 搬回后再更名回原名
                let landed = parent.appendingPathComponent(item.trashed.lastPathComponent)
                if landed.lastPathComponent != item.original.lastPathComponent {
                    self?.run(OperationSpec(kind: .rename, sources: [landed],
                                            newName: item.original.lastPathComponent))
                }
            }
        }
    }

    // MARK: 内部：提交 + 等待终态 + 刷新

    private func run(_ spec: OperationSpec, onComplete: (@MainActor (OperationReceipt?) -> Void)? = nil) {
        Task { @MainActor in
            let id = await kernel.submit(spec)
            var receipt: OperationReceipt?
            for await p in await kernel.projections() where p.id == id {
                guard p.state.isTerminal else { continue }
                if case .completed = p.state { receipt = await kernel.receipt(id) }
                break
            }
            onComplete?(receipt)
            reloadLists()
        }
    }

    private func waitTerminal(_ id: UUID) async -> Bool {
        for await p in await kernel.projections() where p.id == id {
            switch p.state {
            case .completed: return true
            case .failed, .cancelled: return false
            default: continue
            }
        }
        return false
    }

    /// 操作后重新读取各可见窗格活动列表（真实 FS 投影刷新）
    private func reloadLists() {
        grid?.visiblePanes.forEach { $0.reloadActiveList() }
    }

    /// 仅重绘（剪切灰显变化，无需重新读盘）
    private func redrawLists() {
        grid?.visiblePanes.forEach { $0.redrawActiveList() }
    }

    // MARK: 剪贴板读写

    private func writeToPasteboard(_ urls: [URL]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
    }

    private func readPasteboardURLs() -> [URL] {
        let pb = NSPasteboard.general
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return (pb.readObjects(forClasses: [NSURL.self], options: opts) as? [URL]) ?? []
    }
}

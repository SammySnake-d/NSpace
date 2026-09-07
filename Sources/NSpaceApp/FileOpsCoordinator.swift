import AppKit
import NSpaceKernel
import NSpaceContracts
import ArchiveEngine
import Frecency
import TrashLedger

/// 操作后显露落点（新建完成 → 选中并按需进入重命名）；列表/图标视图各自实现（分栏传 nil）
@MainActor
protocol FileRevealTarget: AnyObject {
    func prepareReveal(_ url: URL, rename: Bool)
    /// 取走并清空待定位目标。切视图模式时用来「搬家」：读盘途中切走，pending 还挂在旧视图上，
    /// 不搬就永久丢失，而且会在旧视图里留成日后突然"幽灵跳选"并抢焦点的定时炸弹。
    func takePendingReveal() -> (url: URL, rename: Bool)?
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

    /// 使用习惯学习（M28）：全应用打开/进入记账的载体（AppDelegate 注入同一实例；nil=不学习）。
    var frecencyStore: FrecencyStore?

    /// 「放回原处」台账（AppDelegate 注入同一实例；nil=不记账 → 放回原处一律不可用）
    var trashLedger: TrashLedger?

    /// 记一次访问（打开文件/进入文件夹）——供聚焦搜索按使用习惯排序。actor 异步提交，发后不等。
    func recordAccess(_ url: URL) {
        guard let store = frecencyStore else { return }
        Task { await store.record(url) }
    }

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
        // M27-B：同目录复制粘贴不再静默退化为"制作副本"——走正常 copy 触发自源冲突，
        // 弹面板让用户选替换/跳过/两者保留/重命名/取消（引擎自源安全律护航，绝不删源）。
        let spec = OperationSpec(kind: isMove ? .move : .copy, sources: urls, destination: directory)
        run(spec) { [weak self] _ in
            if isMove { self?.cutURLs = []; self?.redrawLists() }
        }
    }

    /// 拷贝路径。pasteboard 可注入：默认写系统剪贴板（产品行为），自测注入私有板——
    /// 既不污染用户真实剪贴板，也不会被机器上任何别的进程中途改写造成假失败（实测撞到过）。
    func copyPaths(_ urls: [URL], to pasteboard: NSPasteboard = .general) {
        guard !urls.isEmpty else { return }
        let pb = pasteboard
        pb.clearContents()
        pb.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
        Toast.show(urls.count == 1 ? L10n.t("toast.copiedPath")
                   : String(format: L10n.t("toast.copiedPaths"), urls.count),
                   in: grid?.view.window)
    }

    // MARK: 清空废纸篓 / 放回原处（v0.19.19）

    /// 清空废纸篓：**不可逆**。读废纸篓内容（只读，BG-1 允许）→ 确认 → 经内核 `.delete`。
    /// 围栏根 = 该废纸篓本身，节点会拒绝围栏之外的任何项。
    func emptyTrash(at trash: URL, in window: NSWindow?) {
        guard let window = window ?? grid?.view.window, window.attachedSheet == nil else { return }
        // 用 options: [] 读全量：篓里可能有点文件，按显示过滤会漏删、"清空"就成了半句真话
        let victims = (try? FileManager.default.contentsOfDirectory(
            at: trash, includingPropertiesForKeys: nil, options: [])) ?? []
        guard !victims.isEmpty else {
            Toast.show(L10n.t("toast.trashAlreadyEmpty"), in: window)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = L10n.f("alert.emptyTrash.title", victims.count)
        alert.informativeText = L10n.t("alert.emptyTrash.body")
        alert.addButton(withTitle: L10n.t("alert.emptyTrash.confirm"))
        alert.addButton(withTitle: L10n.t("common.cancel"))
        // 破坏性按钮标红 + 默认落在「取消」上：不可逆操作不许一路回车就执行
        alert.buttons.first?.hasDestructiveAction = true
        alert.window.defaultButtonCell = alert.buttons[1].cell as? NSButtonCell
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.performEmptyTrash(at: trash, victims: victims)
        }
    }

    /// 永久删除只从已确认的窗口动作进入。
    private func performEmptyTrash(at trash: URL, victims: [URL]) {
        guard !victims.isEmpty else { return }
        run(OperationSpec(kind: .delete, sources: victims, destination: trash)) { [weak self] receipt in
            guard let self, let receipt else { return }
            // 台账里对应条目一并作废（那些落点已经不存在了）
            if let led = self.trashLedger { Task { await led.forget(victims) } }
            if receipt.failures.isEmpty {
                Toast.show(L10n.f("toast.trashEmptied", receipt.filesDone), in: self.grid?.view.window)
            } else {
                Toast.show(L10n.f("toast.trashEmptiedPartial", receipt.filesDone,
                                  receipt.failures.count, receipt.failures[0].message),
                           in: self.grid?.view.window)
            }
        }
    }

    /// 放回原处：只对**台账里有记录**的项有效（= NSpace 自己删掉的）。
    /// 别的应用删的项没有记录，菜单项诚实置灰——不假装能放回。
    func putBack(_ urls: [URL]) {
        guard !urls.isEmpty, let led = trashLedger else { NSSound.beep(); return }
        Task { @MainActor in
            let map = await led.origins(of: urls)
            let known = urls.compactMap { u in map[u].map { (trashed: u, original: $0) } }
            guard !known.isEmpty else {
                Toast.show(L10n.t("toast.putBackUnknown"), in: self.grid?.view.window)
                return
            }
            // 复用既有的"搬回原处 + 必要时改名回原名"链路（撤销废纸篓走的就是这条）
            self.restore(known.map { TrashedItem(original: $0.original, trashed: $0.trashed) })
            await led.forget(known.map(\.trashed))
            Toast.show(L10n.f("toast.putBackN", known.count), in: self.grid?.view.window)
        }
    }

    // MARK: 内核操作

    func moveToTrash(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        // 废纸篓可浏览之后新出现的情形：对**已在 ~/.Trash 里**的项再 trash 一次。
        // 实测 `fm.trashItem` 此时是安全的空操作（返回同一路径、文件仍在、不抛错），
        // 所以不存在数据风险；但那样会弹一句"已移到废纸篓 N 项"的假话。诚实拒绝，不装。
        // 真正的出路是永久删除，那需要新的内核 kind + 新胶囊节点（不可逆操作，归用户拍）。
        // 量词是 `contains` 不是 `allSatisfy`：混选（一部分在废纸篓、一部分不在）用 allSatisfy
        // 会放行，然后吐司按 items.count 报一个虚高的数、⌘Z 也会拿到一份不自洽的撤销集。
        // 整批拒绝是可预期的行为；用户把选中收窄一次就能继续。
        if urls.contains(where: { TrashLocation.isInsideTrash($0) }) {
            Toast.show(L10n.t("toast.alreadyInTrash"), in: grid?.view.window)
            return
        }
        run(OperationSpec(kind: .trash, sources: urls)) { [weak self] receipt in
            guard let self, let receipt else { return }
            let items = receipt.trashedItems
            // 真落地的那部分必须能撤销，哪怕整个 run 因为别的项判了 .failed
            if !items.isEmpty {
                self.registerRestoreUndo(items)
                // 落台账：「放回原处」跨会话可用全靠它（UndoManager 只活在本窗本次会话里）
                let pairs = items.map { (original: $0.original, trashed: $0.trashed) }
                if let led = self.trashLedger { Task { await led.record(pairs) } }
            }
            // 旧版此路径**零反馈**（copy/move 有吐司，trash 没有），用户只看到行消失。
            // 部分失败时更要说清：几项成了、几项没成、第一条原因是什么。
            if receipt.failures.isEmpty {
                guard !items.isEmpty else { return }
                Toast.show(L10n.f("toast.trashedN", items.count), in: self.grid?.view.window)
            } else {
                Toast.show(L10n.f("toast.trashedPartial", items.count,
                                  receipt.failures.count, receipt.failures[0].message),
                           in: self.grid?.view.window)
            }
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
            guard let self, let receipt else { return }
            let name = receipt.createdURLs.first?.lastPathComponent ?? ""
            Toast.show(L10n.f("toast.compressed", name), in: self.grid?.view.window)
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
            guard let self, let receipt else { return }
            Toast.show(L10n.f("toast.extracted", receipt.createdURLs.count), in: self.grid?.view.window)
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

    /// 拖拽落点提交：内部按拖放偏好 + ⌥ 判定 kind（auto=同卷移动跨卷复制；forceCopy=⌥ 强制复制）
    func dropTransfer(urls: [URL], into destination: URL, forceCopy: Bool,
                      onComplete: (@MainActor (Bool) -> Void)? = nil) {
        guard !urls.isEmpty else { onComplete?(false); return }
        let move = Self.effectiveMove(urls: urls, into: destination, optionCopy: forceCopy)
        transfer(urls: urls, into: destination, move: move, onComplete: onComplete)
    }

    /// 拖放落点"移动还是复制"的唯一判定（validateDrop 视觉反馈与 dropTransfer 实际提交共用）：
    /// - auto：Finder 惯例——⌥ 强制复制、同卷移动、跨卷复制
    /// - copy：恒复制
    /// - move：同卷恒移动、跨卷退化复制（忽略 ⌥）
    static func effectiveMove(urls: [URL], into destination: URL, optionCopy: Bool) -> Bool {
        let sameVolume = urls.allSatisfy { isSameVolume($0, destination) }
        switch Preferences.dragBehavior {
        case "copy": return false
        case "move": return sameVolume
        default:     return !optionCopy && sameVolume
        }
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
        // 全部已在目标目录：移到原处无操作；复制则走正常 copy 触发自源冲突弹面板（与粘贴语义统一，M27-B）
        if move, urls.allSatisfy({ $0.standardizedFileURL.deletingLastPathComponent().path == dest.path }) {
            onComplete?(false)
            return
        }
        run(OperationSpec(kind: move ? .move : .copy, sources: urls, destination: dest)) { [weak self] receipt in
            // 成功落地才吐司（取消/失败 receipt==nil，失败另有自己的呈现）
            if receipt != nil {
                Toast.show(L10n.f(move ? "toast.movedN" : "toast.copiedN", urls.count),
                           in: self?.grid?.view.window)
            }
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

    /// internal 而非 private：「放回原处」复用同一条搬回链路（不另写一份，
    /// 否则两处会各自漂——撤销能改名回原名、放回原处却不能，那就是同病不同修）
    func restore(_ items: [TrashedItem]) {
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
                // 任一终态都取回执，不只 .completed：部分失败的 run 状态是 .failed，
                // 但内核已把回执存下（里面有真落地的那部分）。只在 .completed 取回执
                // 等于把"已经做成的事"连同状态一起丢掉——撤销与汇报全没了。
                receipt = await kernel.receipt(id)
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

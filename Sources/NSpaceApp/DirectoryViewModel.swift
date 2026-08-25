import Foundation
import NSpaceContracts
import DirectoryReader
import DirectoryWatch
import FolderSize
import IconThumb

/// 全 App 共享引擎实例（构造一次、全局注入）：FolderSize 的并发限界（=2）与缓存全局生效，
/// IconThumb 的 LRU 缩略图缓存跨窗格/标签复用。两者均 Sendable，静态持有安全。
enum Engines {
    static let folderSize = FolderSize()
    static let iconThumb = IconThumb()
}

/// 每窗格内容的胶水：订阅 DirectoryReader 投影，持有快照，代际防过期覆盖（spec 3.2）。
/// 另持 DirectoryWatch 监听句柄实现 FSEvents 自动刷新；挂起/恢复走 mtime 比对（北极星：后台零功耗）。
/// 展示层只读消费——本类不含任何写型文件操作（BG-1）。
@MainActor
final class DirectoryViewModel {
    private let reader = DirectoryReader()
    private let watchFactory = DirectoryWatch()

    private var watcher: DirectoryWatcher?
    private var watchTask: Task<Void, Never>?
    /// 挂起态（spec 3.2 suspended）：true 时 FSEventStream 已真停——零回调零功耗
    private(set) var isSuspended = false
    /// 挂起瞬间的目录 mtime；恢复时比对，变了才 reload，没变零工作
    private var suspendedMTime: Date?

    private(set) var directory: URL
    private(set) var items: [FileItem] = []
    private(set) var isLoading = false

    var includeHidden = false { didSet { reload() } }
    var sort = SortSpec() { didSet { reload() } }

    // M9 多播：同一 model 被列表/图标网格多视图消费（观察者与标签同生命周期，不需移除）
    private var updateHandlers: [() -> Void] = []
    private var errorHandlers: [(String) -> Void] = []

    /// 订阅快照更新（多视图共享同一 model 的唯一挂点）
    func addOnUpdate(_ handler: @escaping () -> Void) { updateHandlers.append(handler) }
    /// 订阅就地错误呈现（原位空态横幅，严禁弹窗轰炸——spec 容错矩阵）
    func addOnError(_ handler: @escaping (String) -> Void) { errorHandlers.append(handler) }

    private func notifyUpdate() { updateHandlers.forEach { $0() } }
    private func notifyError(_ message: String) { errorHandlers.forEach { $0(message) } }

    private var lastAppliedGeneration: UInt64 = 0
    private var loadTask: Task<Void, Never>?

    init(directory: URL) {
        self.directory = directory
    }

    func navigate(to url: URL) {
        directory = url
        lastAppliedGeneration = 0  // 新目录重置代际基线
        startWatching()            // 停旧流开新流
        reload()
    }

    func reload() {
        if watcher == nil { startWatching() }  // 首次装载（loadView → reload）时补开监听
        loadTask?.cancel()
        isLoading = true
        let request = ReadRequest(directory: directory, includeHidden: includeHidden, sort: sort)
        loadTask = Task { [weak self, reader] in
            do {
                let snap = try await reader.load(request)
                guard let self, !Task.isCancelled else { return }
                guard snap.generation > self.lastAppliedGeneration,
                      snap.directory == self.directory else { return }
                self.lastAppliedGeneration = snap.generation
                self.items = snap.items
                self.isLoading = false
                self.notifyUpdate()
            } catch is CancellationError {
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.isLoading = false
                self.items = []
                self.notifyUpdate()
                self.notifyError(error.localizedDescription)
            }
        }
    }

    // MARK: 实时刷新（FSEvents）与挂起/恢复（spec 3.2：后台标签/窗格零功耗是北极星）

    /// 开新监听流（先彻底停旧流）。FSEventStream 创建失败时静默降级为手动刷新（⌘R），不崩不弹窗。
    private func startWatching() {
        stopWatching()
        let w = watchFactory.watch(directory)
        watcher = w
        watchTask = Task { [weak self] in
            for await _ in w.signals {
                guard let self else { return }
                // 目录内容变了：先失效其 FolderSize 缓存（父目录列表中的本目录行下次重算）
                await Engines.folderSize.invalidate(self.directory)
                self.reload()
            }
        }
        // 挂起态下换目录（罕见路径）：新流立即挂起，恢复时仍按 mtime 比对
        if isSuspended {
            w.suspend()
            suspendedMTime = currentMTime()
        }
    }

    /// 彻底停流并收尾信号任务（关标签时调用；navigate 换目录经 startWatching 先停旧流）
    func stopWatching() {
        watchTask?.cancel()
        watchTask = nil
        watcher?.stop()
        watcher = nil
    }

    /// 挂起：真停 FSEventStream（零回调零功耗），记录当前目录 mtime 供恢复比对
    func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        watcher?.suspend()
        suspendedMTime = currentMTime()
    }

    /// 恢复：重启流；mtime 变了才 reload，没变零工作（spec 3.2 suspended → loaded/loading）
    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        watcher?.resume()
        let changed = currentMTime() != suspendedMTime
        suspendedMTime = nil
        if changed {
            Task { await Engines.folderSize.invalidate(directory) }
            reload()
        }
    }

    /// 只读 stat（BG-1 允许读）：目录的 contentModificationDate
    private func currentMTime() -> Date? {
        (try? directory.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    deinit {
        // 兜底收流（正常路径 closeTab 已显式 stopWatching）；两者均 Sendable，deinit 可安全触碰
        watchTask?.cancel()
        watcher?.stop()
    }
}

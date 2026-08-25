import AppKit
import StashStore

/// 暂存架操作枚举（分组末尾操作行；FG-1：空暂存架不显示这些行）
enum StashAction {
    case copyHere   // 复制暂存全体到当前窗格
    case moveHere   // 移动暂存全体到当前窗格（完成后清空移动项）
    case airdrop    // AirDrop 暂存全体

    var titleKey: String {
        switch self {
        case .copyHere: "stash.copyHere"
        case .moveHere: "stash.moveHere"
        case .airdrop: "stash.airdrop"
        }
    }

    var symbolName: String {
        switch self {
        case .copyHere: "doc.on.doc"
        case .moveHere: "arrow.right.square"
        case .airdrop: "dot.radiowaves.left.and.right"
        }
    }
}

/// 暂存架控制器（spec 五元组：暂存架内容 Decision Owner）：
/// UI 只发 Command——增删清经 StashStore 胶囊提交，批量复制/移动经 FileOpsCoordinator
/// 构造 OperationSpec 交内核（BG-1：本层零写型文件 API）。行呈现在侧边栏"暂存架"分组。
@MainActor
final class StashShelfController {
    let store: StashStore
    /// 内存投影（侧边栏据此建行；权威状态在 StashStore actor）
    private(set) var items: [StashItem] = []

    /// 内容变化 → 侧边栏重建
    var onChange: (() -> Void)?
    /// 错误原位呈现（侧边栏底部横幅，严禁模态弹窗）
    var onError: ((String) -> Void)?
    /// 文件操作桥与窗格网格（"当前窗格"落点来源），由 MainWindowController 注入
    weak var coordinator: FileOpsCoordinator?
    weak var grid: PaneGridController?

    init(store: StashStore) {
        self.store = store
    }

    func start() {
        Task { await refresh() }
    }

    // MARK: 增删清（全部经 StashStore actor 串行提交）

    func add(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task {
            do { try await store.add(urls) } catch { onError?(error.localizedDescription) }
            await refresh()
        }
    }

    func remove(ids: [UUID]) {
        guard !ids.isEmpty else { return }
        Task {
            do { try await store.remove(ids: ids) } catch { onError?(error.localizedDescription) }
            await refresh()
        }
    }

    func clearAll() {
        Task {
            do { try await store.clear() } catch { onError?(error.localizedDescription) }
            await refresh()
        }
    }

    // MARK: 批量操作（分组末尾操作行）

    func perform(_ action: StashAction) {
        switch action {
        case .copyHere: transferAll(move: false)
        case .moveHere: transferAll(move: true)
        case .airdrop: airdropAll()
        }
    }

    /// 对暂存全体执行复制/移动到当前窗格；移动完成后清空已移动项
    private func transferAll(move: Bool) {
        let pairs: [(id: UUID, url: URL)] = items.compactMap { item in
            store.resolve(item).map { (item.id, $0) }
        }
        guard !pairs.isEmpty, let coordinator, let grid else { NSSound.beep(); return }
        let destination = grid.activePane.activeTab.browser.current
        coordinator.transfer(urls: pairs.map(\.url), into: destination, move: move) { [weak self] ok in
            guard ok, move else { return }
            self?.remove(ids: pairs.map(\.id))
        }
    }

    /// AirDrop 暂存全体（对 resolve 后的真实 URL；失败原位横幅）
    private func airdropAll() {
        let urls = items.compactMap { store.resolve($0) }
        guard !urls.isEmpty else { NSSound.beep(); return }
        guard let service = NSSharingService(named: .sendViaAirDrop),
              service.canPerform(withItems: urls) else {
            onError?(L10n.t("stash.airdropFailed"))
            return
        }
        service.perform(withItems: urls)
    }

    // MARK: 私有

    private func refresh() async {
        items = await store.all()
        onChange?()
    }
}

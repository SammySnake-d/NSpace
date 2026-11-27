import Foundation
import SessionStore

/// 工作区管理器（M17：工作区标签从原生 NSWindow tabbing 迁出 → 自管）。
/// 持有窗口内的 `[SessionWindow]`（每个工作区 = 一份完整分屏布局快照）+ activeIndex。
/// 纯状态与簿记，无 UI：MainWindowController 据此驱动单一 grid（切换=快照当前→恢复目标）。
@MainActor
final class WorkspaceManager {
    /// 全部工作区快照；活动工作区的实时状态由 MainWindowController 在切换前经 syncActive 回灌
    private(set) var states: [SessionWindow]
    private var slotIDs: [UUID]
    private var historyCache: [UUID: [(back: [URL], forward: [URL])]] = [:]
    private(set) var activeIndex: Int
    /// 最近关闭的工作区快照栈（供 ⇧⌘T 恢复，上限 20）
    private var closedStack: [(state: SessionWindow, histories: [(back: [URL], forward: [URL])])] = []
    /// 活跃历史（MRU，首位=最近）：关闭活动工作区后回退到"上一个活跃"而非索引邻居（I-21 用户语义）
    private var mru: [Int]

    init(initial: SessionWindow) {
        self.states = [initial]
        self.slotIDs = [UUID()]
        self.activeIndex = 0
        self.mru = [0]
    }

    init(states: [SessionWindow], activeIndex: Int) {
        precondition(!states.isEmpty, "工作区数组不得为空")
        self.states = states
        self.slotIDs = states.map { _ in UUID() }
        self.activeIndex = min(max(0, activeIndex), states.count - 1)
        self.mru = [self.activeIndex]
    }

    var count: Int { states.count }
    var activeState: SessionWindow { states[activeIndex] }
    var activeHistories: [(back: [URL], forward: [URL])] {
        historyCache[slotIDs[activeIndex]] ?? []
    }
    var canReopenClosed: Bool { !closedStack.isEmpty }

    /// 工作区标签标题 = 目录名；仅当存在不同路径共享同一末尾目录名时才带父目录区分（避免"documents | documents"歧义）
    func titles() -> [String] {
        let paths = states.map(Self.activePath(of:))
        let baseNames = paths.map { p -> String in
            guard !p.isEmpty else { return "—" }
            return p == "/" ? "/" : (p as NSString).lastPathComponent
        }
        var pathsByBase: [String: Set<String>] = [:]
        for (p, n) in zip(paths, baseNames) where !p.isEmpty {
            pathsByBase[n, default: []].insert((p as NSString).standardizingPath)
        }
        return zip(paths, baseNames).map { path, base in
            guard (pathsByBase[base]?.count ?? 0) > 1, !path.isEmpty, path != "/" else { return base }
            let comps = (path as NSString).pathComponents.filter { $0 != "/" }
            if comps.count >= 2 {
                return "\(comps[comps.count - 2])/\(base)"
            }
            return base
        }
    }

    func toolTips() -> [String] {
        states.map { w in
            let names = w.panes.map { ($0.tab.path as NSString).abbreviatingWithTildeInPath }
            return names.joined(separator: " | ")
        }
    }

    private static func activePath(of w: SessionWindow) -> String {
        let pane = w.panes.indices.contains(w.activePaneIndex) ? w.panes[w.activePaneIndex] : w.panes.first
        return pane?.tab.path ?? ""
    }

    static func title(of w: SessionWindow) -> String {
        let path = activePath(of: w)
        guard !path.isEmpty else { return "—" }
        return path == "/" ? "/" : (path as NSString).lastPathComponent
    }

    /// 切换前把 grid 当前实时快照与导航历史回灌到活动槽（否则切走的工作区丢失未落盘状态/后退栈）
    func syncActive(_ snapshot: SessionWindow, histories: [(back: [URL], forward: [URL])]? = nil) {
        guard states.indices.contains(activeIndex) else { return }
        states[activeIndex] = snapshot
        if let histories {
            historyCache[slotIDs[activeIndex]] = histories
        }
    }

    /// 记录活跃（去重前插；所有 activeIndex 变更处都要过这里）
    private func touch(_ index: Int) {
        mru.removeAll { $0 == index }
        mru.insert(index, at: 0)
    }

    /// 追加新工作区并置为活动；limit>0 且超限则覆盖最老（移除 index 0，QSpace 语义）。
    func append(_ w: SessionWindow, limit: Int, histories: [(back: [URL], forward: [URL])] = []) {
        let id = UUID()
        states.append(w)
        slotIDs.append(id)
        if !histories.isEmpty { historyCache[id] = histories }
        if limit > 0, states.count > limit {
            let dropped = states.count - limit
            for removedID in slotIDs.prefix(dropped) { historyCache.removeValue(forKey: removedID) }
            states.removeFirst(dropped)
            slotIDs.removeFirst(dropped)
            mru = mru.compactMap { $0 >= dropped ? $0 - dropped : nil }
        }
        activeIndex = states.count - 1
        touch(activeIndex)
    }

    /// 切到指定工作区（越界忽略）
    func switchTo(_ index: Int) {
        guard states.indices.contains(index) else { return }
        activeIndex = index
        touch(index)
    }

    /// 关闭指定工作区；返回 false 表示这是最后一个（调用方应关窗）。
    @discardableResult
    func close(at index: Int) -> Bool {
        guard states.count > 1, states.indices.contains(index) else { return false }
        let removedState = states.remove(at: index)
        let removedID = slotIDs.remove(at: index)
        let removedHist = historyCache.removeValue(forKey: removedID) ?? []
        closedStack.append((removedState, removedHist))
        if closedStack.count > 20 { closedStack.removeFirst() }

        let wasActive = index == activeIndex
        mru.removeAll { $0 == index }
        mru = mru.map { $0 > index ? $0 - 1 : $0 }
        if wasActive {
            activeIndex = mru.first ?? min(index, states.count - 1)
        } else if index < activeIndex {
            activeIndex -= 1
        }
        touch(activeIndex)
        return true
    }

    /// 重新打开最近关闭的工作区（⇧⌘T）
    @discardableResult
    func reopenLastClosed(limit: Int) -> Bool {
        guard let item = closedStack.popLast() else { return false }
        append(item.state, limit: limit, histories: item.histories)
        return true
    }

    /// 复制指定工作区标签（右键菜单）
    func duplicate(at index: Int, limit: Int) {
        guard states.indices.contains(index) else { return }
        let id = slotIDs[index]
        append(states[index], limit: limit, histories: historyCache[id] ?? [])
    }

    /// 关闭除指定下标以外的其他工作区
    func closeOthers(keeping index: Int) {
        guard states.indices.contains(index), states.count > 1 else { return }
        for i in (0..<states.count).reversed() where i != index {
            let s = states.remove(at: i)
            let id = slotIDs.remove(at: i)
            let h = historyCache.removeValue(forKey: id) ?? []
            closedStack.append((s, h))
        }
        if closedStack.count > 20 { closedStack.removeFirst(closedStack.count - 20) }
        activeIndex = 0
        mru = [0]
    }

    /// 关闭指定下标右侧的全部工作区
    func closeToRight(of index: Int) {
        guard states.indices.contains(index), index + 1 < states.count else { return }
        for i in ((index + 1)..<states.count).reversed() {
            let s = states.remove(at: i)
            let id = slotIDs.remove(at: i)
            let h = historyCache.removeValue(forKey: id) ?? []
            closedStack.append((s, h))
        }
        if closedStack.count > 20 { closedStack.removeFirst(closedStack.count - 20) }
        if activeIndex > index { activeIndex = index }
        mru = mru.filter { $0 < states.count }
        if mru.isEmpty { mru = [activeIndex] }
    }

    /// 循环切换（⌃⇥ / ⌃⇧⇥）
    func cycle(backward: Bool) {
        guard states.count > 1 else { return }
        activeIndex = (activeIndex + (backward ? -1 : 1) + states.count) % states.count
        touch(activeIndex)
    }
}

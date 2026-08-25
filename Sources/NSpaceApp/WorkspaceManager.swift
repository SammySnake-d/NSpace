import Foundation
import SessionStore

/// 工作区管理器（M17：工作区标签从原生 NSWindow tabbing 迁出 → 自管）。
/// 持有窗口内的 `[SessionWindow]`（每个工作区 = 一份完整分屏布局快照）+ activeIndex。
/// 纯状态与簿记，无 UI：MainWindowController 据此驱动单一 grid（切换=快照当前→恢复目标）。
@MainActor
final class WorkspaceManager {
    /// 全部工作区快照；活动工作区的实时状态由 MainWindowController 在切换前经 syncActive 回灌
    private(set) var states: [SessionWindow]
    private(set) var activeIndex: Int
    /// 活跃历史（MRU，首位=最近）：关闭活动工作区后回退到"上一个活跃"而非索引邻居（I-21 用户语义）
    private var mru: [Int]

    init(initial: SessionWindow) {
        self.states = [initial]
        self.activeIndex = 0
        self.mru = [0]
    }

    init(states: [SessionWindow], activeIndex: Int) {
        precondition(!states.isEmpty, "工作区数组不得为空")
        self.states = states
        self.activeIndex = min(max(0, activeIndex), states.count - 1)
        self.mru = [self.activeIndex]
    }

    var count: Int { states.count }
    var activeState: SessionWindow { states[activeIndex] }

    /// 工作区标签标题 = 该工作区活动窗格活动标签的目录名（QSpace 语义）
    func titles() -> [String] { states.map { Self.title(of: $0) } }

    static func title(of w: SessionWindow) -> String {
        let pane = w.panes.indices.contains(w.activePaneIndex) ? w.panes[w.activePaneIndex] : w.panes.first
        let path = pane.flatMap { p -> String? in
            p.tabs.indices.contains(p.activeTabIndex) ? p.tabs[p.activeTabIndex].path : p.tabs.first?.path
        }
        guard let path, !path.isEmpty else { return "—" }
        return path == "/" ? "/" : (path as NSString).lastPathComponent
    }

    /// 切换前把 grid 当前实时快照回灌到活动槽（否则切走的工作区丢失未落盘编辑）
    func syncActive(_ snapshot: SessionWindow) {
        guard states.indices.contains(activeIndex) else { return }
        states[activeIndex] = snapshot
    }

    /// 记录活跃（去重前插；所有 activeIndex 变更处都要过这里）
    private func touch(_ index: Int) {
        mru.removeAll { $0 == index }
        mru.insert(index, at: 0)
    }

    /// 追加新工作区并置为活动；limit>0 且超限则覆盖最老（移除 index 0，同 paneTabLimit 语义）。
    func append(_ w: SessionWindow, limit: Int) {
        states.append(w)
        if limit > 0, states.count > limit {
            let dropped = states.count - limit
            states.removeFirst(dropped)
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
    /// 关闭活动工作区 → 回退到 MRU 里上一个活跃者（I-21）；关非活动的只修正下标。
    @discardableResult
    func close(at index: Int) -> Bool {
        guard states.count > 1, states.indices.contains(index) else { return false }
        let wasActive = index == activeIndex
        states.remove(at: index)
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

    /// 循环切换（⌃⇥ / ⌃⇧⇥）
    func cycle(backward: Bool) {
        guard states.count > 1 else { return }
        activeIndex = (activeIndex + (backward ? -1 : 1) + states.count) % states.count
        touch(activeIndex)
    }
}

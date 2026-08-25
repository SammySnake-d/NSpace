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

    init(initial: SessionWindow) {
        self.states = [initial]
        self.activeIndex = 0
    }

    init(states: [SessionWindow], activeIndex: Int) {
        precondition(!states.isEmpty, "工作区数组不得为空")
        self.states = states
        self.activeIndex = min(max(0, activeIndex), states.count - 1)
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

    /// 追加新工作区并置为活动；limit>0 且超限则覆盖最老（移除 index 0，同 paneTabLimit 语义）。
    func append(_ w: SessionWindow, limit: Int) {
        states.append(w)
        if limit > 0, states.count > limit {
            states.removeFirst(states.count - limit)
        }
        activeIndex = states.count - 1
    }

    /// 切到指定工作区（越界忽略）
    func switchTo(_ index: Int) {
        guard states.indices.contains(index) else { return }
        activeIndex = index
    }

    /// 关闭指定工作区；返回 false 表示这是最后一个（调用方应关窗）。
    /// activeIndex 依 QSpace 惯例回退到邻居。
    @discardableResult
    func close(at index: Int) -> Bool {
        guard states.count > 1, states.indices.contains(index) else { return false }
        states.remove(at: index)
        if activeIndex >= states.count { activeIndex = states.count - 1 }
        else if index < activeIndex { activeIndex -= 1 }
        return true
    }

    /// 循环切换（⌃⇥ / ⌃⇧⇥）
    func cycle(backward: Bool) {
        guard states.count > 1 else { return }
        activeIndex = (activeIndex + (backward ? -1 : 1) + states.count) % states.count
    }
}

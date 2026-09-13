import Foundation
import NSpaceContracts

// SessionStore 胶囊唯一对外契约面（Axiom 3）：窗口/布局/窗格/标签会话快照的唯一 Commit Owner

public struct SessionTab: Sendable, Codable, Equatable {
    public var path: String
    public var sortKey: String
    public var sortAscending: Bool
    public var includeHidden: Bool
    /// 视图模式原始值（icons/list/columns 的 Int raw）；旧档案缺省 nil=列表
    public var viewMode: Int?

    public init(path: String, sortKey: String = "name", sortAscending: Bool = true,
                includeHidden: Bool = false, viewMode: Int? = nil) {
        self.path = path
        self.sortKey = sortKey
        self.sortAscending = sortAscending
        self.includeHidden = includeHidden
        self.viewMode = viewMode
    }
}

/// 一个窗格 = 一个浏览上下文。
///
/// v0.19.26 起窗格内不再有多标签（M13 的「每窗格多标签」退役：产品定位只认窗口级工作区标签，
/// 而窗格标签栏默认隐藏、建出来的标签用户看不见，外部打开又一直往里堆——用户报告
/// 「⌥⌘T 没反应」「这个好像没什么作用」）。外部打开改落到工作区标签，那一层本来就可见可关。
public struct SessionPane: Sendable, Codable, Equatable {
    public var tab: SessionTab

    public init(tab: SessionTab) {
        self.tab = tab
    }

    private enum CodingKeys: String, CodingKey { case tab, tabs, activeTabIndex }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // 先试新结构
        if let t = try? c.decode(SessionTab.self, forKey: .tab) {
            self.tab = t
            return
        }
        // 旧结构（窗格内多标签）一次性迁移：只留当时的**活动**标签，其余丢弃。
        // 不展开成多个工作区——用户会话里最多的一个窗格有 5 个标签，全展开会炸出二十几个
        // 工作区，那不是"删掉这层"该有的结果。
        let tabs = try c.decode([SessionTab].self, forKey: .tabs)
        let idx = (try? c.decode(Int.self, forKey: .activeTabIndex)) ?? 0
        // 空数组是不可能状态（旧实现保证每窗格至少一个标签）；真遇上给空路径，
        // 由上层「会话恢复时路径已消失 → 回退个人目录」接住（spec.md §风险表）。
        self.tab = tabs.indices.contains(idx) ? tabs[idx] : (tabs.first ?? SessionTab(path: ""))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(tab, forKey: .tab)
    }
}

public struct SessionWindow: Sendable, Codable, Equatable {
    /// PaneLayout.rawValue（UI 层枚举不进胶囊契约）
    public var layoutRaw: Int
    public var panes: [SessionPane]
    public var activePaneIndex: Int

    public init(layoutRaw: Int, panes: [SessionPane], activePaneIndex: Int) {
        self.layoutRaw = layoutRaw
        self.panes = panes
        self.activePaneIndex = activePaneIndex
    }
}

/// 一个 OS 窗口 = 一组工作区（M17：工作区标签迁出原生 NSWindow tabbing → 自管）。
/// 每个工作区复用 SessionWindow 编码（布局+窗格+标签+路径+排序+视图模式）。
public struct SessionWorkspaces: Sendable, Codable, Equatable {
    public var workspaces: [SessionWindow]
    public var activeWorkspace: Int

    public init(workspaces: [SessionWindow], activeWorkspace: Int) {
        self.workspaces = workspaces
        self.activeWorkspace = activeWorkspace
    }
}

/// 会话快照（M17 结构）：windows 每项 = 一个窗口内的工作区数组。
/// 旧格式（windows 每项直接是 SessionWindow，即"多窗口各存一份"）解码时一次性迁移：
/// 全部旧窗口包成【单个】窗口的工作区数组（保留 M13 平铺标签所见）。
public struct SessionSnapshot: Sendable, Codable, Equatable {
    public var windows: [SessionWorkspaces]

    public init(windows: [SessionWorkspaces]) {
        self.windows = windows
    }

    private enum CodingKeys: String, CodingKey { case windows }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // 先试新结构（元素含 workspaces 键）
        if let ws = try? container.decode([SessionWorkspaces].self, forKey: .windows) {
            self.windows = ws
            return
        }
        // 回退旧结构：windows 每项是 SessionWindow → 全部包成单窗口的工作区数组
        let legacy = try container.decode([SessionWindow].self, forKey: .windows)
        self.windows = legacy.isEmpty ? [] : [SessionWorkspaces(workspaces: legacy, activeWorkspace: 0)]
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(windows, forKey: .windows)
    }
}

public struct SessionError: ClassifiedError {
    public let errorClass: ErrorClass
    public let localizedDescription: String

    init(_ cls: ErrorClass, _ message: String) {
        self.errorClass = cls
        self.localizedDescription = message
    }
}

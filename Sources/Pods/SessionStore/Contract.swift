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

public struct SessionPane: Sendable, Codable, Equatable {
    public var tabs: [SessionTab]
    public var activeTabIndex: Int

    public init(tabs: [SessionTab], activeTabIndex: Int) {
        self.tabs = tabs
        self.activeTabIndex = activeTabIndex
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

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

public struct SessionSnapshot: Sendable, Codable, Equatable {
    public var windows: [SessionWindow]

    public init(windows: [SessionWindow]) {
        self.windows = windows
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

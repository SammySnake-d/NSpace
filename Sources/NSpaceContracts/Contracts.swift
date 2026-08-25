import Foundation

// MARK: - 目录投影（文件系统的只读投影，BG-5）

public struct FileItem: Sendable, Hashable {
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let isPackage: Bool
    public let isSymlink: Bool
    public let isHidden: Bool
    /// 文件字节数；目录为 nil（FolderSize 胶囊按需回填）
    public let size: Int64?
    public let modified: Date?
    public let created: Date?
    /// UTType.identifier；kind 显示串按此缓存派生
    public let contentTypeID: String?

    public init(url: URL, name: String, isDirectory: Bool, isPackage: Bool,
                isSymlink: Bool, isHidden: Bool, size: Int64?,
                modified: Date?, created: Date?, contentTypeID: String?) {
        self.url = url; self.name = name
        self.isDirectory = isDirectory; self.isPackage = isPackage
        self.isSymlink = isSymlink; self.isHidden = isHidden
        self.size = size; self.modified = modified; self.created = created
        self.contentTypeID = contentTypeID
    }
}

public struct DirectorySnapshot: Sendable {
    public let directory: URL
    /// 代际 token：过期的慢加载结果不得覆盖新导航（spec 3.2）
    public let generation: UInt64
    public let items: [FileItem]

    public init(directory: URL, generation: UInt64, items: [FileItem]) {
        self.directory = directory; self.generation = generation; self.items = items
    }
}

public struct SortSpec: Sendable, Hashable, Codable {
    public enum Key: String, Sendable, Codable { case name, dateModified, size, kind }
    public var key: Key
    public var ascending: Bool
    public var foldersFirst: Bool

    public init(key: Key = .name, ascending: Bool = true, foldersFirst: Bool = true) {
        self.key = key; self.ascending = ascending; self.foldersFirst = foldersFirst
    }
}

// MARK: - 错误三分类（每胶囊 Error 必须归入其一，BG-4 / P6.4）

public enum ErrorClass: Sendable, Equatable {
    /// 内部逻辑错，禁重试
    case logic
    /// 系统抖动，可重试
    case transient
    /// 权限 / 卷不可用等外部依赖问题，提示用户
    case external
}

public protocol ClassifiedError: Error, Sendable {
    var errorClass: ErrorClass { get }
    var localizedDescription: String { get }
}

// MARK: - 操作契约（展示层 → 内核的 Typed Command，BG-1）

public struct OperationSpec: Sendable {
    public enum Kind: String, Sendable {
        case copy, move, trash, duplicate, newFolder, newFile, rename
    }
    public let kind: Kind
    public let sources: [URL]
    public let destination: URL?
    /// rename / newFolder / newFile 用
    public let newName: String?

    public init(kind: Kind, sources: [URL], destination: URL? = nil, newName: String? = nil) {
        self.kind = kind; self.sources = sources
        self.destination = destination; self.newName = newName
    }
}

/// 操作 Run 状态机（spec 3.1；OperationKernel 唯一提交）
public enum RunState: Sendable, Equatable {
    case pending
    case scanning
    case awaitingConflict
    case running
    case completed
    case cancelled
    case failed(message: String, errorClass: ErrorClass)

    public var isTerminal: Bool {
        switch self {
        case .completed, .cancelled, .failed: return true
        default: return false
        }
    }

    public static func == (lhs: RunState, rhs: RunState) -> Bool {
        switch (lhs, rhs) {
        case (.pending, .pending), (.scanning, .scanning), (.awaitingConflict, .awaitingConflict),
             (.running, .running), (.completed, .completed), (.cancelled, .cancelled):
            return true
        case let (.failed(m1, _), .failed(m2, _)):
            return m1 == m2
        default:
            return false
        }
    }
}

/// 内核 → 进度窗的只读投影（AsyncStream 推送）
public struct OperationProjection: Sendable {
    public let id: UUID
    public let kind: OperationSpec.Kind
    public let state: RunState
    public let filesDone: Int
    public let filesTotal: Int
    public let bytesDone: Int64
    public let bytesTotal: Int64
    public let currentPath: String?

    public init(id: UUID, kind: OperationSpec.Kind, state: RunState,
                filesDone: Int, filesTotal: Int, bytesDone: Int64, bytesTotal: Int64,
                currentPath: String?) {
        self.id = id; self.kind = kind; self.state = state
        self.filesDone = filesDone; self.filesTotal = filesTotal
        self.bytesDone = bytesDone; self.bytesTotal = bytesTotal
        self.currentPath = currentPath
    }
}

// MARK: - 冲突裁决

public struct FileConflict: Sendable, Hashable {
    public let source: URL
    public let existing: URL
    public let bothDirectories: Bool

    public init(source: URL, existing: URL, bothDirectories: Bool) {
        self.source = source; self.existing = existing; self.bothDirectories = bothDirectories
    }
}

public enum ConflictDecision: Sendable {
    case replace, skip, keepBoth, mergeFolders
}

/// 废纸篓一对：原位置 → 回收站落点（供撤销把 trashed 搬回 original）
public struct TrashedItem: Sendable, Hashable {
    public let original: URL
    public let trashed: URL
    public init(original: URL, trashed: URL) {
        self.original = original; self.trashed = trashed
    }
}

/// 操作真实成败凭证（Proof Owner 产物）
public struct OperationReceipt: Sendable {
    public let id: UUID
    public let filesDone: Int
    public let bytesDone: Int64
    public let duration: TimeInterval
    /// newFolder / newFile 等产生新条目的操作回传结果 URL（UI 用于选中+进入重命名）
    public let createdURLs: [URL]
    /// trash 操作回传 原URL→回收站URL 对（UI 注册撤销用）
    public let trashedItems: [TrashedItem]

    public init(id: UUID, filesDone: Int, bytesDone: Int64, duration: TimeInterval,
                createdURLs: [URL] = [], trashedItems: [TrashedItem] = []) {
        self.id = id; self.filesDone = filesDone; self.bytesDone = bytesDone; self.duration = duration
        self.createdURLs = createdURLs; self.trashedItems = trashedItems
    }
}

// MARK: - 节点契约（胶囊只依赖本词汇表，不依赖内核实现，BG-4/BG-6）

/// 节点执行中向内核回报的事件（进度切面；遥测失败不伤主链 BG-7）
public enum NodeEvent: Sendable {
    case scanTotals(files: Int, bytes: Int64)
    case progress(filesDone: Int, bytesDone: Int64, currentPath: String?)
}

/// 内核注入给节点的上下文：回报进度、请求冲突裁决
public struct NodeContext: Sendable {
    public let operationID: UUID
    public let report: @Sendable (NodeEvent) -> Void
    /// 返回 nil = 用户取消整个操作
    public let resolveConflicts: @Sendable ([FileConflict]) async -> [URL: ConflictDecision]?

    public init(operationID: UUID,
                report: @escaping @Sendable (NodeEvent) -> Void,
                resolveConflicts: @escaping @Sendable ([FileConflict]) async -> [URL: ConflictDecision]?) {
        self.operationID = operationID
        self.report = report
        self.resolveConflicts = resolveConflicts
    }
}

/// 语义原子节点统一契约：单一原子状态转换，强类型出入（P6）
public protocol OperationNode: Sendable {
    func execute(_ spec: OperationSpec, context: NodeContext) async throws -> OperationReceipt
}

/// 冲突裁决委托（由展示层实现为冲突面板；内核不知道 UI 存在）
public protocol ConflictArbiter: Sendable {
    /// 返回 nil = 用户在面板上取消了操作
    func arbitrate(operation id: UUID, conflicts: [FileConflict]) async -> [URL: ConflictDecision]?
}

import Foundation
import NSpaceContracts

// SearchEngine 胶囊唯一对外契约面（Axiom 3）：聚焦搜索的请求/命中词汇表

public struct SearchRequest: Sendable {
    public enum Scope: Sendable {
        case global
        case directory(URL)
    }

    public let query: String
    public let scope: Scope
    /// 按名称搜（通道A Spotlight kMDItemFSName + 通道B 文件名扫描）
    public let searchNames: Bool
    /// 按内容全文搜（只走通道A Spotlight kMDItemTextContent——全文索引无法自建，诚实降级）
    public let searchContents: Bool
    /// 隐藏文件通道开关（超越 Spotlight：不依赖索引、不跳过隐藏文件，只支持按名搜）
    public let includeHidden: Bool
    /// 通道B 递归扫描跳过的巨坑目录名（可配置）
    public let skippedDirectoryNames: Set<String>

    public init(query: String, scope: Scope,
                searchNames: Bool = true, searchContents: Bool = false,
                includeHidden: Bool = false,
                skippedDirectoryNames: Set<String> = ["node_modules", ".git", ".Trash", "Library"]) {
        self.query = query
        self.scope = scope
        self.searchNames = searchNames
        self.searchContents = searchContents
        self.includeHidden = includeHidden
        self.skippedDirectoryNames = skippedDirectoryNames
    }
}

/// 搜索命中（构建时已取好展示属性，UI 零补 stat）
public struct SearchHit: Sendable, Hashable {
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let size: Int64?
    public let modified: Date?
    /// UTType.identifier（UI 按 conform 做种类过滤）
    public let contentTypeID: String?

    public init(url: URL, name: String, isDirectory: Bool,
                size: Int64?, modified: Date?, contentTypeID: String?) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
        self.contentTypeID = contentTypeID
    }
}

public struct SearchError: ClassifiedError {
    public let errorClass: ErrorClass
    public let localizedDescription: String

    init(_ cls: ErrorClass, _ message: String) {
        self.errorClass = cls
        self.localizedDescription = message
    }
}

import Foundation
import NSpaceContracts

// FolderSize 胶囊唯一对外契约面（Axiom 3）：目录 URL → 递归占用字节数（按需回填 FileItem.size）。

public struct FolderSizeError: ClassifiedError {
    public let errorClass: ErrorClass
    public let localizedDescription: String
    public let underlying: (any Error)?

    init(_ cls: ErrorClass, _ message: String, underlying: (any Error)? = nil) {
        self.errorClass = cls
        self.localizedDescription = message
        self.underlying = underlying
    }
}

public protocol FolderSizing: Sendable {
    /// 递归求和 url 下所有常规文件的占用字节（优先 totalFileAllocatedSize，回退 fileSize）。
    /// 命中缓存直接返回；深枚举并发被限界；取消经 Task.isCancelled 协作式抛 CancellationError。
    func size(of url: URL) async throws -> Int64
    /// 失效某路径缓存（其内容变更后调用，下次 size 会重新计算）。
    func invalidate(_ url: URL) async
}

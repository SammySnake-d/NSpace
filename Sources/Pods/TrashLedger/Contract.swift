import Foundation
import NSpaceContracts

// TrashLedger 胶囊唯一对外契约面（Axiom 3）：「放回原处」的唯一真源。
//
// 为什么必须自己记账：macOS 的 put-back 元数据在 Finder 私有库里，**读不到**。
// 真机实测（2026-09-07）：废纸篓项上唯一的扩展属性是 `com.apple.provenance`（空，与来源无关）；
// `mdls` 无任何来源线索；连 Finder 自己的 AppleScript `original item` 都返回 -1728 拿不到。
// 所以「放回原处」只能覆盖 **NSpace 自己删掉的项**——别的应用删的项没有记录，
// 菜单项必须诚实地不可用，而不是假装能放回。

public struct TrashLedgerEntry: Sendable, Hashable, Codable {
    /// 废纸篓里的落点路径（键）
    public let trashedPath: String
    /// 删除前的原路径
    public let originalPath: String
    /// 记账时间（用于清理陈旧条目）
    public let recordedAt: Date

    public init(trashedPath: String, originalPath: String, recordedAt: Date) {
        self.trashedPath = trashedPath
        self.originalPath = originalPath
        self.recordedAt = recordedAt
    }
}

public struct TrashLedgerError: ClassifiedError {
    public let errorClass: ErrorClass
    public let localizedDescription: String

    init(_ cls: ErrorClass, _ message: String) {
        self.errorClass = cls
        self.localizedDescription = message
    }
}

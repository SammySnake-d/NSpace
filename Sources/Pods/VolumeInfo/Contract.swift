import Foundation
import NSpaceContracts

// VolumeInfo 胶囊唯一对外契约面（Axiom 3）：挂载卷枚举 / 变更信号 / 推出

public struct VolumeItem: Sendable, Hashable {
    public let name: String
    public let url: URL
    public let totalCapacity: Int64
    public let availableCapacity: Int64
    public let isEjectable: Bool
    public let isRemovable: Bool
    /// 内置根卷（"/"）不显示推出钮
    public let isRoot: Bool

    public init(name: String, url: URL, totalCapacity: Int64, availableCapacity: Int64,
                isEjectable: Bool, isRemovable: Bool, isRoot: Bool) {
        self.name = name; self.url = url
        self.totalCapacity = totalCapacity; self.availableCapacity = availableCapacity
        self.isEjectable = isEjectable; self.isRemovable = isRemovable; self.isRoot = isRoot
    }
}

public struct VolumeError: ClassifiedError {
    public let errorClass: ErrorClass
    public let localizedDescription: String

    init(_ cls: ErrorClass, _ message: String) {
        self.errorClass = cls
        self.localizedDescription = message
    }
}

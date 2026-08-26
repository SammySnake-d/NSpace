import Foundation
import NSpaceContracts

// Transfer 胶囊唯一对外契约面（Axiom 3）：
// Composite Node —— 复制 / 移动 / 制作副本（内部微步：预扫描→冲突裁决→逐文件传输）
// 节点边界按不可逆副作用切：一次操作 = 一次原子提交单位

public struct TransferError: ClassifiedError {
    public let errorClass: ErrorClass
    public let localizedDescription: String
    public let path: String?

    init(_ cls: ErrorClass, _ message: String, path: String? = nil) {
        self.errorClass = cls
        self.localizedDescription = message
        self.path = path
    }
}

/// "两者都保留"的命名规则（纯逻辑，可黑盒单测）：
/// file.txt → file 2.txt → file 3.txt…（恒加后缀，绝不返回原名——keepBoth 语义=保留既有再新增副本）
public func keepBothName(for source: URL, in destinationDir: URL,
                         existsCheck: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> String {
    let base = source.deletingPathExtension().lastPathComponent
    let ext = source.pathExtension
    var n = 2
    while true {
        let candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
        if !existsCheck(destinationDir.appendingPathComponent(candidate)) { return candidate }
        n += 1
    }
}

/// rename 兜底命名：用户指定 desired 名可用则原样返回，否则 desired → "desired 2" → …（不覆盖已存在）。
/// 与 keepBothName 的区别：rename 允许命中 desired 本身（用户显式意图），keepBoth 恒新增副本。
public func uniqueName(base: String, ext: String, in destinationDir: URL,
                       existsCheck: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> String {
    let firstName = ext.isEmpty ? base : "\(base).\(ext)"
    if !existsCheck(destinationDir.appendingPathComponent(firstName)) { return firstName }
    var n = 2
    while true {
        let candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
        if !existsCheck(destinationDir.appendingPathComponent(candidate)) { return candidate }
        n += 1
    }
}

/// 合并语义（文档化承诺）：mergeFolders 递归合并目录内容，同名文件以源覆盖目标
public enum TransferMergePolicy {
    public static let documentation = "merge = 递归并集；同名子文件源覆盖目标；同名子目录继续递归"
}

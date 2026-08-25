import Foundation
import NSpaceContracts

// LocalOps 胶囊唯一对外契约面（Axiom 3）：
// 目录级本地原子操作 —— 重命名 / 新建文件夹 / 新建文件 / 移到废纸篓
// 节点边界按不可逆副作用切：每种操作 = 一次原子提交单位；与 Transfer（跨目录传输）互补不重叠

public struct LocalOpsError: ClassifiedError {
    public let errorClass: ErrorClass
    public let localizedDescription: String
    public let path: String?

    init(_ cls: ErrorClass, _ message: String, path: String? = nil) {
        self.errorClass = cls
        self.localizedDescription = message
        self.path = path
    }
}

/// 新建条目的默认基名（UI 无名创建时用；重名自动追加序号 " 2"/" 3"…）。
/// 纯逻辑、可黑盒单测：在目录内找到首个不冲突的候选名。
public func uniqueName(base: String, ext: String, in directory: URL,
                       existsCheck: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> String {
    func compose(_ n: Int) -> String {
        let stem = n <= 1 ? base : "\(base) \(n)"
        return ext.isEmpty ? stem : "\(stem).\(ext)"
    }
    var n = 1
    while existsCheck(directory.appendingPathComponent(compose(n))) { n += 1 }
    return compose(n)
}

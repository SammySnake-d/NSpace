import Foundation

// PathComplete 胶囊唯一对外契约面（Axiom 3）：输入前缀 → 目录补全候选（纯逻辑，Oracle 免文件系统）

public protocol PathCompleting: Sendable {
    /// 输入任意路径前缀（支持 ~ 展开），返回完整路径候选（仅目录，带尾随 /）
    func complete(_ input: String) -> [String]
}

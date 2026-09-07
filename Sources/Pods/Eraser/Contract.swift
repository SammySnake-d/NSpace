import Foundation
import NSpaceContracts

// Eraser 胶囊唯一对外契约面（Axiom 3）：**不可逆**的永久删除。
//
// 为什么另起一块而不是塞进 LocalOps：LocalOps 是已经在跑的成熟节点（rename/newFolder/
// newFile/trash），往它的 switch 里加一个"删了就没了"的分支，是把今天的省事换成明天不敢动。
// 永久删除的爆炸半径与其余本地操作不在一个量级，它该有自己的边界、自己的守卫、自己的自证。

public struct EraserError: ClassifiedError {
    public let errorClass: ErrorClass
    public let localizedDescription: String

    init(_ cls: ErrorClass, _ message: String) {
        self.errorClass = cls
        self.localizedDescription = message
    }
}

public enum EraserLimits {
    /// 爆炸半径守卫：`.delete` 必须带 `destination` 作为**围栏根**，每一个 source
    /// 都必须落在它之内，否则整批拒绝。
    ///
    /// 这不是"想象出来的门"：永久删除是本仓唯一不可逆的操作，一次路径拼错就是用户数据没了。
    /// 让调用方显式声明"我只在这个范围里删"，是把范围写进契约而不是写进注释。
    /// 节点不认识"废纸篓"这个概念——围栏由调用方给，胶囊零业务知识。
    public static func isFenced(_ source: URL, by root: URL) -> Bool {
        let r = root.standardizedFileURL.path
        let s = source.standardizedFileURL.path
        guard s != r else { return false }          // 围栏本身不许被删
        return s.hasPrefix(r.hasSuffix("/") ? r : r + "/")
    }
}

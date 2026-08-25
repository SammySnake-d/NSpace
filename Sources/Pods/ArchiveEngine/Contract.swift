import Foundation
import NSpaceContracts

// ArchiveEngine 胶囊唯一对外契约面（Axiom 3）：
// 归档能力 —— 压缩（compress）/ 解压（extract），经系统工具（zip/tar/unzip/gunzip…）Process 驱动，
// 无第三方依赖（诚实路线）。节点边界按不可逆副作用切：一次 compress = 产出一个归档包；
// 一次 extract = 从归档包落地内容树，均为一次原子提交单位。
//
// 加密说明（诚实告知）：zip 口令走 /usr/bin/zip -P <password>（ZipCrypto 传统加密，
// 属【弱加密】，且口令以明文进入进程参数表存在暴露面）。tar.gz 无内建加密，口令被忽略。
// 设置页对此有说明；如需强加密应改用 AES zip（需第三方，v1 不做）。

public struct ArchiveError: ClassifiedError {
    public let errorClass: ErrorClass
    public let localizedDescription: String
    public let path: String?

    init(_ cls: ErrorClass, _ message: String, path: String? = nil) {
        self.errorClass = cls
        self.localizedDescription = message
        self.path = path
    }
}

// MARK: - 纯逻辑助手（可黑盒单测，无需真实文件系统）

/// 归档包命名（省扩展名基名 + 全后缀）：base.ext → "base 2.ext" → "base 3.ext"…（跳过已存在名）。
/// ext 为完整后缀不含前导点（如 "zip" / "tar.gz"）；编号只追加在 base 上，后缀恒完整。
public func uniqueArchiveName(base: String, ext: String, in directory: URL,
                             exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> String {
    func compose(_ n: Int) -> String {
        let stem = n <= 1 ? base : "\(base) \(n)"
        return ext.isEmpty ? stem : "\(stem).\(ext)"
    }
    var n = 1
    while exists(directory.appendingPathComponent(compose(n))) { n += 1 }
    return compose(n)
}

/// 解压"包裹语义"的核心判据（纯逻辑）：给定归档内所有条目路径，数出顶层不同条目数。
/// 顶层 >1 → 需先建同名包裹文件夹再解；==1（或 0）→ 忽略包裹直接解（QSpace 语义）。
public func topLevelEntryCount(_ entries: [String]) -> Int {
    var tops = Set<String>()
    for raw in entries {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { continue }
        while s.hasPrefix("./") { s.removeFirst(2) }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let first = s.split(separator: "/").first, !first.isEmpty else { continue }
        tops.insert(String(first))
    }
    return tops.count
}

/// 归档格式（按扩展名分发解压工具）
public enum ArchiveFormat: Sendable, Equatable {
    case zip
    case tarGz, tarBz2, tarXz, tar   // tar 家族（含压缩变体）
    case gzip, bzip2, xz             // 单流压缩（非 tar）

    /// 按 URL 扩展名识别（多段后缀优先匹配；不认识返回 nil）
    public static func detect(_ url: URL) -> ArchiveFormat? {
        let n = url.lastPathComponent.lowercased()
        if n.hasSuffix(".tar.gz") || n.hasSuffix(".tgz") { return .tarGz }
        if n.hasSuffix(".tar.bz2") || n.hasSuffix(".tbz2") || n.hasSuffix(".tbz") { return .tarBz2 }
        if n.hasSuffix(".tar.xz") || n.hasSuffix(".txz") { return .tarXz }
        if n.hasSuffix(".tar") { return .tar }
        if n.hasSuffix(".zip") { return .zip }
        if n.hasSuffix(".gz") || n.hasSuffix(".z") { return .gzip }   // .Z 老式 compress 也走 gunzip
        if n.hasSuffix(".bz2") { return .bzip2 }
        if n.hasSuffix(".xz") { return .xz }
        return nil
    }

    /// 单流压缩（.gz/.bz2/.xz/.Z）解压后的输出文件名 = 去掉压缩后缀（供包裹判定/落点命名）
    static func singleStreamOutputName(for url: URL) -> String {
        let name = url.lastPathComponent
        for suffix in [".gz", ".z", ".bz2", ".xz"] where name.lowercased().hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return name
    }
}

// MARK: - 支持检测（诚实路线：按系统实际存在的工具实测，缺工具的扩展名不列入）

public extension ArchiveEngineNode {
    /// 本机可解压的扩展名集合（按 /usr/bin 下实际工具存在性动态构成；UI 据此诚实启用/禁用"解压"）
    static func supportedExtensions() -> [String] {
        var exts: [String] = []
        if toolExists(Tools.unzip) { exts += ["zip"] }
        if toolExists(Tools.tar) { exts += ["tar", "tar.gz", "tgz", "tar.bz2", "tbz2", "tbz", "tar.xz", "txz"] }
        if toolExists(Tools.gunzip) { exts += ["gz", "Z"] }
        if toolExists(Tools.bunzip2) { exts += ["bz2"] }
        if toolExists(Tools.xz) { exts += ["xz"] }
        return exts
    }

    /// 该 URL 是否为本机支持解压的归档（右键菜单据此决定是否出现"解压"项）
    static func isSupportedArchive(_ url: URL) -> Bool {
        guard let fmt = ArchiveFormat.detect(url) else { return false }
        switch fmt {
        case .zip: return toolExists(Tools.unzip)
        case .tarGz, .tarBz2, .tarXz, .tar: return toolExists(Tools.tar)
        case .gzip: return toolExists(Tools.gunzip)
        case .bzip2: return toolExists(Tools.bunzip2)
        case .xz: return toolExists(Tools.xz)
        }
    }

    static func toolExists(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }
}

/// 系统工具绝对路径（诚实路线：固定 /usr/bin，缺失即报 external）
enum Tools {
    static let zip = "/usr/bin/zip"
    static let unzip = "/usr/bin/unzip"
    static let tar = "/usr/bin/tar"
    static let gunzip = "/usr/bin/gunzip"
    static let bunzip2 = "/usr/bin/bunzip2"
    static let xz = "/usr/bin/xz"
}

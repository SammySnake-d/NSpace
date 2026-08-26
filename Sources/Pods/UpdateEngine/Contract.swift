import Foundation
import NSpaceContracts

// UpdateEngine 胶囊唯一对外契约面（Axiom 3）：版本热更新能力。
// 语义边界按不可逆副作用切：一次 check = 只读探测（无副作用）；一次 downloadAndStage =
// 落地一个已校验的暂存 .app（暂存目录，失败即弃）；一次 install = 原子替换旧 .app（唯一破坏性提交）。
//
// 诚实说明（非苹果签名分发路线）：热更新走 GitHub Releases 的 .zip 资产 → ditto 解压 →
// 就地原子替换 .app bundle。不做增量/差分、不做代码签名校验链（ad-hoc 分发场景），
// 仅校验解出的 bundle id 与目标版本号一致，防止把错误的包搬进位。install 后由 App 层提示重启。
//
// Axiom 2（零全局可变状态）：feedURL / currentVersion / 目标 bundleID 全部经方法参数注入，
// 胶囊自身不读 Preferences、不持全局单例。

/// 目标 App 的 bundle 标识（校验解出的 .app 确系 NSpace，防搬错包）。
public let kNSpaceBundleID = "com.nspace.NSpace"

/// 可用更新描述（check 的产物；无新版时 check 返回 nil）。
public struct UpdateInfo: Sendable, Equatable {
    /// 归一化后的语义版本（去前导 v，如 "0.9.4"）
    public let version: String
    /// 原始 tag_name（如 "v0.9.4"）
    public let rawTag: String
    /// 资产里 .zip 的下载地址（browser_download_url）
    public let downloadURL: URL
    /// 更新说明（release body，可空）
    public let releaseNotes: String

    public init(version: String, rawTag: String, downloadURL: URL, releaseNotes: String) {
        self.version = version
        self.rawTag = rawTag
        self.downloadURL = downloadURL
        self.releaseNotes = releaseNotes
    }
}

public struct UpdateError: ClassifiedError {
    public let errorClass: ErrorClass
    public let localizedDescription: String

    init(_ cls: ErrorClass, _ message: String) {
        self.errorClass = cls
        self.localizedDescription = message
    }
}

/// NSError 桥接（I-29b）：不实现 LocalizedError 时 Swift Error 桥出的是
/// "未能完成操作（…错误 1）"——真实消息必须经 errorDescription 透出
extension UpdateError: LocalizedError {
    public var errorDescription: String? { localizedDescription }
}

// MARK: - 纯逻辑：语义化版本比较（自实现，带单测）

/// 语义化版本比较工具（纯函数，可黑盒单测，无需网络/文件系统）。
/// 规则（SemVer 2.0 子集）：
///   - 去前导 v/V 与首尾空白；核心版本按点分数字段逐段数值比较（缺段补 0）；
///   - 预发布（"-" 之后）版本低于同核心的正式版；两者皆预发布时按点分标识符比较
///     （纯数字段按数值、含字母段按 ASCII 字典序，数字段 < 字母段）；
///   - 构建元数据（"+" 之后）不参与比较。
public enum SemVer {
    /// 归一化：去首尾空白与前导 v/V（不改动其余内容）。
    public static func normalize(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let f = t.first, f == "v" || f == "V" { t.removeFirst() }
        return t
    }

    /// 比较 a 与 b：a<b→.orderedAscending，a>b→.orderedDescending，相等→.orderedSame。
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let (coreA, preA) = split(normalize(a))
        let (coreB, preB) = split(normalize(b))

        // 核心版本：数字段逐位比较（缺位补 0）
        let na = coreA, nb = coreB
        let count = max(na.count, nb.count)
        for i in 0..<count {
            let x = i < na.count ? na[i] : 0
            let y = i < nb.count ? nb[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }

        // 核心相等：有预发布 < 无预发布
        switch (preA.isEmpty, preB.isEmpty) {
        case (true, true): return .orderedSame
        case (true, false): return .orderedDescending   // a 正式 > b 预发布
        case (false, true): return .orderedAscending    // a 预发布 < b 正式
        case (false, false): return comparePrerelease(preA, preB)
        }
    }

    /// b 是否严格新于 a（用于"当前版本 vs 最新版本"判定：newer(than:) == true 才提示更新）。
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        compare(candidate, current) == .orderedDescending
    }

    // MARK: 私有

    /// 拆分为（核心数字段数组, 预发布标识符数组）；剥离构建元数据（+ 之后）。
    private static func split(_ raw: String) -> (core: [Int], pre: [String]) {
        var s = raw
        if let plus = s.firstIndex(of: "+") { s = String(s[s.startIndex..<plus]) }
        let dashParts = s.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let coreStr = String(dashParts.first ?? "")
        let preStr = dashParts.count > 1 ? String(dashParts[1]) : ""
        let core = coreStr.split(separator: ".").map { Int($0) ?? 0 }
        let pre = preStr.isEmpty ? [] : preStr.split(separator: ".").map(String.init)
        return (core, pre)
    }

    private static func comparePrerelease(_ a: [String], _ b: [String]) -> ComparisonResult {
        let count = max(a.count, b.count)
        for i in 0..<count {
            // 段数多者更大（前缀相同时 1.0.0-alpha < 1.0.0-alpha.1）
            if i >= a.count { return .orderedAscending }
            if i >= b.count { return .orderedDescending }
            let x = a[i], y = b[i]
            let nx = Int(x), ny = Int(y)
            switch (nx, ny) {
            case let (.some(ix), .some(iy)):
                if ix != iy { return ix < iy ? .orderedAscending : .orderedDescending }
            case (.some, .none): return .orderedAscending    // 数字段 < 字母段
            case (.none, .some): return .orderedDescending
            case (.none, .none):
                if x != y { return x < y ? .orderedAscending : .orderedDescending }
            }
        }
        return .orderedSame
    }
}

// MARK: - 纯逻辑：GitHub Releases JSON 解析（可黑盒单测）

/// 从 GitHub Releases API 的 latest JSON 解析出（tag_name, body, 首个 .zip 资产地址）。
/// 结构缺失/无 .zip 资产 → 返回 nil（调用方据此归类）。纯函数，不触网。
public func parseLatestRelease(_ data: Data) -> (tag: String, notes: String, zipURL: URL)? {
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    guard let tag = obj["tag_name"] as? String, !tag.isEmpty else { return nil }
    let notes = (obj["body"] as? String) ?? ""
    guard let assets = obj["assets"] as? [[String: Any]] else { return nil }
    for asset in assets {
        guard let name = asset["name"] as? String, name.lowercased().hasSuffix(".zip"),
              let urlStr = asset["browser_download_url"] as? String,
              let url = URL(string: urlStr) else { continue }
        return (tag, notes, url)
    }
    return nil
}

/// 组合纯逻辑：给定 latest JSON 与当前版本，判定是否有严格更新（有→UpdateInfo，无/不可解析→nil）。
/// 网络与 HTTP 状态归类由 actor 层负责，此处只做"数据→结论"的确定性映射（便于单测）。
public func evaluateLatest(_ data: Data, currentVersion: String) -> UpdateInfo? {
    guard let parsed = parseLatestRelease(data) else { return nil }
    let normalized = SemVer.normalize(parsed.tag)
    guard SemVer.isNewer(normalized, than: SemVer.normalize(currentVersion)) else { return nil }
    return UpdateInfo(version: normalized, rawTag: parsed.tag,
                      downloadURL: parsed.zipURL, releaseNotes: parsed.notes)
}

import Foundation
import NSpaceContracts

// 私有关注点：读取 .app bundle 的身份（bundle id + 短版本号），用于 downloadAndStage 的搬入前校验。
// 直接解析 Contents/Info.plist（不依赖 Bundle/NSBundle 缓存，避免同 id 已加载时读到宿主自身）。

extension UpdateEngine {
    struct BundleIdentity {
        let bundleID: String
        let shortVersion: String
    }

    /// 读 <app>/Contents/Info.plist 的 CFBundleIdentifier 与 CFBundleShortVersionString。
    /// 缺失/不可解析抛 .external。
    func readBundleIdentity(_ app: URL) throws -> BundleIdentity {
        let plistURL = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL) else {
            throw UpdateError(.external, "更新包缺少 Info.plist")
        }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
            as? [String: Any] else {
            throw UpdateError(.external, "更新包 Info.plist 不可解析")
        }
        let id = (plist["CFBundleIdentifier"] as? String) ?? ""
        let ver = (plist["CFBundleShortVersionString"] as? String) ?? ""
        guard !id.isEmpty else { throw UpdateError(.external, "更新包缺少 CFBundleIdentifier") }
        return BundleIdentity(bundleID: id, shortVersion: SemVer.normalize(ver))
    }
}

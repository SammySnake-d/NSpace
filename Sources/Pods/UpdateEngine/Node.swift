import Foundation
import NSpaceContracts

/// 版本热更新节点（check / downloadAndStage / install）。构造零参（Axiom 2：无全局可变状态，
/// feedURL/currentVersion/目标路径全部经方法参数注入）。可注入 URLSession 便于测试替身。
public actor UpdateEngine {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: check —— 只读探测（无副作用）

    /// 探测 feed（GitHub Releases latest API）：解析最新 tag 与当前版本比较。
    /// 有严格更新 → UpdateInfo；无更新/无 .zip 资产 → nil；404/断网/非 2xx → 抛 .external。
    public func check(feedURL: URL, currentVersion: String) async throws -> UpdateInfo? {
        var request = URLRequest(url: feedURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("NSpace-Updater", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UpdateError(.external, "检查更新失败：\(error.localizedDescription)")
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw UpdateError(.external, "检查更新失败：服务器返回 \(http.statusCode)")
        }
        return evaluateLatest(data, currentVersion: currentVersion)
    }

    // MARK: downloadAndStage —— 下载 + 解压 + 校验（暂存目录，失败即弃）

    /// 下载 info.downloadURL 的 zip → ditto -xk 解压到暂存目录 → 定位解出的 .app →
    /// 校验 bundle id == com.nspace.NSpace 且 CFBundleShortVersionString == info.version →
    /// 返回该 .app 路径。任何一步失败抛 .external（暂存目录随进程退出/下次清理，不留半成品于目标位）。
    public func downloadAndStage(info: UpdateInfo) async throws -> URL {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory
            .appendingPathComponent("nspace-update-\(UUID().uuidString)", isDirectory: true)
        try makeDir(staging)

        // 1) 下载 zip 到暂存目录
        let zipURL = staging.appendingPathComponent("update.zip")
        do {
            let (tmp, response) = try await session.download(from: info.downloadURL)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw UpdateError(.external, "下载更新失败：服务器返回 \(http.statusCode)")
            }
            try? fm.removeItem(at: zipURL)
            try fm.moveItem(at: tmp, to: zipURL)
        } catch let e as UpdateError {
            throw e
        } catch {
            throw UpdateError(.external, "下载更新失败：\(error.localizedDescription)")
        }

        // 2) ditto -xk 解压到 staging/unpacked
        let unpacked = staging.appendingPathComponent("unpacked", isDirectory: true)
        try makeDir(unpacked)
        try await ditto(unzip: zipURL, into: unpacked)

        // 3) 定位解出的 .app（顶层优先，退而递归找首个）
        guard let app = try locateApp(in: unpacked) else {
            throw UpdateError(.external, "更新包内未找到 .app")
        }

        // 4) 校验 bundle id 与版本号（防搬错包）
        let info2 = try readBundleIdentity(app)
        guard info2.bundleID == kNSpaceBundleID else {
            throw UpdateError(.external, "更新包 bundle 标识不符：\(info2.bundleID)")
        }
        guard info2.shortVersion == info.version else {
            throw UpdateError(.external, "更新包版本不符：期望 \(info.version) 实得 \(info2.shortVersion)")
        }
        return app
    }

    // MARK: install —— 原子替换（唯一破坏性提交，失败回滚）

    /// 原子替换：旧 .app 改名到临时备份 → 新 .app 搬入原位 → 成功删备份；
    /// 搬入失败则把备份改名回原位（回滚）。返回后由 App 层提示重启。
    /// 校验：current 必须是现存 .app；staged 必须是现存 .app 且非同一路径。
    public func install(staged: URL, into current: URL) async throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: staged.path, isDirectory: &isDir), isDir.boolValue else {
            throw UpdateError(.logic, "暂存 .app 不存在：\(staged.lastPathComponent)")
        }
        guard fm.fileExists(atPath: current.path, isDirectory: &isDir), isDir.boolValue else {
            throw UpdateError(.logic, "目标 .app 不存在：\(current.lastPathComponent)")
        }
        guard staged.standardizedFileURL != current.standardizedFileURL else {
            throw UpdateError(.logic, "暂存与目标为同一路径")
        }

        let backup = current.deletingLastPathComponent()
            .appendingPathComponent(".\(current.lastPathComponent).bak-\(UUID().uuidString)")

        // 1) 旧 → 备份（同目录 rename，原子）
        do {
            try fm.moveItem(at: current, to: backup)
        } catch {
            throw UpdateError(.external, "无法备份旧版本：\(error.localizedDescription)")
        }

        // 2) 新 → 原位
        do {
            try fm.moveItem(at: staged, to: current)
        } catch {
            // 回滚：备份改名回原位
            try? fm.moveItem(at: backup, to: current)
            throw UpdateError(.external, "无法安装新版本（已回滚）：\(error.localizedDescription)")
        }

        // 3) 成功：删备份（失败不影响安装结果，静默）
        try? fm.removeItem(at: backup)
    }

    // MARK: 私有工具

    private func makeDir(_ url: URL) throws {
        do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        catch { throw UpdateError(.external, "无法创建暂存目录：\(url.lastPathComponent)") }
    }

    /// 定位目录内的 .app：先看顶层，再退而递归找首个。
    private func locateApp(in dir: URL) throws -> URL? {
        let fm = FileManager.default
        let top = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil,
                                               options: [.skipsHiddenFiles])) ?? []
        if let app = top.first(where: { $0.pathExtension == "app" }) { return app }
        if let e = fm.enumerator(at: dir, includingPropertiesForKeys: nil,
                                 options: [.skipsHiddenFiles]) {
            for case let f as URL in e where f.pathExtension == "app" { return f }
        }
        return nil
    }
}

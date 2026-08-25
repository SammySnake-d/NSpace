import Testing
import Foundation
import UpdateEngine
import NSpaceContracts

/// 黑盒验收：只经 Contract 公开面。语义化版本比较 + GitHub JSON 解析走纯函数；
/// install 原子性于临时目录假 bundle 实测（无网络）。check/downloadAndStage 的网络与 ditto
/// 依赖外部资源（feed 尚未发布），此处不真跑，用纯逻辑 + 文件替换覆盖关键不变量。
@Suite struct UpdateEngineTests {

    // MARK: 语义化版本比较表（Oracle：无需网络/文件系统）

    @Test func semverComparisonTable() {
        // (a, b, 期望 a 相对 b)
        let cases: [(String, String, ComparisonResult)] = [
            ("1.0.0", "1.0.1", .orderedAscending),
            ("1.0.1", "1.0.0", .orderedDescending),
            ("1.0.0", "1.0.0", .orderedSame),
            ("2.0.0", "1.9.9", .orderedDescending),
            ("1.10.0", "1.9.0", .orderedDescending),     // 数值比较非字典序（10 > 9）
            ("1.2", "1.2.0", .orderedSame),              // 缺段补 0
            ("1.2.0", "1.2", .orderedSame),
            ("v0.9.4", "0.9.3", .orderedDescending),     // 去前导 v
            ("V1.0.0", "v1.0.0", .orderedSame),
            (" 1.0.0 ", "1.0.0", .orderedSame),          // 去空白
            ("1.0.0-alpha", "1.0.0", .orderedAscending), // 预发布 < 正式
            ("1.0.0", "1.0.0-beta", .orderedDescending),
            ("1.0.0-alpha", "1.0.0-alpha.1", .orderedAscending), // 段数多者更大
            ("1.0.0-alpha.1", "1.0.0-alpha.beta", .orderedAscending), // 数字段 < 字母段
            ("1.0.0-beta.2", "1.0.0-beta.11", .orderedAscending),     // 预发布数字段按数值
            ("1.0.0+build.5", "1.0.0+build.9", .orderedSame),         // 构建元数据不参与
        ]
        for (a, b, expected) in cases {
            #expect(SemVer.compare(a, b) == expected, "compare(\(a), \(b))")
        }
    }

    @Test func isNewerStrictlyGreater() {
        #expect(SemVer.isNewer("0.9.4", than: "0.9.3"))
        #expect(!SemVer.isNewer("0.9.3", than: "0.9.3"))
        #expect(!SemVer.isNewer("0.9.2", than: "0.9.3"))
        #expect(SemVer.isNewer("v1.0.0", than: "0.9.9"))
    }

    @Test func normalizeStripsPrefixAndWhitespace() {
        #expect(SemVer.normalize("  v1.2.3 ") == "1.2.3")
        #expect(SemVer.normalize("V0.0.1") == "0.0.1")
        #expect(SemVer.normalize("1.2.3") == "1.2.3")
    }

    // MARK: GitHub Releases JSON 解析（mock JSON）

    static func releaseJSON(tag: String, body: String, assetNames: [String],
                            urlBase: String = "https://example.com/dl") -> Data {
        let assets = assetNames.map {
            "{\"name\":\"\($0)\",\"browser_download_url\":\"\(urlBase)/\($0)\"}"
        }.joined(separator: ",")
        let json = "{\"tag_name\":\"\(tag)\",\"body\":\"\(body)\",\"assets\":[\(assets)]}"
        return Data(json.utf8)
    }

    @Test func parseLatestPicksZipAsset() {
        let data = Self.releaseJSON(tag: "v0.9.4", body: "修复若干",
                                    assetNames: ["NSpace.dmg", "NSpace.zip", "src.tar.gz"])
        let parsed = parseLatestRelease(data)
        #expect(parsed?.tag == "v0.9.4")
        #expect(parsed?.notes == "修复若干")
        #expect(parsed?.zipURL.absoluteString == "https://example.com/dl/NSpace.zip")
    }

    @Test func parseLatestNilWhenNoZip() {
        let data = Self.releaseJSON(tag: "v0.9.4", body: "", assetNames: ["NSpace.dmg"])
        #expect(parseLatestRelease(data) == nil)
    }

    @Test func parseLatestNilWhenMalformed() {
        #expect(parseLatestRelease(Data("not json".utf8)) == nil)
        #expect(parseLatestRelease(Data("{}".utf8)) == nil)   // 缺 tag_name/assets
    }

    @Test func evaluateReturnsInfoOnlyWhenNewer() {
        let data = Self.releaseJSON(tag: "v0.9.4", body: "note", assetNames: ["NSpace.zip"])
        // 当前 0.9.3 → 有更新
        let info = evaluateLatest(data, currentVersion: "0.9.3")
        #expect(info?.version == "0.9.4")
        #expect(info?.rawTag == "v0.9.4")
        #expect(info?.releaseNotes == "note")
        // 当前已是 0.9.4 → 无更新
        #expect(evaluateLatest(data, currentVersion: "0.9.4") == nil)
        // 当前更高 → 无更新
        #expect(evaluateLatest(data, currentVersion: "1.0.0") == nil)
    }

    // MARK: install 原子替换（临时目录假 bundle，无网络）

    static func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nspace-up-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 造一个最小假 .app（Contents/MacOS/<exe> 内写入 marker 文本，用于验证替换真实生效）。
    static func makeFakeApp(_ url: URL, marker: String) throws {
        let fm = FileManager.default
        let macos = url.appendingPathComponent("Contents/MacOS")
        try fm.createDirectory(at: macos, withIntermediateDirectories: true)
        try Data(marker.utf8).write(to: macos.appendingPathComponent("NSpace"))
    }

    static func marker(of app: URL) -> String? {
        let exe = app.appendingPathComponent("Contents/MacOS/NSpace")
        return (try? Data(contentsOf: exe)).map { String(decoding: $0, as: UTF8.self) }
    }

    @Test func installReplacesInPlace() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let current = dir.appendingPathComponent("NSpace.app")
        let staged = dir.appendingPathComponent("staged/NSpace.app")
        try Self.makeFakeApp(current, marker: "OLD")
        try Self.makeFakeApp(staged, marker: "NEW")

        try await UpdateEngine().install(staged: staged, into: current)

        // 原位内容已是新版本，暂存不再存在
        #expect(Self.marker(of: current) == "NEW")
        #expect(!FileManager.default.fileExists(atPath: staged.path))
        // 备份已清（目录内除 current 外无 .bak 残留）
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        #expect(!leftovers.contains { $0.hasPrefix(".NSpace.app.bak") })
    }

    @Test func installRejectsMissingStaged() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let current = dir.appendingPathComponent("NSpace.app")
        let staged = dir.appendingPathComponent("nope.app")
        try Self.makeFakeApp(current, marker: "OLD")

        await #expect(throws: UpdateError.self) {
            try await UpdateEngine().install(staged: staged, into: current)
        }
        // 目标未被破坏
        #expect(Self.marker(of: current) == "OLD")
    }

    @Test func installRejectsMissingCurrent() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let current = dir.appendingPathComponent("NSpace.app")   // 不存在
        let staged = dir.appendingPathComponent("staged/NSpace.app")
        try Self.makeFakeApp(staged, marker: "NEW")

        await #expect(throws: UpdateError.self) {
            try await UpdateEngine().install(staged: staged, into: current)
        }
    }

    @Test func installRejectsSamePath() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = dir.appendingPathComponent("NSpace.app")
        try Self.makeFakeApp(app, marker: "X")
        await #expect(throws: UpdateError.self) {
            try await UpdateEngine().install(staged: app, into: app)
        }
    }
}

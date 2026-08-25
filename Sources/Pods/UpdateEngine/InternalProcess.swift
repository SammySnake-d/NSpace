import Foundation
import NSpaceContracts

// 私有关注点：Process 物理驱动 —— /usr/bin/ditto -xk 解压 zip。
// Process 阻塞，故用 terminationHandler + CheckedContinuation 非阻塞化（同 ArchiveEngine 精神）。

extension UpdateEngine {
    static let dittoPath = "/usr/bin/ditto"

    /// ditto -xk <zip> <destDir>：解压 macOS zip（保 xattr/资源分叉，优于 unzip）。
    /// 退码非 0 抛 .external（携 stderr 摘要）；工具缺失抛 .external。
    func ditto(unzip zip: URL, into dest: URL) async throws {
        let tool = Self.dittoPath
        guard FileManager.default.isExecutableFile(atPath: tool) else {
            throw UpdateError(.external, "系统工具缺失：\(tool)")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = ["-x", "-k", zip.path, dest.path]
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let result: (status: Int32, stderr: String) = try await withCheckedThrowingContinuation { cont in
            process.terminationHandler = { proc in
                let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
                cont.resume(returning: (proc.terminationStatus, String(decoding: errData, as: UTF8.self)))
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                cont.resume(throwing: UpdateError(.external,
                    "无法启动 ditto：\(error.localizedDescription)"))
            }
        }
        if result.status != 0 {
            let tail = Self.stderrSummary(result.stderr)
            throw UpdateError(.external, "解压更新包失败：\(tail.isEmpty ? "退出码 \(result.status)" : tail)")
        }
    }

    /// stderr 摘要（首个非空行，截断）。
    static func stderrSummary(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        let s = String(line ?? "").trimmingCharacters(in: .whitespaces)
        return s.count > 200 ? String(s.prefix(200)) + "…" : s
    }
}

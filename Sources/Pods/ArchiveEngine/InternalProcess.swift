import Foundation
import NSpaceContracts

// 私有关注点：Process 物理驱动 —— 启动系统工具、捕获 stderr、协作式取消（terminate）。
// Process.run()/waitUntilExit() 阻塞，故用 terminationHandler + CheckedContinuation 非阻塞化，
// 不占用 Swift 并发协作线程池（同 Transfer 的 ioQueue 精神）。

struct ProcessResult {
    let status: Int32
    let stderr: String
}

extension ArchiveEngineNode {

    /// 运行一个系统工具直至退出；支持取消（外层 Task 取消 → SIGTERM 子进程）。
    /// - stdoutTo: 若提供，子进程 stdout 写入该文件句柄（gunzip -c 重定向解压产物用）。
    /// 返回退出码与 stderr 文本；启动失败（工具缺失/无权限）抛 external。
    func runTool(_ toolPath: String, _ arguments: [String], cwd: URL? = nil,
                 stdoutTo: FileHandle? = nil) async throws -> ProcessResult {
        guard FileManager.default.isExecutableFile(atPath: toolPath) else {
            throw ArchiveError(.external, "系统工具缺失: \(toolPath)", path: toolPath)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: toolPath)
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = cwd }
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = stdoutTo ?? FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ProcessResult, any Error>) in
                process.terminationHandler = { proc in
                    let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
                    let text = String(decoding: errData, as: UTF8.self)
                    cont.resume(returning: ProcessResult(status: proc.terminationStatus, stderr: text))
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    cont.resume(throwing: ArchiveError(.external,
                        "无法启动工具 \(toolPath): \(error.localizedDescription)", path: toolPath))
                }
            }
        } onCancel: {
            // 协作式取消：SIGTERM 子进程；terminationHandler 仍会触发让 continuation 落地，
            // 调用方随后查 Task.isCancelled → 清理半成品并抛 CancellationError。
            if process.isRunning { process.terminate() }
        }
    }

    /// 运行并把工具 stdout 收集为文本（列出归档条目用：unzip -Z1 / tar -tf）
    func runToolCapturingStdout(_ toolPath: String, _ arguments: [String]) async throws -> (result: ProcessResult, stdout: String) {
        guard FileManager.default.isExecutableFile(atPath: toolPath) else {
            throw ArchiveError(.external, "系统工具缺失: \(toolPath)", path: toolPath)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: toolPath)
        process.arguments = arguments
        let outPipe = Pipe(); let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(ProcessResult, String), any Error>) in
                process.terminationHandler = { proc in
                    let outData = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
                    let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
                    let outText = String(decoding: outData, as: UTF8.self)
                    let errText = String(decoding: errData, as: UTF8.self)
                    cont.resume(returning: (ProcessResult(status: proc.terminationStatus, stderr: errText), outText))
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    cont.resume(throwing: ArchiveError(.external,
                        "无法启动工具 \(toolPath): \(error.localizedDescription)", path: toolPath))
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    /// stderr 摘要（取非空首行，截断，供 external 错误携带）
    static func stderrSummary(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        let s = String(line ?? "").trimmingCharacters(in: .whitespaces)
        return s.count > 200 ? String(s.prefix(200)) + "…" : s
    }
}

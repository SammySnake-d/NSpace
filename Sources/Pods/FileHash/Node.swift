import CryptoKit
import Foundation
import NSpaceContracts

/// 流式文件校验和计算：单遍 I/O 同步累加 MD5 与 SHA-256，支持协作取消
public enum FileHasher: FileHashService {
    public static func computeDigests(for url: URL, chunkSize: Int = 1_048_576) async throws -> FileDigestResult {
        var st = stat()
        guard lstat(url.path, &st) == 0 else {
            throw FileHashError(.external, "文件不存在: \(url.lastPathComponent)", path: url.path)
        }
        let isDirectory = (st.st_mode & S_IFMT) == S_IFDIR
        if isDirectory {
            throw FileHashError(.logic, "无法对文件夹计算校验和", path: url.path)
        }

        let resolvedChunk = max(4096, chunkSize)
        return try await Task.detached(priority: .utility) {
            let handle: FileHandle
            do {
                handle = try FileHandle(forReadingFrom: url)
            } catch {
                throw FileHashError(.external, "读取失败: \(error.localizedDescription)", path: url.path)
            }
            defer { try? handle.close() }

            var md5 = Insecure.MD5()
            var sha256 = SHA256()
            var totalBytes: Int64 = 0

            while true {
                try Task.checkCancellation()
                let chunk: Data?
                do {
                    chunk = try handle.read(upToCount: resolvedChunk)
                } catch {
                    throw FileHashError(.external, "读取中断: \(error.localizedDescription)", path: url.path)
                }
                guard let chunk, !chunk.isEmpty else { break }
                totalBytes += Int64(chunk.count)
                md5.update(data: chunk)
                sha256.update(data: chunk)
            }

            let md5Hex = md5.finalize().map { String(format: "%02x", $0) }.joined()
            let shaHex = sha256.finalize().map { String(format: "%02x", $0) }.joined()
            return FileDigestResult(md5: md5Hex, sha256: shaHex, byteCount: totalBytes)
        }.value
    }
}

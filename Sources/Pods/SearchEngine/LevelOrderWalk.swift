import Foundation

/// 层序（BFS）目录遍历节点：产出的深度单调不减——浅层条目一定先被看到。
///
/// 为什么不用 `FileManager.enumerator`（它是惰性前序 DFS）：DFS 拿到一个 depth-1 条目后
/// 会把它整棵子树走完才回到下一个 depth-1 兄弟。真机实测（root=~，198.6 万项）：
///   `~/.claude`      DFS 15.5s 才被枚举到（第 75 万项）  / BFS 0.006s（第 104 项）
///   `~/.claude.json` DFS 34.2s（第 163 万项）            / BFS 0.006s（第 214 项）
/// 这就是"能看到却搜不到"的一半根因——不是命中被压住，是压根还没被发现。
/// 全树总成本 BFS 43.6s vs DFS 42.4s（+2.8%），峰值待处理目录 28410 个（≈2.2MB），都有界。
/// 同时这个口径天然吻合产品既有契约「局部搜索按离根近者优先」（I-40）。
///
/// 符号链接：不下钻。URL 资源值对指向目录的 symlink 返回 `isDirectory == false`
/// （实测），故 `isDir` 判据本身就不会把它排进队列——与 enumerator 语义一致，无需额外读 key。
enum LevelOrderWalk {
    /// 逐项回调；`visit` 在「是否下钻」之前调用，所以巨坑目录**本身**仍可被匹配到
    /// （旧 DFS 版在 skip 分支里先 `continue`，导致搜 "Library"/"node_modules" 永远搜不到那个目录本身）。
    /// - Parameters:
    ///   - skipDirectoryNames: 命中此名的目录不下钻（仍参与匹配）
    ///   - shouldContinue: 返回 false 立即停止（协作式取消）
    static func walk(root: URL,
                     skipDirectoryNames: Set<String>,
                     shouldContinue: () -> Bool,
                     visit: (_ url: URL, _ depth: Int, _ isDirectory: Bool) -> Void) {
        let fm = FileManager.default
        var frontier: [URL] = [root]
        var depth = 0
        while !frontier.isEmpty, shouldContinue() {
            depth += 1
            var next: [URL] = []
            for dir in frontier {
                guard shouldContinue() else { return }
                // 每个目录一个 autoreleasepool——**不是可选的**。
                // contentsOfDirectory / resourceValues 产生大量自动释放对象，而扫描跑在
                // Task.detached 里，没有 RunLoop 帮它排水，于是一路堆到扫完。
                // 真机实测（root=~，194 万项）峰值 RSS：
                //   旧 DFS enumerator 512MB ／ 无 pool 的 BFS 1219MB ／ 带 pool 的 BFS 51MB
                // 代价 +3% 时长（42.6s → 44.0s）。frontier 数组本身只占 ~2MB，不是大头。
                autoreleasepool {
                    let kids = (try? fm.contentsOfDirectory(
                        at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? []
                    for url in kids {
                        // 逐项查取消：旧 DFS 是每项查一次，改 BFS 后若只在目录粒度查，
                        // 用户多敲一个字符时上一轮搜索还会把当前目录的孩子列表烧完才停。
                        guard shouldContinue() else { return }
                        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                        visit(url, depth, isDir)
                        if isDir, !skipDirectoryNames.contains(url.lastPathComponent) {
                            next.append(url)
                        }
                    }
                }
            }
            frontier = next
        }
    }
}

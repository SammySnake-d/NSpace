import Foundation

/// 废纸篓位置的唯一口径（用户报告「nspace 缺少废纸篓功能」）。
///
/// 单独成节点而不是散在各调用点写 `.appendingPathComponent(".Trash")`：
/// 甲板钮、Go 菜单、窗格动作、自测四处都要问同一个问题，散着写就会各自漂。
/// 只读路径推导，不含任何写型 API（BG-1）。
enum TrashLocation {
    /// 当前用户的废纸篓（`~/.Trash`）。
    /// 注：`~/.Trash` 自身带 hidden 标志，但 DirectoryReader 的 `.skipsHiddenFiles`
    /// 过滤的是**被列出的条目**、不是被列举的那个目录，所以不开"显示隐藏文件"也能正常浏览
    /// （实测 15/17 项）。
    static var userTrash: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true)
    }

    /// 某个位置**对应的**废纸篓。
    /// 旧版只有 userTrash：在外置盘上浏览时，垃圾桶钮「打开废纸篓」会跳回启动盘的
    /// `~/.Trash`，而拖进去的文件被 `fm.trashItem` 放进了**该卷**的 `.Trashes/<uid>`
    /// ——按钮说的和做的不是同一个地方。只做只读路径推导，不创建任何目录（BG-1）。
    static func trash(for url: URL) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let vol = (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume,
              let homeVol = (try? home.resourceValues(forKeys: [.volumeURLKey]))?.volume,
              vol.standardizedFileURL.path != homeVol.standardizedFileURL.path
        else { return userTrash }
        let perVolume = vol.appendingPathComponent(".Trashes", isDirectory: true)
            .appendingPathComponent(String(getuid()), isDirectory: true)
        // 该卷没有（或不可读）per-user 回收站时回落到用户废纸篓——诚实退化，不假装
        return FileManager.default.fileExists(atPath: perVolume.path) ? perVolume : userTrash
    }

    /// 该 URL 是否就是废纸篓本身（只认用户废纸篓）
    static func isTrash(_ url: URL) -> Bool {
        url.standardizedFileURL.path == userTrash.standardizedFileURL.path
    }

    /// 该 URL 是否是**某个**废纸篓的根（用户废纸篓 或 该卷的 per-user 回收站）。
    /// 「清倒」按钮只在根上出现——同 Finder：进到废纸篓里的子文件夹时不显示，
    /// 那里点「清倒」会让人以为只清这一层。
    static func isTrashRoot(_ url: URL) -> Bool {
        let p = url.standardizedFileURL.path
        return p == userTrash.standardizedFileURL.path
            || p == trash(for: url).standardizedFileURL.path
    }

    /// 该 URL 是否**位于废纸篓之内**（含任意深度的子层级）。
    /// 只判"父目录是不是废纸篓"是不够的：`~/.Trash/某文件夹/文件` 会绕过守卫，
    /// 而 trashItem 对它是把它从子层级悄悄提到废纸篓根下——用户看到文件"自己动了"。
    static func isInsideTrash(_ url: URL) -> Bool {
        let p = url.standardizedFileURL.path
        // 用户废纸篓 + 该 URL 所在卷的 per-user 回收站，两处都算
        for root in Set([userTrash.standardizedFileURL.path,
                         trash(for: url).standardizedFileURL.path]) {
            if p == root || p.hasPrefix(root.hasSuffix("/") ? root : root + "/") { return true }
        }
        return false
    }
}

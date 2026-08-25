import Foundation

/// App 层集中偏好（外部化配置唯一入口——不散落硬编码；胶囊层禁用本类型，经构造注入）。
/// 全部键在此登记，设置窗按此渲染；新增可配置项 = 加一个静态属性。
@MainActor
enum Preferences {
    private static let d = UserDefaults.standard

    /// 新窗口/新工作区标签的默认布局（用户点名：单栏还是双栏要可配）
    static var defaultLayoutRaw: Int {
        get { d.object(forKey: "defaultLayout") as? Int ?? 1 }  // 1 = 单窗格
        set { d.set(newValue, forKey: "defaultLayout") }
    }

    /// 新标签页的默认视图模式（icons=0/list=1/columns=2）
    static var defaultViewModeRaw: Int {
        get { d.object(forKey: "defaultViewMode") as? Int ?? 1 }  // list
        set { d.set(newValue, forKey: "defaultViewMode") }
    }

    /// 新标签默认显示隐藏文件
    static var showHiddenByDefault: Bool {
        get { d.bool(forKey: "showHiddenByDefault") }
        set { d.set(newValue, forKey: "showHiddenByDefault") }
    }

    /// 排序时文件夹置顶
    static var foldersFirst: Bool {
        get { d.object(forKey: "foldersFirst") as? Bool ?? true }
        set { d.set(newValue, forKey: "foldersFirst") }
    }

    /// 默认终端（"auto"=iTerm 优先回退 Terminal）
    static var terminalChoice: String {
        get { d.string(forKey: "terminalChoice") ?? "auto" }
        set { d.set(newValue, forKey: "terminalChoice") }
    }

    /// 可选列显隐（名称恒在）；QSpace 式列头右键勾选
    static var visibleColumns: [String] {
        get { d.stringArray(forKey: "visibleColumns") ?? ["dateModified", "size", "kind"] }
        set { d.set(newValue, forKey: "visibleColumns") }
    }

    /// 侧栏分组顺序（QSpace 语义——用户点名：书签可拖到最前）。
    /// outline 分组键：bookmarks/icloud/volumes（暂存架在专区不入 outline）；拖动分组标题行重排落盘于此。
    static var sidebarGroupOrder: [String] {
        get { d.stringArray(forKey: "sidebarGroupOrder") ?? ["bookmarks", "icloud", "volumes"] }
        set { d.set(newValue, forKey: "sidebarGroupOrder") }
    }

    // MARK: 归档默认值（ArchiveEngine 能力；FileOpsCoordinator 据此构造 ArchiveOptions）

    /// 压缩默认格式："zip" / "tar.gz"
    static var archiveFormat: String {
        get { d.string(forKey: "archiveFormat") ?? "zip" }
        set { d.set(newValue, forKey: "archiveFormat") }
    }

    /// 压缩后保留原文件（false = 打包成功后把原文件移到废纸篓）
    static var archiveKeepOriginal: Bool {
        get { d.object(forKey: "archiveKeepOriginal") as? Bool ?? true }
        set { d.set(newValue, forKey: "archiveKeepOriginal") }
    }

    /// 解压确保创建包裹文件夹（顶层多于一个条目时先建同名文件夹；只有一个条目则忽略）
    static var extractCreateWrapper: Bool {
        get { d.object(forKey: "extractCreateWrapper") as? Bool ?? true }
        set { d.set(newValue, forKey: "extractCreateWrapper") }
    }

    /// 解压后保留压缩包（false = 解压成功后把压缩包移到废纸篓）
    static var extractKeepArchive: Bool {
        get { d.object(forKey: "extractKeepArchive") as? Bool ?? true }
        set { d.set(newValue, forKey: "extractKeepArchive") }
    }

    /// 归档格式候选（popup 渲染用）
    static let archiveFormatOptions: [(id: String, nameKey: String)] = [
        ("zip", "settings.archiveFormat.zip"),
        ("tar.gz", "settings.archiveFormat.targz"),
    ]
    // MARK: 使用习惯（QSpace 对齐子集）

    /// Enter 键行为："rename"（默认，行内重命名）/"open"（打开选中项）
    static var enterAction: String {
        get { d.string(forKey: "enterAction") ?? "rename" }
        set { d.set(newValue, forKey: "enterAction") }
    }

    /// Backspace 键行为："ignore"（默认）/"back"（返回上一步）/"delete"（移到废纸篓）/"up"（上层文件夹）
    static var backspaceAction: String {
        get { d.string(forKey: "backspaceAction") ?? "ignore" }
        set { d.set(newValue, forKey: "backspaceAction") }
    }

    /// 拖放行为："auto"（默认，同卷移动跨卷复制）/"copy"（恒复制）/"move"（同卷恒移动跨卷仍复制）
    static var dragBehavior: String {
        get { d.string(forKey: "dragBehavior") ?? "auto" }
        set { d.set(newValue, forKey: "dragBehavior") }
    }

    /// 双击列表空白处前往上层文件夹（默认 false）
    static var doubleClickBlank: Bool {
        get { d.bool(forKey: "doubleClickBlank") }
        set { d.set(newValue, forKey: "doubleClickBlank") }
    }

    /// 新标签默认排序键（name/dateModified/size/kind；只对新标签生效）
    static var defaultSortKey: String {
        get { d.string(forKey: "defaultSortKey") ?? "name" }
        set { d.set(newValue, forKey: "defaultSortKey") }
    }

    /// 新标签默认升序（默认 true）
    static var defaultSortAscending: Bool {
        get { d.object(forKey: "defaultSortAscending") as? Bool ?? true }
        set { d.set(newValue, forKey: "defaultSortAscending") }
    }

    /// 窗格标签上限（0=不限制；>0 时新建标签超限覆盖最老——移除 index 0 再追加，QSpace 语义）
    static var paneTabLimit: Int {
        get { d.integer(forKey: "paneTabLimit") }  // 未设=0=不限制
        set { d.set(newValue, forKey: "paneTabLimit") }
    }

    /// 外部 open-URL 打开目录的落点："newTab"（默认，现行为=开新窗/工作区标签）/
    /// "activePane"（已有窗口时在活动窗格新建窗格标签定位，不每次开新窗）
    static var externalOpenTarget: String {
        get { d.string(forKey: "externalOpenTarget") ?? "newTab" }
        set { d.set(newValue, forKey: "externalOpenTarget") }
    }

    /// 完全磁盘访问自动提示"不再提示"标记（默认 false=未勾掉，未授权时启动会提示一次）
    static var fdaPromptDismissed: Bool {
        get { d.bool(forKey: "fdaPromptDismissed") }
        set { d.set(newValue, forKey: "fdaPromptDismissed") }
    }

    /// 终端候选（bundle id；auto 特殊值）
    static let terminalOptions: [(id: String, nameKey: String)] = [
        ("auto", "settings.terminal.auto"),
        ("com.googlecode.iterm2", "settings.terminal.iterm"),
        ("com.apple.Terminal", "settings.terminal.terminal"),
        ("dev.warp.Warp-Stable", "settings.terminal.warp"),
        ("net.kovidgoyal.kitty", "settings.terminal.kitty"),
    ]
}

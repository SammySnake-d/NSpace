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

    /// 终端候选（bundle id；auto 特殊值）
    static let terminalOptions: [(id: String, nameKey: String)] = [
        ("auto", "settings.terminal.auto"),
        ("com.googlecode.iterm2", "settings.terminal.iterm"),
        ("com.apple.Terminal", "settings.terminal.terminal"),
        ("dev.warp.Warp-Stable", "settings.terminal.warp"),
        ("net.kovidgoyal.kitty", "settings.terminal.kitty"),
    ]
}

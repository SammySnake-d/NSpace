import AppKit

/// 外观主题小工具（App 层）：强调色与明暗模式的唯一读取点。
/// 读 Preferences（外部化配置），nil/非法值回退系统默认；设置变更后经 broadcastChanged 即时刷新。
@MainActor
enum Theme {
    /// 候选强调色板（8 色，RRGGBB）；另有"系统"项（accentColorHex=nil）走 controlAccentColor。
    /// 取自 macOS 系统强调色近似值，稳定不随系统语言变化。
    static let accentPalette: [(hex: String, nameKey: String)] = [
        ("FF3B30", "accent.red"),
        ("FF9500", "accent.orange"),
        ("FFCC00", "accent.yellow"),
        ("28CD41", "accent.green"),
        ("007AFF", "accent.blue"),
        ("5E5CE6", "accent.indigo"),
        ("AF52DE", "accent.purple"),
        ("FF2D55", "accent.pink"),
    ]

    /// 当前强调色：偏好 hex → NSColor；nil 或解析失败回退系统 controlAccentColor。
    static var accent: NSColor {
        guard let hex = Preferences.accentColorHex, let color = NSColor(hex: hex) else {
            return .controlAccentColor
        }
        return color
    }

    /// 应用明暗模式到 NSApp（启动 + 设置变更）：nil=跟随系统 / aqua=浅色 / darkAqua=深色
    static func applyAppearance() {
        switch Preferences.appearanceMode {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    /// 主题变更广播（设置页任一外观项改动后调用）：
    /// 先套明暗模式，再发通知，最后遍历所有窗口令各窗格重刷描色/暗化——即时生效。
    static func broadcastChanged() {
        applyAppearance()
        NotificationCenter.default.post(name: .nspaceThemeChanged, object: nil)
        for case let wc as MainWindowController in NSApp.windows.compactMap(\.windowController) {
            wc.grid.refreshTheme()
        }
    }
}

extension Notification.Name {
    /// 外观变更广播（强调色/明暗/高亮/暗化）——窗格描色与内容暗化据此重刷
    static let nspaceThemeChanged = Notification.Name("nspaceThemeChanged")
}

extension NSImage {
    /// 官方 SF Symbol 取像（§6.1：一律官方原版，禁自绘 path / 禁 emoji 文字充当图标）；
    /// 系统无此符号时回退到 fallback。
    static func officialSymbol(_ name: String, fallback: String? = nil,
                              accessibility: String? = nil) -> NSImage? {
        if let img = NSImage(systemSymbolName: name, accessibilityDescription: accessibility) {
            return img
        }
        if let fallback {
            return NSImage(systemSymbolName: fallback, accessibilityDescription: accessibility)
        }
        return nil
    }
}

extension NSColor {
    /// 从 6 位 hex（RRGGBB，可含前缀 #）构造 sRGB 颜色；长度/进制非法返回 nil
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                  green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255,
                  alpha: 1)
    }
}

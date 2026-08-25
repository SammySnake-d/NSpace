import AppKit

/// 快捷键注册表（外部化配置：菜单快捷键不硬编码，UserDefaults 可改，设置窗可录制）。
/// 键存储格式 "kb.<id>" = "<modsRaw>|<key>"；缺省用注册表默认值。
@MainActor
enum KeyBindings {
    struct Entry {
        let id: String
        let titleKey: String     // 设置窗显示名（本地化键）
        let defaultKey: String
        let defaultMods: NSEvent.ModifierFlags
    }

    /// 常用命令注册表（设置窗按此渲染；新增可配快捷键 = 加一行）
    static let registry: [Entry] = [
        Entry(id: "newTab", titleKey: "menu.newWorkspace", defaultKey: "t", defaultMods: [.command]),
        Entry(id: "newPaneTab", titleKey: "menu.newPaneTab", defaultKey: "t", defaultMods: [.command, .option]),
        Entry(id: "closeTab", titleKey: "menu.closeWorkspace", defaultKey: "w", defaultMods: [.command]),
        Entry(id: "nextWorkspace", titleKey: "menu.nextWorkspace", defaultKey: "]", defaultMods: [.command, .shift]),
        Entry(id: "prevWorkspace", titleKey: "menu.prevWorkspace", defaultKey: "[", defaultMods: [.command, .shift]),
        // ⌃⇥ / ⌃⇧⇥ 工作区循环（Tab 无法作菜单 keyEquivalent，由事件监视器读本注册表的修饰键，
        // 而非硬编码——满足 §0「快捷键一律走 KeyBindings 注册表」）
        Entry(id: "cycleWorkspace", titleKey: "menu.nextWorkspace", defaultKey: "\t", defaultMods: [.control]),
        Entry(id: "cycleWorkspaceBack", titleKey: "menu.prevWorkspace", defaultKey: "\t", defaultMods: [.control, .shift]),
        Entry(id: "newFolder", titleKey: "menu.newFolder", defaultKey: "n", defaultMods: [.command, .shift]),
        Entry(id: "quickLook", titleKey: "menu.quickLook", defaultKey: " ", defaultMods: []),
        Entry(id: "getInfo", titleKey: "menu.getInfo", defaultKey: "i", defaultMods: [.command]),
        Entry(id: "duplicate", titleKey: "menu.duplicate", defaultKey: "d", defaultMods: [.command]),
        Entry(id: "moveToTrash", titleKey: "menu.moveToTrash", defaultKey: "\u{8}", defaultMods: [.command]),
        Entry(id: "copyPath", titleKey: "menu.copyPath", defaultKey: "c", defaultMods: [.command, .shift]),
        Entry(id: "toggleHidden", titleKey: "menu.toggleHidden", defaultKey: ".", defaultMods: [.command, .shift]),
        Entry(id: "refresh", titleKey: "menu.refresh", defaultKey: "r", defaultMods: [.command]),
        Entry(id: "back", titleKey: "menu.back", defaultKey: "[", defaultMods: [.command]),
        Entry(id: "forward", titleKey: "menu.forward", defaultKey: "]", defaultMods: [.command]),
        Entry(id: "goUp", titleKey: "menu.goUp", defaultKey: "\u{F700}", defaultMods: [.command]),
        Entry(id: "goToPath", titleKey: "menu.goToPath", defaultKey: "l", defaultMods: [.command]),
        // 用户点名默认：⌘F 当前文件夹、⇧⌘F 全局
        Entry(id: "searchHere", titleKey: "menu.searchHere", defaultKey: "f", defaultMods: [.command]),
        Entry(id: "searchGlobal", titleKey: "menu.searchGlobal", defaultKey: "f", defaultMods: [.command, .shift]),
        Entry(id: "toggleSidebar", titleKey: "menu.toggleSidebar", defaultKey: "s", defaultMods: [.command, .option]),
        Entry(id: "togglePaneTabBar", titleKey: "menu.togglePaneTabBar", defaultKey: "", defaultMods: []),
    ]

    static func entry(_ id: String) -> Entry? {
        registry.first { $0.id == id }
    }

    /// 当前生效绑定（用户覆盖 > 注册表默认）
    static func binding(_ id: String) -> (key: String, mods: NSEvent.ModifierFlags) {
        guard let e = entry(id) else { return ("", []) }
        if let raw = UserDefaults.standard.string(forKey: "kb.\(id)") {
            let parts = raw.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2, let mods = UInt(parts[0]) {
                return (String(parts[1]), NSEvent.ModifierFlags(rawValue: mods))
            }
        }
        return (e.defaultKey, e.defaultMods)
    }

    static func set(_ id: String, key: String, mods: NSEvent.ModifierFlags) {
        UserDefaults.standard.set("\(mods.rawValue)|\(key)", forKey: "kb.\(id)")
    }

    static func reset(_ id: String) {
        UserDefaults.standard.removeObject(forKey: "kb.\(id)")
    }

    /// 应用到菜单项（MainMenu 构建时调用）
    static func apply(_ id: String, to item: NSMenuItem) {
        let b = binding(id)
        item.keyEquivalent = b.key
        item.keyEquivalentModifierMask = b.mods
    }

    /// 人类可读描述（设置窗展示："⇧⌘F"）
    static func display(_ id: String) -> String {
        let b = binding(id)
        guard !b.key.isEmpty else { return "—" }
        var out = ""
        if b.mods.contains(.control) { out += "⌃" }
        if b.mods.contains(.option) { out += "⌥" }
        if b.mods.contains(.shift) { out += "⇧" }
        if b.mods.contains(.command) { out += "⌘" }
        return out + symbolName(for: b.key)
    }

    private static func symbolName(for key: String) -> String {
        switch key {
        case " ": "Space"
        case "\t": "⇥"
        case "\u{8}", "\u{7F}": "⌫"
        case "\u{F700}": "↑"
        case "\u{F701}": "↓"
        case "\u{F702}": "←"
        case "\u{F703}": "→"
        default: key.uppercased()
        }
    }

    /// 变更后重建主菜单即时生效
    static func rebuildMenus() {
        NSApp.mainMenu = MainMenu.build()
    }
}

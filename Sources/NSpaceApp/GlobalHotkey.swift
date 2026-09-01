import AppKit
import Carbon.HIToolbox

/// 全局呼出/隐藏热键（M24 用户点名：替代 Raycast 桥接）。
/// Carbon RegisterEventHotKey——系统认可的全局热键通道，无需辅助功能权限。
/// 语义：NSpace 在前台 → 隐藏；在后台/被遮挡 → 激活置顶（无窗则开新窗）。
/// 组合键外部化存 UserDefaults "globalHotkey" = "modsRaw|keyCode|显示串"；默认未设置（设置-通用录制）。
@MainActor
enum GlobalHotkey {
    private static var hotKeyRef: EventHotKeyRef?
    private static var handlerRef: EventHandlerRef?

    static let prefKey = "globalHotkey"

    /// 当前绑定（modsRaw 为 NSEvent.ModifierFlags.rawValue）
    static var current: (mods: NSEvent.ModifierFlags, keyCode: UInt32, display: String)? {
        guard let raw = UserDefaults.standard.string(forKey: prefKey) else { return nil }
        let parts = raw.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let m = UInt(parts[0]), let k = UInt32(parts[1]) else { return nil }
        return (NSEvent.ModifierFlags(rawValue: m), k, String(parts[2]))
    }

    static func set(mods: NSEvent.ModifierFlags, keyCode: UInt32, display: String) {
        UserDefaults.standard.set("\(mods.rawValue)|\(keyCode)|\(display)", forKey: prefKey)
        apply()
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: prefKey)
        apply()
    }

    /// 依当前偏好（重新）注册；返回是否注册成功（未设置=成功注销也返回 true）
    @discardableResult
    static func apply() -> Bool {
        unregister()
        guard let (mods, keyCode, _) = current else { return true }
        var carbonMods: UInt32 = 0
        if mods.contains(.command) { carbonMods |= UInt32(cmdKey) }
        if mods.contains(.option) { carbonMods |= UInt32(optionKey) }
        if mods.contains(.control) { carbonMods |= UInt32(controlKey) }
        if mods.contains(.shift) { carbonMods |= UInt32(shiftKey) }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, _, _ in
            Task { @MainActor in GlobalHotkey.toggle() }
            return noErr
        }, 1, &eventType, nil, &handlerRef)
        let hotKeyID = EventHotKeyID(signature: OSType(0x4E53_5043) /* "NSPC" */, id: 1)
        let status = RegisterEventHotKey(keyCode, carbonMods, hotKeyID,
                                         GetEventDispatcherTarget(), 0, &hotKeyRef)
        return status == noErr
    }

    static func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef); Self.hotKeyRef = nil }
        if let handlerRef { RemoveEventHandler(handlerRef); Self.handlerRef = nil }
    }

    /// 呼出/隐藏切换（热键回调；UISelfTest 直接调用作真效果断言）
    static func toggle() {
        if NSApp.isActive {
            NSApp.hide(nil)
        } else {
            NSApp.unhide(nil)
            NSApp.activate()
            // unhide 是异步的：此刻问 NSApp.windows 的 isVisible 一律还是 false，据此判断"有没有主窗"
            // 会误判成没有 → 每次热键呼出都多开一个空窗（慢机器上必现）。改问 AppDelegate 的窗口台账，
            // 它在 windowWillClose 里同步维护，是唯一同步可信的答案。
            let delegate = NSApp.delegate as? AppDelegate
            if delegate?.hasLiveMainWindow == true {
                delegate?.frontmostMainWindow?.makeKeyAndOrderFront(nil)
            } else {
                delegate?.openWindow(at: FileManager.default.homeDirectoryForCurrentUser)
            }
        }
    }
}

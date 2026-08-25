import AppKit

/// 设置页插件协议：新增设置页 = 新建 XxxSettingsPage.swift + 在 SettingsPages.extraPages 注册一行
@MainActor
protocol SettingsPage {
    var pageTitleKey: String { get }
    func makeView() -> NSView
}

/// 并发扩展位：各功能面（归档/使用习惯/打开模式/权限/外观）在此追加
@MainActor
enum SettingsPages {
    static var extraPages: [any SettingsPage] = [
        ArchiveSettingsPage(),
        BehaviorSettingsPage(),      // 使用习惯 + 打开模式
        PermissionsSettingsPage(),   // 权限（完全磁盘访问）
    ]
}

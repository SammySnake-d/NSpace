import AppKit

/// 全代码菜单栏。只挂当前里程碑已实现的命令——无真实功能则删界面元素（spec 六）。
@MainActor
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()

        // App 菜单
        let appItem = main.addItem(withTitle: "NSpace", action: nil, keyEquivalent: "")
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: L10n.t("menu.about"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L10n.t("menu.hide"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: L10n.t("menu.hideOthers"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: L10n.t("menu.showAll"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L10n.t("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // 文件
        let fileItem = main.addItem(withTitle: L10n.t("menu.file"), action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: L10n.t("menu.file"))
        fileItem.submenu = fileMenu
        fileMenu.addItem(withTitle: L10n.t("menu.newWindow"), action: #selector(AppDelegate.newWindow(_:)), keyEquivalent: "n")
        fileMenu.addItem(withTitle: L10n.t("menu.closeWindow"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        // 编辑（文本编辑标准链，路径编辑框/重命名要用）
        let editItem = main.addItem(withTitle: L10n.t("menu.edit"), action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: L10n.t("menu.edit"))
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: L10n.t("menu.undo"), action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: L10n.t("menu.redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L10n.t("menu.cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L10n.t("menu.copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L10n.t("menu.paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L10n.t("menu.selectAll"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        // 显示
        let viewItem = main.addItem(withTitle: L10n.t("menu.view"), action: nil, keyEquivalent: "")
        let viewMenu = NSMenu(title: L10n.t("menu.view"))
        viewItem.submenu = viewMenu
        let hiddenItem = viewMenu.addItem(withTitle: L10n.t("menu.toggleHidden"),
                                          action: #selector(FileListViewController.toggleHiddenFiles(_:)),
                                          keyEquivalent: ".")
        hiddenItem.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(withTitle: L10n.t("menu.refresh"),
                         action: #selector(FileListViewController.refresh(_:)), keyEquivalent: "r")

        // 前往
        let goItem = main.addItem(withTitle: L10n.t("menu.go"), action: nil, keyEquivalent: "")
        let goMenu = NSMenu(title: L10n.t("menu.go"))
        goItem.submenu = goMenu
        let upItem = goMenu.addItem(withTitle: L10n.t("menu.goUp"),
                                    action: #selector(MainWindowController.goUpFolder(_:)), keyEquivalent: "\u{F700}")
        upItem.keyEquivalentModifierMask = [.command]
        let homeItem = goMenu.addItem(withTitle: L10n.t("menu.goHome"),
                                      action: #selector(MainWindowController.goHome(_:)), keyEquivalent: "h")
        homeItem.keyEquivalentModifierMask = [.command, .shift]

        // 窗口
        let windowItem = main.addItem(withTitle: L10n.t("menu.window"), action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: L10n.t("menu.window"))
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: L10n.t("menu.minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: L10n.t("menu.zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu

        return main
    }
}

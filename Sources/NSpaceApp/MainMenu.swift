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
        appMenu.addItem(withTitle: L10n.t("menu.settings"), action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
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
        let newTabItem = fileMenu.addItem(withTitle: L10n.t("menu.newWorkspace"), action: #selector(MainWindowController.newWorkspaceTab(_:)), keyEquivalent: "")
        KeyBindings.apply("newTab", to: newTabItem)
        let paneTabItem = fileMenu.addItem(withTitle: L10n.t("menu.newPaneTab"), action: #selector(PaneViewController.newTab(_:)), keyEquivalent: "")
        KeyBindings.apply("newPaneTab", to: paneTabItem)
        let nextWsItem = fileMenu.addItem(withTitle: L10n.t("menu.nextWorkspace"),
                                          action: #selector(MainWindowController.nextWorkspace(_:)), keyEquivalent: "")
        KeyBindings.apply("nextWorkspace", to: nextWsItem)
        let prevWsItem = fileMenu.addItem(withTitle: L10n.t("menu.prevWorkspace"),
                                          action: #selector(MainWindowController.previousWorkspace(_:)), keyEquivalent: "")
        KeyBindings.apply("prevWorkspace", to: prevWsItem)
        let newFolderItem = fileMenu.addItem(withTitle: L10n.t("menu.newFolder"),
                                             action: #selector(FileListViewController.newFolderHere(_:)), keyEquivalent: "")
        KeyBindings.apply("newFolder", to: newFolderItem)
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: L10n.t("menu.open"),
                         action: #selector(FileListViewController.openSelected(_:)), keyEquivalent: "o")
        let qlItem = fileMenu.addItem(withTitle: L10n.t("menu.quickLook"),
                         action: #selector(FileListViewController.toggleQuickLook(_:)), keyEquivalent: "")
        KeyBindings.apply("quickLook", to: qlItem)
        let infoItem = fileMenu.addItem(withTitle: L10n.t("menu.getInfo"),
                         action: #selector(FileListViewController.getInfo(_:)), keyEquivalent: "")
        KeyBindings.apply("getInfo", to: infoItem)
        fileMenu.addItem(withTitle: L10n.t("menu.rename"),
                         action: #selector(FileListViewController.renameSelected(_:)), keyEquivalent: "")
        let dupItem = fileMenu.addItem(withTitle: L10n.t("menu.duplicate"),
                         action: #selector(FileListViewController.duplicateItems(_:)), keyEquivalent: "")
        KeyBindings.apply("duplicate", to: dupItem)
        let trashItem = fileMenu.addItem(withTitle: L10n.t("menu.moveToTrash"),
                                         action: #selector(FileListViewController.moveToTrash(_:)), keyEquivalent: "")
        KeyBindings.apply("moveToTrash", to: trashItem)
        fileMenu.addItem(.separator())
        // F5 复制 / F6 移动 到另一窗格（QSpace 肌肉记忆）
        let f5 = fileMenu.addItem(withTitle: L10n.t("menu.copyToOtherPane"),
                                  action: #selector(FileListViewController.copyToOtherPane(_:)), keyEquivalent: "\u{F708}")
        f5.keyEquivalentModifierMask = []
        let f6 = fileMenu.addItem(withTitle: L10n.t("menu.moveToOtherPane"),
                                  action: #selector(FileListViewController.moveToOtherPane(_:)), keyEquivalent: "\u{F709}")
        f6.keyEquivalentModifierMask = []
        fileMenu.addItem(.separator())
        // ⌘W 分层关闭（I-21）：路由到 AppDelegate.closeTopmost——浮层优先，主窗才关工作区标签
        let closeTabItem = fileMenu.addItem(withTitle: L10n.t("menu.closeWorkspace"), action: #selector(AppDelegate.closeTopmost(_:)), keyEquivalent: "")
        KeyBindings.apply("closeTab", to: closeTabItem)
        let closePaneTabItem = fileMenu.addItem(withTitle: L10n.t("menu.closePaneTab"), action: #selector(PaneViewController.closeActiveTab(_:)), keyEquivalent: "w")
        closePaneTabItem.keyEquivalentModifierMask = [.command, .option]
        let closeWinItem = fileMenu.addItem(withTitle: L10n.t("menu.closeWindow"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        closeWinItem.keyEquivalentModifierMask = [.command, .shift]

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
        let copyPathItem = editMenu.addItem(withTitle: L10n.t("menu.copyPath"),
                                            action: #selector(FileListViewController.copyPath(_:)), keyEquivalent: "")
        KeyBindings.apply("copyPath", to: copyPathItem)
        editMenu.addItem(withTitle: L10n.t("menu.selectAll"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        // 显示
        let viewItem = main.addItem(withTitle: L10n.t("menu.view"), action: nil, keyEquivalent: "")
        let viewMenu = NSMenu(title: L10n.t("menu.view"))
        viewItem.submenu = viewMenu

        // 视图模式（M9：每窗格独立；I-13 迁注册表默认 ⌥⌘1/2/3，validateMenuItem 打勾当前模式）
        let modeSpecs: [(String, Selector, String, String)] = [
            ("menu.viewAsIcons", #selector(PaneViewController.viewAsIcons(_:)), "viewAsIcons", "square.grid.2x2"),
            ("menu.viewAsList", #selector(PaneViewController.viewAsList(_:)), "viewAsList", "list.bullet"),
            ("menu.viewAsColumns", #selector(PaneViewController.viewAsColumns(_:)), "viewAsColumns", "rectangle.split.3x1"),
        ]
        for (key, sel, bindingID, symbol) in modeSpecs {
            let item = viewMenu.addItem(withTitle: L10n.t(key), action: sel, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            KeyBindings.apply(bindingID, to: item)
        }
        viewMenu.addItem(.separator())

        // 布局子菜单（⌃⌘1..5）
        let layoutItem = viewMenu.addItem(withTitle: L10n.t("menu.layout"), action: nil, keyEquivalent: "")
        let layoutMenu = NSMenu(title: L10n.t("menu.layout"))
        layoutItem.submenu = layoutMenu
        for (i, layout) in PaneLayout.allCases.enumerated() {
            let item = layoutMenu.addItem(withTitle: layout.localizedName,
                                          action: #selector(MainWindowController.applyLayout(_:)),
                                          keyEquivalent: "\(i + 1)")
            item.keyEquivalentModifierMask = [.control, .command]
            item.tag = layout.rawValue
            item.image = NSImage(systemSymbolName: layout.symbolName, accessibilityDescription: nil)
        }
        viewMenu.addItem(.separator())
        let sidebarItem = viewMenu.addItem(withTitle: L10n.t("menu.toggleSidebar"),
                                           action: #selector(MainWindowController.toggleSidebar(_:)),
                                           keyEquivalent: "")
        KeyBindings.apply("toggleSidebar", to: sidebarItem)
        let paneBarItem = viewMenu.addItem(withTitle: L10n.t("menu.togglePaneTabBar"),
                         action: #selector(MainWindowController.togglePaneTabBar(_:)), keyEquivalent: "")
        KeyBindings.apply("togglePaneTabBar", to: paneBarItem)
        viewMenu.addItem(.separator())
        let hiddenItem = viewMenu.addItem(withTitle: L10n.t("menu.toggleHidden"),
                                          action: #selector(FileListViewController.toggleHiddenFiles(_:)),
                                          keyEquivalent: "")
        KeyBindings.apply("toggleHidden", to: hiddenItem)
        let refreshItem = viewMenu.addItem(withTitle: L10n.t("menu.refresh"),
                         action: #selector(FileListViewController.refresh(_:)), keyEquivalent: "")
        KeyBindings.apply("refresh", to: refreshItem)

        // 前往
        let goItem = main.addItem(withTitle: L10n.t("menu.go"), action: nil, keyEquivalent: "")
        let goMenu = NSMenu(title: L10n.t("menu.go"))
        goItem.submenu = goMenu
        let backItem = goMenu.addItem(withTitle: L10n.t("menu.back"),
                       action: #selector(PaneViewController.goBack(_:)), keyEquivalent: "")
        KeyBindings.apply("back", to: backItem)
        let fwdItem = goMenu.addItem(withTitle: L10n.t("menu.forward"),
                       action: #selector(PaneViewController.goForward(_:)), keyEquivalent: "")
        KeyBindings.apply("forward", to: fwdItem)
        let upItem = goMenu.addItem(withTitle: L10n.t("menu.goUp"),
                                    action: #selector(PaneViewController.goUpFolder(_:)), keyEquivalent: "")
        KeyBindings.apply("goUp", to: upItem)
        goMenu.addItem(.separator())
        let homeItem = goMenu.addItem(withTitle: L10n.t("menu.goHome"),
                                      action: #selector(PaneViewController.goHome(_:)), keyEquivalent: "h")
        homeItem.keyEquivalentModifierMask = [.command, .shift]
        let pathItem = goMenu.addItem(withTitle: L10n.t("menu.goToPath"),
                       action: #selector(PaneViewController.editPath(_:)), keyEquivalent: "")
        KeyBindings.apply("goToPath", to: pathItem)
        goMenu.addItem(.separator())
        // 聚焦搜索：默认 ⌘F 当前文件夹 / ⇧⌘F 全局（可在设置改键）
        let hereSearch = goMenu.addItem(withTitle: L10n.t("menu.searchHere"),
                       action: #selector(MainWindowController.showSearchHere(_:)), keyEquivalent: "")
        KeyBindings.apply("searchHere", to: hereSearch)
        let globalSearch = goMenu.addItem(withTitle: L10n.t("menu.searchGlobal"),
                                          action: #selector(MainWindowController.showSearchGlobal(_:)),
                                          keyEquivalent: "")
        KeyBindings.apply("searchGlobal", to: globalSearch)

        // 窗口
        let windowItem = main.addItem(withTitle: L10n.t("menu.window"), action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: L10n.t("menu.window"))
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: L10n.t("menu.minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: L10n.t("menu.zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        // 工作区数字直达 ⌘1..9（I-13；tag = 工作区下标，超出现有数量时 validate 置灰）
        for n in 1...9 {
            let item = windowMenu.addItem(withTitle: L10n.t("menu.gotoWorkspace\(n)"),
                                          action: #selector(MainWindowController.switchWorkspaceByNumber(_:)),
                                          keyEquivalent: "")
            item.tag = n - 1
            KeyBindings.apply("workspace\(n)", to: item)
        }
        NSApp.windowsMenu = windowMenu

        return main
    }
}

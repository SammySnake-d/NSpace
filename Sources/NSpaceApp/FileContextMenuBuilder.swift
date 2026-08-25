import AppKit
import NSpaceContracts

/// 右键菜单构造器：按选中态生成菜单；命令全部路由到 FileListViewController 的响应链动作。
/// 空白区右键 → 目录级菜单（新建/粘贴/显示简介当前目录）。
@MainActor
enum FileContextMenuBuilder {

    static func menu(selection: [FileItem], directory: URL,
                     target: FileListViewController) -> NSMenu {
        selection.isEmpty
            ? directoryMenu(directory: directory, target: target)
            : itemMenu(selection: selection, directory: directory, target: target)
    }

    // MARK: 目录级菜单（空白区）

    private static func directoryMenu(directory: URL, target: FileListViewController) -> NSMenu {
        let menu = NSMenu()
        add(menu, "menu.newFolder", #selector(FileListViewController.newFolderHere(_:)), target,
            key: "N", mods: [.command, .shift], symbol: "folder.badge.plus")
        add(menu, "menu.paste", #selector(FileListViewController.pasteItems(_:)), target,
            key: "v", mods: .command, symbol: "doc.on.clipboard")
        menu.addItem(.separator())
        add(menu, "menu.getInfo", #selector(FileListViewController.getInfo(_:)), target,
            key: "i", mods: .command, symbol: "info.circle")
        add(menu, "menu.openInTerminal", #selector(FileListViewController.openInTerminal(_:)), target,
            symbol: "terminal")
        return menu
    }

    // MARK: 条目菜单（有选中）

    private static func itemMenu(selection: [FileItem], directory: URL,
                                 target: FileListViewController) -> NSMenu {
        let menu = NSMenu()
        let single = selection.count == 1 ? selection.first : nil

        add(menu, "menu.open", #selector(FileListViewController.openSelected(_:)), target,
            symbol: "arrow.up.forward.app")
        if let single {
            menu.addItem(openWithSubmenu(for: single.url, target: target))
        }
        menu.addItem(.separator())

        add(menu, "menu.copy", #selector(FileListViewController.copyItems(_:)), target,
            key: "c", mods: .command, symbol: "doc.on.doc")
        add(menu, "menu.cut", #selector(FileListViewController.cutItems(_:)), target,
            key: "x", mods: .command, symbol: "scissors")
        add(menu, "menu.paste", #selector(FileListViewController.pasteItems(_:)), target,
            key: "v", mods: .command, symbol: "doc.on.clipboard")
        add(menu, "menu.copyPath", #selector(FileListViewController.copyPath(_:)), target,
            key: "c", mods: [.command, .shift], symbol: "link")
        menu.addItem(.separator())

        if single != nil {
            add(menu, "menu.rename", #selector(FileListViewController.renameSelected(_:)), target,
                symbol: "pencil")
        }
        add(menu, "menu.duplicate", #selector(FileListViewController.duplicateItems(_:)), target,
            key: "d", mods: .command, symbol: "plus.square.on.square")
        add(menu, "menu.moveToTrash", #selector(FileListViewController.moveToTrash(_:)), target,
            key: "\u{8}", mods: .command, symbol: "trash")
        menu.addItem(.separator())

        add(menu, "menu.newFolder", #selector(FileListViewController.newFolderHere(_:)), target,
            key: "N", mods: [.command, .shift], symbol: "folder.badge.plus")
        add(menu, "menu.getInfo", #selector(FileListViewController.getInfo(_:)), target,
            key: "i", mods: .command, symbol: "info.circle")
        add(menu, "menu.openInTerminal", #selector(FileListViewController.openInTerminal(_:)), target,
            symbol: "terminal")
        if let single, single.isPackage {
            add(menu, "menu.showPackageContents",
                #selector(FileListViewController.showPackageContents(_:)), target,
                symbol: "shippingbox")
        }
        return menu
    }

    // MARK: 打开方式子菜单（列 App + 图标 + 默认项标注 + 其他…）

    private static func openWithSubmenu(for url: URL, target: FileListViewController) -> NSMenuItem {
        let item = NSMenuItem(title: L10n.t("menu.openWith"), action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
        let submenu = NSMenu()
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: url)
        let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: url)
        for app in apps {
            let name = FileManager.default.displayName(atPath: app.path)
            let isDefault = app == defaultApp
            let title = isDefault ? "\(name) \(L10n.t("openWith.default"))" : name
            let mi = NSMenuItem(title: title,
                                action: #selector(FileListViewController.openWithApp(_:)),
                                keyEquivalent: "")
            mi.target = target
            mi.representedObject = app
            let icon = NSWorkspace.shared.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            mi.image = icon
            submenu.addItem(mi)
        }
        if !apps.isEmpty { submenu.addItem(.separator()) }
        let other = NSMenuItem(title: L10n.t("openWith.other"),
                               action: #selector(FileListViewController.openWithOther(_:)),
                               keyEquivalent: "")
        other.target = target
        submenu.addItem(other)
        item.submenu = submenu
        return item
    }

    // MARK: 构造工具

    @discardableResult
    private static func add(_ menu: NSMenu, _ key: String, _ action: Selector,
                            _ target: FileListViewController,
                            key equiv: String = "", mods: NSEvent.ModifierFlags = [],
                            symbol: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: L10n.t(key), action: action, keyEquivalent: equiv)
        item.keyEquivalentModifierMask = mods
        item.target = target
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        menu.addItem(item)
        return item
    }
}

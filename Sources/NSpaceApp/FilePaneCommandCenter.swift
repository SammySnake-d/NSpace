import AppKit
import ArchiveEngine
import NSpaceContracts
import QuickLookUI

extension FileItem {
    var isArchive: Bool { ArchiveEngineNode.isSupportedArchive(url) }
}

/// 终端与外部打开统一入口（MIT 独立公理：三视图与上下文菜单共享 Preferences.terminalChoice）
@MainActor
enum TerminalLauncher {
    static func open(directory url: URL) {
        let target = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        let ws = NSWorkspace.shared
        let choice = Preferences.terminalChoice
        let terminal: URL? = choice == "auto"
            ? (ws.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2")
               ?? ws.urlForApplication(withBundleIdentifier: "com.apple.Terminal"))
            : ws.urlForApplication(withBundleIdentifier: choice)
        guard let terminal else { NSSound.beep(); return }
        ws.open([target], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// 统一拖拽目标运算：复用 FileOpsCoordinator.effectiveMove / isSelfOrDescendant / dropTransfer
@MainActor
enum FileDropPolicy {
    static func dragOperation(
        for info: NSDraggingInfo,
        targetDirectory: URL,
        targetItem: FileItem?
    ) -> NSDragOperation {
        if let targetItem, (!targetItem.isDirectory || targetItem.isPackage) {
            return []
        }
        let destination = targetItem?.url ?? targetDirectory
        if TrashLocation.isInsideTrash(destination) {
            return []
        }
        let urls = urlsFromPasteboard(info.draggingPasteboard)
        guard !urls.isEmpty else { return [] }

        for src in urls {
            if FileOpsCoordinator.isSelfOrDescendant(destination: destination, ofSource: src) {
                return []
            }
        }

        let forceCopy = NSEvent.modifierFlags.contains(.option)
            || info.draggingSourceOperationMask == .copy
        let move = FileOpsCoordinator.effectiveMove(urls: urls, into: destination, optionCopy: forceCopy)
        if move,
           urls.allSatisfy({ $0.standardizedFileURL.deletingLastPathComponent().path == destination.standardizedFileURL.path }) {
            return []
        }
        return move ? .move : .copy
    }

    static func acceptDrop(
        _ info: NSDraggingInfo,
        targetDirectory: URL,
        targetItem: FileItem?,
        coordinator: FileOpsCoordinator?
    ) -> Bool {
        guard let coordinator else { return false }
        let destination = targetItem?.url ?? targetDirectory
        let op = dragOperation(for: info, targetDirectory: targetDirectory, targetItem: targetItem)
        guard op == .copy || op == .move else { return false }
        let urls = urlsFromPasteboard(info.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        let forceCopy = NSEvent.modifierFlags.contains(.option) || op == .copy
        coordinator.dropTransfer(urls: urls, into: destination, forceCopy: forceCopy)
        return true
    }

    static func urlsFromPasteboard(_ pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
}

/// 窗格内文件视图统一抽象（List / Icon / Column 共同遵循）
@MainActor
protocol FilePaneContent: NSViewController, FileRevealTarget {
    var currentDirectory: URL { get }
    var coordinator: FileOpsCoordinator? { get set }
    var model: DirectoryViewModel { get }
    var selectedItems: [FileItem] { get }
    var selectedURLs: [URL] { get }
    var isEditingName: Bool { get }
    var isPaneActiveProvider: (() -> Bool)? { get set }
    var hasOtherPane: Bool { get }
    var isGrouped: Bool { get }

    func focusFileView()
    func selectAllItems()
    func renameSelection()
    func open(_ item: FileItem)
    func toggleQuickLook(_ sender: Any?)
}

/// 统一 Quick Look 预览桥梁：三视图共用数据源、刷新与退出淡出守卫（I-45）
@MainActor
final class FileQuickLookBridge: NSObject {
    private var urls: [URL] = []
    private var frameProvider: ((URL) -> NSRect)?

    var quickLookDismissing = false

    func toggle(urls: [URL], frameProvider: @escaping (URL) -> NSRect) {
        self.urls = urls
        self.frameProvider = frameProvider
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            quickLookDismissing = true
            panel.orderOut(nil)
        } else if !urls.isEmpty {
            quickLookDismissing = false
            panel.makeKeyAndOrderFront(nil)
            panel.reloadData()
        }
    }

    func updateIfVisible(urls: [URL], frameProvider: @escaping (URL) -> NSRect) {
        self.urls = urls
        self.frameProvider = frameProvider
        guard let panel = QLPreviewPanel.shared(), panel.isVisible else { return }
        panel.reloadData()
    }

    func count() -> Int { urls.count }

    func item(at index: Int) -> (any QLPreviewItem)? {
        guard index >= 0, index < urls.count else { return nil }
        return urls[index] as NSURL
    }

    func sourceFrame(on screen: QLPreviewPanel?, for previewItem: (any QLPreviewItem)?,
                     frameProvider: ((URL) -> NSRect)? = nil) -> NSRect {
        if quickLookDismissing { return .zero }
        if let screen, !screen.isVisible { return .zero }
        guard let url = previewItem?.previewItemURL else { return .zero }
        return (frameProvider ?? self.frameProvider)?(url) ?? .zero
    }
}

/// 三视图共享命令分发与菜单校验中心（MIT 独立公理：每个 Command 仅此一条权威路径）
@MainActor
enum FileViewActions {
    static func validateMenuItem(_ menuItem: NSMenuItem, pane: any FilePaneContent) -> Bool {
        let items = pane.selectedItems
        let hasSelection = !items.isEmpty
        let inTrash = TrashLocation.isInsideTrash(pane.currentDirectory)
        let selectedArchives = items.filter(\.isArchive)

        switch menuItem.action {
        case #selector(FileListViewController.copyPath(_:)),
             #selector(FilePaneExtendedActions.copyNames(_:)),
             #selector(FileListViewController.openInTerminal(_:)),
             #selector(FileListViewController.getInfo(_:)):
            return true
        case #selector(FileListViewController.putBackItems(_:)):
            guard inTrash, hasSelection, let coord = pane.coordinator else { return false }
            return coord.canPutBackAny(pane.selectedURLs)
        case #selector(FileListViewController.cutItems(_:)),
             #selector(FileListViewController.duplicateItems(_:)),
             #selector(FileListViewController.moveToTrash(_:)),
             #selector(FileListViewController.compressItems(_:)),
             #selector(FilePaneExtendedActions.newFolderWithSelection(_:)),
             #selector(FilePaneExtendedActions.batchRenameItems(_:)),
             #selector(FileListViewController.cut(_:)):
            return hasSelection && !inTrash
        case #selector(FileListViewController.copyItems(_:)),
             #selector(FileListViewController.copy(_:)),
             #selector(FileListViewController.openSelected(_:)),
             #selector(FilePaneExtendedActions.deleteImmediately(_:)):
            return hasSelection
        case #selector(FileListViewController.copyToOtherPane(_:)),
             #selector(FileListViewController.moveToOtherPane(_:)):
            return hasSelection && !inTrash && pane.hasOtherPane
        case #selector(FileListViewController.airdropSelected(_:)):
            return hasSelection && (NSSharingService(named: .sendViaAirDrop)?.canPerform(withItems: pane.selectedURLs) ?? false)
        case #selector(FileListViewController.extractItems(_:)),
             #selector(FileListViewController.extractItemsTo(_:)):
            return !inTrash && !selectedArchives.isEmpty
        case #selector(FileListViewController.renameSelected(_:)):
            return items.count == 1 && !inTrash
        case #selector(FileListViewController.pasteItems(_:)),
             #selector(FileListViewController.paste(_:)):
            return !inTrash && FileOpsCoordinator.canPasteOrCreateFromPasteboard
        case #selector(FilePaneExtendedActions.moveItemsHere(_:)):
            return !inTrash && FileOpsCoordinator.hasClipboardFiles
        case #selector(FileListViewController.newFolderHere(_:)),
             #selector(FileListViewController.newFileHere(_:)):
            return !inTrash
        case #selector(FileListViewController.toggleGrouping(_:)):
            menuItem.state = pane.isGrouped ? .on : .off
            return true
        case #selector(FileListViewController.selectAll(_:)):
            return true
        default:
            return true
        }
    }

    static func openSelected(pane: any FilePaneContent) {
        pane.selectedItems.forEach { pane.open($0) }
    }

    static func copyItems(pane: any FilePaneContent) {
        guard !pane.selectedURLs.isEmpty else { return }
        pane.coordinator?.copy(pane.selectedURLs)
    }

    static func cutItems(pane: any FilePaneContent) {
        guard !pane.selectedURLs.isEmpty, !TrashLocation.isInsideTrash(pane.currentDirectory) else { return }
        pane.coordinator?.cut(pane.selectedURLs)
    }

    static func pasteItems(pane: any FilePaneContent) {
        guard !TrashLocation.isInsideTrash(pane.currentDirectory) else { return }
        pane.coordinator?.paste(into: pane.currentDirectory, revealIn: pane)
    }

    static func moveItemsHere(pane: any FilePaneContent) {
        guard !TrashLocation.isInsideTrash(pane.currentDirectory) else { return }
        pane.coordinator?.movePaste(into: pane.currentDirectory, revealIn: pane)
    }

    static func copyPath(pane: any FilePaneContent, to pasteboard: NSPasteboard = .general) {
        let targets = pane.selectedURLs.isEmpty ? [pane.currentDirectory] : pane.selectedURLs
        pane.coordinator?.copyPaths(targets, to: pasteboard)
    }

    static func copyNames(pane: any FilePaneContent) {
        let targets = pane.selectedURLs.isEmpty ? [pane.currentDirectory] : pane.selectedURLs
        pane.coordinator?.copyNames(targets)
    }

    static func duplicateItems(pane: any FilePaneContent) {
        guard !pane.selectedURLs.isEmpty, !TrashLocation.isInsideTrash(pane.currentDirectory) else { return }
        pane.coordinator?.duplicate(pane.selectedURLs)
    }

    static func moveToTrash(pane: any FilePaneContent) {
        guard !pane.selectedURLs.isEmpty, !TrashLocation.isInsideTrash(pane.currentDirectory) else { return }
        pane.coordinator?.moveToTrash(pane.selectedURLs)
    }

    static func deleteImmediately(pane: any FilePaneContent) {
        guard !pane.selectedURLs.isEmpty else { return }
        pane.coordinator?.deleteImmediately(pane.selectedURLs, window: pane.view.window)
    }

    static func putBackItems(pane: any FilePaneContent) {
        guard !pane.selectedURLs.isEmpty, TrashLocation.isInsideTrash(pane.currentDirectory) else { return }
        pane.coordinator?.putBack(pane.selectedURLs)
    }

    static func newFolderHere(pane: any FilePaneContent) {
        guard !TrashLocation.isInsideTrash(pane.currentDirectory) else { return }
        pane.coordinator?.newFolder(in: pane.currentDirectory, revealIn: pane)
    }

    static func newFileHere(pane: any FilePaneContent) {
        guard !TrashLocation.isInsideTrash(pane.currentDirectory) else { return }
        pane.coordinator?.newFile(in: pane.currentDirectory, revealIn: pane)
    }

    static func newFolderWithSelection(pane: any FilePaneContent) {
        guard !pane.selectedURLs.isEmpty, !TrashLocation.isInsideTrash(pane.currentDirectory) else { return }
        pane.coordinator?.newFolderWithSelection(pane.selectedURLs, in: pane.currentDirectory, revealIn: pane)
    }

    static func batchRenameItems(pane: any FilePaneContent) {
        guard !pane.selectedURLs.isEmpty, !TrashLocation.isInsideTrash(pane.currentDirectory) else { return }
        pane.coordinator?.presentBatchRename(urls: pane.selectedURLs, in: pane.view.window, revealIn: pane)
    }

    static func compressItems(pane: any FilePaneContent) {
        guard !pane.selectedURLs.isEmpty, !TrashLocation.isInsideTrash(pane.currentDirectory) else { return }
        pane.coordinator?.compress(pane.selectedURLs)
    }

    static func extractItems(pane: any FilePaneContent) {
        let archives = pane.selectedItems.filter(\.isArchive).map(\.url)
        guard !archives.isEmpty, !TrashLocation.isInsideTrash(pane.currentDirectory) else { return }
        pane.coordinator?.extract(archives, into: nil)
    }

    static func extractItemsTo(pane: any FilePaneContent) {
        let archives = pane.selectedItems.filter(\.isArchive).map(\.url)
        guard !archives.isEmpty, !TrashLocation.isInsideTrash(pane.currentDirectory) else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = L10n.t("menu.extractTo.prompt")
        panel.directoryURL = pane.currentDirectory
        let run: (NSApplication.ModalResponse) -> Void = { resp in
            guard resp == .OK, let dir = panel.url else { return }
            pane.coordinator?.extract(archives, into: dir)
        }
        if let win = pane.view.window {
            panel.beginSheetModal(for: win, completionHandler: run)
        } else {
            run(panel.runModal())
        }
    }

    static func getInfo(pane: any FilePaneContent) {
        let targets = pane.selectedURLs.isEmpty ? [pane.currentDirectory] : pane.selectedURLs
        InfoPanel.show(for: targets)
    }

    static func openInTerminal(pane: any FilePaneContent) {
        let target: URL
        if pane.selectedItems.count == 1, pane.selectedItems[0].isDirectory, !pane.selectedItems[0].isPackage {
            target = pane.selectedItems[0].url
        } else {
            target = pane.currentDirectory
        }
        TerminalLauncher.open(directory: target)
    }

    static func showPackageContents(pane: any FilePaneContent) {
        guard let first = pane.selectedItems.first, first.isPackage else { return }
        pane.open(first)
    }

    static func openWithApp(pane: any FilePaneContent, sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let appURL = item.representedObject as? URL,
              !pane.selectedURLs.isEmpty else { return }
        NSWorkspace.shared.open(pane.selectedURLs, withApplicationAt: appURL,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    static func openWithOther(pane: any FilePaneContent) {
        guard !pane.selectedURLs.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let appURL = panel.url else { return }
        NSWorkspace.shared.open(pane.selectedURLs, withApplicationAt: appURL,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    static func airdropSelected(pane: any FilePaneContent) {
        let urls = pane.selectedURLs
        guard !urls.isEmpty,
              let service = NSSharingService(named: .sendViaAirDrop),
              service.canPerform(withItems: urls) else { NSSound.beep(); return }
        service.perform(withItems: urls)
    }
}

/// 扩展响应链选择器定义（供 Menu / FileViewActions 与三视图复用，保持既有 selector 完全兼容）
@MainActor
@objc protocol FilePaneExtendedActions: AnyObject {
    @objc func moveItemsHere(_ sender: Any?)
    @objc func deleteImmediately(_ sender: Any?)
    @objc func newFolderWithSelection(_ sender: Any?)
    @objc func batchRenameItems(_ sender: Any?)
    @objc func copyNames(_ sender: Any?)
}

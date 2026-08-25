import AppKit
import NSpaceContracts

/// 冲突裁决面板：实现 ConflictArbiter（内核经此在活动窗口就地弹 sheet）。
/// arbitrate 是 async；内部 hop 到 MainActor 逐冲突呈现，支持「应用到全部」短路。
/// 无状态 → 线程安全（@unchecked Sendable，仅在 MainActor 上触碰 UI）。
final class ConflictSheet: ConflictArbiter, @unchecked Sendable {
    func arbitrate(operation id: UUID, conflicts: [FileConflict]) async -> [URL: ConflictDecision]? {
        await withCheckedContinuation { (cont: CheckedContinuation<[URL: ConflictDecision]?, Never>) in
            Task { @MainActor in
                Self.resolve(conflicts) { cont.resume(returning: $0) }
            }
        }
    }

    // MARK: 逐冲突呈现（递归推进；applyToAll 时把决议套用到剩余全部）

    @MainActor
    private static func resolve(_ conflicts: [FileConflict],
                                completion: @escaping @MainActor ([URL: ConflictDecision]?) -> Void) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
            completion([:]); return
        }
        var decisions: [URL: ConflictDecision] = [:]
        var index = 0

        func step() {
            guard index < conflicts.count else { completion(decisions); return }
            let conflict = conflicts[index]
            let alert = makeAlert(for: conflict)
            alert.beginSheetModal(for: window) { response in
                MainActor.assumeIsolated {
                    guard let (decision, applyAll) = decode(response, bothDirs: conflict.bothDirectories) else {
                        completion(nil); return   // 用户取消整个操作
                    }
                    if applyAll {
                        for c in conflicts[index...] { decisions[c.source] = decision }
                        completion(decisions); return
                    }
                    decisions[conflict.source] = decision
                    index += 1
                    step()
                }
            }
        }
        step()
    }

    // MARK: 面板构造（源 vs 目标：图标/名/改期/大小 + 应用到全部）

    @MainActor
    private static func makeAlert(for conflict: FileConflict) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = L10n.f("conflict.title", conflict.existing.lastPathComponent)
        alert.informativeText = L10n.t("conflict.message")
        alert.icon = NSWorkspace.shared.icon(forFile: conflict.source.path)
        alert.accessoryView = accessory(source: conflict.source, existing: conflict.existing)

        // 按钮顺序即 decode 的判定顺序
        alert.addButton(withTitle: L10n.t("conflict.replace"))   // 第 1 个 = 默认（回车）
        alert.addButton(withTitle: L10n.t("conflict.skip"))
        alert.addButton(withTitle: L10n.t("conflict.keepBoth"))
        if conflict.bothDirectories {
            alert.addButton(withTitle: L10n.t("conflict.merge"))
        }
        alert.addButton(withTitle: L10n.t("conflict.cancel"))
        return alert
    }

    /// 返回 (决议, 是否应用到全部)；nil = 取消
    @MainActor
    private static func decode(_ response: NSApplication.ModalResponse, bothDirs: Bool) -> (ConflictDecision, Bool)? {
        let applyAll = applyAllCheckbox?.state == .on
        switch response {
        case .alertFirstButtonReturn:  return (.replace, applyAll)
        case .alertSecondButtonReturn: return (.skip, applyAll)
        case .alertThirdButtonReturn:  return (.keepBoth, applyAll)
        case NSApplication.ModalResponse(rawValue: 1003):
            // 第 4 个按钮：目录冲突时为「合并」，否则为「取消」
            return bothDirs ? (.mergeFolders, applyAll) : nil
        default:
            return nil   // 取消
        }
    }

    // 复用同一勾选框实例以便 decode 读取其状态
    @MainActor private static var applyAllCheckbox: NSButton?

    @MainActor
    private static func accessory(source: URL, existing: URL) -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 96))
        let src = fileRow(title: L10n.t("conflict.source"), url: source, y: 60)
        let dst = fileRow(title: L10n.t("conflict.existing"), url: existing, y: 28)

        let checkbox = NSButton(checkboxWithTitle: L10n.t("conflict.applyToAll"),
                                target: nil, action: nil)
        checkbox.frame = NSRect(x: 0, y: 0, width: 380, height: 20)
        applyAllCheckbox = checkbox

        container.addSubview(src)
        container.addSubview(dst)
        container.addSubview(checkbox)
        return container
    }

    @MainActor
    private static func fileRow(title: String, url: URL, y: CGFloat) -> NSView {
        let row = NSView(frame: NSRect(x: 0, y: y, width: 380, height: 28))

        let icon = NSImageView(frame: NSRect(x: 0, y: 4, width: 20, height: 20))
        icon.image = NSWorkspace.shared.icon(forFile: url.path)
        icon.image?.size = NSSize(width: 20, height: 20)

        let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey])
        let sizeStr: String = (vals?.isDirectory == true)
            ? "—"
            : (vals?.fileSize).map { Formatters.size.string(fromByteCount: Int64($0)) } ?? "—"
        let dateStr = vals?.contentModificationDate.map { Formatters.date.string(from: $0) } ?? "—"

        let label = NSTextField(labelWithString: "\(title)  \(dateStr) · \(sizeStr)")
        label.frame = NSRect(x: 26, y: 4, width: 350, height: 20)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle

        row.addSubview(icon)
        row.addSubview(label)
        return row
    }
}

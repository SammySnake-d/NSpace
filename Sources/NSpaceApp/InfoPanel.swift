import AppKit
import UniformTypeIdentifiers

/// 显示简介面板：图标 / 名称 / 种类 / 大小 / 路径（可选中）/ 创建·修改日期。
/// 就地信息面板，非模态；每次调用弹一个独立 NSPanel。
@MainActor
enum InfoPanel {
    private static var open: [NSPanel] = []

    static func show(for url: URL) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 300),
                            styleMask: [.titled, .closable, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = L10n.f("info.title", url.lastPathComponent)
        panel.isReleasedWhenClosed = false
        panel.contentView = buildContent(for: url)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        open.append(panel)   // 防止被释放；关闭后清理
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                               object: panel, queue: .main) { [weak panel] _ in
            MainActor.assumeIsolated {
                open.removeAll { $0 === panel }
            }
        }
    }

    private static func buildContent(for url: URL) -> NSView {
        let vals = try? url.resourceValues(forKeys: [
            .contentTypeKey, .fileSizeKey, .totalFileAllocatedSizeKey,
            .creationDateKey, .contentModificationDateKey, .isDirectoryKey,
        ])
        let isDir = vals?.isDirectory == true
        let kindStr = vals?.contentType?.localizedDescription
            ?? (isDir ? L10n.t("kind.folder") : L10n.t("kind.document"))
        let sizeStr = isDir
            ? "—"
            : (vals?.fileSize).map { Formatters.size.string(fromByteCount: Int64($0)) } ?? "—"
        let created = vals?.creationDate.map { Formatters.relativeDate($0) } ?? "—"
        let modified = vals?.contentModificationDate.map { Formatters.relativeDate($0) } ?? "—"

        let iconView = NSImageView()
        iconView.image = NSWorkspace.shared.icon(forFile: url.path)
        iconView.image?.size = NSSize(width: 64, height: 64)
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: url.lastPathComponent)
        name.font = .boldSystemFont(ofSize: 13)
        name.alignment = .center
        name.lineBreakMode = .byTruncatingMiddle

        let fields = NSStackView(views: [
            row(L10n.t("info.kind"), kindStr),
            row(L10n.t("info.size"), sizeStr),
            row(L10n.t("info.created"), created),
            row(L10n.t("info.modified"), modified),
            row(L10n.t("info.path"), url.path, selectable: true),
        ])
        fields.orientation = .vertical
        fields.alignment = .leading
        fields.spacing = 8
        fields.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        for v in [iconView, name, fields] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
        }
        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            iconView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 64),
            iconView.heightAnchor.constraint(equalToConstant: 64),
            name.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 8),
            name.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            name.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            fields.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 16),
            fields.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            fields.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            fields.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -16),
        ])
        return container
    }

    private static func row(_ title: String, _ value: String, selectable: Bool = false) -> NSView {
        let key = NSTextField(labelWithString: title)
        key.font = .systemFont(ofSize: 11)
        key.textColor = .secondaryLabelColor
        key.setContentHuggingPriority(.required, for: .horizontal)

        let val = selectable
            ? NSTextField(string: value)
            : NSTextField(labelWithString: value)
        val.font = .systemFont(ofSize: 11)
        if selectable {
            val.isEditable = false
            val.isSelectable = true
            val.isBordered = false
            val.drawsBackground = false
        }
        val.lineBreakMode = .byTruncatingMiddle
        val.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [key, val])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .firstBaseline
        return stack
    }
}

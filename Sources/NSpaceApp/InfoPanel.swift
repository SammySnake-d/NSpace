import AppKit
import FileHash
import FolderSize
import UniformTypeIdentifiers

/// 显示简介面板：单选/多选摘要、异步文件夹统计、POSIX 权限、符号链接原身定位、路径复制与按需 MD5/SHA-256 校验和
@MainActor
enum InfoPanel {
    private static var openControllers: [InfoPanelWindowController] = []

    static func show(for url: URL) {
        show(for: [url])
    }

    static func show(for urls: [URL]) {
        guard !urls.isEmpty else { return }
        let controller = InfoPanelWindowController(urls: urls) { closed in
            openControllers.removeAll { $0 === closed }
        }
        openControllers.append(controller)
        controller.showWindow(nil)
    }
}

@MainActor
private final class InfoPanelWindowController: NSWindowController, NSWindowDelegate {
    private let urls: [URL]
    private let onClose: (InfoPanelWindowController) -> Void

    private var sizeTask: Task<Void, Never>?
    private var hashTask: Task<Void, Never>?

    private let sizeValueLabel = NSTextField(labelWithString: "—")
    private let hashButton = NSButton(title: "", target: nil, action: nil)
    private let md5ValueLabel = NSTextField(string: "")
    private let sha256ValueLabel = NSTextField(string: "")
    private let md5CopyButton = NSButton(title: "", target: nil, action: nil)
    private let shaCopyButton = NSButton(title: "", target: nil, action: nil)
    private var hashResultStack: NSStackView?

    init(urls: [URL], onClose: @escaping (InfoPanelWindowController) -> Void) {
        self.urls = urls
        self.onClose = onClose
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 360),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = urls.count == 1
            ? L10n.f("info.title", urls[0].lastPathComponent)
            : L10n.f("info.titleMulti", urls.count)
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        panel.delegate = self
        panel.contentView = urls.count == 1 ? buildSingleView(for: urls[0]) : buildMultiView(for: urls)
        panel.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建 UI，无 xib") }

    func windowWillClose(_ notification: Notification) {
        sizeTask?.cancel()
        hashTask?.cancel()
        onClose(self)
    }

    private func buildSingleView(for url: URL) -> NSView {
        let vals = try? url.resourceValues(forKeys: [
            .contentTypeKey, .fileSizeKey, .creationDateKey,
            .contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey,
        ])
        let isDir = vals?.isDirectory == true
        let isSymlink = vals?.isSymbolicLink == true
        let kindStr: String = if isSymlink {
            L10n.t("info.kind.symlink")
        } else {
            vals?.contentType?.localizedDescription
                ?? (isDir ? L10n.t("kind.folder") : L10n.t("kind.document"))
        }

        if isDir {
            sizeValueLabel.stringValue = L10n.t("info.calculating")
            startFolderSizeCalculation(urls: [url])
        } else {
            sizeValueLabel.stringValue = (vals?.fileSize).map { Formatters.size.string(fromByteCount: Int64($0)) } ?? "—"
        }

        let created = vals?.creationDate.map { Formatters.relativeDate($0) } ?? "—"
        let modified = vals?.contentModificationDate.map { Formatters.relativeDate($0) } ?? "—"
        let permsStr = Self.posixPermissionsString(for: url)

        let iconView = NSImageView()
        iconView.image = NSWorkspace.shared.icon(forFile: url.path)
        iconView.image?.size = NSSize(width: 64, height: 64)

        let name = NSTextField(labelWithString: url.lastPathComponent)
        name.font = .boldSystemFont(ofSize: 13)
        name.alignment = .center
        name.lineBreakMode = .byTruncatingMiddle

        var rows: [NSView] = [
            makeRow(L10n.t("info.kind"), kindStr),
            makeRowView(L10n.t("info.size"), valueView: configureValueLabel(sizeValueLabel)),
            makeRow(L10n.t("info.created"), created),
            makeRow(L10n.t("info.modified"), modified),
            makeRow(L10n.t("info.permissions"), permsStr, selectable: true),
            makePathRow(url.path),
        ]

        if isSymlink, let targetPath = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) {
            rows.append(makeSymlinkRow(targetPath: targetPath, sourceURL: url))
        }

        if !isDir {
            rows.append(makeChecksumSection(for: url))
        }

        return layoutInfoContainer(iconView: iconView, nameLabel: name, rows: rows)
    }

    private func buildMultiView(for urls: [URL]) -> NSView {
        let iconView = NSImageView()
        iconView.image = NSImage.officialSymbol("doc.on.doc", accessibility: L10n.f("info.titleMulti", urls.count))
        iconView.contentTintColor = .secondaryLabelColor

        let name = NSTextField(labelWithString: L10n.f("info.multiSummary", urls.count))
        name.font = .boldSystemFont(ofSize: 13)
        name.alignment = .center

        sizeValueLabel.stringValue = L10n.t("info.calculating")
        startFolderSizeCalculation(urls: urls)

        let parent = urls[0].deletingLastPathComponent().path
        let rows: [NSView] = [
            makeRowView(L10n.t("info.totalSize"), valueView: configureValueLabel(sizeValueLabel)),
            makePathRow(parent),
        ]
        return layoutInfoContainer(iconView: iconView, nameLabel: name, rows: rows)
    }

    private func layoutInfoContainer(iconView: NSImageView, nameLabel: NSTextField, rows: [NSView]) -> NSView {
        let fields = NSStackView(views: rows)
        fields.orientation = .vertical
        fields.alignment = .leading
        fields.spacing = 8

        let container = NSView()
        for v in [iconView, nameLabel, fields] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
        }
        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            iconView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 64),
            iconView.heightAnchor.constraint(equalToConstant: 64),
            nameLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 8),
            nameLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            nameLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            fields.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 16),
            fields.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            fields.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            fields.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -16),
        ])
        return container
    }

    private func configureValueLabel(_ label: NSTextField) -> NSTextField {
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    private func makeRow(_ title: String, _ value: String, selectable: Bool = false) -> NSView {
        let val = selectable ? NSTextField(string: value) : NSTextField(labelWithString: value)
        val.font = .systemFont(ofSize: 11)
        if selectable {
            val.isEditable = false
            val.isSelectable = true
            val.isBordered = false
            val.drawsBackground = false
        }
        val.lineBreakMode = .byTruncatingMiddle
        val.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return makeRowView(title, valueView: val)
    }

    private func makeRowView(_ title: String, valueView: NSView) -> NSView {
        let key = NSTextField(labelWithString: title)
        key.font = .systemFont(ofSize: 11)
        key.textColor = .secondaryLabelColor
        key.setContentHuggingPriority(.required, for: .horizontal)
        key.setContentCompressionResistancePriority(.required, for: .horizontal)

        let stack = NSStackView(views: [key, valueView])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .firstBaseline
        return stack
    }

    private func makePathRow(_ path: String) -> NSView {
        let pathField = NSTextField(string: path)
        pathField.font = .systemFont(ofSize: 11)
        pathField.isEditable = false
        pathField.isSelectable = true
        pathField.isBordered = false
        pathField.drawsBackground = false
        pathField.lineBreakMode = .byTruncatingMiddle
        pathField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let copyBtn = NSButton(title: L10n.t("info.copy"), target: self, action: #selector(copyPathClicked(_:)))
        copyBtn.bezelStyle = .rounded
        copyBtn.controlSize = .small
        copyBtn.font = .systemFont(ofSize: 11)
        copyBtn.toolTip = path

        let valStack = NSStackView(views: [pathField, copyBtn])
        valStack.orientation = .horizontal
        valStack.spacing = 8
        valStack.alignment = .centerY
        return makeRowView(L10n.t("info.path"), valueView: valStack)
    }

    private func makeSymlinkRow(targetPath: String, sourceURL: URL) -> NSView {
        let valLabel = NSTextField(labelWithString: targetPath)
        valLabel.font = .systemFont(ofSize: 11)
        valLabel.lineBreakMode = .byTruncatingMiddle
        valLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let revealBtn = NSButton(title: L10n.t("info.revealTarget"), target: self,
                                 action: #selector(revealSymlinkTarget(_:)))
        revealBtn.bezelStyle = .rounded
        revealBtn.controlSize = .small
        revealBtn.font = .systemFont(ofSize: 11)
        let resolved = sourceURL.resolvingSymlinksInPath()
        revealBtn.toolTip = resolved.path

        let stack = NSStackView(views: [valLabel, revealBtn])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        return makeRowView(L10n.t("info.symlinkTarget"), valueView: stack)
    }

    private func makeChecksumSection(for url: URL) -> NSView {
        hashButton.title = L10n.t("info.computeChecksum")
        hashButton.bezelStyle = .rounded
        hashButton.controlSize = .small
        hashButton.font = .systemFont(ofSize: 11)
        hashButton.target = self
        hashButton.action = #selector(computeChecksumClicked)

        for (field, btn, tag) in [(md5ValueLabel, md5CopyButton, 1), (sha256ValueLabel, shaCopyButton, 2)] {
            field.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            field.isEditable = false
            field.isSelectable = true
            field.isBordered = false
            field.drawsBackground = false
            field.lineBreakMode = .byTruncatingMiddle
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            btn.title = L10n.t("info.copy")
            btn.bezelStyle = .rounded
            btn.controlSize = .small
            btn.font = .systemFont(ofSize: 10)
            btn.tag = tag
            btn.target = self
            btn.action = #selector(copyHashClicked(_:))
        }

        let md5Row = NSStackView(views: [NSTextField(labelWithString: "MD5:"), md5ValueLabel, md5CopyButton])
        let shaRow = NSStackView(views: [NSTextField(labelWithString: "SHA-256:"), sha256ValueLabel, shaCopyButton])
        for row in [md5Row, shaRow] {
            row.orientation = .horizontal
            row.spacing = 4
            row.alignment = .centerY
        }

        let results = NSStackView(views: [md5Row, shaRow])
        results.orientation = .vertical
        results.alignment = .leading
        results.spacing = 4
        results.isHidden = true
        hashResultStack = results

        let box = NSStackView(views: [hashButton, results])
        box.orientation = .vertical
        box.alignment = .leading
        box.spacing = 8
        return box
    }

    private func startFolderSizeCalculation(urls: [URL]) {
        sizeTask?.cancel()
        sizeTask = Task { @MainActor [weak self] in
            var total: Int64 = 0
            for url in urls {
                if Task.isCancelled { return }
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                if isDir {
                    if let dirBytes = try? await Engines.folderSize.size(of: url) {
                        total += dirBytes
                    }
                } else {
                    let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                    total += Int64(bytes)
                }
            }
            if !Task.isCancelled {
                self?.sizeValueLabel.stringValue = Formatters.size.string(fromByteCount: total)
            }
        }
    }

    @objc private func copyPathClicked(_ sender: NSButton) {
        guard let path = sender.toolTip else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        Toast.show(L10n.t("toast.copiedPath"), in: window)
    }

    @objc private func revealSymlinkTarget(_ sender: NSButton) {
        guard let path = sender.toolTip else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @objc private func computeChecksumClicked() {
        guard let url = urls.first else { return }
        hashButton.isEnabled = false
        hashButton.title = L10n.t("info.computing")
        hashTask?.cancel()
        hashTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let digest = try await FileHasher.computeDigests(for: url)
                guard !Task.isCancelled else { return }
                self.md5ValueLabel.stringValue = digest.md5
                self.sha256ValueLabel.stringValue = digest.sha256
                self.hashResultStack?.isHidden = false
                self.hashButton.title = L10n.t("info.checksumReady")
            } catch {
                self.hashButton.isEnabled = true
                self.hashButton.title = L10n.t("info.computeChecksum")
                Toast.show(error.localizedDescription, in: self.window)
            }
        }
    }

    @objc private func copyHashClicked(_ sender: NSButton) {
        let value = sender.tag == 1 ? md5ValueLabel.stringValue : sha256ValueLabel.stringValue
        guard !value.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        Toast.show(L10n.t("toast.copied"), in: window)
    }

    private static func posixPermissionsString(for url: URL) -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mode = (attrs[.posixPermissions] as? NSNumber)?.uint16Value else { return "—" }
        let flags = [(S_IRUSR, "r"), (S_IWUSR, "w"), (S_IXUSR, "x"),
                     (S_IRGRP, "r"), (S_IWGRP, "w"), (S_IXGRP, "x"),
                     (S_IROTH, "r"), (S_IWOTH, "w"), (S_IXOTH, "x")]
        let sym = flags.map { (Int(mode) & Int($0.0)) != 0 ? $0.1 : "-" }.joined()
        return String(format: "%@ (%03o)", sym, mode & 0o777)
    }
}

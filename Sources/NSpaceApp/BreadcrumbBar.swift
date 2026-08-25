import AppKit

/// 面包屑地址栏（自绘，不用 NSPathControl——需要 chevron 弹子目录与后续分段拖放）
/// 布局 4pt 标尺；点击空白或 ⌘L 切换到路径编辑器（PathEditorField）
@MainActor
final class BreadcrumbBar: NSView {
    var onNavigate: ((URL) -> Void)?
    var onBeginEditing: (() -> Void)?

    private let stack = NSStackView()
    private let scroll = NSScrollView()
    private(set) var url: URL = FileManager.default.homeDirectoryForCurrentUser

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        stack.orientation = .horizontal
        stack.spacing = 0
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)

        scroll.documentView = stack
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        scroll.verticalScrollElasticity = .none
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.heightAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建 UI，无 xib") }

    func setURL(_ url: URL) {
        self.url = url
        rebuild()
    }

    /// 点击空白区进入编辑模式（QSpace 惯例）
    override func mouseDown(with event: NSEvent) {
        onBeginEditing?()
    }

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        // 按 path 组件正向构建（严禁 deletingLastPathComponent 向上循环——
        // macOS 对 "/" 返回 "/.."，不等于自身，会造成无限循环+内存爆炸）
        var components: [URL] = [URL(fileURLWithPath: "/")]
        var cursor = URL(fileURLWithPath: "/")
        for part in url.standardizedFileURL.path.split(separator: "/") {
            cursor.appendPathComponent(String(part))
            components.append(cursor)
        }

        for (index, segURL) in components.enumerated() {
            let title = index == 0 ? "/" : segURL.lastPathComponent
            let button = SegmentButton(title: title, url: segURL)
            button.onClick = { [weak self] in self?.onNavigate?(segURL) }
            stack.addArrangedSubview(button)

            if index < components.count - 1 {
                let chevron = ChevronButton(parentURL: segURL)
                chevron.onPick = { [weak self] child in self?.onNavigate?(child) }
                stack.addArrangedSubview(chevron)
            }
        }
        // 尾段也挂 chevron：快速下钻当前目录的子目录
        if let last = components.last {
            let chevron = ChevronButton(parentURL: last)
            chevron.onPick = { [weak self] child in self?.onNavigate?(child) }
            stack.addArrangedSubview(chevron)
        }
        // 滚动到尾部（路径过长优先展示末端）
        DispatchQueue.main.async { [weak self] in
            guard let self, let doc = self.scroll.documentView else { return }
            let w = doc.frame.width
            if w > self.scroll.contentSize.width {
                doc.scroll(NSPoint(x: w - self.scroll.contentSize.width, y: 0))
            }
        }
    }
}

/// 路径分段按钮
@MainActor
private final class SegmentButton: NSButton {
    let url: URL
    var onClick: (() -> Void)?

    init(title: String, url: URL) {
        self.url = url
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .accessoryBarAction
        isBordered = false
        font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        contentTintColor = .labelColor
        target = self
        action = #selector(clicked)
        setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建 UI，无 xib") }

    @objc private func clicked() { onClick?() }
}

/// 分段间箭头：点击弹出该级子目录菜单（懒构建）
@MainActor
private final class ChevronButton: NSButton {
    let parentURL: URL
    var onPick: ((URL) -> Void)?

    init(parentURL: URL) {
        self.parentURL = parentURL
        super.init(frame: .zero)
        title = ""
        image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: L10n.t("addressbar.subfolders"))
        symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        contentTintColor = .tertiaryLabelColor
        isBordered = false
        target = self
        action = #selector(showMenu)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建 UI，无 xib") }

    @objc private func showMenu() {
        let menu = NSMenu()
        let fm = FileManager.default
        let children = (try? fm.contentsOfDirectory(at: parentURL,
                                                    includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                                                    options: [.skipsHiddenFiles])) ?? []
        let dirs = children
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]))
                .map { ($0.isDirectory ?? false) && !($0.isPackage ?? false) } ?? false }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        if dirs.isEmpty {
            let item = menu.addItem(withTitle: L10n.t("addressbar.noSubfolders"), action: nil, keyEquivalent: "")
            item.isEnabled = false
        }
        for dir in dirs {
            let item = menu.addItem(withTitle: dir.lastPathComponent, action: #selector(pick(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = dir
            item.image = NSWorkspace.shared.icon(for: .folder)
            item.image?.size = NSSize(width: 14, height: 14)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 2), in: self)
    }

    @objc private func pick(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        onPick?(url)
    }
}

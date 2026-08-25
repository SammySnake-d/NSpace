import AppKit
import NSpaceContracts

/// 窗格：地址栏（面包屑⟷编辑器互换）+ 内容视图 + 每标签历史。
/// M4 起被 PaneGrid 多实例化；每窗格独立浏览器（QSpace 核心语义）
@MainActor
final class PaneViewController: NSViewController {
    let browser: BrowserState
    let model: DirectoryViewModel
    let listVC: FileListViewController

    /// 位置变化上抛（窗口标题等）
    var onLocationChange: ((URL) -> Void)?

    private let breadcrumb = BreadcrumbBar()
    private let pathEditor = PathEditorField()
    private let addressArea = NSView()

    init(directory: URL) {
        self.browser = BrowserState(url: directory)
        self.model = DirectoryViewModel(directory: directory)
        self.listVC = FileListViewController(model: model)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建 UI，无 xib") }

    override func loadView() {
        breadcrumb.setURL(browser.current)
        breadcrumb.onNavigate = { [weak self] url in self?.navigate(to: url) }
        breadcrumb.onBeginEditing = { [weak self] in self?.beginPathEditing() }
        pathEditor.onCommit = { [weak self] url in
            self?.endPathEditing()
            self?.navigate(to: url)
        }
        pathEditor.onCancel = { [weak self] in self?.endPathEditing() }
        pathEditor.isHidden = true

        addressArea.wantsLayer = true
        for sub in [breadcrumb, pathEditor] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            addressArea.addSubview(sub)
            NSLayoutConstraint.activate([
                sub.topAnchor.constraint(equalTo: addressArea.topAnchor, constant: 2),
                sub.bottomAnchor.constraint(equalTo: addressArea.bottomAnchor, constant: -2),
                sub.leadingAnchor.constraint(equalTo: addressArea.leadingAnchor, constant: 4),
                sub.trailingAnchor.constraint(equalTo: addressArea.trailingAnchor, constant: -4),
            ])
        }

        addChild(listVC)
        listVC.onNavigate = { [weak self] url in self?.navigate(to: url) }

        let separator = NSBox()
        separator.boxType = .separator

        let root = NSView()
        for sub in [addressArea, separator, listVC.view] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(sub)
        }
        NSLayoutConstraint.activate([
            addressArea.topAnchor.constraint(equalTo: root.topAnchor),
            addressArea.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            addressArea.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            addressArea.heightAnchor.constraint(equalToConstant: 30),
            separator.topAnchor.constraint(equalTo: addressArea.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            listVC.view.topAnchor.constraint(equalTo: separator.bottomAnchor),
            listVC.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            listVC.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            listVC.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    // MARK: 导航（唯一入口，历史/地址栏/内容三方同步）

    func navigate(to url: URL) {
        browser.navigate(to: url)
        applyLocation()
    }

    private func applyLocation() {
        model.navigate(to: browser.current)
        breadcrumb.setURL(browser.current)
        onLocationChange?(browser.current)
    }

    // MARK: 地址栏编辑

    func beginPathEditing() {
        pathEditor.isHidden = false
        breadcrumb.isHidden = true
        pathEditor.beginEditing(with: browser.current.path)
    }

    private func endPathEditing() {
        pathEditor.isHidden = true
        breadcrumb.isHidden = false
        view.window?.makeFirstResponder(listVC.view)
    }

    // MARK: 菜单命令（响应链）

    @objc func goBack(_ sender: Any?) {
        if browser.goBack() != nil { applyLocation() }
    }

    @objc func goForward(_ sender: Any?) {
        if browser.goForward() != nil { applyLocation() }
    }

    @objc func goUpFolder(_ sender: Any?) {
        if browser.goUp() != nil { applyLocation() }
    }

    @objc func editPath(_ sender: Any?) {
        beginPathEditing()
    }

    @objc func goHome(_ sender: Any?) {
        navigate(to: FileManager.default.homeDirectoryForCurrentUser)
    }
}

extension PaneViewController: @preconcurrency NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(goBack(_:)): browser.canGoBack
        case #selector(goForward(_:)): browser.canGoForward
        case #selector(goUpFolder(_:)): browser.canGoUp
        default: true
        }
    }
}

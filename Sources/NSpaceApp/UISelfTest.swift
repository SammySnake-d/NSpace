import AppKit
import NSpaceContracts

/// UI 自测通道（NSPACE_UITEST=1 时启动后自动执行；非产品路径，环境变量门控）。
/// 无需辅助功能/录屏权限：场景由程序化驱动，截图走自渲染（cacheDisplay），
/// 断言写 /tmp/nspace-ui/report.txt，完成后按结果 exit(0/1)。
@MainActor
enum UISelfTest {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["NSPACE_UITEST"] == "1"
    }

    private static let outDir = URL(fileURLWithPath: "/tmp/nspace-ui")
    private static var lines: [String] = []
    private static var failed = false

    static func run(delegate: AppDelegate) {
        Task { @MainActor in
            try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            lines = []
            failed = false
            // 等窗口就绪
            try? await Task.sleep(for: .milliseconds(600))
            guard let wc = NSApp.windows.compactMap({ $0.windowController as? MainWindowController }).first,
                  let window = wc.window else {
                record(false, "窗口未创建")
                return finish()
            }

            // 场景0：frame 持久化端到端（SETFRAME 阶段设定并退出；EXPECT 阶段断言恢复）
            let env = ProcessInfo.processInfo.environment
            if let spec = env["NSPACE_UITEST_SETFRAME"] {
                let parts = spec.split(separator: ",").compactMap { Double($0) }
                if parts.count == 2 {
                    window.setFrame(NSRect(x: 120, y: 120, width: parts[0], height: parts[1]),
                                    display: true)
                    // 显式走自管持久化（模拟用户拖拽结束的落盘路径）
                    wc.persistFrameNow()
                    try? await Task.sleep(for: .milliseconds(300))
                    record(true, "SETFRAME \(Int(parts[0]))x\(Int(parts[1])) 已设置并退出")
                }
                return finish()
            }
            if let spec = env["NSPACE_UITEST_EXPECTFRAME"] {
                let parts = spec.split(separator: ",").compactMap { Double($0) }
                if parts.count == 2 {
                    let ok = abs(window.frame.width - parts[0]) < 2 && abs(window.frame.height - parts[1]) < 2
                    record(ok, "frame 持久化恢复: 期望 \(Int(parts[0]))x\(Int(parts[1])) 实得 \(Int(window.frame.width))x\(Int(window.frame.height))")
                }
                // 继续跑常规场景
            }

            capture(window, "00-baseline")
            let baseline = window.frame
            // 抓现行：任何窗口尺寸变化记录调用栈（定位"视图切换改窗口尺寸"的真凶）
            var resizeLogs: [String] = []
            let obs = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: window, queue: .main) { note in
                let f = (note.object as? NSWindow)?.frame ?? .zero
                var dump: [String] = []
                func walk(_ v: NSView, depth: Int) {
                    for c in v.constraints where c.priority == .required
                        && c.relation == .equal && c.secondItem == nil && c.constant > 0
                        && (c.firstAttribute == .width || c.firstAttribute == .height) {
                        var extra = ""
                        if v is NSSplitView {
                            extra = " frame=\(Int(v.frame.width))x\(Int(v.frame.height)) super=\(type(of: v.superview as Any)) tamic=\(v.translatesAutoresizingMaskIntoConstraints) vertical=\((v as! NSSplitView).isVertical) arranged=\((v as! NSSplitView).arrangedSubviews.map { String(describing: type(of: $0)) })"
                        }
                        dump.append("\(String(repeating: " ", count: depth))\(type(of: v)) \(c.firstAttribute == .width ? "W" : "H")==\(Int(c.constant))\(extra)")
                    }
                    for sub in v.subviews { walk(sub, depth: depth + 1) }
                }
                if let cv = (note.object as? NSWindow)?.contentView { walk(cv, depth: 0) }
                resizeLogs.append("RESIZE → \(Int(f.width))x\(Int(f.height))\n必需尺寸约束:\n" + dump.joined(separator: "\n"))
            }
            defer { NotificationCenter.default.removeObserver(obs) }

            // 场景1：视图切换绝不改变窗口尺寸（用户报告 bug 的回归断言）
            let pane = wc.grid.activePane
            for (mode, name) in [(PaneViewMode.icons, "icons"), (.columns, "columns"), (.list, "list")] {
                pane.setViewMode(mode)
                try? await Task.sleep(for: .milliseconds(400))
                let same = window.frame.size == baseline.size
                record(same, "视图切换[\(name)]窗口尺寸不变: \(Int(window.frame.width))x\(Int(window.frame.height))")
                capture(window, "01-viewmode-\(name)")
            }

            // 场景2：五种布局遍历，窗口尺寸不变 + 不崩
            for layout in PaneLayout.allCases {
                wc.grid.apply(layout: layout)
                try? await Task.sleep(for: .milliseconds(350))
                let same = window.frame.size == baseline.size
                record(same, "布局[\(layout)]窗口尺寸不变")
            }
            wc.grid.apply(layout: .dualH)
            capture(window, "02-layout-dualH")

            // 场景3：任务状态窗——空态必须有说明文字，绝非空白
            let progress = ProgressWindowController.shared
            progress.toggleVisible(nil)
            try? await Task.sleep(for: .milliseconds(300))
            let shown = progress.window?.isVisible == true
            record(shown, "任务窗可打开")
            if let pw = progress.window {
                capture(pw, "03-tasks-empty")
                // 空态标签可见性经视图树探测
                let hasVisibleText = viewTree(pw.contentView).contains {
                    ($0 as? NSTextField).map { !$0.isHidden && !$0.stringValue.isEmpty } ?? false
                }
                record(hasVisibleText, "任务窗空态有文字说明（非空白）")
            }
            progress.toggleVisible(nil)

            // 场景4：暂存架——程序化入架（与拖放同一代码路径），牌堆/计数呈现
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("nspace-uitest-\(UUID().uuidString).txt")
            try? Data("x".utf8).write(to: tmp)
            wc.sidebar.model.stash?.add([tmp])
            try? await Task.sleep(for: .milliseconds(500))
            let stashCount = wc.sidebar.model.stash?.items.count ?? 0
            record(stashCount >= 1, "暂存入架成功（\(stashCount) 项）")
            capture(window, "04-stash")
            // 收尾清理：本次测试项 + 历轮残留（uitest 前缀或目标已失效的）——绝不污染用户真实暂存
            if let stash = wc.sidebar.model.stash {
                let junk = stash.items.compactMap { item -> UUID? in
                    guard let url = stash.store.resolve(item) else { return item.id }  // 失效项
                    return url.lastPathComponent.hasPrefix("nspace-uitest-") ? item.id : nil
                }
                stash.remove(ids: junk)
            }
            try? FileManager.default.removeItem(at: tmp)

            // 场景5：聚焦搜索面板开合不崩
            Self.extraDump = resizeLogs
            wc.showSearchGlobal(nil)
            try? await Task.sleep(for: .milliseconds(400))
            record(true, "搜索面板打开未崩溃")
            capture(window, "05-search")
            NSApp.keyWindow?.close()

            finish()
        }
    }

    // MARK: 工具

    private static func record(_ ok: Bool, _ message: String) {
        lines.append("\(ok ? "PASS" : "FAIL") \(message)")
        if !ok { failed = true }
    }

    /// 自渲染截图：无需录屏权限
    private static func capture(_ window: NSWindow, _ name: String) {
        guard let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: outDir.appendingPathComponent("\(name).png"))
    }

    private static func viewTree(_ root: NSView?) -> [NSView] {
        guard let root else { return [] }
        return [root] + root.subviews.flatMap { viewTree($0) }
    }

    static var extraDump: [String] = []

    private static func finish() {
        if !extraDump.isEmpty {
            try? extraDump.joined(separator: "\n\n").data(using: .utf8)?
                .write(to: outDir.appendingPathComponent("resize-stacks.txt"))
        }
        let report = lines.joined(separator: "\n") + "\n"
        try? report.data(using: .utf8)?.write(to: outDir.appendingPathComponent("report.txt"))
        exit(failed ? 1 : 0)
    }
}

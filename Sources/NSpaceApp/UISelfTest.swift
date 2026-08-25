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
                    // 走真实链路：发 didEndLiveResize 通知 → 观察者 persistFrameNow（不许直调捷径，
                    // 否则测不到观察者接线断裂——用户 2026-08-26 质询后加固）
                    NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification,
                                                    object: wc.window)
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

            // ── 场景 M17：自绘甲板 + 全高侧栏 + 工作区迁移（§5 验收门）──────────
            window.contentView?.layoutSubtreeIfNeeded()

            // M17-1：无 NSToolbar（I-10 追踪分隔线体系消亡）
            record(window.toolbar == nil, "无 NSToolbar（甲板自绘）")

            // M17-2：甲板两行高度 40 / 36
            let tabH = wc.deck.tabRow.frame.height
            let toolH = wc.deck.toolbarRow.frame.height
            record(abs(tabH - TopDeckView.tabRowHeight) < 1.5, "甲板标签行高 40（实得 \(Int(tabH))）")
            record(abs(toolH - TopDeckView.toolbarRowHeight) < 1.5, "甲板工具条行高 36（实得 \(Int(toolH))）")

            // M17-3：工作区标签条存在（甲板视图树含 workspaceTabBar）+ 初始单工作区
            let hasTabBar = viewTree(window.contentView).contains { $0 === wc.deck.workspaceTabBar }
            record(hasTabBar, "工作区标签条存在于甲板")
            record(wc.workspaceCount == 1, "初始单工作区（\(wc.workspaceCount)）")

            // M22：版本徽章（无更新态）存在于甲板标签条 + 文字为"v{短版本}"（不带 ↑）
            let badge = wc.deck.versionBadge
            let badgeInTree = viewTree(window.contentView).contains { $0 === badge }
            record(badgeInTree, "版本徽章存在于甲板标签条")
            let badgeLabel = viewTree(badge).compactMap { ($0 as? NSTextField)?.stringValue }
                .first { $0.hasPrefix("v") } ?? ""
            record(badgeLabel == "v\(AppVersion.shortVersion)" && !badgeLabel.contains("↑"),
                   "版本徽章无更新态文字 v\(AppVersion.shortVersion)（实得「\(badgeLabel)」）")
            capture(window, "14-version-badge")

            // M17-4：⌘T 新增 / ⌘W 关闭 增删正确
            wc.newWorkspaceTab(nil)
            try? await Task.sleep(for: .milliseconds(250))
            let afterNew = wc.workspaceCount
            record(afterNew == 2, "⌘T 新建工作区 → 2（实得 \(afterNew)）")
            capture(window, "06-workspaces-2")
            wc.closeActiveWorkspace(nil)
            try? await Task.sleep(for: .milliseconds(250))
            let afterClose = wc.workspaceCount
            record(afterClose == 1, "⌘W 关闭工作区 → 1（实得 \(afterClose)）")

            // M17-5：分割线全高（sidebarColumn.height == contentView.height）
            let contentH = window.contentView?.frame.height ?? 0
            let sideH = wc.sidebarColumnFrame.height
            record(abs(sideH - contentH) < 2,
                   "侧栏列全高贯通：列高 \(Int(sideH)) == 内容高 \(Int(contentH))")

            // M17-6：侧栏折叠/展开 3 轮，窗口尺寸与右列布局不漂移（I-10 回归）
            wc.setSidebar(collapsed: false)  // 从确定的展开态起测
            try? await Task.sleep(for: .milliseconds(250))
            window.contentView?.layoutSubtreeIfNeeded()
            let sizeBefore = window.frame.size
            let contentXBefore = wc.contentColumnFrame.minX
            var driftFree = true
            var driftDetail = ""
            for i in 0..<3 {
                wc.setSidebar(collapsed: true)   // 折叠
                try? await Task.sleep(for: .milliseconds(220))
                window.contentView?.layoutSubtreeIfNeeded()
                wc.setSidebar(collapsed: false)  // 展开回原态
                try? await Task.sleep(for: .milliseconds(220))
                window.contentView?.layoutSubtreeIfNeeded()
                if window.frame.size != sizeBefore { driftFree = false; driftDetail += " [轮\(i) 尺寸\(Int(window.frame.width))x\(Int(window.frame.height))]" }
                if abs(wc.contentColumnFrame.minX - contentXBefore) > 2 { driftFree = false; driftDetail += " [轮\(i) 右列X \(Int(contentXBefore))→\(Int(wc.contentColumnFrame.minX))]" }
            }
            record(driftFree, "折叠/展开 3 轮窗口尺寸与右列布局不漂移\(driftDetail)")

            // M17-7：暂存架 contentGroup 居中（|中心偏移|≤2pt，I-07 回归）
            let tmp2 = FileManager.default.temporaryDirectory
                .appendingPathComponent("nspace-uitest-\(UUID().uuidString).txt")
            try? Data("y".utf8).write(to: tmp2)
            wc.sidebar.model.stash?.add([tmp2])
            try? await Task.sleep(for: .milliseconds(450))
            window.contentView?.layoutSubtreeIfNeeded()
            let offset = wc.sidebar.stashShelfView.contentGroupCenterOffsetX
            record(abs(offset) <= 2, "暂存架 contentGroup 居中（偏移 \(String(format: "%.1f", offset))pt）")
            // §6.3 B2：常态动作条隐藏（hover 才浮出）+ 浮条为 overlay 不入 Auto Layout 主链
            record(wc.sidebar.stashShelfView.actionBarHidden, "暂存架常态动作条隐藏（hover-reveal）")
            record(wc.sidebar.stashShelfView.actionBarIsOverlay, "暂存架浮条为 overlay（不参与主链布局）")
            if let stash = wc.sidebar.model.stash {
                let junk = stash.items.compactMap { item -> UUID? in
                    guard let url = stash.store.resolve(item) else { return item.id }
                    return url.lastPathComponent.hasPrefix("nspace-uitest-") ? item.id : nil
                }
                stash.remove(ids: junk)
            }
            try? FileManager.default.removeItem(at: tmp2)

            // M17 截图矩阵：单/双/四窗格 + 折叠态 + 深/浅外观（人查无裁切/错位）
            wc.setSidebar(collapsed: false)  // 全高侧栏可见（展开态）
            try? await Task.sleep(for: .milliseconds(250))
            for (layout, name) in [(PaneLayout.single, "single"), (.dualH, "dual"), (.quad, "quad")] {
                wc.grid.apply(layout: layout)
                try? await Task.sleep(for: .milliseconds(320))
                window.contentView?.layoutSubtreeIfNeeded()
                capture(window, "10-deck-\(name)")
            }
            wc.grid.apply(layout: .dualH)
            wc.setSidebar(collapsed: true)  // 折叠态截图（红绿灯让位）
            try? await Task.sleep(for: .milliseconds(320))
            window.contentView?.layoutSubtreeIfNeeded()
            capture(window, "11-deck-collapsed")
            wc.setSidebar(collapsed: false)  // 复原展开
            try? await Task.sleep(for: .milliseconds(250))
            // 外观矩阵（展开态，甲板材质深/浅）
            let savedAppearance = NSApp.appearance
            NSApp.appearance = NSAppearance(named: .darkAqua)
            try? await Task.sleep(for: .milliseconds(300))
            window.contentView?.layoutSubtreeIfNeeded()
            capture(window, "12-deck-dark")
            NSApp.appearance = NSAppearance(named: .aqua)
            try? await Task.sleep(for: .milliseconds(300))
            window.contentView?.layoutSubtreeIfNeeded()
            capture(window, "13-deck-light")
            NSApp.appearance = savedAppearance

            // ── 场景 M21：等宽数字列对齐 + 选中药丸渲染（列表模式）───────────────
            wc.grid.apply(layout: .single)
            pane.setViewMode(.list)
            try? await Task.sleep(for: .milliseconds(450))
            window.contentView?.layoutSubtreeIfNeeded()
            capture(window, "20-list-columns")          // 亲查大小/日期列等宽对齐 + 单位灰阶
            let pillVisible = pane.uiTestSelectFirstItemsAndPillVisible(2)
            try? await Task.sleep(for: .milliseconds(250))
            window.contentView?.layoutSubtreeIfNeeded()
            record(pillVisible, "列表选中 → 状态栏 accent 药丸可见")
            capture(window, "21-status-pill")           // 亲查"已选 N 项 · 大小"药丸渲染
            // 深色下再截一张（药丸底 10% accent 明暗重解析核实）
            let savedAppr2 = NSApp.appearance
            NSApp.appearance = NSAppearance(named: .darkAqua)
            try? await Task.sleep(for: .milliseconds(300))
            window.contentView?.layoutSubtreeIfNeeded()
            capture(window, "22-status-pill-dark")
            NSApp.appearance = savedAppr2

            // 场景5：聚焦搜索面板开合不崩 + I-19 隐藏文件开关可见性核实（截面板自身）
            Self.extraDump = resizeLogs
            wc.showSearchGlobal(nil)
            try? await Task.sleep(for: .milliseconds(400))
            record(true, "搜索面板打开未崩溃")
            capture(window, "05-search")
            // I-19：全窗口扫描找面板（UITEST 下拿不到 keyWindow），核实隐藏开关存在且可见
            let panelWin = NSApp.windows.first { w in
                w.isVisible && !(w.windowController is MainWindowController) &&
                viewTree(w.contentView).contains { ($0 as? NSButton)?.title == L10n.t("search.includeHidden") }
            }
            if let panelWin {
                capture(panelWin, "05b-search-panel")
                let hiddenBtn = viewTree(panelWin.contentView).compactMap { $0 as? NSButton }
                    .first { $0.title == L10n.t("search.includeHidden") }
                record(hiddenBtn?.isHiddenOrHasHiddenAncestor == false,
                       "全局搜索面板含「包含隐藏文件」开关且可见")
                panelWin.close()
            } else {
                record(false, "全局搜索面板含「包含隐藏文件」开关且可见")
            }
            try? await Task.sleep(for: .milliseconds(200))

            // 场景6（I-21）：⌘W 分层关闭 + MRU 回退 + 关最后窗口后可重开
            // 6a 分层：设置窗为 key 时 closeTopmost 只关设置窗，不动工作区
            SettingsWindowController.shared.showWindow(nil)
            try? await Task.sleep(for: .milliseconds(300))
            let wsCountBefore = wc.workspaces.count
            (NSApp.delegate as? AppDelegate)?.closeTopmost(nil)
            try? await Task.sleep(for: .milliseconds(200))
            record(SettingsWindowController.shared.window?.isVisible != true, "⌘W 分层：先关顶层设置窗")
            record(wc.workspaces.count == wsCountBefore, "⌘W 分层：主窗工作区未被误关")
            // 6b MRU：新建 2/3 号（3 活跃）→ 切回 1 号 → ⌘W 关活动 1 号 → 应回退到 3 号（上一个活跃）
            window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .milliseconds(200))
            wc.newWorkspaceTab(nil)
            wc.newWorkspaceTab(nil)
            wc.switchWorkspace(to: 0)
            (NSApp.delegate as? AppDelegate)?.closeTopmost(nil)
            try? await Task.sleep(for: .milliseconds(200))
            record(wc.workspaces.activeIndex == 1 && wc.workspaces.count == 2,
                   "⌘W 关闭后 MRU 回退到上一个活跃工作区")
            while wc.workspaces.count > 1 { wc.closeWorkspace(at: wc.workspaces.count - 1) }
            // 6c 重开：关最后窗口 → 模拟 Dock 重新激活必须能开出新窗
            window.performClose(nil)
            try? await Task.sleep(for: .milliseconds(300))
            _ = (NSApp.delegate as? AppDelegate)?
                .applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
            try? await Task.sleep(for: .milliseconds(400))
            let reopened = NSApp.windows.contains { $0.isVisible && $0.windowController is MainWindowController }
            record(reopened, "关最后窗口后 Dock 重开有窗")

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

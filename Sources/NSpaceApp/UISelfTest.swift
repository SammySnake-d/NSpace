import AppKit
import NSpaceContracts
import SearchEngine

/// UI 自测通道（NSPACE_UITEST=1 时启动后自动执行；非产品路径，环境变量门控）。
/// 无需辅助功能/录屏权限：场景由程序化驱动，截图走自渲染（cacheDisplay），
/// 断言写 /tmp/nspace-ui/report.txt，完成后按结果 exit(0/1)。
@MainActor
enum UISelfTest {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["NSPACE_UITEST"] == "1"
    }

    private static let outDir: URL = {
        // 并行 worktree 隔离：NSPACE_UITEST_OUT 指定私有输出目录，避免多实例抢 /tmp/nspace-ui
        if let custom = ProcessInfo.processInfo.environment["NSPACE_UITEST_OUT"], !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        return URL(fileURLWithPath: "/tmp/nspace-ui")
    }()
    private static var lines: [String] = []
    private static var failed = false

    static func run(delegate: AppDelegate) {
        // 看门狗：任何场景 await 悬死（等交互 sheet 之类）→ 180 秒强制收尾报 FAIL，绝不无限挂
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(180))
            record(false, "看门狗触发：自测超时未收尾（最后到达点见 progress.txt）")
            finish()
        }
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
                // I-24b 内容级断言（"铺满"不够，行必须真渲染）：分栏首列行数>0 且表格有可见高度
                if mode == .columns {
                    let unit = pane.activeTab.columnVC?.columns.first
                    let rows = unit?.tableView.numberOfRows ?? -1
                    let tf = unit?.tableView.frame ?? .zero
                    let clipW = unit?.tableView.superview?.frame.width ?? 0
                    record(rows > 0 && tf.height > 20 && clipW > 100,
                           "分栏首列内容真渲染（行数 \(rows)，表格 \(Int(tf.width))x\(Int(tf.height))，视口宽 \(Int(clipW))）")
                    // I-24b 深探针：逐层 frame + 首列自渲染成图（定位内容在哪一层丢失）
                    if let unit, let colVC = pane.activeTab.columnVC {
                        var f: [String] = []
                        var v: NSView? = unit.tableView
                        while let cur = v, cur !== window.contentView {
                            f.append("\(type(of: cur)) \(Int(cur.frame.origin.x)),\(Int(cur.frame.origin.y)) \(Int(cur.frame.width))x\(Int(cur.frame.height)) hidden=\(cur.isHidden) win=\(cur.window != nil)")
                            v = cur.superview
                        }
                        Self.extraDump.append("I-24b 层链（table→contentView）:\n" + f.joined(separator: "\n") + "\ncolVC.view.frame=\(colVC.view.frame)")
                        try? ("I-24b 层链（table→contentView）:\n" + f.joined(separator: "\n")
                              + "\ncolVC.view.frame=\(colVC.view.frame)").data(using: .utf8)?
                            .write(to: outDir.appendingPathComponent("i24b-chain.txt"))
                        if let rep = unit.bitmapImageRepForCachingDisplay(in: unit.bounds) {
                            unit.cacheDisplay(in: unit.bounds, to: rep)
                            try? rep.representation(using: .png, properties: [:])?
                                .write(to: outDir.appendingPathComponent("24-column-unit.png"))
                        }
                    }
                }
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

            // I-22：按钮路径折叠→再点必须真展开（侧栏可见且宽≥160，不是只移分割线）
            wc.toggleSidebar(nil)   // 折叠（与甲板侧栏钮同一路径 deckToggleSidebar→toggleSidebar）
            try? await Task.sleep(for: .milliseconds(220))
            window.contentView?.layoutSubtreeIfNeeded()
            let collapsedOK = wc.sidebarWrap.frame.width < 1 || wc.sidebarWrap.isHidden
            wc.toggleSidebar(nil)   // 再点展开
            try? await Task.sleep(for: .milliseconds(220))
            window.contentView?.layoutSubtreeIfNeeded()
            let reopenedOK = !wc.sidebarWrap.isHidden && wc.sidebarWrap.frame.width >= 160
            record(collapsedOK && reopenedOK,
                   "侧栏按钮折叠后再点可真展开（宽 \(Int(wc.sidebarWrap.frame.width))，hidden=\(wc.sidebarWrap.isHidden)）")

            // I-26：全部六列列头排序真生效——走列头点击同一条 sortDescriptors 链路，双向各验
            let sortListVC = wc.grid.activePane.activeTab.listVC
            for key in SortSpec.Key.allCases {
                sortListVC.tableView.sortDescriptors = [NSSortDescriptor(key: key.rawValue, ascending: false)]
                try? await Task.sleep(for: .milliseconds(120))
                let descOK = sortListVC.model.sort.key == key && sortListVC.model.sort.ascending == false
                sortListVC.tableView.sortDescriptors = [NSSortDescriptor(key: key.rawValue, ascending: true)]
                try? await Task.sleep(for: .milliseconds(120))
                let ascOK = sortListVC.model.sort.key == key && sortListVC.model.sort.ascending == true
                record(descOK && ascOK, "列头排序真生效[\(key.rawValue)]（降/升双向）")
            }
            sortListVC.tableView.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
            try? await Task.sleep(for: .milliseconds(150))

            // I-27：目录"打开"一律 App 内导航（QSpace 语义；沙箱夹具，绝不碰真实文件）
            let openSandbox = FileManager.default.temporaryDirectory
                .appendingPathComponent("nspace-uitest-open-\(UUID().uuidString)", isDirectory: true)
            let openChild = openSandbox.appendingPathComponent("子文件夹", isDirectory: true)
            try? FileManager.default.createDirectory(at: openChild, withIntermediateDirectories: true)
            let openPane = wc.grid.activePane
            openPane.navigate(to: openSandbox)
            try? await Task.sleep(for: .milliseconds(500))
            let openListVC = openPane.activeTab.listVC
            if let idx = openListVC.model.items.firstIndex(where: { $0.name == "子文件夹" }) {
                openListVC.tableView.selectRowIndexes([idx], byExtendingSelection: false)
                openListVC.openSelected(nil)   // 右键"打开"/⌘O 同一路径
                try? await Task.sleep(for: .milliseconds(400))
                let landed = openPane.activeTab.browser.current.standardizedFileURL.path
                record(landed == openChild.standardizedFileURL.path,
                       "目录右键打开=App 内导航（落点 \(landed.hasSuffix("子文件夹") ? "子文件夹" : landed)）")
            } else {
                record(false, "目录右键打开=App 内导航（夹具行未找到）")
            }
            openPane.navigate(to: FileManager.default.homeDirectoryForCurrentUser)
            try? await Task.sleep(for: .milliseconds(300))
            try? FileManager.default.removeItem(at: openSandbox)

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

            // 公开素材脱敏通道（I-35）：NSPACE_UITEST_DEMO=演示目录 → 截图前全部窗格导航到演示数据，
            // 保证 README 等公开截图零真实文件名
            if let demo = env["NSPACE_UITEST_DEMO"], !demo.isEmpty {
                let demoURL = URL(fileURLWithPath: demo)
                wc.grid.apply(layout: .dualH)
                try? await Task.sleep(for: .milliseconds(250))
                for p in wc.grid.visiblePanes { p.navigate(to: demoURL) }
                try? await Task.sleep(for: .milliseconds(600))
            }

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

            // ── 场景 M23：全功能自测矩阵——每条断言验「真实效果」而非「没崩溃」──────────
            // （用户 2026-08-26 教训：折叠断言只查尺寸不查真可见性）。
            // 全插在场景5（搜索）之前：主窗必须存活；关窗/重开在最后的场景6。
            let fs = FileManager.default

            // M23-1：视图模式切换 → 对应内容视图真在窗口层级里且可见（不是只查窗口尺寸）
            wc.grid.apply(layout: .single)
            try? await Task.sleep(for: .milliseconds(300))
            // 复用场景1 的 pane（pool[0]；布局切换后 activePaneIndex 归 0，仍指同一窗格）
            for (mode, name) in [(PaneViewMode.list, "list"), (.icons, "icons"), (.columns, "columns")] {
                pane.setViewMode(mode)
                try? await Task.sleep(for: .milliseconds(350))
                window.contentView?.layoutSubtreeIfNeeded()
                let tab = pane.activeTab
                let v: NSView?
                switch mode {
                case .list: v = tab.listVC.view
                case .icons: v = tab.iconVC?.view
                case .columns: v = tab.columnVC?.view
                }
                let inTree = v.map { view in viewTree(window.contentView).contains { $0 === view } } ?? false
                // 真可见：不隐藏、且真实铺满内容区（宽高均 >1）——分栏坍缩 220×1/696×1 曾在此被抓（已修）
                let visible = (v?.isHiddenOrHasHiddenAncestor == false)
                    && (v?.frame.width ?? 0) > 1 && (v?.frame.height ?? 0) > 1
                record(inTree && visible, "视图模式[\(name)]对应视图真在层级且可见（\(Int(v?.frame.width ?? 0))x\(Int(v?.frame.height ?? 0))）")
            }
            // 分栏视图坍缩 bug 修复的人查证据（单栏布局，列视图须铺满右列而非塌成 220×1/696×1）
            try? await Task.sleep(for: .milliseconds(700))   // 待列异步加载出内容再截图
            window.contentView?.layoutSubtreeIfNeeded()
            capture(window, "23-columns-single")

            // M23-2：布局切换 → 真实呈现对应窗格数（不是只查窗口尺寸）
            wc.grid.apply(layout: .quad)
            try? await Task.sleep(for: .milliseconds(350))
            window.contentView?.layoutSubtreeIfNeeded()
            record(wc.grid.visiblePanes.count == 4, "布局 quad 真实呈现 4 窗格（实得 \(wc.grid.visiblePanes.count)）")
            wc.grid.apply(layout: .single)
            try? await Task.sleep(for: .milliseconds(350))
            record(wc.grid.visiblePanes.count == 1, "布局 single 真实呈现 1 窗格（实得 \(wc.grid.visiblePanes.count)）")

            // 沙箱（真实文件系统 fixture；测完清理，绝不污染用户目录）
            let sandbox = fs.temporaryDirectory
                .appendingPathComponent("nspace-uitest-m23-\(UUID().uuidString)")
            let child = sandbox.appendingPathComponent("child")
            try? fs.createDirectory(at: child, withIntermediateDirectories: true)

            // M23-3：导航后退/前进/上层 → 路径真的变了（不是只看没崩）
            pane.setViewMode(.list)
            try? await Task.sleep(for: .milliseconds(200))
            pane.navigate(to: sandbox)
            try? await Task.sleep(for: .milliseconds(250))
            record(samePath(pane.activeTab.browser.current, sandbox), "导航进入沙箱路径生效")
            pane.navigate(to: child)
            try? await Task.sleep(for: .milliseconds(250))
            record(samePath(pane.activeTab.browser.current, child), "导航进入子目录路径生效")
            pane.goBack(nil)
            try? await Task.sleep(for: .milliseconds(250))
            record(samePath(pane.activeTab.browser.current, sandbox), "导航后退路径真变回上级")
            pane.goForward(nil)
            try? await Task.sleep(for: .milliseconds(250))
            record(samePath(pane.activeTab.browser.current, child), "导航前进路径真恢复")
            pane.goUpFolder(nil)
            try? await Task.sleep(for: .milliseconds(250))
            record(samePath(pane.activeTab.browser.current, sandbox), "导航上层路径真变父级")

            // M23-4：新建窗格标签 → 标签数+1 且活动路径正确；关闭 → 复原
            let tabsBefore = pane.tabs.count
            pane.openNewTab(at: child)
            try? await Task.sleep(for: .milliseconds(250))
            record(pane.tabs.count == tabsBefore + 1 && samePath(pane.activeTab.browser.current, child),
                   "新建窗格标签 → 标签数+1 且活动路径正确（\(pane.tabs.count)）")
            pane.closeActiveTab(nil)
            try? await Task.sleep(for: .milliseconds(200))
            record(pane.tabs.count == tabsBefore, "关闭窗格标签 → 标签数复原（\(pane.tabs.count)）")

            // M23-5：显示隐藏文件开关 → 真实翻转模型状态
            let h0 = pane.activeTab.model.includeHidden
            pane.activeTab.listVC.toggleHiddenFiles(nil)
            try? await Task.sleep(for: .milliseconds(200))
            let h1 = pane.activeTab.model.includeHidden
            pane.activeTab.listVC.toggleHiddenFiles(nil)
            try? await Task.sleep(for: .milliseconds(150))
            let h2 = pane.activeTab.model.includeHidden
            record(h1 == !h0 && h2 == h0, "显示隐藏文件开关真实翻转模型状态")

            // M23-6：显示/隐藏窗格标签栏 → 真实翻转控制状态（净零复原）
            let p0 = PaneViewController.paneTabBarVisible
            wc.togglePaneTabBar(nil)
            try? await Task.sleep(for: .milliseconds(150))
            let p1 = PaneViewController.paneTabBarVisible
            wc.togglePaneTabBar(nil)
            try? await Task.sleep(for: .milliseconds(150))
            let p2 = PaneViewController.paneTabBarVisible
            record(p1 == !p0 && p2 == p0, "窗格标签栏开关真实翻转控制状态")

            // M23-7：新建文件夹/制作副本/重命名/移到废纸篓 → 真跑 coordinator/kernel + 断言文件系统结果
            // 铁律（用户 2026-08-26）：每个 mutating 操作前先过沙箱守卫，守卫失败即跳过（绝不误伤真实文件）
            let folderName = L10n.t("newItem.folder")
            let newFolderURL = sandbox.appendingPathComponent(folderName)
            let gNewFolder = assertSandboxed(sandbox)
            record(gNewFolder, "沙箱守卫: 新建文件夹目标在自建夹具内")
            if gNewFolder { wc.coordinator.newFolder(in: sandbox, revealIn: nil) }
            let created = gNewFolder ? (await pollFS { fs.fileExists(atPath: newFolderURL.path) }) : false
            record(created, "新建文件夹真实落盘（沙箱出现「\(folderName)」）")

            let dupSrc = sandbox.appendingPathComponent("dup-src.txt")
            let gDup = assertSandboxed(dupSrc)
            record(gDup, "沙箱守卫: 制作副本源在自建夹具内")
            if gDup { try? Data("z".utf8).write(to: dupSrc); wc.coordinator.duplicate([dupSrc]) }
            let duped = gDup ? (await pollFS {
                let names = (try? fs.contentsOfDirectory(atPath: sandbox.path)) ?? []
                return names.filter { $0.hasPrefix("dup-src") }.count >= 2
            }) : false
            record(duped, "制作副本真实落盘（dup-src 出现 ≥2 份）")

            let renamedName = "nspace-uitest-renamed-\(UUID().uuidString.prefix(8))"
            let renamedURL = sandbox.appendingPathComponent(renamedName)
            let gRename = assertSandboxed(newFolderURL) && assertSandboxed(renamedURL)
            record(gRename, "沙箱守卫: 重命名目标在自建夹具内")
            if gRename { wc.coordinator.rename(newFolderURL, to: renamedName) { _ in } }
            let renamed = gRename ? (await pollFS {
                !fs.fileExists(atPath: newFolderURL.path) && fs.fileExists(atPath: renamedURL.path)
            }) : false
            record(renamed, "重命名真实生效（新名存在、旧名消失）")

            let gTrash = assertSandboxed(renamedURL)
            record(gTrash, "沙箱守卫: 移废纸篓目标在自建夹具内")
            if gTrash { wc.coordinator.moveToTrash([renamedURL]) }
            let trashed = gTrash ? (await pollFS { !fs.fileExists(atPath: renamedURL.path) }) : false
            record(trashed, "移到废纸篓真实生效（源目录中消失）")
            // 清理落进用户废纸篓的测试项（唯一名，安全）
            let trashDir = fs.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
            if let entries = try? fs.contentsOfDirectory(atPath: trashDir.path) {
                for e in entries where e.hasPrefix(renamedName) {
                    try? fs.removeItem(at: trashDir.appendingPathComponent(e))
                }
            }

            // M23-8：拷贝路径 → 断言剪贴板内容（走 listVC.copyPath → coordinator.copyPaths 真实链）
            pane.activeTab.model.reload()
            _ = await pollFS { pane.activeTab.model.items.contains { $0.url.lastPathComponent == "dup-src.txt" } }
            window.contentView?.layoutSubtreeIfNeeded()
            let srcItem = pane.activeTab.model.items.first { $0.url.lastPathComponent == "dup-src.txt" }
            if let srcItem {
                pane.activeTab.listVC.select(urls: [srcItem.url])
                try? await Task.sleep(for: .milliseconds(150))
                pane.activeTab.listVC.copyPath(nil)
                try? await Task.sleep(for: .milliseconds(150))
                let clip = NSPasteboard.general.string(forType: .string)
                record(clip == srcItem.url.path, "拷贝路径 → 剪贴板内容正确")
            } else {
                record(false, "拷贝路径 → 剪贴板内容正确")
            }

            // M23-9：右键菜单构建 → items 数 + 关键项存在 + enabled 状态诚实随选中态
            let selection = pane.activeTab.listVC.selectedItems
            let listVC = pane.activeTab.listVC
            let itemMenu = FileContextMenuBuilder.menu(selection: selection, directory: sandbox, target: listVC)
            let actions = Set(itemMenu.items.compactMap { $0.action })
            let keyActions: [Selector] = [
                #selector(FileListViewController.openSelected(_:)),
                #selector(FileListViewController.copyItems(_:)),
                #selector(FileListViewController.cutItems(_:)),
                #selector(FileListViewController.pasteItems(_:)),
                #selector(FileListViewController.copyPath(_:)),
                #selector(FileListViewController.renameSelected(_:)),
                #selector(FileListViewController.duplicateItems(_:)),
                #selector(FileListViewController.moveToTrash(_:)),
                #selector(FileListViewController.compressItems(_:)),
                #selector(FileListViewController.newFolderHere(_:)),
                #selector(FileListViewController.getInfo(_:)),
                #selector(FileListViewController.openInTerminal(_:)),
            ]
            record(keyActions.allSatisfy { actions.contains($0) },
                   "条目右键菜单含全部关键项（\(itemMenu.items.count) 项）")
            // 诚实禁用：纯文本选中 → 无「解压」项
            record(!actions.contains(#selector(FileListViewController.extractItems(_:))),
                   "条目右键菜单诚实禁用：非归档选中无「解压」项")
            // enabled 随选中态：有选中 → 复制项 enabled；清选中 → disabled
            let copyItem = itemMenu.items.first { $0.action == #selector(FileListViewController.copyItems(_:)) }
            let enabledWithSel = copyItem.map { listVC.validateMenuItem($0) } ?? false
            listVC.select(urls: [])
            try? await Task.sleep(for: .milliseconds(120))
            let disabledNoSel = copyItem.map { listVC.validateMenuItem($0) == false } ?? false
            record(enabledWithSel && disabledNoSel, "右键「复制」enabled 随选中态正确切换")
            // 空白区目录菜单
            let dirMenu = FileContextMenuBuilder.menu(selection: [], directory: sandbox, target: listVC)
            let dirActions = Set(dirMenu.items.compactMap { $0.action })
            let dirKey = dirActions.contains(#selector(FileListViewController.newFolderHere(_:)))
                && dirActions.contains(#selector(FileListViewController.pasteItems(_:)))
                && dirActions.contains(#selector(FileListViewController.getInfo(_:)))
                && dirActions.contains(#selector(FileListViewController.openInTerminal(_:)))
            record(dirMenu.items.count == 5 && dirKey, "空白区目录菜单项数=5 且含新建/粘贴/简介/终端")

            // M23-10：任务窗手动开关 → 真的可见/隐藏（不是只看没崩）；复用场景3 的 progress
            progress.toggleVisible(nil)
            try? await Task.sleep(for: .milliseconds(250))
            record(progress.window?.isVisible == true, "任务窗手动开→可见")
            progress.toggleVisible(nil)
            try? await Task.sleep(for: .milliseconds(250))
            record(progress.window?.isVisible != true, "任务窗手动关→隐藏")

            // M23-11：⌘I 信息面板 → 窗口出现又能关
            let infoBase = sandbox.lastPathComponent
            listVC.getInfo(nil)   // 无选中 → 对当前目录（沙箱）
            try? await Task.sleep(for: .milliseconds(300))
            let infoWin = NSApp.windows.first { w in
                w.isVisible && !(w.windowController is MainWindowController) && w.title.contains(infoBase)
            }
            record(infoWin != nil, "显示简介面板出现")
            if let infoWin {
                infoWin.performClose(nil)
                try? await Task.sleep(for: .milliseconds(250))
                record(infoWin.isVisible == false, "显示简介面板可关闭")
            } else {
                record(false, "显示简介面板可关闭")
            }
            window.makeKeyAndOrderFront(nil)

            // M23-12：设置各插件页 makeView → 无约束歧义 + 关键控件存在
            for page in SettingsPages.extraPages {
                let v = page.makeView()
                let host = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 460))
                v.frame = host.bounds
                v.autoresizingMask = [.width, .height]
                host.addSubview(v)
                host.layoutSubtreeIfNeeded()
                let tree = viewTree(v)
                let ambiguous = tree.contains { $0.hasAmbiguousLayout }
                let hasControl = tree.contains { $0 is NSButton || $0 is NSPopUpButton || $0 is NSSlider }
                record(!ambiguous && hasControl,
                       "设置页[\(page.pageTitleKey)] makeView 无约束歧义且含关键控件")
            }

            // M23-13：快捷键注册表默认绑定读取正确（外部化配置真源）
            let dispGlobal = KeyBindings.display("searchGlobal")
            let dispInfo = KeyBindings.display("getInfo")
            record(dispGlobal == "⇧⌘F" && dispInfo == "⌘I",
                   "快捷键注册表默认绑定读取正确（全局搜索⇧⌘F/简介⌘I）")

            // M23-14：侧栏含书签分组且种子书签行呈现（异步播种，短轮询）
            var bmCount = 0
            for _ in 0..<20 {
                if let g = wc.sidebar.model.groups.first(where: { $0.kind == .bookmarks }),
                   g.children.count >= 1 { bmCount = g.children.count; break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            record(bmCount >= 1, "侧栏含书签分组且种子书签行 ≥1（\(bmCount)）")

            // M23-15（I-31）：搜索结果行右键菜单 → items>0 + 含「拷贝路径」+ 执行后剪贴板==该路径（真实效果）
            // 经真实链注入 onReveal/onStash（wc.showSearchGlobal → SearchPanelController.show）后，
            // 用真实 fixture URL 构造 SearchHit 并调 menu(for:)——验搜索上下文裁剪后的菜单确有内容与可用拷贝路径。
            wc.showSearchGlobal(nil)
            try? await Task.sleep(for: .milliseconds(200))
            let searchHit = SearchHit(url: sandbox, name: sandbox.lastPathComponent,
                                      isDirectory: true, size: nil, modified: nil, contentTypeID: nil)
            let searchMenu = SearchPanelController.shared.menu(for: searchHit)
            let copyPathTitle = L10n.t("menu.copyPath")
            let hasCopyPath = searchMenu.items.contains { $0.title == copyPathTitle }
            record(searchMenu.items.count > 0 && hasCopyPath,
                   "搜索结果右键菜单 items>0 且含「拷贝路径」（\(searchMenu.items.count) 项）")
            // 定位链 + 暂存架可达 → 对应项存在（FG-1：可达才出）
            record(searchMenu.items.contains { $0.title == L10n.t("search.reveal") }
                   && searchMenu.items.contains { $0.title == L10n.t("search.addToStash") }
                   && searchMenu.items.contains { $0.title == L10n.t("menu.getInfo") },
                   "搜索结果右键菜单含定位/加入暂存架/显示简介（可达项齐全）")
            // 真实效果：执行「拷贝路径」→ 剪贴板内容 == 该 URL 路径
            if let cp = searchMenu.items.first(where: { $0.title == copyPathTitle }) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("SENTINEL-\(UUID().uuidString)", forType: .string)
                _ = cp.target?.perform(cp.action, with: cp)
                try? await Task.sleep(for: .milliseconds(120))
                let clip = NSPasteboard.general.string(forType: .string)
                record(clip == sandbox.path, "搜索结果右键「拷贝路径」→ 剪贴板内容==该路径")
            } else {
                record(false, "搜索结果右键「拷贝路径」→ 剪贴板内容==该路径")
            }
            window.makeKeyAndOrderFront(nil)   // 主窗夺 key → 面板 resignKey 自动关闭
            try? await Task.sleep(for: .milliseconds(200))

            // M23 收尾：复原确定性初态 + 清沙箱（绝不污染用户目录/暂存/书签）
            listVC.select(urls: [])
            pane.navigate(to: fs.homeDirectoryForCurrentUser)
            pane.setViewMode(.list)
            wc.grid.apply(layout: .single)
            try? await Task.sleep(for: .milliseconds(200))
            try? fs.removeItem(at: sandbox)
            window.makeKeyAndOrderFront(nil)

            // ── I-30：⌘L 进入路径编辑后首键必须【一次生效】——字符落定 + 补全首键即触发（延迟到事务外）──
            // 根因：controlTextDidChange 内同步 complete(nil) 会被文本变更事务吞掉首键补全 popup
            // （首键无反应，需第二键才浮出）。修复：complete(nil) 延迟到下一 runloop。
            window.makeKeyAndOrderFront(nil)
            wc.grid.apply(layout: .single)
            try? await Task.sleep(for: .milliseconds(250))
            do {
                let dpane = wc.grid.activePane
                let editor = dpane.uiTestPathEditor
                // 焦点复位到内容区（模拟按 ⌘L 前初态），再走真实 beginPathEditing（净种子便于精确断言）
                window.makeFirstResponder(dpane.focusTarget)
                try? await Task.sleep(for: .milliseconds(120))
                dpane.uiTestBeginPathEditing(seed: "")
                try? await Task.sleep(for: .milliseconds(20))
                let seed = editor.stringValue
                let fe = editor.currentEditor() as? NSTextView
                // 首键 '/'：真实 field editor keyDown（interpretKeyEvents→insertText→controlTextDidChange→complete）
                if let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil,
                        characters: "/", charactersIgnoringModifiers: "/",
                        isARepeat: false, keyCode: 44), let fe {
                    fe.keyDown(with: ev)
                }
                try? await Task.sleep(for: .milliseconds(80))   // 等延迟补全跑完
                let afterFirst = editor.stringValue
                // 真实效果三连：①字符一次落定 ②首键即算出补全候选 ③补全在文本变更事务【之外】触发（修复本体）
                record(afterFirst == seed + "/",
                       "I-30 ⌘L 后首键 '/' 字符一次生效（stringValue=「\(afterFirst)」）")
                record(editor.uiTestLastCompletionCount > 0,
                       "I-30 首键即触发补全候选（数=\(editor.uiTestLastCompletionCount)）")
                record(editor.uiTestCompletionWasDeferred,
                       "I-30 补全在文本变更事务之外触发（首键 popup 不被吞）")
                editor.stringValue = ""
                window.makeFirstResponder(nil)
                try? await Task.sleep(for: .milliseconds(100))
            }
            // ── 场景 I-32：多选删除(移废纸篓)后选中清空——三视图同验 ─────────────────
            // 用户报告 bug：多选删除后高亮"跟随"到顶上来的新行（语义应为选中清空）。
            // 铁律：只动自建 nspace-uitest-i32-* 夹具（assertSandboxed 守卫）；经 coordinator 走真实
            //       移废纸篓；等终态后断言视图层选中真清空（原始 selectedRowIndexes 空）且状态栏无"已选"药丸。
            let i32TrashDir = fs.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
            for (i32Mode, i32Name) in [(PaneViewMode.list, "list"), (.icons, "icons"), (.columns, "columns")] {
                let token = String(UUID().uuidString.prefix(8))
                let i32box = fs.temporaryDirectory
                    .appendingPathComponent("nspace-uitest-i32-\(token)", isDirectory: true)
                let fileNames = ["nspace-uitest-i32-\(token)-a.txt",
                                 "nspace-uitest-i32-\(token)-b.txt",
                                 "nspace-uitest-i32-\(token)-c.txt"]
                try? fs.createDirectory(at: i32box, withIntermediateDirectories: true)
                for n in fileNames { try? Data("x".utf8).write(to: i32box.appendingPathComponent(n)) }

                pane.setViewMode(i32Mode)
                try? await Task.sleep(for: .milliseconds(250))
                pane.navigate(to: i32box)
                // 焦点视图可见项数（分栏读焦点列，列/图标读共享 model）
                @MainActor func i32VisibleCount() -> Int {
                    i32Mode == .columns ? (pane.activeTab.columnVC?.statusCounts.items ?? 0)
                                        : pane.activeTab.model.items.count
                }
                _ = await pollFS { i32VisibleCount() >= 3 }
                try? await Task.sleep(for: .milliseconds(200))

                // 选中前两项，走各视图真实选中链；victims 取自"已载入的真实项 URL"（避免 symlink 路径不匹配）
                let victims: [URL]
                switch i32Mode {
                case .list, .icons:
                    victims = Array(pane.activeTab.model.items.prefix(2)).map(\.url)
                case .columns:
                    victims = Array((pane.activeTab.columnVC?.uiTestFocusedColumnItemURLs ?? []).prefix(2))
                }
                switch i32Mode {
                case .list:    pane.activeTab.listVC.select(urls: victims)
                case .icons:   pane.activeTab.iconVC?.select(urls: victims)
                case .columns: pane.activeTab.columnVC?.uiTestSelectInFocusedColumn(victims)
                }
                try? await Task.sleep(for: .milliseconds(200))
                let selBefore = pane.currentSelectionCount

                let gI32 = victims.allSatisfy { assertSandboxed($0) }
                record(gI32, "沙箱守卫[\(i32Name)]: I-32 移废纸篓目标在自建夹具内")
                if gI32 { wc.coordinator.moveToTrash(victims) }   // 真实 coordinator → kernel → trash
                // 等终态：焦点视图只剩 1 项（reloadLists 在 kernel 终态后触发）
                let settled = gI32 ? (await pollFS { i32VisibleCount() == 1 }) : false
                try? await Task.sleep(for: .milliseconds(150))

                // 断言：视图层原始选中数=0（不是"漂移"到新行）且状态栏无"已选"药丸
                let rawSel: Int
                switch i32Mode {
                case .list:    rawSel = pane.activeTab.listVC.tableView.selectedRowIndexes.count
                case .icons:   rawSel = pane.activeTab.iconVC?.uiTestRawSelectionCount ?? -1
                case .columns: rawSel = pane.activeTab.columnVC?.uiTestFocusedRawSelectionCount ?? -1
                }
                let pillVisible = pane.uiTestRefreshAndSelectionPillVisible()
                record(selBefore == 2 && settled && rawSel == 0 && !pillVisible,
                       "多选删除后选中清空[\(i32Name)]（删前选\(selBefore)、终态余1=\(settled)、删后选\(rawSel)、药丸=\(pillVisible)）")

                // 清理：夹具目录 + 落入废纸篓的唯一名测试件（token 唯一，安全）
                switch i32Mode {
                case .list:    pane.activeTab.listVC.select(urls: [])
                case .icons:   pane.activeTab.iconVC?.select(urls: [])
                case .columns: pane.activeTab.columnVC?.select(urls: [])
                }
                pane.navigate(to: fs.homeDirectoryForCurrentUser)
                try? await Task.sleep(for: .milliseconds(150))
                try? fs.removeItem(at: i32box)
                if let entries = try? fs.contentsOfDirectory(atPath: i32TrashDir.path) {
                    for e in entries where e.hasPrefix("nspace-uitest-i32-\(token)") {
                        try? fs.removeItem(at: i32TrashDir.appendingPathComponent(e))
                    }
                }
            }
            pane.setViewMode(.list)
            pane.navigate(to: fs.homeDirectoryForCurrentUser)
            try? await Task.sleep(for: .milliseconds(150))
            window.makeKeyAndOrderFront(nil)

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

            // M24：全局热键注册 + 呼出/隐藏切换真生效（测完恢复原偏好）
            let hadHotkey = UserDefaults.standard.string(forKey: GlobalHotkey.prefKey)
            GlobalHotkey.set(mods: [.control, .option, .shift], keyCode: 79, display: "⌃⌥⇧F18")
            record(GlobalHotkey.apply(), "全局热键注册成功（⌃⌥⇧F18 测试组合）")
            GlobalHotkey.toggle()   // 前台 → 隐藏
            try? await Task.sleep(for: .milliseconds(350))
            let hiddenOK = NSApp.isHidden || !NSApp.isActive
            GlobalHotkey.toggle()   // 后台 → 呼出置顶
            try? await Task.sleep(for: .milliseconds(450))
            let backOK = NSApp.windows.contains { $0.isVisible && $0.windowController is MainWindowController }
            record(hiddenOK && backOK, "全局热键呼出/隐藏切换真生效（隐藏=\(hiddenOK) 回归=\(backOK)）")
            if let hadHotkey { UserDefaults.standard.set(hadHotkey, forKey: GlobalHotkey.prefKey) }
            else { UserDefaults.standard.removeObject(forKey: GlobalHotkey.prefKey) }
            GlobalHotkey.apply()
            window.makeKeyAndOrderFront(nil)
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
        // 实时进度落盘（挂死可定位最后到达点；finish 前 record 只在内存，挂死即全丢——I-35 后补仪器）
        try? (lines.joined(separator: "\n") + "\n").data(using: .utf8)?
            .write(to: outDir.appendingPathComponent("progress.txt"))
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

    /// 文件系统结果轮询（coordinator/kernel 操作异步落盘）：条件满足即返回，超时返回末次判定
    private static func pollFS(_ tries: Int = 30, _ cond: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<tries {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return cond()
    }

    /// 路径等价（消解 /var⟷/private/var 符号链接差异）
    private static func samePath(_ a: URL, _ b: URL) -> Bool {
        a.resolvingSymlinksInPath().standardizedFileURL.path
            == b.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// 沙箱守卫（用户铁律 2026-08-26）：任何测试可变文件操作的目标必须在自建临时夹具内
    /// （temporaryDirectory 下），防误伤用户真实文件。守卫失败即跳过该 mutating 操作。
    private static func assertSandboxed(_ url: URL) -> Bool {
        let sandboxRoot = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        return url.resolvingSymlinksInPath().path.hasPrefix(sandboxRoot)
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

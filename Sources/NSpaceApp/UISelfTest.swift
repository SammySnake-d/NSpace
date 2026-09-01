import AppKit
import NSpaceContracts
import SearchEngine
import Frecency

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
            // harness 前置：强制本 App 成为前台活动应用，令随后需真键窗焦点的场景（I-30 字段编辑补全
            // popup）能显示，不被其他前台 App 抢焦造成补全 popup 嵌套 runloop 挂死（并行/后台启动加固）。
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .milliseconds(200))

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
            // 窗口尺寸持久化根因锁（用户报告"更新后尺寸回默认"）：关闭 macOS 原生窗口恢复，
            // 仅自管 windowFrame 键权威——跨版本更新不与被系统作废的 savedState 竞争
            record(window.isRestorable == false,
                   "窗口尺寸自管恢复：isRestorable=false（不与 macOS 原生恢复竞争）")
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
            let child2 = sandbox.appendingPathComponent("child2")   // I-39：区分"选中驱动"与"历史兜底"
            try? fs.createDirectory(at: child2, withIntermediateDirectories: true)

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

            // I-39：⌘↑ 自动选中来源子目录，⌘↓ 与其互逆（选中驱动优先；无选中回退历史直接子级）
            var upSelectsChild = false
            for _ in 0..<10 {
                if pane.activeTab.listVC.selectedURLs.contains(where: { samePath($0, child) }) {
                    upSelectsChild = true
                    break
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            record(upSelectsChild, "I-39 ⌘↑ 上层后自动选中来源子目录")
            // 反假绿设计：历史里是 child，故意改选 child2——若 ⌘↓ 偷走历史兜底会落 child，
            // 落 child2 才证明"进入所选"主路径真实生效（收敛终态断言曾在此假绿）
            pane.activeTab.listVC.select(urls: [child2])
            pane.goDownFolder(nil)
            try? await Task.sleep(for: .milliseconds(250))
            record(samePath(pane.activeTab.browser.current, child2),
                   "I-39 ⌘↓ 进入所选文件夹（选中驱动，非历史兜底）")
            pane.goUpFolder(nil)
            try? await Task.sleep(for: .milliseconds(250))
            pane.activeTab.listVC.select(urls: [])   // 清选中 → 验"无选中回退历史直接子级"兜底
            pane.goDownFolder(nil)
            try? await Task.sleep(for: .milliseconds(250))
            record(samePath(pane.activeTab.browser.current, child2), "I-39 ⌘↓ 无选中时回退最近历史直接子级")
            pane.goUpFolder(nil)   // 复位到沙箱（后续场景假设从此出发）
            try? await Task.sleep(for: .milliseconds(250))
            // 守卫真值：禁用态 ⌘↓ 泄漏到表视图时必须被吞（原 bug=NSTableView 默认跳选行）——
            // 直发按键事件给表（绕过菜单），选中与路径都不得变
            let guardTable = pane.activeTab.listVC.tableView
            let selBefore = guardTable.selectedRowIndexes
            let pathBefore = pane.activeTab.browser.current
            if let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
                                         timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                         characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}",
                                         isARepeat: false, keyCode: 125) {
                guardTable.keyDown(with: ev)
            }
            record(guardTable.selectedRowIndexes == selBefore
                   && samePath(pane.activeTab.browser.current, pathBefore),
                   "I-39 ⌘↓ 落表视图被吞不跳选（守卫真实生效）")

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
            // I-38/I-40：结果流不打断选中 + 局部按根近排序 + 路径列常驻（夹具直驱 appendResults 真链）
            let sp = SearchPanelController.shared
            func fixtureHit(_ rel: String) -> SearchHit {
                let u = URL(fileURLWithPath: sandbox.path + "/" + rel)
                return SearchHit(url: u, name: u.lastPathComponent, isDirectory: false,
                                 size: 1, modified: nil, contentTypeID: nil)
            }
            sp.uiTestReset(root: sandbox)
            sp.uiTestAppend([fixtureHit("deep/deeper/c.txt"), fixtureHit("a.txt"), fixtureHit("deep/b.txt")])
            let wantOrder = ["a.txt", "deep/b.txt", "deep/deeper/c.txt"].map { sandbox.path + "/" + $0 }
            record(sp.uiTestResultPaths == wantOrder, "I-40 局部搜索按离根近者优先排序（直接子级最先）")
            record(sp.uiTestFirstRowPathCellText?.isEmpty == false, "I-40 结果表常驻路径列实渲染父目录路径")
            sp.uiTestSelectRow(1)                    // 选中 deep/b.txt
            sp.uiTestAppend([fixtureHit("aa.txt")])  // 新批次插到更前 → 行号位移
            // 同层字典序 tiebreaker 全序核验（a.txt 先于 aa.txt——比较器反向/被删则此断言必红）
            let wantOrder2 = ["a.txt", "aa.txt", "deep/b.txt", "deep/deeper/c.txt"]
                .map { sandbox.path + "/" + $0 }
            record(sp.uiTestResultPaths == wantOrder2, "I-40 同层字典序（a.txt 先于 aa.txt，全序核验）")
            record(sp.uiTestSelectedPath == sandbox.path + "/deep/b.txt",
                   "I-38 流式新批次到达后选中项不丢不漂（行号位移仍锁同一 URL）")
            // 符号链接口径：Spotlight 通道回报解析后路径（/var→/private/var）——
            // 根为未解析表示时命中仍须按深度排序，不得整体沉底（评审实锤的主通道失效缺陷）
            let resolvedBase = sandbox.resolvingSymlinksInPath().path
            if resolvedBase != sandbox.path {
                sp.uiTestAppend([SearchHit(url: URL(fileURLWithPath: resolvedBase + "/deep/rr.txt"),
                                           name: "rr.txt", isDirectory: false,
                                           size: 1, modified: nil, contentTypeID: nil)])
                let rrIndex = sp.uiTestResultPaths.firstIndex { $0.hasSuffix("/deep/rr.txt") }
                record(rrIndex != nil && rrIndex! < sp.uiTestResultPaths.count - 1
                       && sp.uiTestResultPaths.last?.hasSuffix("/deep/deeper/c.txt") == true,
                       "I-40 解析路径口径命中仍按深度排序（符号链接根不失效）")
            } else {
                record(true, "I-40 解析路径口径命中仍按深度排序（符号链接根不失效）")   // 本机无符号链接差异：口径天然一致
            }
            // 根外命中沉底（.max 兜底分支真值）：sandbox 之外的路径必须排最后
            sp.uiTestAppend([SearchHit(url: URL(fileURLWithPath: fs.temporaryDirectory.path
                                                    + "/nspace-uitest-outside.txt"),
                                       name: "nspace-uitest-outside.txt", isDirectory: false,
                                       size: 1, modified: nil, contentTypeID: nil)])
            record(sp.uiTestResultPaths.last?.hasSuffix("/nspace-uitest-outside.txt") == true,
                   "I-40 根外命中沉底为最后一行")
            // I-42 卡死回归：大结果集流式累积必须 O(n) 且不卡（旧 `hits+visible` 每批全量重拼=O(n²)→卡死）。
            // 灌 maxResults 条（分 50/批模拟流），限时完成 + 达上限显示截断提示。
            sp.uiTestReset(root: nil)
            let big = SearchLimits.maxResults
            let t0 = Date()
            var fed = 0
            while fed < big {
                let n = min(50, big - fed)
                sp.uiTestAppend((0..<n).map { j in
                    SearchHit(url: URL(fileURLWithPath: "/tmp/nspace-i42/\(fed + j).txt"),
                              name: "\(fed + j).txt", isDirectory: false, size: 1, modified: nil, contentTypeID: nil)
                })
                fed += n
            }
            let elapsed = Date().timeIntervalSince(t0)
            record(elapsed < 3.0 && sp.uiTestResultCount == big,
                   "I-42 大结果流式累积 O(n) 不卡（灌 \(big) 条耗时 \(String(format: "%.2f", elapsed))s < 3s）")
            record(sp.uiTestTruncationVisible, "I-42 达结果上限显示「仅显示前 N 条」截断提示")
            sp.uiTestReset(root: nil)
            // 实景截图：路径列 + 根近排序 + 选中保持（人眼终审用）
            if let spWin = NSApp.windows.first(where: { w in
                w.isVisible && !(w.windowController is MainWindowController) &&
                viewTree(w.contentView).contains { ($0 as? NSButton)?.title == L10n.t("search.includeHidden") }
            }) {
                capture(spWin, "05c-search-path-rank")
            }
            sp.uiTestReset(root: nil)

            // ── I-34：大小列窄宽不折行（单行 + 头部截断，防 22pt 行高装不下 attributed 串）──
            let i34cell = TextCellView(identifier: .init("i34-size"))
            i34cell.configureSize(value: "151.4", unit: "MB", alignment: .right)
            record(i34cell.textField?.usesSingleLineMode == true
                   && i34cell.textField?.lineBreakMode == .byTruncatingHead,
                   "I-34 大小列单行不折行（usesSingleLineMode + 头部截断）")

            // ── M27 冲突体验：三按钮 + 「应用到此文件夹」checkbox 的按文件夹批量决议 + 自绘面板截图 ──
            // 夹具跨两个文件夹：folderA 两条冲突、folderB 一条 → checkbox 批量一次只作用一个文件夹。
            let folderA = sandbox.appendingPathComponent("conflictA")
            let folderB = sandbox.appendingPathComponent("conflictB")
            try? fs.createDirectory(at: folderA, withIntermediateDirectories: true)
            try? fs.createDirectory(at: folderB, withIntermediateDirectories: true)
            let a1 = folderA.appendingPathComponent("a1.txt")
            let a2 = folderA.appendingPathComponent("a2.txt")
            let b1 = folderB.appendingPathComponent("b1.txt")
            for u in [a1, a2, b1] { try? Data("x".utf8).write(to: u) }
            let conflicts = [a1, a2, b1].map { FileConflict(source: $0, existing: $0, bothDirectories: false) }
            // 勾 checkbox 批量：第一次「替换」只定 folderA 两条，folderB 仍待决（面板须再现一次）
            var m1 = ConflictDecisionMachine(conflicts)
            m1.decideCurrentFolder(.replace)
            let folderAOnly = m1.decisions.count == 2
                && { if case .replace = m1.decisions[a1] { return true }; return false }()
                && { if case .replace = m1.decisions[a2] { return true }; return false }()
                && m1.decisions[b1] == nil && !m1.isComplete
            record(folderAOnly, "M27 checkbox 批量一次只作用一个文件夹（folderA 2 条已定，folderB 仍待决）")
            // 面板出现次数 == 文件夹数（3 文件夹 → 3 次；这里 2 文件夹 → 2 次）
            record(ConflictSheet.uiTestFolderPromptCount(conflicts, batchDecision: .replace) == 2,
                   "M27 逐文件夹批量：面板出现次数==文件夹数（2 文件夹→2 次）")
            // 未勾 checkbox 只决当前一条
            var m2 = ConflictDecisionMachine(conflicts)
            m2.decideCurrent(.replace)
            record(m2.decisions.count == 1, "M27 未勾 checkbox 只决议当前一条（逐条推进）")
            // 取消 → nil（契约：整体放弃）
            record(ConflictSheet.uiTestResolve(conflicts, actions: [("cancel", nil)]) == nil,
                   "M27 取消 → 决议返回 nil（整体放弃）")
            // 自绘面板：三按钮右对齐（取消/合并/替换）+ 左下 checkbox；文件冲突「合并」禁用。
            // headless captureView 出图骨架（控件 cell 需窗口服务才完整渲染，真机预览见 NSPACE_CONFLICT_PREVIEW）。
            if let cpanel = ConflictSheet.uiTestPanel(conflicts, host: window) {
                if let cv = cpanel.contentView { captureView(cv, "32-conflict-sheet") }
                let tree = viewTree(cpanel.contentView)
                let btns = tree.compactMap { ($0 as? NSButton)?.title }
                let hasThree = btns.contains(L10n.t("conflict.cancel"))
                    && btns.contains(L10n.t("conflict.replace")) && btns.contains(L10n.t("conflict.merge"))
                let hasCheck = tree.contains { ($0 as? NSButton)?.title == L10n.t("conflict.applyFolder") }
                let mergeBtn = tree.first { ($0 as? NSButton)?.title == L10n.t("conflict.merge") } as? NSButton
                record(hasThree && hasCheck, "M27 面板三按钮(取消/合并/替换)+左下「应用到此文件夹」checkbox（自绘真渲染）")
                record(mergeBtn?.isEnabled == false, "M27 文件冲突「合并」禁用（仅文件夹可合并，诚实不可点）")
            } else {
                record(false, "M27 面板三按钮(取消/合并/替换)+左下「应用到此文件夹」checkbox（自绘真渲染）")
                record(false, "M27 文件冲突「合并」禁用（仅文件夹可合并，诚实不可点）")
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

            // NSPACE_UITEST_ONLY=i37：聚焦跑 I-37（跳过 I-30/I-32——二者依赖 NSTextView.complete()
            // 补全 popup 的嵌套事件循环，在非前台/无 key 窗的 headless 环境会阻塞）。仅调试 I-37 时用。
            let focusI37 = env["NSPACE_UITEST_ONLY"] == "i37"
            if !focusI37 {
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
                dpane.uiTestEndPathEditing()   // 编排收尾：退出编辑态，恢复面包屑（截图不被编辑框遮盖）
                try? await Task.sleep(for: .milliseconds(150))
                editor.stringValue = ""
                window.makeFirstResponder(nil)
                try? await Task.sleep(for: .milliseconds(100))
            }
            // ── I-53：地址栏三连 bug 修复回归（用户 2026-08-31 报告）─────────────────
            // bug1: ⌘L 呼出后文本未全选（旧=moveToEndOfLine）→ 输入/粘贴追加而非替换
            // bug2: 粘贴文件路径（.apk 等）Enter 只抖动不跳转；应导航父目录+选中该文件
            // bug3: 编辑框失焦不复位——删除清空/点击他处后地址栏永远空白
            do {
                let dpane = wc.grid.activePane
                let editor = dpane.uiTestPathEditor
                let i53box = fs.temporaryDirectory
                    .appendingPathComponent("nspace-uitest-i53-\(UUID().uuidString)", isDirectory: true)
                let i53file = i53box.appendingPathComponent("app-release.apk")
                try? fs.createDirectory(at: i53box, withIntermediateDirectories: true)
                try? Data("PK".utf8).write(to: i53file)
                defer { try? fs.removeItem(at: i53box) }
                let g53 = assertSandboxed(i53box) && assertSandboxed(i53file)
                record(g53, "沙箱守卫[I-53]: 地址栏回归夹具在自建临时目录内")
                if g53 {
                    func pressEnter() {
                        guard let fe = editor.currentEditor() as? NSTextView,
                              let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                      timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil,
                                      characters: "\r", charactersIgnoringModifiers: "\r",
                                      isARepeat: false, keyCode: 36) else { return }
                        fe.keyDown(with: ev)
                    }
                    // bug1: ⌘L 全选
                    window.makeFirstResponder(dpane.focusTarget)
                    try? await Task.sleep(for: .milliseconds(120))
                    dpane.uiTestBeginPathEditing(seed: "/tmp/some/path")
                    try? await Task.sleep(for: .milliseconds(30))
                    let selRange = (editor.currentEditor() as? NSTextView)?.selectedRange ?? NSRange(location: 0, length: 0)
                    let fullLen = editor.stringValue.count
                    record(selRange.location == 0 && selRange.length == fullLen && fullLen > 0,
                           "I-53 ⌘L 呼出后地址栏文本全选（选区 0..<\(selRange.length) 全长 \(fullLen)）")
                    dpane.uiTestEndPathEditing()
                    try? await Task.sleep(for: .milliseconds(100))
                    // bug2a: Enter 文件夹路径 → 导航
                    window.makeFirstResponder(dpane.focusTarget)
                    try? await Task.sleep(for: .milliseconds(120))
                    dpane.uiTestBeginPathEditing(seed: i53box.path)
                    try? await Task.sleep(for: .milliseconds(30))
                    pressEnter()
                    try? await Task.sleep(for: .milliseconds(300))
                    record(samePath(dpane.uiTestCurrentURL, i53box),
                           "I-53 Enter 文件夹路径 → 导航到该文件夹（实得 \(dpane.uiTestCurrentURL.lastPathComponent)）")
                    record(!dpane.uiTestIsPathEditing, "I-53 文件夹导航后编辑框已退出（面包屑回显）")
                    // bug2b: Enter 文件路径（.apk）→ 导航父目录并选中该文件
                    window.makeFirstResponder(dpane.focusTarget)
                    try? await Task.sleep(for: .milliseconds(120))
                    dpane.uiTestBeginPathEditing(seed: i53file.path)
                    try? await Task.sleep(for: .milliseconds(30))
                    pressEnter()
                    var revealOK = false
                    for _ in 0..<15 {
                        try? await Task.sleep(for: .milliseconds(100))
                        if samePath(dpane.uiTestCurrentURL, i53box),
                           dpane.activeTab.listVC.selectedURLs.contains(where: { samePath($0, i53file) }) {
                            revealOK = true; break
                        }
                    }
                    record(revealOK,
                           "I-53 Enter 文件路径（.apk）→ 导航父目录并选中该文件（dir=\(samePath(dpane.uiTestCurrentURL, i53box)) sel=\(dpane.activeTab.listVC.selectedURLs.count)）")
                    record(!dpane.uiTestIsPathEditing, "I-53 文件 reveal 后编辑框已退出（面包屑回显）")
                    // bug2c: 不存在路径 → 不跳转
                    let beforeInvalid = dpane.uiTestCurrentURL
                    window.makeFirstResponder(dpane.focusTarget)
                    try? await Task.sleep(for: .milliseconds(120))
                    dpane.uiTestBeginPathEditing(seed: "/definitely/not/exists/\(UUID().uuidString)")
                    try? await Task.sleep(for: .milliseconds(30))
                    pressEnter()
                    try? await Task.sleep(for: .milliseconds(200))
                    record(samePath(dpane.uiTestCurrentURL, beforeInvalid),
                           "I-53 Enter 不存在路径 → 不跳转（仍在原目录）")
                    // bug3: 清空地址栏失焦 → 编辑框退出，面包屑回显
                    dpane.uiTestBeginPathEditing(seed: "")
                    try? await Task.sleep(for: .milliseconds(30))
                    dpane.uiTestBlurPathEditor()
                    try? await Task.sleep(for: .milliseconds(200))
                    record(!dpane.uiTestIsPathEditing,
                           "I-53 清空地址栏后失焦 → 编辑框退出，面包屑回显当前路径")
                    // bug3b: 编辑中（删空）触发导航（退回上级/刷新，不经失焦）→ 编辑框仍须退出、面包屑回显。
                    // 用户报"退回上级再重进也不恢复"——这条路径不失焦，只靠失焦复位覆盖不到，须由导航强制收编辑态。
                    dpane.navigate(to: i53box)
                    try? await Task.sleep(for: .milliseconds(200))
                    dpane.uiTestBeginPathEditing(seed: "")   // 进编辑并删空
                    try? await Task.sleep(for: .milliseconds(30))
                    dpane.goUpFolder(nil)                     // 编辑中退回上级（键盘/菜单路径，不失焦）
                    try? await Task.sleep(for: .milliseconds(250))
                    record(!dpane.uiTestIsPathEditing && samePath(dpane.uiTestCurrentURL, i53box.deletingLastPathComponent()),
                           "I-53 编辑中退回上级 → 编辑框退出+面包屑回显新目录（editing=\(dpane.uiTestIsPathEditing)）")
                    if dpane.uiTestIsPathEditing { dpane.uiTestEndPathEditing() }
                    window.makeFirstResponder(dpane.focusTarget)
                    try? await Task.sleep(for: .milliseconds(100))
                }
                // 卫生：夹具即将删除，别把窗格留在已删目录里污染后续场景
                dpane.navigate(to: fs.homeDirectoryForCurrentUser)
                try? await Task.sleep(for: .milliseconds(150))
            }
            // ── I-54：地址栏路径解析矩阵——剪贴板真实形态 × 目标类型（纯解析层，零时序依赖）────────
            // 用户报"有时候粘贴文件夹也无法跳转，很奇怪"：不是玄学。旧实现只
            // trimmingCharacters(in: .whitespaces)（**该字符集不含 \n**）+ expandingTildeInPath，
            // 于是"尾随换行 / file:// URL / percent 编码 / 成对引号 / 反斜杠转义"这五类真实剪贴板
            // 形态统统落进 shake 分支——粘同一个文件夹，从 Finder 复制的能跳、从终端复制的不能跳。
            // 这里直接断言 resolve()：端到端导航跑 26 条既慢又测不到解析层，纯函数断言才盯得住真因。
            do {
                let dpane = wc.grid.activePane
                let editor = dpane.uiTestPathEditor
                let box = fs.temporaryDirectory
                    .appendingPathComponent("nspace-uitest-i54-\(UUID().uuidString)", isDirectory: true)
                let folder = box.appendingPathComponent("My Folder", isDirectory: true)
                let cnFolder = box.appendingPathComponent("中文 目录", isDirectory: true)
                let quoteDir = box.appendingPathComponent("weird'quote", isDirectory: true)
                let slashDir = box.appendingPathComponent("back\\slash", isDirectory: true)
                let pkgDir = box.appendingPathComponent("Test.app", isDirectory: true)
                let apk = folder.appendingPathComponent("app-release.apk")
                let linkDir = box.appendingPathComponent("linkdir")
                let linkFile = box.appendingPathComponent("linkfile")
                for dir in [folder, cnFolder, quoteDir, slashDir, pkgDir] {
                    try? fs.createDirectory(at: dir, withIntermediateDirectories: true)
                }
                try? Data("PK".utf8).write(to: apk)
                try? fs.createSymbolicLink(at: linkDir, withDestinationURL: folder)
                try? fs.createSymbolicLink(at: linkFile, withDestinationURL: apk)
                defer { if assertSandboxed(box) { try? fs.removeItem(at: box) } }
                let g54 = assertSandboxed(box) && assertSandboxed(apk)
                record(g54, "沙箱守卫[I-54]: 路径解析矩阵夹具在自建临时目录内")
                if g54 {
                    // 相对路径用例要拿"当前浏览目录"当基准，先把窗格开到夹具里
                    dpane.navigate(to: box)
                    _ = await pollFS { samePath(dpane.uiTestCurrentURL, box) }

                    func norm(_ url: URL) -> String {
                        url.resolvingSymlinksInPath().standardizedFileURL.path
                    }
                    func describe(_ r: PathEditorField.Resolution) -> String {
                        switch r {
                        case .directory(let u): return "DIR:\(norm(u))"
                        case .file(let u):      return "FILE:\(norm(u))"
                        case .unreadable:       return "DENIED"
                        case .notFound:         return "NONE"
                        case .empty:            return "EMPTY"
                        }
                    }
                    func dirOf(_ u: URL) -> String { "DIR:\(norm(u))" }
                    func fileOf(_ u: URL) -> String { "FILE:\(norm(u))" }
                    func pct(_ p: String) -> String {
                        p.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? p
                    }

                    // 维度：剪贴板形态 × 目标类型 × 特殊名字 × 负例
                    let matrix: [(String, String, String)] = [
                        // ① 形态 × 文件夹
                        ("plain 目录",         folder.path,                    dirOf(folder)),
                        ("尾随换行",           folder.path + "\n",             dirOf(folder)),
                        ("尾随 CRLF",          folder.path + "\r\n",           dirOf(folder)),
                        ("前后空格",           "  " + folder.path + "  ",      dirOf(folder)),
                        ("尾随斜杠",           folder.path + "/",              dirOf(folder)),
                        ("file:// 未编码",     "file://" + folder.path,        dirOf(folder)),
                        ("file:// percent",    "file://" + pct(folder.path),   dirOf(folder)),
                        ("双引号包裹",         "\"" + folder.path + "\"",      dirOf(folder)),
                        ("单引号包裹",         "'" + folder.path + "'",        dirOf(folder)),
                        ("反斜杠转义空格",     folder.path.replacingOccurrences(of: " ", with: "\\ "), dirOf(folder)),
                        ("中文目录",           cnFolder.path,                  dirOf(cnFolder)),
                        ("中文 file:// 编码",  "file://" + pct(cnFolder.path), dirOf(cnFolder)),
                        ("相对路径",           "My Folder",                    dirOf(folder)),
                        ("./ 相对",            "./My Folder",                  dirOf(folder)),
                        ("~ 家目录",           "~",                            dirOf(fs.homeDirectoryForCurrentUser)),
                        ("根目录",             "/",                            "DIR:/"),
                        // ② 形态 × 文件（用户点名的 .apk）
                        ("apk 文件",           apk.path,                       fileOf(apk)),
                        ("apk 尾随换行",       apk.path + "\n",                fileOf(apk)),
                        ("apk file:// 编码",   "file://" + pct(apk.path),      fileOf(apk)),
                        // ③ 目标类型：包按 Finder 语义当文件（选中而非钻进去）、符号链接跟随
                        (".app 包当文件处理",  pkgDir.path,                    fileOf(pkgDir)),
                        ("符号链接→目录",      linkDir.path,                   dirOf(folder)),
                        ("符号链接→文件",      linkFile.path,                  fileOf(apk)),
                        // ④ 名字里真含特殊字符不被"聪明"解析误伤（靠原样候选排最前保证）
                        ("名字真含单引号",     quoteDir.path,                  dirOf(quoteDir)),
                        ("名字真含反斜杠",     slashDir.path,                  dirOf(slashDir)),
                        // ⑤ 负例
                        ("不存在的路径",       box.appendingPathComponent("nope-\(UUID().uuidString)").path, "NONE"),
                        ("纯空白",             "   \n  ",                      "EMPTY"),
                    ]
                    var bad: [String] = []
                    for (label, input, expect) in matrix {
                        let got = describe(editor.resolve(input))
                        if got != expect { bad.append("\(label)→\(got)≠\(expect)") }
                    }
                    record(bad.isEmpty,
                           "I-54 路径解析矩阵 \(matrix.count - bad.count)/\(matrix.count) 通过"
                           + (bad.isEmpty ? "" : "；失败：\(bad.joined(separator: " | "))"))

                    // ⑥ 端到端：⌘L 全选后"粘贴"须整段替换而非追加。
                    // 不碰 NSPasteboard.general——那是用户真实剪贴板，测试无权污染（沿用沙箱铁律）；
                    // insertText(替换选区) 正是 ⌘V 在全选态下走的同一条 field editor 路径。
                    window.makeFirstResponder(dpane.focusTarget)
                    try? await Task.sleep(for: .milliseconds(120))
                    dpane.uiTestBeginPathEditing(seed: "/some/old/path/that/must/be/replaced")
                    try? await Task.sleep(for: .milliseconds(30))
                    if let fe = editor.currentEditor() as? NSTextView {
                        fe.insertText(apk.path, replacementRange: fe.selectedRange)
                    }
                    try? await Task.sleep(for: .milliseconds(30))
                    record(dpane.uiTestPathEditorText == apk.path,
                           "I-54 ⌘L 全选后粘贴整段替换（非追加）（得「\(dpane.uiTestPathEditorText)」）")

                    // ⑦ 端到端：无效路径 Enter → 不跳转 + 内联红字提示（不弹窗）
                    let beforeInvalid = dpane.uiTestCurrentURL
                    dpane.uiTestBeginPathEditing(seed: "/definitely/not/exists/\(UUID().uuidString)")
                    try? await Task.sleep(for: .milliseconds(30))
                    if let fe = editor.currentEditor() as? NSTextView,
                       let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil,
                               characters: "\r", charactersIgnoringModifiers: "\r",
                               isARepeat: false, keyCode: 36) {
                        fe.keyDown(with: ev)
                    }
                    try? await Task.sleep(for: .milliseconds(150))
                    record(samePath(dpane.uiTestCurrentURL, beforeInvalid)
                             && dpane.uiTestPathHintVisible
                             && dpane.uiTestIsPathEditing,
                           "I-54 无效路径 → 不跳转 + 内联提示 + 留在输入框可就地改（未跳转=\(samePath(dpane.uiTestCurrentURL, beforeInvalid)) 提示=\(dpane.uiTestPathHintVisible)「\(dpane.uiTestPathHintText)」 仍在编辑=\(dpane.uiTestIsPathEditing)）")

                    // ⑧ 用户点名的第三条路径：删空地址栏后按 ⌘R 刷新 —— 编辑框须退出、面包屑回显。
                    // 刷新既不失焦也不导航，前两条复位路径都盖不到。这里走 sendAction 的**真实响应链**
                    // （而非直调探针）：菜单项挂的是 #selector(FileListViewController.refresh(_:))，
                    // 地址栏持有焦点时链上根本到不了那三个内容 VC，必须由 PaneViewController 同名实现接住。
                    dpane.uiTestBeginPathEditing(seed: "")
                    try? await Task.sleep(for: .milliseconds(30))
                    // tryToPerform 直接走本窗口的响应链（从 firstResponder 起），
                    // 避开 NSApp.sendAction 依赖 keyWindow 在无头环境可能为 nil 的干扰
                    let refreshDelivered = window.tryToPerform(
                        #selector(FileListViewController.refresh(_:)), with: nil)
                    try? await Task.sleep(for: .milliseconds(200))
                    record(refreshDelivered && !dpane.uiTestIsPathEditing,
                           "I-54 删空地址栏后 ⌘R 刷新 → 菜单动作经响应链送达且编辑框退出（送达=\(refreshDelivered) 仍在编辑=\(dpane.uiTestIsPathEditing)）")

                    // ⑨ 粘贴「就在当前目录里」的文件：revealFile 会 navigate 到同一个目录，
                    // 若那条路径被当成"目录没变"短路掉，pending 选中就永远落不了地（选中数 0）。
                    dpane.setViewMode(.list)
                    dpane.navigate(to: folder)
                    _ = await pollFS { samePath(dpane.uiTestCurrentURL, folder) }
                    dpane.activeTab.listVC.tableView.deselectAll(nil)
                    try? await Task.sleep(for: .milliseconds(120))
                    dpane.uiTestBeginPathEditing(seed: apk.path)
                    try? await Task.sleep(for: .milliseconds(30))
                    if let fe = editor.currentEditor() as? NSTextView,
                       let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil,
                               characters: "\r", charactersIgnoringModifiers: "\r",
                               isARepeat: false, keyCode: 36) {
                        fe.keyDown(with: ev)
                    }
                    var sameDirOK = false
                    for _ in 0..<15 {
                        try? await Task.sleep(for: .milliseconds(100))
                        if samePath(dpane.uiTestCurrentURL, folder),
                           dpane.activeTab.listVC.selectedURLs.contains(where: { samePath($0, apk) }) {
                            sameDirOK = true; break
                        }
                    }
                    record(sameDirOK,
                           "I-54 粘贴当前目录内的文件 → 原地选中（不因'目录没变'丢掉 pending 选中，选中数=\(dpane.activeTab.listVC.selectedURLs.count)）")

                    // ⑩ 粘贴不弹补全 popup。这是 bug2 的第二个真因：popup 会接管事件循环并吃掉紧随其后的
                    // 那次 Enter（去采纳候选而非导航）。PathCompleter 只列目录——粘文件夹路径必有候选必弹，
                    // 粘 .apk 没候选不弹，正对上用户说的"有时候"。手敲字符仍须照常补全（I-30 契约）。
                    if dpane.uiTestIsPathEditing { dpane.uiTestEndPathEditing() }
                    dpane.navigate(to: box)
                    _ = await pollFS { samePath(dpane.uiTestCurrentURL, box) }
                    window.makeFirstResponder(dpane.focusTarget)
                    try? await Task.sleep(for: .milliseconds(120))
                    dpane.uiTestBeginPathEditing(seed: "")
                    try? await Task.sleep(for: .milliseconds(30))
                    let trigBefore = editor.uiTestCompletionTriggerCount
                    if let fe = editor.currentEditor() as? NSTextView {
                        fe.insertText(folder.path, replacementRange: fe.selectedRange)   // 模拟 ⌘V
                    }
                    try? await Task.sleep(for: .milliseconds(150))
                    let afterPaste = editor.uiTestCompletionTriggerCount
                    if let fe = editor.currentEditor() as? NSTextView {
                        let end = (editor.stringValue as NSString).length
                        fe.insertText("/", replacementRange: NSRange(location: end, length: 0))  // 手敲一个字符
                    }
                    try? await Task.sleep(for: .milliseconds(180))
                    let afterType = editor.uiTestCompletionTriggerCount
                    record(afterPaste == trigBefore && afterType > afterPaste,
                           "I-54 粘贴不弹补全(否则 popup 吞掉 Enter)、手敲仍补全（粘贴 \(trigBefore)→\(afterPaste)，敲键 →\(afterType)）")

                    // ⑪ 补全候选必须是"填进 charRange 的那一段"。PathComplete 契约返回整条绝对路径，
                    // AppKit 只替换末段词——原样返回则采纳任一候选就拼成 /a/b//a/b/c/，再 Enter 必 shake。
                    if let fe = editor.currentEditor() as? NSTextView {
                        let probe = box.path + "/My" as NSString
                        editor.stringValue = probe as String
                        let lastSlash = probe.range(of: "/", options: .backwards).location
                        let partial = NSRange(location: lastSlash + 1, length: probe.length - lastSlash - 1)
                        var idx = -1
                        let cands = editor.control(editor, textView: fe, completions: [],
                                                   forPartialWordRange: partial, indexOfSelectedItem: &idx)
                        let segments = !cands.isEmpty && cands.allSatisfy { !$0.hasPrefix("/") }
                        let assembled = probe.substring(to: partial.location) + (cands.first ?? "")
                        let assembledExists = fs.fileExists(atPath: (assembled as NSString).standardizingPath)
                        record(segments && assembledExists,
                               "I-54 补全候选是末段而非整条绝对路径（候选=\(cands.first ?? "无") 采纳后拼出=\(((assembled as NSString).lastPathComponent)) 存在=\(assembledExists)）")
                    }

                    if dpane.uiTestIsPathEditing { dpane.uiTestEndPathEditing() }
                    window.makeFirstResponder(dpane.focusTarget)
                }
                // 卫生：夹具即将删除，窗格先撤回家目录
                dpane.navigate(to: fs.homeDirectoryForCurrentUser)
                try? await Task.sleep(for: .milliseconds(150))
            }
            // ── I-55：地址栏与定位的边界修复（大小写 / 隐藏文件 / pending 作废 / Tab 补全 / 拖放）─────
            do {
                let dpane = wc.grid.activePane
                let editor = dpane.uiTestPathEditor
                let box = fs.temporaryDirectory
                    .appendingPathComponent("nspace-uitest-i55-\(UUID().uuidString)", isDirectory: true)
                let mixed = box.appendingPathComponent("MixedCase", isDirectory: true)
                let target = mixed.appendingPathComponent("TARGET.txt")
                let hidden = mixed.appendingPathComponent(".secret.txt")
                let tabA = box.appendingPathComponent("CompletionShared-Alpha", isDirectory: true)
                let tabB = box.appendingPathComponent("CompletionShared-Beta", isDirectory: true)
                for dir in [mixed, tabA, tabB] {
                    try? fs.createDirectory(at: dir, withIntermediateDirectories: true)
                }
                try? Data("x".utf8).write(to: target)
                try? Data("x".utf8).write(to: hidden)
                defer { if assertSandboxed(box) { try? fs.removeItem(at: box) } }
                let g55 = assertSandboxed(box) && assertSandboxed(target)
                record(g55, "沙箱守卫[I-55]: 边界修复夹具在自建临时目录内")
                if g55 {
                    dpane.setViewMode(.list)
                    dpane.navigate(to: box)
                    _ = await pollFS { samePath(dpane.uiTestCurrentURL, box) }
                    let hiddenWas = dpane.uiTestIncludeHidden

                    // ① 大小写与盘上不一致的路径仍能定位。APFS/HFS+ 默认大小写不敏感：
                    // fileExists 能过，但定位用的是精确字符串比较 → 跳到父目录却什么都不选中（静默失败）。
                    let wrongCase = mixed.deletingLastPathComponent()
                        .appendingPathComponent("mixedcase").appendingPathComponent("target.TXT")
                    dpane.uiTestBeginPathEditing(seed: wrongCase.path)
                    try? await Task.sleep(for: .milliseconds(30))
                    pressReturn(in: editor, window: window)
                    var caseOK = false
                    for _ in 0..<20 {
                        try? await Task.sleep(for: .milliseconds(100))
                        if samePath(dpane.uiTestCurrentURL, mixed),
                           dpane.activeTab.listVC.selectedURLs.contains(where: { samePath($0, target) }) {
                            caseOK = true; break
                        }
                    }
                    record(caseOK,
                           "I-55 大小写与盘上不一致的路径仍能定位选中（选中数=\(dpane.activeTab.listVC.selectedURLs.count)）")

                    // ② 隐藏文件被点名时自动打开"显示隐藏"，否则只跳父目录不选中，用户眼里就是"没反应"
                    dpane.uiTestBeginPathEditing(seed: hidden.path)
                    try? await Task.sleep(for: .milliseconds(30))
                    pressReturn(in: editor, window: window)
                    var hiddenOK = false
                    for _ in 0..<20 {
                        try? await Task.sleep(for: .milliseconds(100))
                        if dpane.uiTestIncludeHidden,
                           dpane.activeTab.listVC.selectedURLs.contains(where: { samePath($0, hidden) }) {
                            hiddenOK = true; break
                        }
                    }
                    record(hiddenOK,
                           "I-55 粘贴隐藏文件路径 → 自动显示隐藏文件并选中（显示隐藏=\(dpane.uiTestIncludeHidden)）")

                    // ③ 落空的 pending 定位必须就地作废，不能留成日后的"幽灵跳选"定时炸弹
                    let ghost = mixed.appendingPathComponent("never-exists-\(UUID().uuidString).txt")
                    dpane.navigate(to: mixed)
                    _ = await pollFS { samePath(dpane.uiTestCurrentURL, mixed) }
                    dpane.reveal(ghost)
                    _ = await pollFS { !dpane.activeTab.listVC.uiTestHasPendingReveal }
                    record(!dpane.activeTab.listVC.uiTestHasPendingReveal,
                           "I-55 目标目录已载入仍找不到目标 → pending 定位作废（不留幽灵跳选）")

                    // ④ Tab 在路径框里是补全，不是切走焦点（旧行为：移焦 → 失焦复位 → 输入内容一起蒸发）
                    dpane.navigate(to: box)
                    _ = await pollFS { samePath(dpane.uiTestCurrentURL, box) }
                    let stem = box.appendingPathComponent("CompletionShared-A").path
                    dpane.uiTestBeginPathEditing(seed: stem)
                    try? await Task.sleep(for: .milliseconds(30))
                    if let fe = editor.currentEditor() as? NSTextView,
                       let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil,
                               characters: "\t", charactersIgnoringModifiers: "\t",
                               isARepeat: false, keyCode: 48) {
                        fe.keyDown(with: ev)
                    }
                    try? await Task.sleep(for: .milliseconds(150))
                    let tabbed = dpane.uiTestPathEditorText
                    record(dpane.uiTestIsPathEditing && samePath(URL(fileURLWithPath: tabbed), tabA),
                           "I-55 Tab 补全唯一候选且仍留在输入框（得「\((tabbed as NSString).lastPathComponent)」编辑中=\(dpane.uiTestIsPathEditing)）")
                    // 多候选时补到最长公共前缀（纯函数，确定性）
                    let lcp = PathEditorField.longestCommonPrefix([tabA.path + "/", tabB.path + "/"])
                    record(lcp == box.path + "/CompletionShared-",
                           "I-55 多候选 Tab 补到最长公共前缀（得「\((lcp as NSString).lastPathComponent)」）")

                    // ⑤ 地址栏接受文件投放（Finder 前往面板与各家浏览器地址栏皆支持）。
                    // 走私有 NSPasteboard 驱动真实落地逻辑——绝不碰用户真实剪贴板（沿用沙箱铁律）。
                    record(editor.registeredDraggedTypes.contains(.fileURL),
                           "I-55 地址栏已注册 fileURL 拖放类型")
                    let pb = NSPasteboard(name: NSPasteboard.Name("nspace.uitest.i55.\(UUID().uuidString)"))
                    pb.clearContents()
                    pb.writeObjects([target as NSURL])
                    dpane.uiTestBeginPathEditing(seed: "")
                    try? await Task.sleep(for: .milliseconds(30))
                    let dropped = editor.acceptDrop(from: pb)
                    try? await Task.sleep(for: .milliseconds(60))
                    record(dropped && samePath(URL(fileURLWithPath: dpane.uiTestPathEditorText), target),
                           "I-55 拖文件到地址栏 → 填成其路径（落地=\(dropped) 得「\((dpane.uiTestPathEditorText as NSString).lastPathComponent)」）")
                    pb.releaseGlobally()

                    // ⑥ 补全候选与「charRange 之前那段」对不上时必须不给候选（不弹 popup），
                    // 不能把整条绝对路径丢回去让 AppKit 替换末段——那会拼出 ~/Users/me/ 这种垃圾。
                    // 典型触发：输入 `~`，候选却是展开后的 /Users/xxx/。
                    // 先退出编辑态再探：编辑中 stringValue 与 field editor 的同步时机不确定，
                    // 会让这条断言测的是 AppKit 的同步行为而不是我们的裁剪逻辑。
                    if dpane.uiTestIsPathEditing { dpane.uiTestEndPathEditing() }
                    try? await Task.sleep(for: .milliseconds(80))
                    do {
                        let probe = NSTextView()   // control(_:textView:...) 不读它，仅满足签名
                        var idx = -1
                        // 对照组 A（不安全）：head="~" 与候选（展开后的绝对路径）对不上 → 必须一条不给。
                        // 同时看原始候选数，证明"是被裁掉的"，而不是"本来就没候选"。
                        editor.stringValue = "~"
                        let unsafeHead = editor.control(editor, textView: probe, completions: [],
                                                        forPartialWordRange: NSRange(location: 1, length: 0),
                                                        indexOfSelectedItem: &idx)
                        let rawForTilde = editor.uiTestLastCompletionCount
                        // 对照组 B（安全）：head 是候选的真前缀 → 返回末段，拼回去即正确路径，不该被误杀
                        let stem = (box.path + "/Completion") as NSString
                        let headLen = (box.path + "/" as NSString).length
                        editor.stringValue = stem as String
                        let safe = editor.control(editor, textView: probe, completions: [],
                                                  forPartialWordRange: NSRange(location: headLen,
                                                                               length: stem.length - headLen),
                                                  indexOfSelectedItem: &idx)
                        editor.stringValue = ""
                        let assembled = box.path + "/" + (safe.first ?? "")
                        let assembledOK = !safe.isEmpty && fs.fileExists(atPath: assembled)
                        record(unsafeHead.isEmpty && rawForTilde > 0 && assembledOK,
                               "I-55 补全候选 head 对不上时全裁(原始 \(rawForTilde) 条→0)、对得上时返回末段(\(safe.count) 条，拼出 \((assembled as NSString).lastPathComponent) 存在=\(assembledOK))")
                    }

                    if dpane.uiTestIsPathEditing { dpane.uiTestEndPathEditing() }
                    // 复原：本场景为定位隐藏文件打开过"显示隐藏"，别把状态漏给后续场景
                    if dpane.uiTestIncludeHidden != hiddenWas { dpane.uiTestSetIncludeHidden(hiddenWas) }
                    window.makeFirstResponder(dpane.focusTarget)
                }
                dpane.navigate(to: fs.homeDirectoryForCurrentUser)
                try? await Task.sleep(for: .milliseconds(150))
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

            }  // 结束 if !focusI37（I-30/I-32 环境相关跳过门）

            // ── 场景 I-37：面包屑地址栏宽度自适应——深层级/长名不溢出 + 中间折叠全层级永远可达 ──
            // 用户原话「尽可能保证地址栏可以展示全部层级」。沙箱建 8 层深、每层 40 字符的目录链，
            // 导航到最深层后断言：①内容真实不溢出 ②「…」折叠段存在且菜单项数==被折叠层级数
            // ③程序化触发折叠菜单项 → 窗格路径真跳到该层级 ④可见末段 toolTip==完整名。
            // 铁律：只动自建 nspace-uitest-i37-* 夹具（assertSandboxed 守卫）；测完清理。
            wc.grid.apply(layout: .single)
            pane.setViewMode(.list)
            try? await Task.sleep(for: .milliseconds(200))
            window.contentView?.layoutSubtreeIfNeeded()
            do {
                let token = String(UUID().uuidString.prefix(8))
                // 每层名恰 40 字符（唯一可辨识前缀 + 「长」补齐）
                @MainActor func longName(_ i: Int) -> String {
                    let prefix = "nspace-uitest-i37-\(token)-L\(i)-"
                    return prefix + String(repeating: "长", count: max(0, 40 - prefix.count))
                }
                let base = fs.temporaryDirectory
                    .appendingPathComponent("nspace-uitest-i37-\(token)", isDirectory: true)
                var deep = base
                for i in 1...8 { deep = deep.appendingPathComponent(longName(i), isDirectory: true) }
                try? fs.createDirectory(at: deep, withIntermediateDirectories: true)

                let gI37 = assertSandboxed(deep)
                record(gI37, "沙箱守卫: I-37 深层链在自建夹具内")

                let bc = pane.uiTestBreadcrumb
                pane.navigate(to: deep)
                try? await Task.sleep(for: .milliseconds(400))
                window.contentView?.layoutSubtreeIfNeeded()
                bc.layoutSubtreeIfNeeded()

                // ① 不溢出：内容右缘 ≤ 容器宽 + 2（真实测排布，不是"没崩"）
                let containerW = bc.bounds.width
                let contentR = bc.uiTestContentRight
                record(contentR <= containerW + 2,
                       "I-37 面包屑不溢出（内容右缘 \(Int(contentR)) ≤ 容器 \(Int(containerW))+2）")
                capture(window, "30-breadcrumb-deep")

                // ② 「…」折叠段存在且菜单项数 == 被折叠层级数
                let hasEllipsis = bc.uiTestHasEllipsis
                let collapsed = bc.uiTestCollapsedURLs
                let menu = bc.uiTestEllipsisMenu()
                let menuCount = menu?.items.count ?? -1
                record(hasEllipsis && menu != nil && collapsed.count > 0 && menuCount == collapsed.count,
                       "I-37 「…」折叠段存在且菜单项数==折叠层级数（折叠 \(collapsed.count)，菜单 \(menuCount)）")

                // ③ 程序化触发折叠菜单中间项 → 窗格路径真跳到该层级
                if let menu, !menu.items.isEmpty,
                   let mid = Optional(menu.items[menu.items.count / 2]),
                   let targetURL = mid.representedObject as? URL {
                    _ = mid.target?.perform(mid.action, with: mid)
                    try? await Task.sleep(for: .milliseconds(350))
                    record(samePath(pane.activeTab.browser.current, targetURL),
                           "I-37 点折叠菜单项 → 窗格真跳到该层级（\(targetURL.lastPathComponent.prefix(16))…）")
                } else {
                    record(false, "I-37 点折叠菜单项 → 窗格真跳到该层级")
                }

                // 回到最深层，验 ④ 与窄窗格态
                pane.navigate(to: deep)
                try? await Task.sleep(for: .milliseconds(350))
                window.contentView?.layoutSubtreeIfNeeded()
                bc.layoutSubtreeIfNeeded()

                // ④ 可见末段 toolTip == 完整名（40 字符全名）
                let tip = bc.uiTestLastSegmentToolTip
                let full = bc.uiTestLastSegmentFullName
                record(tip != nil && full != nil && tip == full && (full?.count ?? 0) == 40,
                       "I-37 可见末段 toolTip==完整名（长度 \(full?.count ?? -1)）")

                // 窄窗格态：缩窄窗口再截一张，逐级折叠后仍真实不溢出
                let savedFrame = window.frame
                window.setFrame(NSRect(x: savedFrame.origin.x, y: savedFrame.origin.y,
                                       width: 520, height: savedFrame.height), display: true)
                try? await Task.sleep(for: .milliseconds(400))
                window.contentView?.layoutSubtreeIfNeeded()
                bc.layoutSubtreeIfNeeded()
                let narrowW = bc.bounds.width
                let narrowR = bc.uiTestContentRight
                record(narrowR <= narrowW + 2,
                       "I-37 窄窗格仍不溢出（内容右缘 \(Int(narrowR)) ≤ 容器 \(Int(narrowW))+2）")
                capture(window, "30b-breadcrumb-narrow")
                window.setFrame(savedFrame, display: true)
                try? await Task.sleep(for: .milliseconds(250))

                // 清理夹具（token 唯一，安全）
                pane.navigate(to: fs.homeDirectoryForCurrentUser)
                try? await Task.sleep(for: .milliseconds(200))
                try? fs.removeItem(at: base)
            }
            window.makeKeyAndOrderFront(nil)

            if focusI37 { return finish() }   // 聚焦模式：I-37 验完即收尾
            // ── 场景 M26：列表「年/月」分组 + 折叠 + 组过滤 + 跨排序选中保持 + 开关 ─────────
            // 铁律：只动自建 nspace-uitest-m26-* 夹具（assertSandboxed 守卫）；6 文件造 3 个不同年月。
            await runGroupingScenario(wc: wc, window: window)

            // ── 场景 M29：相对时间纯逻辑（6 桶 keyTitle 落位 + 日期列本年隐年/非本年显年）──────
            runRelativeTimeUnit()

            // ── 场景 I-46：帧持久化键在 UITEST 下隔离，绝不污染用户真实 windowFrame ──────────
            record(MainWindowController.frameDefaultsKey == "windowFrame.uitest",
                   "I-46 UITEST 帧键隔离（写 windowFrame.uitest 不碰产品 windowFrame）")

            // M28/I-47 测试沙箱：frecency 记账 + 会话保存在 UITEST 走隔离临时目录，绝不污染用户真实排序/会话
            record(AppDelegate.supportDirectory.path.contains("nspace-uitest-support"),
                   "M28/I-47 UITEST 存储隔离（frecency/session 写临时目录不碰用户真实数据）")

            // ── 场景 I-43：点选区内收敛谓词（纯逻辑确定性；行为层 0.5s→0.16s 已真机插桩实测）─────
            let i43a = FocusReportingTableView.shouldPreemptCollapse(clickedRow: 2, modifiers: [], clickCount: 1, selectedCount: 5, rowIsSelected: true)
            let i43cmd = FocusReportingTableView.shouldPreemptCollapse(clickedRow: 2, modifiers: [.command], clickCount: 1, selectedCount: 5, rowIsSelected: true)
            let i43dbl = FocusReportingTableView.shouldPreemptCollapse(clickedRow: 2, modifiers: [], clickCount: 2, selectedCount: 5, rowIsSelected: true)
            let i43out = FocusReportingTableView.shouldPreemptCollapse(clickedRow: 9, modifiers: [], clickCount: 1, selectedCount: 5, rowIsSelected: false)
            let i43single = FocusReportingTableView.shouldPreemptCollapse(clickedRow: 2, modifiers: [], clickCount: 1, selectedCount: 1, rowIsSelected: true)
            record(i43a && !i43cmd && !i43dbl && !i43out && !i43single,
                   "I-43 点选区内收敛谓词：纯单击多选已选行=抢先收敛，修饰键/双击/选区外/单选=不介入（\(i43a)/\(i43cmd)/\(i43dbl)/\(i43out)/\(i43single)）")

            // ── 场景 M28：搜索智能排序（frecency+匹配融合）接管排序 vs 开关关回退到达序 ──────────
            runSmartSortScenario()

            // ── 场景 I-47：导航即落盘（会话记住上次目录，非干净退出也不回 home）──────────────────
            await runSessionSaveScenario(delegate: delegate)

            // ── 场景 I-44：第三方"打开文件位置"→ openWindow(selecting:) 真定位选中（列表+图标）──
            await runRevealSelectScenario(delegate: delegate)

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
            // 确定性前置：显式激活并夺 key，使首次 toggle 的 NSApp.isActive 分支稳定为"隐藏"
            // （此断言依赖 app-active 环境态，40+ 场景后的 ambient 状态不可靠——由测试自建前置，非产品 bug）
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .milliseconds(300))
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

            // ── 场景 I-52：外部/浏览器 reveal 落点可配（默认现有窗口新标签，不弹新窗）──────────────
            // 放在搜索之后（会开关窗口，须让搜索场景先在干净窗口态跑）；自身清理回进入前状态供场景6。
            await runExternalOpenTargetScenario(delegate: delegate)
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

    // MARK: M26 分组场景（列表「年/月」分组 + 折叠 + 组过滤 + 跨排序选中保持 + 开关）

    private static func runGroupingScenario(wc: MainWindowController, window: NSWindow) async {
        let fs = FileManager.default
        let cal = Calendar.current
        let token = String(UUID().uuidString.prefix(8))
        let box = fs.temporaryDirectory
            .appendingPathComponent("nspace-uitest-m26-\(token)", isDirectory: true)
        // M29 相对分桶：注入固定时钟 now=2026-06-17 12:00，夹具落在 3 个不同相对桶（各 2 文件，共 6）——
        // 往年(2025-05-10) / 本月更早(2026-06-02) / 今天(2026-06-17)。今天/昨天/周/月/年判定全经 nowProvider
        // （见 FileGrouping），故与真实系统时钟无关、确定性可断言。
        let fixedNow = cal.date(from: DateComponents(year: 2026, month: 6, day: 17, hour: 12))!
        let priorNowProvider = FileGrouping.nowProvider
        FileGrouping.nowProvider = { fixedNow }
        // 升序排序后组序 = [往年, 本月, 今天]
        let bucketDates: [Date] = [
            cal.date(from: DateComponents(year: 2025, month: 5, day: 10, hour: 9))!,   // g5-2025
            cal.date(from: DateComponents(year: 2026, month: 6, day: 2, hour: 9))!,     // g3-month
            cal.date(from: DateComponents(year: 2026, month: 6, day: 17, hour: 9))!,    // g0-today
        ]
        try? fs.createDirectory(at: box, withIntermediateDirectories: true)
        var created: [URL] = []
        for (mi, date) in bucketDates.enumerated() {
            for k in 0..<2 {
                let f = box.appendingPathComponent("m26-\(token)-\(mi)-\(k).txt")
                try? Data("x".utf8).write(to: f)
                if assertSandboxed(f) {
                    try? fs.setAttributes([.modificationDate: date], ofItemAtPath: f.path)
                }
                created.append(f)
            }
        }
        let gSandbox = created.allSatisfy { assertSandboxed($0) }
        record(gSandbox, "沙箱守卫[m26]: 分组夹具 6 文件在自建夹具内")

        // 前置：分组开、日期排序
        let hadGrouping = Preferences.listGrouping
        Preferences.listGrouping = true
        let pane = wc.grid.activePane
        pane.setViewMode(.list)
        try? await Task.sleep(for: .milliseconds(200))
        pane.navigate(to: box)
        _ = await pollFS { pane.activeTab.model.items.count == 6 }
        let listVC = pane.activeTab.listVC
        // 按修改日期升序排序（走列头同一 sortDescriptors 链路）
        listVC.tableView.sortDescriptors = [NSSortDescriptor(key: "dateModified", ascending: true)]
        _ = await pollFS { listVC.uiTestGroupHeaderCount == 3 }
        try? await Task.sleep(for: .milliseconds(200))

        // ① 组头行数==3 且标题为相对桶（往年/本月/今天）、各组项数正确
        let groups = listVC.uiTestGroups
        let headerCount = listVC.uiTestGroupHeaderCount
        let expectTitles = [
            String(format: L10n.t("group.year"), 2025),
            L10n.t("group.thisMonth"),
            L10n.t("group.today"),
        ]
        let titlesOK = groups.map(\.title) == expectTitles
        let countsOK = groups.map(\.count) == [2, 2, 2]
        record(headerCount == 3 && titlesOK && countsOK && listVC.uiTestItemRowCount == 6,
               "M26 分组组头数==3 相对桶标题正确各组2项（头\(headerCount) 标题\(groups.map(\.title)) 期望\(expectTitles) 项数\(groups.map(\.count))）")
        capture(window, "31-grouping")

        // ② 折叠首组 → 该组项从表消失、其他组不动
        let firstKey = listVC.uiTestGroupKeys.first ?? ""
        listVC.uiTestClickGroupRow(0)   // 真实点击处理路径
        try? await Task.sleep(for: .milliseconds(200))
        let afterCollapse = listVC.uiTestGroups
        let collapsedFlags = afterCollapse.map(\.collapsed)
        let itemRowsAfter = listVC.uiTestItemRowCount
        record(collapsedFlags == [true, false, false] && itemRowsAfter == 4
               && listVC.uiTestGroupHeaderCount == 3 && afterCollapse.map(\.count) == [2, 2, 2],
               "M26 折叠首组项消失其他不动（折叠标记\(collapsedFlags) 余项行\(itemRowsAfter)）")
        capture(window, "31b-collapsed")
        listVC.uiTestClickGroupRow(0)   // 展开还原
        try? await Task.sleep(for: .milliseconds(150))
        let expandedBack = listVC.uiTestItemRowCount == 6

        // ③ 仅显示此组 → 表中仅剩该组行且过滤提示可见；显示全部还原
        listVC.applyGroupFilter(key: firstKey)
        try? await Task.sleep(for: .milliseconds(200))
        let onlyOK = listVC.uiTestGroupHeaderCount == 1 && listVC.uiTestItemRowCount == 2
            && listVC.uiTestFilterPillVisible
        capture(window, "31c-filtered")
        listVC.clearGroupFilter()
        try? await Task.sleep(for: .milliseconds(200))
        let restoredOK = listVC.uiTestGroupHeaderCount == 3 && !listVC.uiTestFilterPillVisible
        record(expandedBack && onlyOK && restoredOK,
               "M26 仅显示此组表仅剩该组+药丸可见，显示全部还原（展开回\(expandedBack) 仅剩\(onlyOK) 还原\(restoredOK)）")

        // ④ 选中某项后跨组重排序 → 选中按 URL 仍在（I-32 语义）
        // victim 取自「已载入的真实项 URL」（避免 /var⟷/private/var symlink 路径不匹配——同 I-32 铁律）
        let victim = listVC.model.items.count == 6 ? listVC.model.items[2].url : (created.count > 2 ? created[2] : box)
        listVC.select(urls: [victim])
        try? await Task.sleep(for: .milliseconds(150))
        let selBefore = listVC.selectedURLs
        listVC.tableView.sortDescriptors = [NSSortDescriptor(key: "dateModified", ascending: false)]
        _ = await pollFS { listVC.uiTestGroupHeaderCount == 3 }
        try? await Task.sleep(for: .milliseconds(200))
        let selAfter = listVC.selectedURLs
        record(selBefore == [victim] && selAfter == [victim],
               "M26 跨组重排序后选中按 URL 仍在（前\(selBefore.map(\.lastPathComponent)) 后\(selAfter.map(\.lastPathComponent))）")

        // ④b 图标视图分组（M26 v2）：同夹具切图标视图，section=组、折叠、过滤、选中跨 rebuild 保持
        pane.setViewMode(.icons)
        try? await Task.sleep(for: .milliseconds(300))
        if let iconVC = pane.activeTab.iconVC {
            _ = await pollFS { iconVC.uiTestSectionCount == 3 }
            let iTitles = iconVC.uiTestGroupTitles
            record(iconVC.uiTestSectionCount == 3 && Set(iTitles) == Set(expectTitles),
                   "M26v2 图标视图分组 section==3 相对桶标题正确（\(iTitles)）")
            capture(window, "31d-icon-grouping")
            iconVC.uiTestToggleFirstGroup()
            try? await Task.sleep(for: .milliseconds(200))
            record(iconVC.uiTestCollapsedCount == 1 && iconVC.uiTestSectionCount == 3,
                   "M26v2 图标视图折叠首组（collapsed=\(iconVC.uiTestCollapsedCount) section=\(iconVC.uiTestSectionCount)）")
            iconVC.uiTestToggleFirstGroup()   // 展开还原
            try? await Task.sleep(for: .milliseconds(150))
            iconVC.uiTestFilterFirstGroup()
            try? await Task.sleep(for: .milliseconds(200))
            let iFilterOK = iconVC.uiTestSectionCount == 1 && iconVC.uiTestFilterPillVisible
            iconVC.uiTestClearFilter()
            try? await Task.sleep(for: .milliseconds(200))
            let iRestore = iconVC.uiTestSectionCount == 3 && !iconVC.uiTestFilterPillVisible
            record(iFilterOK && iRestore,
                   "M26v2 图标视图仅显示此组+药丸，显示全部还原（仅剩\(iFilterOK) 还原\(iRestore)）")
            // 选中按 URL 跨 rebuild 保持（分组映射不丢选中，I-32 语义在图标视图成立）
            let ivictim = iconVC.model.items.count == 6 ? iconVC.model.items[0].url : box
            iconVC.select(urls: [ivictim])
            try? await Task.sleep(for: .milliseconds(150))
            let iSelBefore = iconVC.selectedURLs
            iconVC.uiTestClearFilter()   // 触发一次 rebuild+reload
            try? await Task.sleep(for: .milliseconds(150))
            record(iSelBefore == [ivictim] && iconVC.selectedURLs == [ivictim],
                   "M26v2 图标视图选中按 URL 跨 rebuild 保持")
        } else {
            record(false, "M26v2 图标视图分组 section==3 相对桶标题正确")
            record(false, "M26v2 图标视图折叠首组")
            record(false, "M26v2 图标视图仅显示此组+药丸，显示全部还原")
            record(false, "M26v2 图标视图选中按 URL 跨 rebuild 保持")
        }
        pane.setViewMode(.list)   // 切回列表供 ⑤ 断言
        try? await Task.sleep(for: .milliseconds(250))

        // ⑤ 关闭分组 → 组头行数==0 恢复单线
        Preferences.listGrouping = false
        NotificationCenter.default.post(name: .nspaceGroupingChanged, object: nil)
        try? await Task.sleep(for: .milliseconds(250))
        record(listVC.uiTestGroupHeaderCount == 0 && listVC.uiTestRowCount == 6 && !listVC.uiTestGroupingActive,
               "M26 关闭分组组头数==0 恢复单线（头\(listVC.uiTestGroupHeaderCount) 行\(listVC.uiTestRowCount)）")

        // 收尾：恢复偏好/排序/时钟、清夹具
        Preferences.listGrouping = hadGrouping
        FileGrouping.nowProvider = priorNowProvider
        NotificationCenter.default.post(name: .nspaceGroupingChanged, object: nil)
        listVC.tableView.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        listVC.select(urls: [])
        pane.navigate(to: fs.homeDirectoryForCurrentUser)
        try? await Task.sleep(for: .milliseconds(200))
        if assertSandboxed(box) { try? fs.removeItem(at: box) }
        window.makeKeyAndOrderFront(nil)
    }

    /// M29 相对时间纯逻辑：固定时钟 now=2026-06-17 下 6 桶 keyTitle 落位 + 日期列相对格式
    /// （今天/昨天带前缀、本年隐年份、仅非本年显年份）。纯函数确定性验证，不碰文件系统/UI。
    private static func runRelativeTimeUnit() {
        let cal = Calendar.current
        guard let now = cal.date(from: DateComponents(year: 2026, month: 6, day: 17, hour: 12)) else {
            record(false, "M29 相对分桶 6 桶 keyTitle 落位正确"); record(false, "M29 日期列本年隐年份/非本年显年份"); return
        }
        let prior = FileGrouping.nowProvider
        FileGrouping.nowProvider = { now }
        defer { FileGrouping.nowProvider = prior }

        func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
            cal.date(from: DateComponents(year: y, month: m, day: d, hour: 9))!
        }
        func item(_ dt: Date) -> FileItem {
            FileItem(url: URL(fileURLWithPath: "/tmp/nspace-m29-\(dt.timeIntervalSinceReferenceDate)"),
                     name: "x", isDirectory: false, isPackage: false, isSymlink: false,
                     isHidden: false, size: 0, modified: dt, created: dt, added: dt, contentTypeID: nil)
        }
        // 6 桶：今天/昨天/本周/本月更早/今年更早/往年
        let cases: [(Date, String)] = [
            (date(2026, 6, 17), "g0-today"),        // 同日
            (date(2026, 6, 16), "g1-yesterday"),    // now-1d
            (date(2026, 6, 15), "g2-week"),         // 同周非今昨（周一/二/三同周，跨 locale 稳）
            (date(2026, 6, 2),  "g3-month"),        // 同月非本周
            (date(2026, 2, 10), "g4-year-earlier"), // 同年非本月
            (date(2025, 5, 10), "g5-2025"),         // 往年按年
        ]
        let keys = cases.map { FileGrouping.keyTitle(for: item($0.0), key: .dateModified).key }
        let expected = cases.map { $0.1 }
        record(keys == expected, "M29 相对分桶 6 桶 keyTitle 落位正确（得\(keys) 期望\(expected)）")

        // 日期列相对格式（Formatters.relativeDate，now 显式注入）
        let today = Formatters.relativeDate(date(2026, 6, 17), now: now)
        let yst = Formatters.relativeDate(date(2026, 6, 16), now: now)
        let thisYear = Formatters.relativeDate(date(2026, 2, 10), now: now)   // 本年 → 不含 "2026"
        let otherYear = Formatters.relativeDate(date(2025, 5, 10), now: now)  // 往年 → 含 "2025"
        let todayOK = today.hasPrefix(L10n.t("date.today"))
        let ystOK = yst.hasPrefix(L10n.t("date.yesterday"))
        let thisYearNoYear = !thisYear.contains("2026")     // 本年隐年份（用户点名核心）
        let otherYearHasYear = otherYear.contains("2025")   // 非本年显年份
        record(todayOK && ystOK && thisYearNoYear && otherYearHasYear,
               "M29 日期列本年隐年份/非本年显年份（今\(today) 昨\(yst) 本年\(thisYear) 往年\(otherYear)）")

        // I-49：foldersFirst 打乱首次出现顺序时，组仍按相对时间新近排（今天最新→最前）。
        // 模拟 items=[文件夹段 desc][文件段 desc]：文件夹落在昨天/本周，文件落在今天——旧"首次出现"逻辑会把
        // 只含文件的"今天"桶挤到文件夹建立的桶序之后（用户报"今天在最底下"）。新逻辑按 recencyRank 排，今天最前。
        func dirItem(_ dt: Date) -> FileItem {
            FileItem(url: URL(fileURLWithPath: "/tmp/nspace-i49-\(dt.timeIntervalSinceReferenceDate)"),
                     name: "d", isDirectory: true, isPackage: false, isSymlink: false,
                     isHidden: false, size: nil, modified: dt, created: dt, added: dt, contentTypeID: nil)
        }
        let scrambled = [dirItem(date(2026, 6, 16)), dirItem(date(2026, 6, 15)), item(date(2026, 6, 17))]
        let gsDesc = FileGrouping.buckets(scrambled, key: .dateModified, ascending: false).map(\.key)
        record(gsDesc.first == "g0-today",
               "I-49 foldersFirst 下组仍按新近排：今天(仅文件)在最前不被文件夹桶挤到末尾（得 \(gsDesc)）")
    }

    /// I-44：第三方"打开文件位置"（Antigravity 等经 activateFileViewerSelectingURLs → openFileURLs →
    /// openWindow(selecting:)）此前 select 参数被整段丢弃，只到父目录不选中文件。验证：
    /// ① openWindow(selecting:) 列表视图真选中目标；② pane.reveal 在图标视图（非 listVC）也真选中。
    /// 沙箱铁律：只动自建 nspace-uitest-reveal-* 夹具。
    private static func runRevealSelectScenario(delegate: AppDelegate) async {
        let fs = FileManager.default
        let token = String(UUID().uuidString.prefix(8))
        let box = fs.temporaryDirectory
            .appendingPathComponent("nspace-uitest-reveal-\(token)", isDirectory: true)
        try? fs.createDirectory(at: box, withIntermediateDirectories: true)
        var files: [URL] = []
        for i in 0..<4 {
            let f = box.appendingPathComponent("reveal-\(token)-\(i).txt")
            try? Data("x".utf8).write(to: f)
            files.append(f)
        }
        let target = files[2]
        record(files.allSatisfy { assertSandboxed($0) }, "沙箱守卫[I-44]: reveal 夹具 4 文件在自建夹具内")

        // ① 模拟第三方"打开文件位置"默认落点（externalOpenTarget=newTab → openWindow(selecting:)）。
        // select 参数此前被整段丢弃——此处验证它真被接通并在默认视图落选中（视图模式无关，不受用户默认视图影响）
        let wc = delegate.openWindow(at: box, selecting: target)
        let pane = wc.grid.activePane
        _ = await pollFS { pane.activeTab.model.items.count == 4 }
        _ = await pollFS { pane.currentSelectionCount == 1 }
        record(pane.currentSelectionCount == 1,
               "I-44 openWindow(selecting:) 真定位选中目标文件（select 参数不再被丢弃，选中数=\(pane.currentSelectionCount)）")
        if let w = wc.window { capture(w, "32-reveal") }

        // ② 列表视图 reveal 分派：navigate 触发异步载入 + pending 选中落位
        pane.setViewMode(.list)
        try? await Task.sleep(for: .milliseconds(200))
        pane.navigate(to: box)
        pane.reveal(target)
        _ = await pollFS { pane.activeTab.listVC.selectedURLs.count == 1 }
        let selList = pane.activeTab.listVC.selectedURLs.map(\.standardizedFileURL)
        record(selList == [target.standardizedFileURL],
               "I-44 列表视图 reveal 真定位选中目标文件（\(selList.map(\.lastPathComponent))）")

        // I-48：reveal 定位后表格成为 first responder → 选中显蓝色强调（否则未强调灰几乎不可见，用户报"没蓝色选中"）
        let fr = wc.window?.firstResponder
        record(fr === pane.activeTab.listVC.tableView,
               "I-48 reveal 后表格获焦（选中显蓝色强调，非未强调灰）（firstResponder=\(type(of: fr as Any))）")

        // I-45：QL 收起走淡出（sourceFrame 收起态=.zero，QL 不再"缩到图标"）、开启态=行内图标矩形（保留放大）
        let lvc = pane.activeTab.listVC
        let qlFade = lvc.uiTestQLSourceFrame(dismissing: true, for: target)
        let qlZoom = lvc.uiTestQLSourceFrame(dismissing: false, for: target)
        record(qlFade == .zero && qlZoom != .zero,
               "I-45 QL 收起 sourceFrame 淡出(.zero)、开启为图标矩形缩放（收起\(NSStringFromRect(qlFade)) 开启\(NSStringFromRect(qlZoom))）")

        // ③ 图标视图 reveal（走 iconVC 分支，非硬编码 listVC）：同 navigate+pending 落位
        pane.setViewMode(.icons)
        try? await Task.sleep(for: .milliseconds(250))
        pane.navigate(to: box)
        pane.reveal(target)
        _ = await pollFS { (pane.activeTab.iconVC?.selectedURLs.count ?? 0) == 1 }
        let selIcon = (pane.activeTab.iconVC?.selectedURLs ?? []).map(\.standardizedFileURL)
        record(selIcon == [target.standardizedFileURL],
               "I-44 图标视图 reveal 真定位选中目标文件（视图模式感知，非硬编码 listVC）（\(selIcon.map(\.lastPathComponent))）")

        // 收尾：关测试窗 + 清夹具
        wc.window?.orderOut(nil)
        wc.window?.close()
        try? await Task.sleep(for: .milliseconds(150))
        if assertSandboxed(box) { try? fs.removeItem(at: box) }
    }

    /// M28：搜索智能排序集成——两条同名（同匹配质量）命中仅 frecency 不同，验证：
    /// 开关开 → 高 frecency 排最前（融合分接管）；开关关 → 回退到达序（frecency 不介入）。
    /// 走真实 appendResults/rankLess 链（uiTestAppend），确定性、不碰真实引擎与用户文件。
    private static func runSmartSortScenario() {
        let sp = SearchPanelController.shared
        let base = URL(fileURLWithPath: "/tmp/nspace-m28-\(UUID().uuidString.prefix(6))")
        let a = base.appendingPathComponent("A/note.txt")
        let b = base.appendingPathComponent("B/note.txt")
        func hit(_ u: URL) -> SearchHit {
            SearchHit(url: u, name: "note.txt", isDirectory: false, size: 1, modified: nil,
                      contentTypeID: "public.plain-text")
        }
        let snapshot = [b.standardizedFileURL.path: FrecencyEntry(count: 12, lastAccess: Date())]

        // 智能开：B（高 frecency）排到 A 前（二者匹配质量相同 → 仅 frecency 决定）
        sp.uiTestReset(root: nil)
        sp.uiTestConfigureSmart(query: "note", snapshot: snapshot, active: true)
        sp.uiTestAppend([hit(a), hit(b)])
        let onFirst = sp.uiTestResultPaths.first
        record(onFirst == b.path,
               "M28 智能排序开：高 frecency 命中排最前（首=\((onFirst.map { ($0 as NSString).lastPathComponent }) ?? "nil")，期望 B/note.txt）")

        // 智能关：回退到达序（先 append A → A 在前，不受 frecency 影响）
        sp.uiTestReset(root: nil)
        sp.uiTestConfigureSmart(query: "note", snapshot: snapshot, active: false)
        sp.uiTestAppend([hit(a), hit(b)])
        let offFirst = sp.uiTestResultPaths.first
        record(offFirst == a.path,
               "M28 智能排序关：回退到达序（首=\((offFirst.map { ($0 as NSString).lastPathComponent }) ?? "nil")，期望 A/note.txt）")
        sp.uiTestReset(root: nil)
    }

    /// I-47：导航即落盘——导航活动窗格到夹具后，会话（隔离存储）应在防抖内记住该目录。
    /// 证明 onActiveLocationChange→noteStateChanged 生效：位置不再只在干净退出才保存，非干净退出也不回 home。
    private static func runSessionSaveScenario(delegate: AppDelegate) async {
        let fs = FileManager.default
        let token = String(UUID().uuidString.prefix(8))
        let box = fs.temporaryDirectory.appendingPathComponent("nspace-uitest-sess-\(token)", isDirectory: true)
        try? fs.createDirectory(at: box, withIntermediateDirectories: true)
        record(assertSandboxed(box), "沙箱守卫[I-47]: 会话夹具在自建夹具内")
        guard let wc = NSApp.windows.compactMap({ $0.windowController as? MainWindowController }).first else {
            record(false, "I-47 导航即落盘：会话记住导航目录"); return
        }
        let pane = wc.grid.activePane
        pane.navigate(to: box)   // → onActiveLocationChange → noteStateChanged（UITEST 下 sessionReady=true）
        try? await Task.sleep(for: .milliseconds(1400))   // SessionStore 防抖 1s + 余量
        let snap = await delegate.sessionStore.load()
        let paths = (snap?.windows ?? [])
            .flatMap { $0.workspaces }.flatMap { $0.panes }.flatMap { $0.tabs }.map { $0.path }
        let hit = paths.contains(box.path) || paths.contains(box.standardizedFileURL.path)
        record(hit, "I-47 导航即落盘：会话记住导航目录（隔离 session 含 \(box.lastPathComponent)=\(hit)）")

        // I-50：改排序即落盘（点列头改排序此前不触发保存，非干净退出重启回退旧排序）
        pane.setViewMode(.list)
        try? await Task.sleep(for: .milliseconds(150))
        pane.activeTab.listVC.tableView.sortDescriptors = [NSSortDescriptor(key: "size", ascending: false)]
        try? await Task.sleep(for: .milliseconds(1400))
        let snap2 = await delegate.sessionStore.load()
        let boxTab = (snap2?.windows ?? [])
            .flatMap { $0.workspaces }.flatMap { $0.panes }.flatMap { $0.tabs }
            .first { $0.path == box.path || $0.path == box.standardizedFileURL.path }
        let sortSaved = boxTab?.sortKey == "size" && boxTab?.sortAscending == false
        record(sortSaved, "I-50 改排序即落盘：会话记住排序列/方向（得 \(boxTab?.sortKey ?? "nil")/\(boxTab.map { String($0.sortAscending) } ?? "nil")，期望 size/false）")

        // 收尾：导航回 home + 清夹具
        pane.navigate(to: fs.homeDirectoryForCurrentUser)
        try? await Task.sleep(for: .milliseconds(200))
        if assertSandboxed(box) { try? fs.removeItem(at: box) }
    }

    /// I-52：外部/浏览器 reveal 落点可配——默认「现有窗口新标签」复用当前窗口开新标签（不弹新窗，
    /// 修用户报的"每次开新窗口"）；「新窗口」才每次弹新窗。经真实 application(_:open:) → openFileURLs 链验证。
    private static func runExternalOpenTargetScenario(delegate: AppDelegate) async {
        let fs = FileManager.default
        let token = String(UUID().uuidString.prefix(8))
        let box = fs.temporaryDirectory.appendingPathComponent("nspace-uitest-extopen-\(token)", isDirectory: true)
        try? fs.createDirectory(at: box, withIntermediateDirectories: true)
        record(assertSandboxed(box), "沙箱守卫[I-52]: 外部打开夹具在自建夹具内")
        func mainWins() -> Int { NSApp.windows.filter { $0.windowController is MainWindowController && $0.isVisible }.count }
        guard let wc = NSApp.windows.compactMap({ $0.windowController as? MainWindowController }).first,
              let hostWindow = wc.window else {
            record(false, "I-52 外部打开默认新标签：复用现有窗口不弹新窗"); return
        }
        let prev = Preferences.externalOpenTarget

        // 前置settle：外部打开路由到【key 窗】——先令宿主窗夺 key 并等前序场景遗留窗关净，
        // 否则断言查的是 first 窗、开的却落在残留 key 窗上，造成"标签未+1"的时序假失败（I-53 加时暴露）。
        hostWindow.makeKeyAndOrderFront(nil)
        _ = await pollFS { mainWins() == 1 }
        try? await Task.sleep(for: .milliseconds(100))

        // 默认「现有窗口新标签」：窗口数不变、活动窗格标签 +1
        Preferences.externalOpenTarget = "newTab"
        let w0 = mainWins(); let t0 = wc.grid.activePane.tabs.count
        delegate.application(NSApp, open: [box])
        _ = await pollFS { wc.grid.activePane.tabs.count == t0 + 1 }
        record(mainWins() == w0 && wc.grid.activePane.tabs.count == t0 + 1,
               "I-52 外部打开默认「新标签」：复用现有窗口不弹新窗（窗口 \(w0)→\(mainWins())，标签 \(t0)→\(wc.grid.activePane.tabs.count)）")

        // 「新窗口」：窗口数 +1
        Preferences.externalOpenTarget = "newWindow"
        let w1 = mainWins()
        delegate.application(NSApp, open: [box])
        _ = await pollFS { mainWins() == w1 + 1 }
        record(mainWins() == w1 + 1, "I-52 外部打开「新窗口」：弹新窗（窗口 \(w1)→\(mainWins())）")

        // 收尾：复原偏好 + 关掉多开的窗口（保留宿主窗）+ 关掉本场景加的标签（回进入前态）+ 清夹具
        Preferences.externalOpenTarget = prev
        for w in NSApp.windows where (w.windowController is MainWindowController) && w !== hostWindow { w.close() }
        while wc.grid.activePane.tabs.count > t0 { wc.grid.activePane.closeTab(at: wc.grid.activePane.tabs.count - 1) }
        hostWindow.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(200))
        if assertSandboxed(box) { try? fs.removeItem(at: box) }
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

    /// 截图任意视图（无需在可见窗口中；自绘 sheet 内容 headless 人眼终审用）
    private static func captureView(_ view: NSView, _ name: String) {
        view.layoutSubtreeIfNeeded()
        guard view.bounds.width > 0, view.bounds.height > 0,
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

    /// 向地址栏 field editor 发一次**真实** Return 键（走 keyDown → 响应链 → doCommandBy
    /// insertNewline；直调回调是捷径，测不到键路由断裂）
    private static func pressReturn(in editor: PathEditorField, window: NSWindow) {
        guard let fe = editor.currentEditor() as? NSTextView,
              let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                        timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil,
                                        characters: "\r", charactersIgnoringModifiers: "\r",
                                        isARepeat: false, keyCode: 36)
        else { return }
        fe.keyDown(with: ev)
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

# M17 自绘顶部甲板 + 全高侧栏 —— 设计规格（方向契约）

<!-- 方向契约（direction contract）
THESIS: 原生 macOS 专业工具标准做到极致——Finder 的材质语言 × QSpace 的密度与拓扑；
       特色走结构与做工，不走色彩（用户否决一切"web 花哨配色"，seed f8a2afe5 的骰子结果被用户的 canon 出口取代）。
OWN-WORLD: 现有主题系统（Theme.accent / appearanceMode / accentColorHex）+ 系统材质
       （NSVisualEffectView .titlebar/.sidebar）+ SF Symbols + 发丝分隔线 + 4pt 网格。去掉全部内容后
       仍可辨识的是拓扑：一条贯通全高的分割线，左列暂存牌堆压顶，右列三层甲板。
STORY: 打开即是四件事同屏可扫——哪个窗格有焦点、路径在哪、暂存架里有什么、任务跑到哪。
FIRST VIEWPORT: 左列 = 红绿灯行(28) + 暂存架(148) + 书签/iCloud/位置；右列 = 工作区标签条(28)
       + 图标工具条(36) + 窗格矩阵(每窗格自带地址栏) + 状态栏(24)。
FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review,
       the verdict, and DESIGN.md.
-->

## 0. 不可动摇的前提

- **混合原则（用户原话）**：搜索面板、设置窗、系统对话框、Quick Look、右键菜单等原生组件**保持原生不动**。本次只重做窗口主画面的顶部结构。
- **配色零新增**：不引入任何新品牌色。全部取现有 Theme/系统语义色（controlAccentColor 途径的 Theme.accent、labelColor 族、separatorColor、系统材质）。
- **北极星不回退**：四窗格闲置 CPU 0.0%。甲板全部是静态控件，禁止常驻动画/定时器。
- **元架构门禁**：BG-1（甲板视图不得直接调 FileManager 写 API）、FG-1（无假按钮——每个图标必须接真动作）、快捷键一律走 KeyBindings 注册表、新可配项进 Preferences。
- **确定性网格（frontend-design-methodology.md:84，机械执法 scripts/grid-lint.sh 已入 pre-commit）**：
  一切新增 UI 尺寸（constraint constant/spacing/edgeInsets）严格收敛 4pt 阶梯；仅 |值|≤2 的发丝线/视错觉
  修正与 0.5 小数豁免；存量偏离已入 grid-lint-allow.txt 基线（M18 清零），新代码禁止新增登记。

## 1. 窗口结构（弃 NSToolbar）

```
NSWindow: styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
          titleVisibility = .hidden, titlebarAppearsTransparent = true
          toolbar = nil（整个 NSToolbar/NSTrackingSeparatorToolbarItem 体系移除 → I-10 随之消亡）
          红绿灯保持系统默认位置（左列顶部行内）
```

```
┌───────────────┬────────────────────────────────────────────────┐
│ ●●●      (28) │ [工作区1][工作区2]                    [＋] (28) │ ← 工作区标签条
│───────────────│────────────────────────────────────────────────│ ← 发丝线
│   暂存架       │ ◀ ▶ ⌃ │ ⊞ ≡ ⫿ │ ᯤ ⌘ ⟳ 🗑 │ ▭ ▯▯ ⊟ ▤ ⊞ (36) │ ← 图标工具条
│   (148)       │────────────────────────────────────────────────│ ← 发丝线
│───────────────│                                                │
│ 书签           │        窗格矩阵（每窗格自带地址栏/窗格标签条）    │
│ iCloud        │                                                │
│ 位置           │────────────────────────────────────────────────│
│               │ 287 项 · 已选 3 项 · 可用 42.21 GB        (24) │ ← 状态栏（22→24 网格收敛）
└───────────────┴────────────────────────────────────────────────┘
        ↑ 唯一一条垂直分割线，从窗口顶贯通到底 = 用户要的"等高贯通"
```

- 左列（sidebarColumn）：NSVisualEffectView(.sidebar) 全高。顶部 28pt 红绿灯行（空白、可拖动窗口）；
  其下暂存架 148pt（现 StashShelfView，I-07 的居中重排在此列宽内完成）；其下书签 outline（现有）。
- 右列（contentColumn）：顶部甲板 TopDeckView = NSVisualEffectView(material: .titlebar) 内两行
  （标签条 28 + 工具条 36 + 两条发丝线），甲板下是现 PaneGridController.view，底部现状态栏。
- 分割：沿用现 manual NSSplitView（min160/max320/可折叠逻辑保留）。**侧栏折叠时**：甲板需给红绿灯
  让位——contentColumn 顶部行 leading inset 80pt（仅折叠态，4pt 阶梯）。
- 窗口拖动：甲板与红绿灯行空白处可拖（自定义 NSView.mouseDownCanMoveWindow=true 且命中非控件区）；
  双击甲板空白 = 系统缩放行为（依系统偏好 AppleActionOnDoubleClick）。

## 2. 工作区标签条（从原生 NSWindow tabbing 迁出 —— 本次最大迁移）

- 现状：M13 用原生窗口标签（tabbingIdentifier "NSpaceMain"）。原生标签栏横跨全窗，与贯通布局冲突，弃用
  （window.tabbingMode = .disallowed）。
- 新模型：`WorkspaceManager`（App 层）持有 `[WorkspaceState]` + activeIndex；
  WorkspaceState 直接复用 SessionStore 的 SessionWindow 编码（布局+窗格+标签+路径+排序+视图模式）。
- 切换 = 把当前 grid 会话快照存回数组 → 用目标状态 grid.restoreSession（隐藏窗格 watcher 挂起复用现机制）。
- 标签条 UI：复用/泛化现 TabBarView 语法（胶囊、hover 关闭、中键关闭、拖动重排 v1 可选）；活动标签
  Theme.accent 0.18 底 + labelColor，同现窗格标签风格；右端 "＋"。标题 = 该工作区活动窗格目录名。
- 快捷键（走 KeyBindings 注册表，沿用现 id）：⌘T 新工作区 / ⌘W 关闭（最后一个则关窗）/ ⌃⇥、⌃⇧⇥ 或
  ⌘⇧]、⌘⇧[ 循环。paneTabLimit 语义不变（窗格标签层）；工作区数上限新增 Preferences 键
  workspaceTabLimit（0=不限，超限覆盖最老，同 QSpace 语义）。
- 会话恢复：SessionStore 从"多窗口各存一份"改为窗口内含 workspaces 数组；老格式做一次性迁移
 （读到旧结构 → 包成单工作区）。拖出成独立窗口延后 v2（记 TODO，不算本次回归）。

## 3. 图标工具条（36pt，密度对齐 QSpace）

按钮 24×24、SF Symbol pointSize 13、间距 4、簇间发丝竖线分隔，全部图标+tooltip（隐性语义）。**排布与符号以 §6 定稿为准**：
| 簇 | 项 | 动作（全部已存在，1:1 迁移自现 NSToolbar） |
|---|---|---|
| 导航 | ◀ ▶（长按出历史菜单）⌃ | 现 navItemID 三联 |
| 视图 | ⊞ ≡ ⫿ 分段 | 现 viewMode segmented（syncViewModeControl 保留） |
| 动作 | AirDrop、终端、任务、废纸篓 | 现 airdrop/terminal/tasks/trashSel |
| 布局 | 单/双列/双行/三列/四宫格 分段 | 现 layout switcher |
| 最左 | 侧栏开关 ◫ | 现 toggleSidebar（自管宽度逻辑保留） |
FG-1：迁移时逐个接回 action+validate，禁止先摆图标后补功能。

## 4. 已知陷阱（前车之鉴，实现者必读）

1. 窗口 frame 持久化顺序：restore 必须在 `window.contentViewController =` 赋值**之后**（赋值会按
   fittingSize 收缩窗口）；shouldCascadeWindows=false；自管 "windowFrame" 键——这套现逻辑保留勿动。
2. NSSplitViewController 会泄漏 W==320/H==52 必需等式约束——继续用 manual NSSplitView，禁止回退。
3. PaneGrid 子视图必须设 autoresizingMask=[.width,.height]，makeSplit 等分名义 frame。
4. Foundation 的 resolvingSymlinksInPath 会剥 /private 前缀杀死 FSEvents——路径一律 POSIX realpath。
5. grep -cE 零命中退出码 1 会断 && 链；BSD sed 无 \b。
6. QLPreviewPanel 要 import QuickLookUI。
7. pod-lint-swift.sh 对 UISelfTest.swift 有 BG-1 豁免——新增自测场景写在该文件内。

## 5. 验收门（DoD——全绿才算完成）

1. `swift build` 0 error；`./scripts/test.sh` 全绿；meta-doctor 退出 0（pre-commit 自动拦）。
1b. `GRID_LINT_ALL=1 ./scripts/grid-lint.sh` 退出 0（M17 范围文件不靠基线，全量收敛）。
2. `./scripts/ui-smoke.sh` 现 13 断言全过 + 新增断言：无 NSToolbar；甲板两行高度 28/36；
   工作区标签条存在且 ⌘T/⌘W 增删正确；分割线全高（sidebarColumn.frame.height == contentView.height）；
   侧栏折叠/展开 3 轮窗口尺寸与右列布局不漂移（I-10 回归）；暂存架 contentGroup 居中（|center 差|≤2pt）。
3. UISelfTest 新场景截图：单/双/四窗格 + 折叠态 + 深浅两外观，人查无裁切/无错位。
4. 北极星复测：4 窗格闲置 top 采样 ≥6 次 CPU 0.0%。
5. 窗口 frame/侧栏宽度/会话（含工作区数组迁移）持久化 E2E 过（ui-smoke 两阶段法）。
6. 功能零丢失：原工具栏每个动作在甲板上可点且 validate 正确；搜索/设置/预览等原生组件未被触碰。
7. **网格收敛顺手项（已从 grid-lint 基线移除，本次必须收敛，否则 pre-commit 拦截）**：
   StatusBarView 高 22→24；PaneViewController 地址栏 26→24；SidebarViewController 暂存顶距 34→36、
   杂项 6→8、18→16 或 20；StashShelfView 10→12、-6→-8；TabBarView 3→4、-6→-8。
   其余存量偏离（设置页/Toast/FileCellViews）留在基线，M18 清零。

## 6. 用户定稿（2026-08-26，权威覆盖——与上文冲突处以本节为准）

### 6.1 图标：一律用官方原版 SF Symbols（用户点名）
- 实现只允许 `NSImage(systemSymbolName:)` 取**官方符号**，严禁自绘 path、严禁 emoji/文字充当图标。
- 定稿符号表（pointSize 13 / .regular；系统无此符号时用括号内回退）：
  | 动作 | 符号 |
  |---|---|
  | 后退/前进/上层 | `chevron.backward` / `chevron.forward` / `arrow.up` |
  | 显示类型三段 | `square.grid.2x2` / `list.bullet` / `rectangle.split.3x1` |
  | AirDrop | `airdrop`（回退 `dot.radiowaves.left.and.right`） |
  | 在终端打开 | `apple.terminal`（回退 `terminal`） |
  | 文件操作任务 | `arrow.up.arrow.down`（弃循环箭头，消除"刷新"误读） |
  | 布局五段（同族） | `rectangle` / `rectangle.split.2x1` / `rectangle.split.1x2` / `rectangle.split.3x1` / `rectangle.split.2x2` |
  | 侧栏开关 | `sidebar.leading` |
  | 暂存架五钮 | `doc.on.doc` / `arrow.forward.square` / `airdrop` / `trash` / `ellipsis.circle` |
  | 侧栏条目 | 保持现状：`folder.fill`/`icloud`/`internaldrive` + accent 着色 |

### 6.2 工具条排布：A1 左右分野（用户拍板）
`[侧栏开关] │ [◀ ▶ ⌃] │ [视图三段] ——弹性留白（兼窗口拖动把手）—— [AirDrop 终端 任务 废纸篓] │ [布局五段]`
簇间 16pt + 发丝竖线；左=高频导航/视图（就近内容），右=全局动作/布局。

### 6.3 暂存架：B2 hover-reveal 浮条（用户拍板，覆盖 §1 的常显动作列）
- **常态**：仅牌堆 + 计数药丸（10% 浅底、tabular-nums），组在 148pt 区内居中，牌堆可放大至约 112×100。
- **悬停暂存区 150ms**：底部浮出动作条（overlay 材质 + 发丝框 + 阴影，五钮 20×20 间距 4：
  拷贝/移动/AirDrop/清空/更多）。浮条是浮层，**不改变布局**（FG-4 空间防抖）；移出即隐。
- **拖拽悬停**：隐浮条，区内显示 accent 发丝内圈投放高亮（150ms 原位反馈）。
- **空态**：托盘符号（`tray.and.arrow.down`）+ "拖入文件暂存" muted 文案（空态说明下一步）。
- 计数药丸点击 = 现有逐项管理菜单（保留）。
- ui-smoke 断言相应改为：常态动作条 isHidden==true；牌堆容器居中（|center 差|≤2pt）；浮条为 overlay 不参与 Auto Layout 主链。

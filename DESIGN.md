---
name: NSpace
description: 原生 macOS 多窗格文件管理器——Finder 的材质语言 × QSpace 的密度，特色走结构与做工、不走色彩
colors:
  # 值 = AppKit 语义色标识符（唯一权威、随明暗动态解析）；无硬编码 hex 品牌色。
  ink-primary: "labelColor"          # 墨色一级（正文/活动态）
  ink-secondary: "secondaryLabelColor"  # 墨色二级（副信息/图标默认）
  ink-muted: "tertiaryLabelColor"    # 墨色三级（占位/丢失/单位）
  hairline: "separatorColor"         # 发丝分隔线
  surface-window: "windowBackgroundColor"
  surface-control: "controlBackgroundColor"
  surface-selected: "selectedContentBackgroundColor"  # 列表选中行（系统态）
  accent: "controlAccentColor"       # = Theme.accent 默认值；用户可经 8 色调色板覆盖
  error: "systemRed"                 # 原位错误横幅
typography:
  title:
    fontFamily: "system (-apple-system / SF Pro)"
    fontSize: "13px"
    fontWeight: 400
  body:
    fontFamily: "system (-apple-system / SF Pro)"
    fontSize: "12px"          # 列表/单元格默认；Preferences.listFontSize 可配 11–14
    fontWeight: 400
  label:
    fontFamily: "system (-apple-system / SF Pro)"
    fontSize: "11px"          # 甲板/状态栏/标签/分组标题等 chrome
    fontWeight: 400
  caption:
    fontFamily: "system (-apple-system / SF Pro)"
    fontSize: "10px"          # 侧栏行副标题（容量）
    fontWeight: 400
  numeric:
    fontFamily: "system monospaced-digit"
    fontSize: "12px"
    fontWeight: 500           # 暂存架计数药丸（tabular-nums 不跳字）
rounded:
  tab: "5px"      # 工作区标签胶囊
  pill: "8px"     # 计数药丸 / hover 浮条 / 投放环
spacing:
  optical: "2px"  # 视错觉/发丝微调（豁免项，非 4pt 阶梯）
  xs: "4px"
  sm: "8px"
  md: "12px"
  lg: "16px"
  xl: "20px"
  row: "24px"       # 地址栏/状态栏/侧栏行
  tab-row: "28px"   # 工作区标签条 / 红绿灯行
  toolbar-row: "36px"  # 图标工具条
components:
  workspace-tab-active:
    backgroundColor: "{colors.accent}"   # @ 18% alpha（见 Colors 强调色阶梯）
    textColor: "{colors.ink-primary}"
    rounded: "{rounded.tab}"
    height: "20px"
  workspace-tab-inactive:
    textColor: "{colors.ink-secondary}"
    rounded: "{rounded.tab}"
    height: "20px"
  icon-button:
    textColor: "{colors.ink-secondary}"  # contentTintColor；SF Symbol pointSize 13 / .regular
    size: "24px"
  count-pill:
    backgroundColor: "{colors.accent}"   # @ 10% alpha
    textColor: "{colors.ink-primary}"
    typography: "{typography.numeric}"
    rounded: "{rounded.pill}"
    height: "16px"
  pane-address-active:
    backgroundColor: "{colors.accent}"   # controlBackgroundColor 混入 10% accent
    height: "24px"
  status-bar:
    backgroundColor: "{colors.surface-window}"
    textColor: "{colors.ink-secondary}"
    typography: "{typography.label}"
    height: "24px"
---

# Design System: NSpace

> 面向未来贡献者与开源读者的视觉系统记录。**以真实代码为准（ground truth over intention）**：凡代码实测与
> `docs/design/M17-deck-spec.md` 规格或 `docs/design/mockup-m17.html` 版式稿不一致处，本文件如实记录代码事实，并在相应处标注差异。
> 新增 UI 必须同时满足本文件的原则与 `scripts/grid-lint.sh` 机械门禁（见 Do's and Don'ts）。

## Overview

**Creative North Star: "外科手术刀 · 实体透视工作台"（The Surgical Instrument / Structural Worktable）**

NSpace 是一台原生 macOS 专业文件工具，视觉标准 = **Finder 的材质语言 × QSpace 的信息密度**。它的身份不来自颜色，而来自**结构、密度与做工**：一条从窗口顶贯通到底的发丝分割线、左列压顶的暂存牌堆、右列的三层甲板——去掉全部内容后，仅凭这套拓扑就能认出是 NSpace。用户已明确否决"花里胡哨的 web 配色"（永久生效的品牌承诺，见 PRODUCT.md）：整套系统零新增品牌色，全部取现有主题系统（`Theme.accent`）与 macOS 语义色/系统材质。

性格是**克制、密集、原生**。密度即对 power user 时间的尊重：列表行 22pt、字号 12、发丝线代替边框、以留白距离代替卡片套娃。装饰服从北极星——四窗格闲置 CPU 0.0%，甲板全部是静态控件，禁止常驻动画或定时器。表达绝不遮蔽任务/状态/惯用可供性：哪个窗格有焦点、路径在哪、暂存架里有什么、任务跑到哪，打开即四件事同屏可扫。

明确的反参照（anti-reference）：**不做 web 风格的彩色世界、不做圆角卡片套娃、不做常驻重绘的炫技动效**。QSpace 是密度/功能基准，不是视觉模仿对象。自绘身份集中在日常主画面（甲板/窗格/暂存架/侧栏）；搜索面板、设置窗、系统对话框、Quick Look、右键菜单等原生组件保持原生不动（**混合原则**）。

**Key Characteristics:**
- **零新增色**：语义色 + 单一强调色（`Theme.accent`，用户可改），无一处硬编码品牌 hex。
- **确定性 4pt 网格**：一切尺寸收敛 4pt 阶梯，`grid-lint.sh` 机械执法（pre-commit）。
- **发丝线为界**：1px `separatorColor` 与留白距离取代边框和阴影。
- **系统材质分层**：`NSVisualEffectView`（`.sidebar` / `.titlebar`）提供深度，界面本身扁平。
- **隐性语义直达**：官方 SF Symbols + tooltip 承载操作，文字只在不可图标化处出现。
- **hover-reveal 纪律**：常态零杂质，动作在悬停/需要时才浮现（150ms 原位反馈）。

## Colors

调色板是**系统语义色 + 单一动态强调色**——没有静态品牌 hex；所有颜色随明暗外观自动解析。深浅两色都是一等公民（跟随系统）。

### Primary
- **强调色 Accent**（`{colors.accent}` = `controlAccentColor`）：唯一的品牌色声音。默认取系统强调色；用户可在设置里从 8 色调色板（`Theme.accentPalette`：红 `FF3B30` / 橙 `FF9500` / 黄 `FFCC00` / 绿 `28CD41` / 蓝 `007AFF` / 靛 `5E5CE6` / 紫 `AF52DE` / 粉 `FF2D55`）覆盖，或回落系统色。用于：活动工作区标签、计数药丸底、活动窗格地址栏、暂存投放高亮环、侧栏图标着色。**运行期改强调色/切明暗时，凡用 `cgColor` 缓存的 accent 处必须经 `.nspaceThemeChanged` 广播或 `viewDidChangeEffectiveAppearance` 重解析**（否则深色下渲染陈旧，见 `StashShelfView.applyAccentColors`）。

### Neutral（墨色三级 + 表面 + 发丝）
- **墨色一级**（`{colors.ink-primary}` = `labelColor`）：正文、活动标签文字、活动/存在的条目。
- **墨色二级**（`{colors.ink-secondary}` = `secondaryLabelColor`）：图标钮默认着色、副信息、非活动标签、状态栏文字。
- **墨色三级**（`{colors.ink-muted}` = `tertiaryLabelColor`）：空态图标与文案、目标丢失条目、侧栏容量副标题。
- **发丝线**（`{colors.hairline}` = `separatorColor`）：所有分隔（甲板两行间、窗格间、状态栏顶、簇间竖线、浮条边框）。
- **表面**：窗口底 `windowBackgroundColor`（状态栏/标签底衬）、控件底 `controlBackgroundColor`（地址栏底衬）；侧栏与甲板不是纯色而是**系统材质**（见 Elevation & Depth）。
- **选中行**（`{colors.surface-selected}` = `selectedContentBackgroundColor`）：列表/图标/分栏的选中态，走系统默认高亮（未自绘 accent-28%——与 mockup 的 `--surface-sel` 近似值不同，代码用系统态）。
- **错误红**（`{colors.error}` = `systemRed`）：侧栏原位错误横幅（3s 自退，严禁模态弹窗）。

### Named Rules

**零硬编码色规则（The Zero-Hex Rule）.** 展示层不得出现品牌 hex 字面量。唯一允许的 `NSColor(hex:)` 是渲染 `Theme.accentPalette` 的调色板色点（`AppearanceSettingsPage`）。其余一律语义色或 `Theme.accent`。结构性用色（`.black`/`.white`/`.clear`）只用于暗化覆盖层、浮条阴影、透明底——不承载品牌。

**强调色阶梯规则（The Accent-Alpha Rule）.** 强调色只以固定透明度阶梯出现，从不满铺大面积：**18%** = 活动工作区标签底；**10%** = 计数药丸底、活动窗格地址栏混入；**6%** = 拖拽投放环填充；**100%** = 投放环描边、侧栏条目图标着色。稀少与低饱和是重点——它标记状态，不做装饰。

## Typography

**字体家族：** 全系统字体（`.systemFont` / `-apple-system`，即 SF Pro / PingFang SC 回退），不引入自带字体。等宽数字用 `.monospacedDigitSystemFont`。

**性格：** 系统原生、紧凑、克制。字阶只有四档常规尺寸 + 一档等宽数字，靠字号与墨色三级建立层级，不靠字重堆叠。

### Hierarchy
- **Title**（regular, 13px）：侧栏条目标题、甲板图标 SF Symbol 的 `pointSize`（13 / `.regular`）。
- **Body**（regular, 12px，可配 11–14）：文件列表/图标/分栏单元格。经 `Preferences.listFontSize`（`Formatters.listFontSize`）外部化；字号 ≥13 时列表行高 24pt，否则 22pt（`FileListViewController.rowHeight(for:)`）。
- **Label**（regular, 11px）：甲板/状态栏/工作区标签文字、暂存空态文案、侧栏分组标题（此处 `.semibold`）、错误横幅。是界面里出现最多的尺寸。
- **Caption**（regular, 10px）：侧栏叶子行的容量副标题（`tertiaryLabelColor`）。
- **Numeric**（medium, 12px, monospaced-digit）：暂存架计数药丸——唯一使用 tabular 数字的地方。

### Named Rules

**墨色三级规则（The Three-Ink Rule）.** 文本颜色只在三级墨色间选择：`labelColor`（存在/活动）→ `secondaryLabelColor`（次要/静默）→ `tertiaryLabelColor`（占位/丢失/单位）。层级靠墨色与字号，不靠彩色文字。

**等宽数字克制规则（The Tabular-Where-It-Counts Rule）.** tabular 数字目前只用于暂存计数药丸。⚠️ 代码实测：状态栏"N 项 / 已选 M 项 / 可用 X GB"与列表的大小/日期列**用的是普通 `systemFont`，非 tabular**——与 mockup 版式稿（`font-variant-numeric: tabular-nums`）不一致，此处以代码为准。若后续为高频跳动的计数列引入 tabular，应统一走等宽数字字体。

## Layout

**拓扑（不可动摇，属结构不属可变视觉方向）：** 一条从窗口顶贯通到底的垂直发丝分割线，把窗口分成两列——这是 NSpace 的骨架。

```
┌───────────────┬────────────────────────────────────────────────┐
│ ●●●      (28) │ [工作区1][工作区2]                    [＋] (28) │ 工作区标签条
│───────────────│──────────────────发丝线─────────────────────────│
│   暂存架      │ [◫] │ [◀ ▶ ⌃] │ [⊞ ≡ ▥] ——留白—— [⤴ ⌘ ⇅ 🗑] │ [▭▯▯▤⊞] (36) │ 图标工具条
│   (148)       │──────────────────发丝线─────────────────────────│
│──────发丝──────│                                                │
│ 书签           │        窗格矩阵（每窗格自带地址栏(24)）          │
│ iCloud        │                                                │
│ 位置           │──────────────────发丝线─────────────────────────│
│               │ 287 项 · 已选 3 项 · 可用 42.21 GB        (24) │ 状态栏
└───────────────┴────────────────────────────────────────────────┘
                ↑ 唯一一条垂直分割线，全高贯通（sidebarColumn.height == contentView.height）
```

- **左列（全高侧栏）**：`NSVisualEffectView(.sidebar)`，顶部让出 36pt（红绿灯行 + 顶距，`stashView.top = 36`）→ 暂存架专区 148pt（恒高，空/满不跳变）→ 发丝分隔 → 书签/iCloud/位置的 source-list outline（行高 `.small`，QSpace 式紧凑）。宽度经手写 `NSSplitView` 管理（min 160 / max 320 / 可折叠）。
- **右列（内容列）**：顶部自绘甲板 `TopDeckView` = `NSVisualEffectView(.titlebar)` 内**两行**——工作区标签条 28pt + 发丝线 + 图标工具条 36pt + 发丝线；甲板下是窗格矩阵（`PaneGridController`），最底状态栏。**弃用 `NSToolbar`** 整条顶栏自绘（M17 决策）。
- **每窗格自带地址栏**：窗格 = 标签栏（默认隐藏，`showPaneTabBar`）+ 地址栏 24pt（面包屑⟷路径编辑）+ 发丝分隔 + 内容视图 + 底部状态栏 24pt。
- **窗口结构**：无标题栏（`titleVisibility=.hidden`、`titlebarAppearsTransparent`、`.fullSizeContentView`、`toolbar=nil`）；红绿灯保持系统默认位置（左列顶部行内）。**侧栏折叠时**标签行 leading 让位 80pt 给红绿灯（`trafficLightInset`，仅折叠态）。甲板空白处 `performDrag` 拖窗、双击按系统 `AppleActionOnDoubleClick` 缩放。

### 4pt 网格阶梯（确定性网格）

一切新增 UI 尺寸（约束常量 / spacing / `NSEdgeInsets` 四边）**严格收敛 4pt 阶梯**。实测在用阶梯值：`4 · 8 · 12 · 16 · 20 · 24 · 28 · 36 · 80 · 100 · 112 · 148`。

**豁免规则**（`scripts/grid-lint.sh`）：
1. **4 的倍数**——在阶梯上，直接放行。
2. **|值| ≤ 2**——发丝线与视错觉/重心微调（如标签栈 `spacing=2`、标题 `centerY` 常量 `-1`、地址栏内边距 `2`）。
3. **带小数**——0.5 发丝线。
4. **遗留/有意例外**登记 `scripts/grid-lint-allow.txt`（格式 `文件名:数值`，行内 `#` 写理由），不登记即红。

`grid-lint.sh` 默认**增量模式**（只查本次暂存的 `Sources/*.swift`，pre-commit 语义）；`GRID_LINT_ALL=1` 为全量审计（CI/验收门）。当前基线（`grid-lint-allow.txt`）只剩设置页（`*SettingsPage.swift`、`SettingsWindowController.swift`）、`Toast.swift`、`FileCellViews.swift:6` 等存量偏离，计划 M18 清零；**M17 范围文件（甲板/侧栏/暂存/标签/状态栏）已全量收敛，不靠基线**。

### 间距节奏（示例）
- 图标网格：item 间距/行距 8，section inset 12。
- 侧栏分组：以距离代边框——组间 16、组内 4（mockup 版式稿语义）。
- 甲板工具条：左簇 leading 8、右簇 trailing -8、左右簇最小间隙 8。

## Elevation & Depth

**基本扁平 + 系统材质分层**。深度不靠投影，靠三件事：(1) `NSVisualEffectView` 震动材质区分层级——侧栏 `.sidebar`、甲板 `.titlebar`、暂存浮条 `.menu`；(2) 1px 发丝线划界；(3) 强调色低透明度背景标记活动/选中态。界面在静止时是平的。

### Shadow Vocabulary（唯一一处真实阴影）
- **暂存 hover 浮条**（`StashShelfView.floatBar`）：`NSShadow` — 色 `black @ 28%`、`blurRadius 8`、`offset (0, -1)`，配 `.menu` 材质 + 1px `separatorColor` 边框 + 8pt 圆角。这是全系统唯一的结构性阴影，且只在悬停浮出时短暂出现。

### Named Rules

**静止即扁平规则（The Flat-At-Rest Rule）.** 表面静止时无阴影。深度来自系统材质与发丝线；阴影仅作为**状态响应**出现（暂存浮条 hover）。不要给甲板、窗格、卡片、按钮加常驻投影。

**材质而非填色规则（The Material-Not-Fill Rule）.** 侧栏与甲板用 `NSVisualEffectView` 材质（`blendingMode=.behindWindow`、`state=.followsWindowActiveState`），不是纯色填充——这样窗口失活时会自然去饱和，与系统一致。

## Shapes

**发丝线 + 极简圆角**的形语言。

- **发丝线**：水平分隔一律 `NSBox(boxType: .separator)`（系统语义色，自动明暗）；簇间竖线为 1px 宽 × 20pt 高的 `separatorColor` layer。宽度恒 1px。
- **圆角**：只有两档——工作区标签胶囊 **5px**（`{rounded.tab}`）；计数药丸 / hover 浮条 / 投放环 **8px**（`{rounded.pill}`）。
- **系统 bezel**：图标钮（`.accessoryBarAction`、`isBordered=false`、`.momentaryChange`）与分段控件（`.separated`）用系统外观，不自定义圆角/描边。
- **投放高亮**：拖拽悬停暂存区时显示 accent 发丝内圈（`ringView`，1px 边框 + 6% 填充 + 8pt 圆角，内缩 4pt），原位反馈、不改布局。
- **暂存牌堆**：最多 3 层图标错位堆叠（每层偏移 6pt，最新在顶），容器 112×100、图标 80×80。

## Components

按官方 SF Symbols 与语义色约束，逐个记录代码实测的形/色/态。

### 图标语汇（SF Symbols）
- **只用官方原版 SF Symbols**：实现仅允许 `NSImage(systemSymbolName:)`（经 `NSImage.officialSymbol(_:fallback:accessibility:)`），**严禁自绘 path、严禁 emoji/文字充当图标**。系统无此符号时用括号内回退。
- 甲板图标 `pointSize 13 / .regular`；暂存浮条 `12 / .medium`；侧栏推出 `10`；计数箭头 `8`；标签关闭 `7`。
- **定稿符号表（M17 §6.1，权威）：**

| 动作 | 官方符号（回退） |
|---|---|
| 后退 / 前进 / 上层 | `chevron.backward` / `chevron.forward` / `arrow.up` |
| 显示类型三段 | `square.grid.2x2` / `list.bullet` / `rectangle.split.3x1` |
| AirDrop | `airdrop`（回退 `dot.radiowaves.left.and.right`） |
| 在终端打开 | `apple.terminal`（回退 `terminal`） |
| 文件操作任务 | `arrow.up.arrow.down`（双向传输箭头，弃循环箭头以消除"刷新"误读） |
| 布局五段（同族） | `rectangle` / `rectangle.split.2x1` / `rectangle.split.1x2` / `rectangle.split.3x1` / `rectangle.split.2x2` |
| 侧栏开关 | `sidebar.leading`（回退 `sidebar.left`） |
| 暂存架五钮 | `doc.on.doc` / `arrow.forward.square` / `airdrop` / `trash` / `ellipsis.circle` |
| 暂存空态 | `tray.and.arrow.down` |
| 侧栏条目 | `folder.fill` / `icloud` / `internaldrive` + accent 着色 |

### 图标工具条（甲板第二行）
- **A1 左右分野**：`[侧栏开关] │ [◀ ▶ ⌃] │ [视图三段] —— 弹性留白（兼窗口拖动把手）—— [AirDrop 终端 任务 废纸篓] │ [布局五段]`。左 = 高频导航/视图（就近内容），右 = 全局动作/布局。
- **钮**：`icon-button` 24×24，`contentTintColor = secondaryLabelColor`，SF13。⚠️ **簇距实测**：不是字面 16pt——是 `NSStackView spacing=8` + 1px×20pt 发丝竖线，视觉≈16pt；右簇动作四钮内部 `spacing=4`。
- **分段控件**：导航 `.separated`/`.momentary`（段宽 26，长按后退/前进段 0.4s 弹历史菜单）；视图 `.selectOne`（段宽 28）；布局 `.separated`/`.selectOne`（段宽 28，段数 = `PaneLayout.allCases`）。
- **动作校验（FG-1，无假按钮）**：AirDrop/废纸篓需有选中才 enabled；终端/任务恒可用。响应链动作 `target=nil` 上抛活动窗格。

### 工作区标签（`TabBarView` / `TabItemView`）
- **胶囊**：圆角 5px，高 20pt，最大宽 160pt。**活动** = `Theme.accent @ 18%` 底 + `labelColor` 文字；**非活动** = 透明底 + `secondaryLabelColor`。字号 11。
- **hover-reveal 关闭钮**（`xmark`，SF7）：常态隐藏，鼠标进入才显示（仅当可关闭 `titles.count > 1`）；中键直接关闭。
- 甲板内复用时 `useTransparentBackground()` 透出 `.titlebar` 材质；末端 `＋` 新建。

### 计数药丸（暂存架，`count-pill`）
- 圆角 8px，高 16pt，`Theme.accent @ 10%` 底，文字 `labelColor`（⚠️ 非 accent 色文字——与 mockup 的 accent 文字不同），字体 12pt monospaced-digit medium，尾随 `chevron.down`（SF8）。
- 内容：单项显示文件名、多项显示数量。点击 = 逐项管理菜单（移除/清空）。

### 暂存架（`StashShelfView`，签名组件 · B2 hover-reveal）
- **常态**：148pt 区内只见牌堆 + 计数药丸，整组居中（`|center 偏移| ≤ 2pt`，I-07 回归）。牌堆 3 层错位堆叠。
- **悬停 150ms**：底部浮出动作条 `floatBar`（`.menu` 材质 + 发丝框 + 阴影，五钮 20×20 间距 4：拷贝/移动/AirDrop/清空/更多）。**浮条是 overlay（`frame` 定位，不入 Auto Layout 主链，不改布局——FG-4 空间防抖）**；移出即隐。
- **拖拽悬停**：隐浮条，显 accent 发丝内圈投放高亮（原位反馈）。
- **空态**：`tray.and.arrow.down`（`tertiaryLabelColor`）+ "拖入文件暂存" 11pt muted 文案。

### 窗格地址栏（`PaneViewController` / `AddressBarBacking`，`pane-address-active`）
- 高 24pt，面包屑 ⟷ 路径编辑器切换。底衬用 `updateLayer`（外观感知，明暗/主题广播自动重解析）。
- **活动窗格高亮**：⚠️ 实测为**整条底衬** `controlBackgroundColor` 混入 **10% accent**（`blended(withFraction:0.10)`），受 `Preferences.activePaneHighlight` 开关控制——**不是** mockup 的"2px accent 底缘光"。非活动窗格可选内容暗化（`inactivePaneDimming`，0~0.3，默认 0）。

### 文件列表 / 图标 / 分栏
- 列表行高 22pt（字号 <13）或 24pt（≥13）；`usesAlternatingRowBackgroundColors`（系统斑马）；选中走系统 `selectedContentBackgroundColor`。单元格字体 `Formatters.listFontSize`（默认 12），文字 `labelColor`/次要 `secondaryLabelColor`。
- 图标网格：item 间距/行距 8，section inset 12，`itemSize = 图标边长 + 32`。

### 状态栏（`StatusBarView`，`status-bar`）
- 高 24pt，`windowBackgroundColor` 底衬 + 顶部发丝线，两枚 11pt `secondaryLabelColor` 标签：左"N 项（已选 M 项）"、右"可用 X GB"。⚠️ 无药丸、无 tabular-nums（与 mockup 不同）。容量只在目录变化/标签切换时读一次（`statfs` 级只读），绝不轮询——北极星零空闲功耗。

### 侧栏（`SidebarViewController` / `SidebarLeafCell`）
- source-list outline，行高 `.small`；分组标题 11pt `.semibold` `secondaryLabelColor`。
- 叶子行：图标 16×16（accent 着色，Finder 蓝风格）+ 标题 13pt + 可选容量副标题 10pt `tertiaryLabelColor` + 推出钮（`eject.fill`，SF10，仅可推出卷显示）。目标丢失置灰 `tertiaryLabelColor`。
- 错误走原位横幅（3s 自退），非模态。

## Do's and Don'ts

面向新增 UI 的贡献者须知。**任何新 UI 必须同时过 `grid-lint` 与以下原则。**

### Do:
- **Do** 只用 macOS 语义色（`labelColor` 族 / `separatorColor` / `windowBackgroundColor` / `controlBackgroundColor`）与 `Theme.accent`；颜色随明暗动态解析。
- **Do** 把一切尺寸收敛 4pt 阶梯；发丝线/视错觉微调保持 |值|≤2 或 0.5 小数；提交前跑 `GRID_LINT_ALL=1 ./scripts/grid-lint.sh` 退出 0。
- **Do** 图标只用官方 SF Symbols，经 `NSImage.officialSymbol(...)` 取像并给 fallback + accessibility；每个图标配 tooltip。
- **Do** 用发丝线（`NSBox .separator`）和留白距离划界；深度交给 `NSVisualEffectView` 材质。
- **Do** accent 只以透明度阶梯出现（18% / 10% / 6% / 100%），标记状态而非铺装饰。
- **Do** 让动作 hover-reveal、150ms 原位反馈、浮层用 `frame` 定位不改主链布局（FG-4 空间防抖）。
- **Do** 缓存 accent `cgColor` 时监听 `.nspaceThemeChanged` 并 override `viewDidChangeEffectiveAppearance` 重解析。
- **Do** 每个新按钮接真动作 + `validate`（FG-1 无假按钮）；新可配项进 `Preferences`（外部化）；快捷键走 `KeyBindings` 注册表。

### Don't:
- **Don't** 写死品牌 hex 或 web 花哨配色；除渲染 `Theme.accentPalette` 色点外，展示层不得出现 `NSColor(hex:)`/`srgbRed:` 字面量。
- **Don't** 用非 4pt 尺寸而不登记 `grid-lint-allow.txt`——**M17 范围文件禁止新增登记**（pre-commit 会拦）。
- **Don't** 自绘图标 path、用 emoji/文字充当图标、或先摆图标后补功能。
- **Don't** 给静止表面加常驻投影/边框/圆角卡片套娃；唯一结构性阴影是暂存 hover 浮条。
- **Don't** 引入常驻动画/定时器或轮询（北极星：四窗格闲置 CPU 0.0%）。
- **Don't** 触碰原生已好用的组件（全局搜索/设置窗/系统对话框/Quick Look/右键菜单）——混合原则只重做主画面顶部结构。
- **Don't** 大面积满铺强调色或用彩色文字建立层级；层级靠墨色三级 + 字号。
- **Don't** 用 `--no-verify` 绕过 pre-commit（meta-doctor / pod-lint / grid-lint / tests）。

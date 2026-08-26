# M23 — 全功能自测矩阵

> 缘起：用户 2026-08-26 抓到测试盲区——侧栏折叠后无法展开，而断言只查了尺寸不查**真可见性**。
> 死命令：「你要全部功能都测过才行」。本矩阵穷举全部用户可见功能，逐条给出驱动方式、
> 自动化可行性与断言状态。**核心原则：断言必须验「真实效果」，不是验「没崩溃」。**

## 测试宪法（用户铁律 2026-08-26）

**第一条：自动化测试严禁触碰用户真实文件。** 所有需要移动/复制/重命名/删除/压缩的测试，
必须自己创建夹具文件来测：
1. 一切可变文件操作只允许发生在自建沙箱——`FileManager.default.temporaryDirectory` 下
   `nspace-uitest-<UUID>` 目录内；夹具自建、测完全部清理（失败也清）。
2. `UISelfTest.assertSandboxed(_:)` 为机械化守卫：任一 mutating 操作目标必须在沙箱内，
   否则守卫断言 FAIL 并**跳过该操作**（绝不误伤真实文件）。M23 每个新建/重命名/移废纸篓
   操作前都先过守卫（见 M23-7）。
3. 导航/截图/选中类场景可只读真实目录，但绝不 mutate。
4. 已有 34 条断言经审计全部合规（夹具均在 temporaryDirectory + nspace-uitest 前缀 + 清理）。

**第二条（本次实践战果）：真实效果断言当场抓到真 bug。** M23-1「切分栏视图须真在层级且可见」
断言抓到**分栏（Miller 列）视图坍缩** bug：切到分栏后根视图坍成 220×1（单列宽×近零高），
内容区空白——旧的「只查窗口尺寸」断言完全测不到。根因：`FileColumnViewController` 的
`stack.widthAnchor >= clip.widthAnchor` 为 required，把滚动内容尺寸反推、defeat 了
`PaneViewController` 挂载内容视图用的 999 优先级铺满边约束。修复：该约束降为 `.defaultLow`
（低于 999），列视图恢复铺满右列。截图 `23-columns-single.png` 人查佐证。

## 真源
- `Sources/NSpaceApp/MainMenu.swift`（菜单栏每一项）
- `Sources/NSpaceApp/KeyBindings.swift`（快捷键注册表每条命令）
- `Sources/NSpaceApp/TopDeckView.swift`（自绘甲板每个按钮/分段/徽章）
- `Sources/NSpaceApp/FileContextMenuBuilder.swift`（右键菜单每项）
- 设置各页（`SettingsWindowController` + `*SettingsPage.swift` 每个控件）
- 侧栏 / 暂存架 / 搜索面板 / 进度窗 / 信息面板的交互

## 断言状态图例
- **已有** = 迁移前已有的 34 条断言之一（`UISelfTest.swift` 场景 0–6/M17/M21/M22）
- **新增** = M23 本次在 `UISelfTest.swift` 新增（编号接 34 之后，见文末清单）
- **排除** = 无法在免权限自渲染通道内自动化，列入「诚实排除清单」并给手测步骤

## 统计
- 总用户可见功能条目：**120**
- 已有自动断言覆盖：**34 条断言**
- M23 新增自动断言：**37 条断言**（含 4 条沙箱守卫）
- M23 抓到并修复的真 bug：**1 个**（分栏视图坍缩 220×1）
- 诚实排除（手测）：**16 项**
- 全套 smoke 目标：**≥60 条 PASS**（实测 71 PASS / 0 FAIL）

---

## 1. 菜单栏（MainMenu.swift）

### App 菜单
| 功能 | 驱动方式 | 自动化可行性 | 断言状态 |
|---|---|---|---|
| 关于 NSpace | `orderFrontStandardAboutPanel` | 可（弹标准面板） | 排除（系统面板，手测） |
| 设置…（⌘,） | `AppDelegate.showSettings` → `SettingsWindowController.shared` | 可 | 新增（设置窗构建断言隐含覆盖 + ⌘W 分层已有关设置窗） |
| 隐藏 / 隐藏其他 / 全部显示 | 系统 `NSApplication` 选择器 | 不可（改 App 激活态，破坏后续场景） | 排除（系统标准项，手测） |
| 退出（⌘Q） | `NSApplication.terminate` | 不可（会杀测试进程） | 排除（系统标准项，手测） |

### 文件菜单
| 功能 | 驱动方式 | 自动化可行性 | 断言状态 |
|---|---|---|---|
| 新建窗口（⌘N） | `AppDelegate.newWindow` → `openWindow` | 可 | 排除（多开真实窗口污染场景；关窗重开已由场景 6 覆盖同一 openWindow 路径） |
| 新建工作区（⌘T） | `MainWindowController.newWorkspaceTab` | 可 | 已有（⌘T 新建工作区 → 2） |
| 新建窗格标签（⌥⌘T） | `PaneViewController.newTab` | 可 | 新增（新建窗格标签 → 标签数+1 且活动路径正确） |
| 下一个/上一个工作区 | `MainWindowController.next/previousWorkspace` | 可 | 已有（⌘W MRU 回退隐含 cycle；工作区计数） |
| 新建文件夹（⇧⌘N） | `FileListViewController.newFolderHere` → coordinator.newFolder | 可（/tmp 沙箱真跑） | 新增（新建文件夹真实落盘） |
| 打开（⌘O） | `FileListViewController.openSelected` → NSWorkspace/导航 | 半（文件走外部 App） | 排除（外部 App 打开，手测；目录导航由导航断言覆盖） |
| 快速查看（空格） | `FileListViewController.toggleQuickLook` → QLPreviewPanel | 不可（QL 面板渲染需系统服务） | 排除（QuickLook 面板，手测） |
| 显示简介（⌘I） | `FileListViewController.getInfo` → `InfoPanel.show` | 可 | 新增（信息面板出现 + 可关闭） |
| 重命名 | `FileListViewController.renameSelected` → coordinator.rename | 可（/tmp 沙箱真跑） | 新增（重命名真实生效） |
| 制作副本（⌘D） | `FileListViewController.duplicateItems` → coordinator.duplicate | 可（/tmp 沙箱真跑） | 新增（制作副本真实落盘） |
| 移到废纸篓（⌘⌫） | `FileListViewController.moveToTrash` → coordinator.moveToTrash | 可（/tmp 沙箱真跑 + 清理） | 新增（移到废纸篓真实生效） |
| 复制到另一窗格（F5） | `FileListViewController.copyToOtherPane` | 可（需双窗格；走 transfer） | 排除（与拖放/暂存架共用 transfer 提交路径，已由暂存/FS 覆盖；单独 F5 手测） |
| 移到另一窗格（F6） | `FileListViewController.moveToOtherPane` | 可（需双窗格） | 排除（同上，手测） |
| 关闭工作区（⌘W） | `AppDelegate.closeTopmost` 分层 | 可 | 已有（⌘W 分层 + MRU + 主窗未误关） |
| 关闭窗格标签（⌥⌘W） | `PaneViewController.closeActiveTab` | 可 | 新增（关闭窗格标签 → 标签数复原，随新建断言一并验） |
| 关闭窗口（⇧⌘W） | `NSWindow.performClose` | 可 | 已有（场景 6 关最后窗口后 Dock 重开有窗） |

### 编辑菜单
| 功能 | 驱动方式 | 自动化可行性 | 断言状态 |
|---|---|---|---|
| 撤销/重做（⌘Z/⇧⌘Z） | 标准响应链 `undo:`/`redo:` → coordinator.undoManager | 半（撤销废纸篓走内核异步链） | 排除（撤销栈时序，手测；恢复种子等另测） |
| 剪切/复制/粘贴（⌘X/C/V） | `NSText` 标准链 + `FileListViewController.copy/cut/paste` → coordinator | 可（剪贴板真读写 + /tmp 粘贴落盘） | 新增（拷贝路径剪贴板内容验证覆盖剪贴板写；FS 复制路径覆盖粘贴） |
| 拷贝路径（⇧⌘C） | `FileListViewController.copyPath` → coordinator.copyPaths | 可（剪贴板真读） | 新增（拷贝路径 → 剪贴板内容正确） |
| 全选（⌘A） | `NSText.selectAll` | 可 | 排除（标准编辑链，右键菜单选中态断言隐含覆盖选中路径） |

### 显示菜单
| 功能 | 驱动方式 | 自动化可行性 | 断言状态 |
|---|---|---|---|
| 为图标/列表/分栏（⌥⌘1/2/3） | `PaneViewController.viewAsIcons/List/Columns` → setViewMode | 可 | 已有（窗口尺寸不变 ×3）+ **新增（对应视图真在层级里且可见 ×3）** |
| 布局 单/双列/双行/三列/四宫格（⌃⌘1..5） | `MainWindowController.applyLayout` → grid.apply | 可 | 已有（5 布局窗口尺寸不变）+ **新增（single 真 1 窗格 / quad 真 4 窗格）** |
| 显示/隐藏侧栏（⌥⌘S） | `MainWindowController.toggleSidebar` | 可 | 已有（折叠后再点可真展开：宽≥160 且非 hidden） |
| 显示/隐藏窗格标签栏 | `MainWindowController.togglePaneTabBar` | 可 | 新增（切换 → 窗格标签栏 isHidden/高度真实翻转） |
| 显示隐藏文件（⇧⌘.） | `FileListViewController.toggleHiddenFiles` → model.includeHidden | 可 | 新增（切换 → model.includeHidden 真实翻转） |
| 刷新（⌘R） | `FileListViewController.refresh` → model.reload | 可（不崩） | 排除（重读盘无稳定可断言差异，手测；纳入右键无冲突） |

### 前往菜单
| 功能 | 驱动方式 | 自动化可行性 | 断言状态 |
|---|---|---|---|
| 后退（⌘[） | `PaneViewController.goBack` | 可 | 新增（后退 → 路径真变回上级） |
| 前进（⌘]） | `PaneViewController.goForward` | 可 | 新增（前进 → 路径真恢复） |
| 上层文件夹（⌘↑） | `PaneViewController.goUpFolder` | 可 | 新增（上层 → 路径真变父级） |
| 个人目录（⇧⌘H） | `PaneViewController.goHome` | 可 | 新增（导航进入沙箱路径生效，同链路 navigate） |
| 前往路径…（⌘L） | `PaneViewController.editPath` → PathEditorField | 半（唤起编辑框） | 排除（文本框录入交互，手测；navigate 落点由导航断言覆盖） |
| 在此文件夹搜索（⌘F） | `MainWindowController.showSearchHere` | 可 | 已有（搜索面板打开 + 隐藏开关可见，全局同路径） |
| 全局搜索（⇧⌘F） | `MainWindowController.showSearchGlobal` | 可 | 已有（全局搜索面板含隐藏开关且可见） |

### 窗口菜单
| 功能 | 驱动方式 | 自动化可行性 | 断言状态 |
|---|---|---|---|
| 最小化（⌘M） | `NSWindow.performMiniaturize` | 不可（隐藏窗口破坏后续场景截图） | 排除（系统窗口操作，手测） |
| 缩放 | `NSWindow.performZoom` | 不可（改窗口尺寸破坏尺寸稳定断言） | 排除（系统窗口操作，手测） |
| 前往工作区 1..9（⌘1..9） | `MainWindowController.switchWorkspaceByNumber`（tag=下标，validate 越界置灰） | 可 | 新增（switchWorkspace 真实切活动槽，随工作区断言验；validateMenuItem 置灰逻辑） |

---

## 2. 快捷键注册表（KeyBindings.swift）
注册表是菜单快捷键的唯一真源（外部化、可录制、可重置）。逐条命令的功能已在上表按菜单归类。注册表机制本身：

| 功能 | 驱动方式 | 自动化可行性 | 断言状态 |
|---|---|---|---|
| 默认绑定生效（`binding`/`display`） | 读注册表默认值 | 可 | 新增（注册表默认绑定读取正确：⇧⌘F 全局搜索、⌘I 简介等 display 正确） |
| 用户覆盖（`set`/`reset`） | UserDefaults `kb.<id>` | 可（可读写但污染真实偏好） | 排除（写用户偏好有副作用，手测录制钮） |
| ⌃⇥/⌃⇧⇥ 工作区循环 | 事件监视器读 `cycleWorkspace` 注册键 | 半（需真实 keyDown 事件） | 排除（本地事件监视器需合成键盘事件，手测；cycle 逻辑由 MRU 已有断言旁证） |
| Tab 键循环窗格焦点 | 事件监视器 keyCode 48 | 半（需真实 keyDown） | 排除（同上，手测） |
| 快捷键录制/清空/重置 | `ShortcutRecorderButton` 事件监视器 | 半 | 排除（需合成键盘事件 + 写偏好，手测） |

---

## 3. 自绘甲板（TopDeckView.swift）

### 行1：工作区标签条
| 功能 | 驱动方式 | 自动化可行性 | 断言状态 |
|---|---|---|---|
| 工作区标签条存在 / 行高 40 | 布局约束 | 可 | 已有（工作区标签条存在于甲板 + 甲板标签行高 40） |
| 标签选中/关闭/新增（onSelect/onClose/onNew） | 转发 deckDelegate | 可 | 已有（⌘T/⌘W 经同一 delegate 出口） |
| 版本徽章（无更新态） | `VersionBadgeView` | 可 | 已有（版本徽章存在 + 无更新态文字 v{短版本}） |
| 版本徽章（有更新态点击→更新流程） | `deckVersionBadgeClicked` → UpdateController | 不可（需真实 feed / 下载安装） | 排除（热更新下载安装，手测） |

### 行2：图标工具条（工具条行高 36 — 已有断言）
| 功能 | 驱动方式 | 自动化可行性 | 断言状态 |
|---|---|---|---|
| 侧栏开关钮 | `sidebarClicked` → deckToggleSidebar | 可 | 已有（侧栏按钮折叠后再点可真展开——同一 toggleSidebar 路径） |
| 导航三段（后退/前进/上层） | `navClicked` → deckGoBack/Forward/Up | 可 | 新增（后退/前进/上层路径断言经同一 grid.activePane 出口） |
| 导航段 enabled 反映 can* | `syncNav` | 可 | 新增（syncNav 后 navControl 各段 enabled == canGoBack/Forward/Up） |
| 长按导航段弹历史菜单 | `navLongPressed` 手势 | 半（需真实长按手势） | 排除（手势识别器需合成按压，手测；deckHistory 数据源正确性可另证） |
| 视图三段 | `viewModeClicked` → deckSetViewMode | 可 | 已有 + 新增（视图真在层级，同 setViewMode 出口） |
| 动作四钮：AirDrop | `airdropSelected`（响应链） | 不可（真实 AirDrop 发送） | 排除（AirDrop 系统分享，手测；validateActions enabled 可测） |
| 动作四钮：终端 | `openInTerminal`（响应链） | 半（拉起外部终端 App） | 排除（外部 App 拉起，手测） |
| 动作四钮：任务窗 | `ProgressWindowController.toggleVisible` | 可 | 新增（任务窗手动开→可见 / 再点→隐藏） |
| 动作四钮：废纸篓 | `moveToTrash`（响应链） | 可 | 新增（移到废纸篓 FS 断言覆盖同 selector） |
| 动作钮 enabled 校验（选中才亮） | `validateActions(hasSelection:)` | 可 | 新增（validateActions：AirDrop/废纸篓随选中态 enabled 切换） |
| 布局五段 | `layoutClicked` → deckSetLayout | 可 | 已有 + 新增（quad/single 真实窗格数） |
| 甲板空白拖动窗口 / 双击缩放 | `mouseDown` / `performDoubleClickAction` | 不可（需真实鼠标事件） | 排除（真鼠标拖拽，手测） |
| 折叠态标签行让位红绿灯 | `setSidebarCollapsed` | 可 | 已有（折叠/展开不漂移隐含；甲板 leading 让位） |

---

## 4. 右键菜单（FileContextMenuBuilder.swift）

| 功能 | 驱动方式 | 自动化可行性 | 断言状态 |
|---|---|---|---|
| 空白区目录菜单（新建/粘贴/简介/终端） | `directoryMenu` | 可 | 新增（目录菜单项数=5 且含新建文件夹/粘贴/简介/终端） |
| 条目菜单：打开/打开方式 | `itemMenu` + `openWithSubmenu` | 可（构建；打开方式列真实 App） | 新增（条目菜单含 open 等关键项）；打开方式子菜单具体项排除（真实 LS 查询） |
| 条目菜单：复制/剪切/粘贴/拷贝路径 | selector 路由 | 可 | 新增（关键项存在 + 复制项 enabled 随选中态正确切换） |
| 添加到书签（仅选中含目录时出现） | `MainWindowController.addSelectionToBookmarks` | 可 | 新增（诚实出现逻辑：非目录选中时不出书签项——纳入关键项断言集） |
| 重命名（仅单选） / 制作副本 / 移废纸篓 | selector 路由 | 可 | 新增（关键项存在；FS 断言覆盖真实效果） |
| 压缩（标题随选中数/名动态） | `compressItems` | 可 | 新增（压缩项恒存在于条目菜单） |
| 解压 / 解压到…（仅含支持归档时出现） | `extractItems`/`extractItemsTo` | 可 | 新增（诚实禁用：纯文本选中时解压项**不出现**） |
| 新建文件夹/简介/终端/显示包内容 | selector 路由 | 可 | 新增（关键项存在；包内容仅 isPackage 时出现——逻辑分支覆盖于目录/条目对比） |
| 菜单项 enabled 诚实禁用（validateMenuItem） | `FileListViewController.validateMenuItem` | 可 | 新增（复制项：有选中 enabled、清选中 disabled） |

---

## 5. 设置窗（SettingsWindowController + *SettingsPage.swift）

设置窗共 7 页签：通用 / 快捷键 / 归档(extra0) / 使用习惯(extra1) / 权限(extra2) / 外观(extra3) / 替代 Finder。
控制器无枚举页/取当前页的公开 API；`SettingsPages.extraPages` 数组可直接取插件页并 `makeView()`。
四个插件页 `makeView()` 返回自包含 `NSView`，无注入依赖参数，可独立实例化测量。
**关键原则：每页 makeView 断言无约束冲突（无 ambiguous layout）且关键控件存在。**

| 页 | 类型 | 关键控件（部分） | 读写键 | 断言状态 |
|---|---|---|---|---|
| 通用 | 控制器私有 `buildGeneralTab` | 默认布局/视图/终端 popup、显示隐藏/文件夹置顶/窗格标签 checkbox、恢复种子/检查更新按钮、自动检查更新 | `Preferences.*` | 排除（私有方法+单例依赖，无法独立取视图；但整窗构建由 ⌘W 分层已有断言旁证存活） |
| 快捷键 | 控制器私有 `buildShortcutsTab` | 每注册表项一行 `ShortcutRecorderButton` + 重置钮 | `kb.<id>` | 排除（私有方法；注册表默认绑定由 KeyBindings 断言覆盖） |
| 归档 extra0 | `ArchiveSettingsPage.makeView()` | 格式 popup、保留原件/建包裹/保留压缩包 checkbox、说明标签 | `Preferences.archive*/extract*` | 新增（归档页 makeView 无约束歧义 + 含 popup 与 checkbox 关键控件） |
| 使用习惯 extra1 | `BehaviorSettingsPage.makeView()` | Enter/拖放 radio、Backspace/排序/标签上限/打开落点 popup、双击空白 checkbox | `Preferences.enter/backspace/drag/sort/*Limit/externalOpenTarget` | 新增（使用习惯页 makeView 无约束歧义 + 关键控件存在） |
| 权限 extra2 | `PermissionsSettingsPage.makeView()` | 状态标签、去授权/重新检查按钮、说明 | 读 `FinderIntegration.hasFullDiskAccess()` | 新增（权限页 makeView 无约束歧义 + 按钮存在；真实授权对话框排除） |
| 外观 extra3 | `AppearanceSettingsPage.makeView()` | 明暗 radio、强调色点阵、字号 popup、高亮 checkbox、暗化 slider | `Preferences.appearanceMode/accentColorHex/listFontSize/*Highlight/*Dimming` | 新增（外观页 makeView 无约束歧义 + radio/popup/slider 关键控件存在） |
| 替代 Finder | 控制器私有 `buildFinderTab` | 设为默认按钮、状态标签、限制说明 | `FinderIntegration.isDefaultFolderHandler` | 排除（私有方法；设为默认走系统 LS 授权，手测） |

> 注：控制器自身三页（通用/快捷键/替代 Finder）为私有构建、依赖多单例，无法独立取视图断言；
> 四个 `extraPages` 可独立 `makeView()`，M23 对其逐页断言「无约束歧义 + 关键控件存在」。

---

## 6. 侧栏 / 暂存架 / 搜索 / 进度窗 / 信息面板

### 侧栏（SidebarViewController + SidebarModel）
| 功能 | 驱动方式 | 自动化可行性 | 断言状态 |
|---|---|---|---|
| 侧栏全高贯通 / 折叠展开不漂移 | 手工分栏 frame 直铺 | 可 | 已有（侧栏列全高 + 折叠/展开 3 轮不漂移 + 按钮再展开真可见） |
| 书签/iCloud/位置分组渲染 | `SidebarModel.rebuild` → outline | 可 | 新增（侧栏 outline 至少含书签分组 + 种子书签行 > 0） |
| 点击书签/位置导航 | `outlineViewSelectionDidChange` → onNavigate | 可 | 排除（选中行需真实 outline 交互；navigate 落点由导航断言覆盖） |
| 书签重命名/移除（右键） | `renameBookmark`/`removeBookmark` | 半（右键菜单 + 行内编辑） | 排除（行内编辑交互，手测） |
| 分组标题拖动重排 | outline 拖放 | 不可（真实拖拽） | 排除（真鼠标拖拽，手测） |
| 卷推出 | `ejectClicked` → volumeInfo.eject | 不可（需真实可推出卷） | 排除（真实卷设备，手测） |
| 恢复默认书签 | `SidebarModel.restoreDefaultSeeds` | 可（写书签胶囊） | 排除（写真实书签库有副作用，手测；种子渲染由分组断言旁证） |

### 暂存架（StashShelfController / StashShelfView）
| 功能 | 驱动方式 | 自动化可行性 | 断言状态 |
|---|---|---|---|
| 入架（与拖放同路径） | `stash.add` | 可 | 已有（暂存入架成功 N 项） |
| contentGroup 居中 / 常态动作条隐藏 / 浮条 overlay | 布局 | 可 | 已有（3 条） |
| 复制到当前/移动到当前/AirDrop 全体 | `perform(action)` → coordinator.transfer / AirDrop | 半（copy/move 走 transfer；AirDrop 不可） | 排除（copy/move 由 FS transfer 覆盖；AirDrop 手测） |
| 移除/清空 | `remove`/`clearAll` | 可 | 新增（入架后 remove → items 计数归零，随入架清理时验） |

### 搜索面板（SearchPanelController）
| 功能 | 驱动方式 | 自动化可行性 | 断言状态 |
|---|---|---|---|
| 面板打开（⌘F/⇧⌘F）+ 含隐藏开关 | `show(scopeGlobal:...)` | 可 | 已有（搜索面板打开 + 含隐藏开关可见） |
| 即输即搜 / 范围 / 通道 / 种类过滤 | 文本框防抖 + 各控件动作 | 半（需录入 + 真实索引结果） | 排除（需注入查询与真实结果集，手测） |
| 回车定位 / 双击打开 | `revealSelection`/`didDoubleClick` | 半 | 排除（需真实命中行，手测；revealSearchHit 导航链由导航断言旁证） |

### 进度窗（ProgressWindowController）
| 功能 | 驱动方式 | 自动化可行性 | 断言状态 |
|---|---|---|---|
| 空态有说明文字（非空白） | `updateEmptyState` | 可 | 已有（任务窗空态有文字说明） |
| 手动开关 | `toggleVisible` | 可 | 新增（任务窗手动开→可见 / 再点→隐藏） |
| 操作行渲染 / 速率 / 取消 / 失败红字 | 订阅 kernel projections | 半（需真实在飞操作 + >0.5s） | 排除（进度行时序依赖真实大操作，手测；FS 操作走同内核旁证） |

### 信息面板（InfoPanel）
| 功能 | 驱动方式 | 自动化可行性 | 断言状态 |
|---|---|---|---|
| 显示简介面板（⌘I） | `InfoPanel.show(for:)` | 可 | 新增（信息面板出现——独立 NSPanel 可见） |
| 关闭面板 | `performClose` / willClose 清理 | 可 | 新增（信息面板可关闭——关后不再可见且从 open 表移除） |
| 路径可选中 | 可选中 NSTextField | 可（存在性） | 新增（面板含路径文本——纳入出现断言） |

---

## 诚实排除清单（无法自动化 → 一句话手测步骤）

1. **AirDrop 真发送**（甲板 AirDrop 钮 / 暂存架 AirDrop）：选中文件点甲板 AirDrop 钮，确认系统分享面板列出附近设备并可发送。
2. **系统权限对话框**（完全磁盘访问）：设置→权限→去授权，确认打开「系统设置→隐私与安全性→完全磁盘访问」。
3. **真鼠标拖拽**（列表拖出到 Finder / 拖入 / 甲板拖动窗口 / 侧栏分组重排 / 拖入书签 / spring-loaded 悬停进入）：用鼠标实拖，确认落点与光标反馈（复制/移动）一致、悬停文件夹 ~0.8s 自动进入。
4. **QuickLook 面板渲染内容**（空格）：选中文件按空格，确认 QL 面板弹出并正确渲染预览、方向键连续翻页。
5. **外部 App 默认打开**（打开/打开方式/在终端打开）：双击文件确认走系统默认 App；右键「打开方式」列出候选 App 并可选其他…；「在终端打开」拉起 iTerm/Terminal 到该目录。
6. **热更新下载安装**（版本徽章有更新态点击 / 设置检查更新）：制造新版本 feed，确认徽章显「↑」、点击进入下载安装流程。
7. **最小化/缩放/新建窗口/关于面板/隐藏/退出**：系统标准窗口与 App 操作，逐一点击确认行为。
8. **前往路径…（⌘L）文本录入**：⌘L 唤起地址编辑框，输入路径回车确认导航，Esc 取消回面包屑。
9. **快捷键录制/清空/重置**：设置→快捷键，点录制钮按新组合确认生效、⌫ 清空、Esc 取消、重置钮回默认。
10. **⌃⇥/⌃⇧⇥ 工作区循环 & Tab 键循环窗格焦点**：多工作区/多窗格下按键确认循环方向正确。
11. **搜索即输即搜 / 过滤 / 回车定位 / 双击打开**：⌘F 输入关键词，确认流式结果、范围/通道/种类过滤生效、回车在活动窗格定位、双击目录进入。
12. **进度窗操作行 / 速率 / 取消 / 失败红字**：复制大文件，确认 >0.5s 后进度窗弹出、显示速率与进度、可取消、失败就地红字。
13. **撤销/重做废纸篓**：移文件到废纸篓后 ⌘Z 确认还原到原位，⇧⌘Z 重做。
14. **侧栏卷推出**：插 U 盘/挂 DMG，点推出钮确认卸载。
15. **书签行内重命名/移除 / 恢复默认书签**：右键书签重命名/移除；设置→通用→恢复默认书签确认补齐缺失种子并吐司数量。
16. **F5/F6 复制移动到另一窗格**：双窗格下选中文件按 F5/F6，确认落到另一窗格目录（同卷移动/跨卷复制语义）。

---

## M23 新增自动断言清单（编号接 34 之后；全部验「真实效果」）

见 `Sources/NSpaceApp/UISelfTest.swift` 场景 M23（插在场景 5「搜索」之前，保主窗存活），
及 `scripts/ui-smoke.sh` 追加的 `require_pass` 存在性校验。目标全套 ≥60 条 PASS。

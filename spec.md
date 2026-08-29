# NSpace 技术规格 (spec.md)

> 原生 macOS 多窗格文件管理器，仿 QSpace Pro 核心体验。macOS 27 / Swift 6.4 / 纯 AppKit / SwiftPM + 脚本打包（无 Xcode）。

## 一、北极星 (North Star)

**在 macOS 27 上提供一个日常可完全替代 Finder/QSpace 的多窗格文件管理器，且空闲 CPU ≈ 0%。**

- 用户逃离 QSpace 的原因是卡顿与高 CPU；本产品的第一验收物是性能：万级条目目录秒开顺滑、4 窗格空闲时 `top` 采样 CPU ≈ 0%。
- 核心体验闭环：多窗格布局(1/2H/2V/3/4) + 每窗格多标签 + 面包屑地址栏 + 左侧书签栏 + 暂存架 + 空格 Quick Look + 完整文件操作（队列/进度/冲突/撤销）+ 双击走系统默认打开方式 + 可设为默认文件夹处理程序。
- 反目标（v1 不做）：批量重命名、压缩引擎、哈希、文件夹同步、网络盘、工作区快捷键、着色规则——全部靠新胶囊零侵入后补。

## 用户故事与验收样例 (User Stories & Acceptance Examples)

> outside-in 需求真源（见 references/spec-by-example-and-bdd-masters.md）：用户故事是"要什么"，下方状态机/数据契约/容错矩阵是其技术分解，两向必须闭合。每条故事附可机判的 Given-When-Then 关键样例（正/边界/异常）。

- **US-1 多窗格并排搬运**：作为整理文件的人，我想在两个窗格里并排浏览不同目录，把文件从一侧搬到另一侧，以便不来回切目录。
  - 正：Given 双列布局、左窗格选中 3 个文件；When 按 F6（移动到另一窗格）；Then 3 文件出现在右窗格目录、左窗格消失、操作回执 filesDone==3。
  - 异常：Given 目标目录已有同名文件；When 移动；Then 弹冲突面板（替换/合并/取消 + 应用到此文件夹），选取消则源与目标都不变。

- **US-2 同目录复制不误删**：作为怕丢文件的人，我在同一文件夹内复制粘贴时，即使手滑选"替换"，也绝不能把源文件删掉。
  - 边界（自源）：Given destination 经 inode 判定即 source 本体；When 裁决替换/合并；Then 一律收敛为改名保留（源完好、新增副本），绝不 removeItem 源。

- **US-3 按月找文件**：作为找不久前文件的人，我想让列表/图标视图按修改月份分组，以便快速定位。
  - 正：Given 目录含 3 个不同年月的文件、排序键=修改日期、分组开；When 打开列表或图标视图；Then 呈现 3 个组头「YYYY年M月」，点组头折叠该组、右键可"仅显示此组"。

- **US-4 设置与窗口尺寸跨版本更新保留**：作为长期用户，我调好的窗口大小、侧栏宽度、列显隐、书签、快捷键，在应用更新到新版本后必须原样保留，不能回默认。
  - 正：Given 窗口调至 1333×733 且改过侧栏宽/列显隐；When 经热更新（替换 .app + 重启）或任意重启；Then 新版本窗口仍为 1333×733、其余设置不变。
  - 根因不变量：窗口几何由自管 `windowFrame` 键单一权威恢复，`isRestorable=false` 杜绝 macOS 原生恢复在版本变更（savedState 被系统作废）时的竞争；一切设置存于 `~/Library`（UserDefaults / Application Support），更新不覆盖。

- **US-5 空闲零功耗**：作为整天开着文件管理器的人，我不想它在后台空耗 CPU。
  - 正：Given 四窗格常驻、无操作；When `top` 采样 60s；Then 进程 CPU ≈ 0%（后台标签/窗格 FSEventStream 真停、缩略图请求滚出即取消）。

## 二、职责五元组 (Responsibility Contract)

| 对象 | Decision Owner | Execution Owner | Commit Owner | Lifecycle Owner | Proof Owner |
| --- | --- | --- | --- | --- | --- |
| 文件系统变更（复制/移动/废纸篓/新建/重命名） | UI 收集意图 → `FileOpsCoordinator` 构造 `OperationSpec` | `Transfer`/`TrashOps` 等胶囊节点 | **文件系统本身**（macOS）；操作生命周期状态由 `OperationKernel.RunStore` 唯一提交 | `OperationKernel`（排队/取消/排空） | 节点返回的 `OperationReceipt`（字节数/目标路径/耗时）+ 进度流日志 |
| 目录展示内容 | `DirectoryViewModel`（何时加载/过滤/排序） | `DirectoryReader` 胶囊 | 无共享可写状态——`DirectorySnapshot` 是文件系统的只读投影 | 各窗格 `PaneViewController`（挂起/恢复） | snapshot 代际 token + FSEvents 回调时间戳 |
| 书签 | `SidebarViewController` 发 Command | `BookmarkStore` 胶囊 | `BookmarkStore` actor（唯一写 `bookmarks.json`，原子替换） | AppDelegate（启动加载/退出落盘） | JSON 落盘文件 + 版本号 |
| 暂存架内容 | `StashShelfViewController` 发 Command | `StashStore` 胶囊 | `StashStore` actor（唯一写 `stash.json`） | 同上 | JSON 落盘 + URL bookmark Data |
| 窗口/窗格/标签会话 | `MainWindowController`（何时快照） | `SessionStore` 胶囊 | `SessionStore` actor（唯一写 `session.json`，防抖 1s） | AppDelegate | JSON 落盘 |
| 图标/缩略图缓存 | 各视图控制器按可见行请求 | `IconThumb` 胶囊 | 无权威状态（纯派生缓存，可随时丢弃） | `IconThumb` LRU | 缓存命中率不作证据要求 |

单一真源裁决：任何 UI 组件严禁直接调用写型 FileManager API 或直接写 JSON——展示层只发 Typed Command、消费只读投影（BG-1/BG-5，由 pod-lint-swift.sh 机检 NSpaceApp 目录禁用写型 API）。

## 三、状态机 (State Machines)

### 3.1 操作 Run 状态机（OperationKernel 唯一提交）

```
pending ──开始──▶ scanning ──发现冲突──▶ awaitingConflict ──用户裁决──▶ running
   │                 │ 无冲突 ─────────────────────────────────────────▶ │
   │                 │                                                   ├──全部完成──▶ completed
   │                 │                                                   ├──节点抛错──▶ failed(errorClass)
   └──取消──────────┴──取消─────────────(任意非终态)──────────────────────┴──取消──────▶ cancelled
```

- 终态：`completed` / `failed` / `cancelled`，不可再转移；取消是协作式（节点在 copyfile 回调查 `Task.isCancelled` 返回 `COPYFILE_QUIT`）。
- `awaitingConflict` 通过 `CheckedContinuation` 挂起，冲突面板回填决议（替换/跳过/两者保留/合并 + 应用到全部）后恢复。

### 3.2 目录浏览状态机（每标签 BrowserState）

```
idle ──navigate(url)──▶ loading(gen=N) ──snapshot(gen=N)──▶ loaded ──FSEvent──▶ loading(gen=N+1)
                              │ snapshot(gen<N) 到达 → 丢弃（代际防过期覆盖）
loaded ──标签隐藏──▶ suspended（挂起 watcher/缩略图，记录 mtime）──标签显示──▶ mtime 变则 loading，否则 loaded
```

### 3.3 行内重命名（FG-6 乐观回滚）

```
displaying ──Enter/菜单──▶ editing(快照旧名) ──提交──▶ renaming ──FS 成功──▶ displaying(新名)
                                │ Esc ──▶ displaying(旧名)          └─FS 失败──▶ 原子回滚旧名 + 原位错误横幅
```

## 状态转移矩阵 (Transition Matrix)

操作 Run 状态机（3.1）的表格化真值——(当前态 × 事件 → 次态)；`—` 表示非法转移（忽略）。终态不可再转移。

| 当前态 \ 事件 | scan开始 | 发现冲突 | 无冲突 | 用户裁决 | 全部完成 | 节点抛错 | 取消 |
|---|---|---|---|---|---|---|---|
| pending | scanning | — | — | — | — | — | cancelled |
| scanning | — | awaitingConflict | running | — | — | failed | cancelled |
| awaitingConflict | — | — | — | running | — | failed | cancelled |
| running | — | — | — | — | completed | failed | cancelled |
| completed / failed / cancelled（终态） | — | — | — | — | — | — | — |

- 目录浏览（3.2）：`idle→loading(gen=N)→loaded`；旧代际 snapshot(gen<N) 到达即丢弃；`loaded→suspended`（标签隐藏）→按 mtime 决定回 `loading` 或 `loaded`。
- 行内重命名（3.3）：`displaying→editing→renaming→displaying`；FS 失败原子回滚旧名。

## 四、数据契约 (Data Contracts)

全部为 Sendable 值类型；胶囊 public 面只含契约类型与协议（Contract.swift）。

```swift
// 目录投影（DirectoryReader 输出）
struct FileItem: Sendable, Hashable {
    let url: URL; let name: String
    let isDirectory: Bool; let isPackage: Bool; let isSymlink: Bool; let isHidden: Bool
    let size: Int64?              // 文件字节数；目录为 nil（FolderSize 按需回填）
    let modified: Date?; let created: Date?
    let contentTypeID: String?    // UTType.identifier，kind 显示串按此缓存派生
}
struct DirectorySnapshot: Sendable {
    let directory: URL; let generation: UInt64
    let items: [FileItem]         // 已按 SortOrder 排序、按 showHidden 过滤
    let error: DirectoryError?    // 不可读目录等
}

// 操作契约（UI → 内核）
struct OperationSpec: Sendable {
    enum Kind: Sendable { case copy, move, trash, duplicate, newFolder, newFile, rename }
    let kind: Kind; let sources: [URL]; let destination: URL?
    let newName: String?          // rename/newFolder/newFile 用
}
struct OperationProjection: Sendable {   // 内核 → 进度窗（只读投影，AsyncStream 推送）
    let id: UUID; let state: RunState
    let filesDone: Int; let filesTotal: Int
    let bytesDone: Int64; let bytesTotal: Int64
    let currentPath: String?; let failure: OperationFailure?
}
enum ConflictDecision: Sendable { case replace, skip, keepBoth, mergeFolders }

// 错误三分类（每胶囊 Error 必须归入其一，BG-4/P6.4）
enum ErrorClass: Sendable { case logic /*内部逻辑错,禁重试*/, transient /*系统抖动,可重试*/, external /*权限/卷不可用,提示用户*/ }
```

存储契约：`~/Library/Application Support/NSpace/{bookmarks,stash,session,frecency}.json`，Codable + 临时文件原子替换；stash 项存 URL bookmark `Data`（抗改名）；session 结构 = 窗口→frame/布局→窗格→标签→(路径/视图模式/排序/选中集)；frecency 结构 = path→(count/lastAccess)。

## 前置条件 (Preconditions)

操作提交前必须成立的守卫（不满足即拒绝并原位反馈，绝不产生半成品或误伤）：

| 操作 | 前置条件 | 不满足时 |
| --- | --- | --- |
| 复制/移动（Transfer） | 源存在且可读；目标目录可写；自源冲突（destination==source，inode 判定）时替换/合并安全收敛为改名 | 拒绝并进度行标红；自源绝不删源 |
| 移到废纸篓 / 重命名（LocalOps） | 目标在可变夹具内、非只读卷；新名非空且同目录无未决撞名 | 原子回滚旧名 + 原位错误横幅 |
| 分组（FileGrouping） | 偏好开启 且 排序键为日期类（修改/创建/添加） | 不分组，单线列表 |
| 外部打开落点复用（openFileURLs） | `externalOpenTarget != "newWindow"` 且存在活动主窗口 | 回落开新窗口 |
| 会话/frecency 落盘 | 恢复完成（sessionReady）后的状态变化才落盘 | 恢复期变化被 guard 挡下，不自我覆盖 |
| 测试可变操作（UISelfTest） | 目标路径经 assertSandboxed 在自建临时夹具内；session/frecency/windowFrame 走 UITEST 隔离键/目录 | 机械拒绝，绝不碰用户真实文件/偏好 |

## 五、容错矩阵 (Fault-Tolerance Matrix)

| 故障 | 检测点 | 处置 | 用户可见行为 |
| --- | --- | --- | --- |
| 目录不可读（权限/TCC 未授权） | DirectoryReader 抛 external | 投影带 error 字段 | 窗格内原位空态 + "授权指引"按钮，不弹窗轰炸 |
| 复制中途源/目标卷消失 | copyfile 返回错误 → external | Run→failed，已复制的完整文件保留、半成品删除 | 进度行标红 + 原位重试按钮 |
| 复制目标重名 | ConflictScan 预检 | Run→awaitingConflict 挂起 | 冲突面板四选项+应用到全部 |
| 用户取消 | Task.isCancelled → COPYFILE_QUIT | Run→cancelled，清理当前半成品 | 进度行显示"已取消" |
| FSEvents 流创建失败 | DirectoryWatch 返回 transient | 降级为手动刷新（⌘R 可用），不崩 | 无感知（自动刷新静默失效） |
| JSON 落盘失败（磁盘满） | Store 原子写抛错 | 保留内存态 + 下次防抖重试；连续失败原位横幅 | 一次性提示，不阻塞操作 |
| 缩略图生成崩溃/超时 | QLThumbnail 错误 | 回退通用 UTType 图标（BG-7：遥测/装饰失败不伤主链） | 只是图标不精美 |
| 会话恢复时路径已消失 | 启动时逐标签 stat | 该标签回退个人目录 | 标签仍在，位置回家 |
| 重命名 FS 失败 | rename 抛错 | FG-6 原子回滚旧名 | 原位横幅，严禁白屏 |

## 六、做工不变量 (Craftsmanship Invariants)

- **无真实功能则删界面元素**：不留死按钮/占位菜单；空态/加载骨架/禁用态是功能，不得删。
- **就地闭环**：一切错误与冲突在发生位置原位呈现（横幅/面板/行内标红），严禁模态白屏或跳页。
- **后台零功耗**：非活动标签/窗格挂起 watcher、取消缩略图、零轮询——这是北极星，不是优化项。
- **Finder 肌肉记忆**：⌘1/2/3 视图、⌘⇧. 隐藏、⌘⌫ 废纸篓、空格 QL、⌘L 路径、⌘[/⌘] 历史、⌘↑ 上层；深浅色全自动跟随。
- **中文为主双语**：所有 UI 串过 L10n，zh-Hans 为 base。
- **4pt 网格**：自绘控件（面包屑/标签栏/暂存架）间距对齐 4pt 标尺。
- **观察者主语律**：面向用户的文案全部大白话（"两者都保留"，不是"KeepBoth 策略"）。

## 七、验收检查清单 (Acceptance Checklist)

- [ ] `meta-doctor ~/development/NSpace` 退出 0（pre-commit 常驻）
- [ ] `swift test` 全绿（L-plan）；每胶囊有 `nspace-probe` 子命令可单独驱动（L-readonly / L-irreversible 于 /tmp 夹具树）
- [ ] `./scripts/run.sh` 启动：浏览家目录、/usr/bin 万级条目秒开顺滑滚动
- [ ] 双击 zip → Bandizip（系统默认打开方式）；双击文件夹窗格内导航
- [ ] 四宫格布局 + 每窗格多标签 + Tab 焦点循环 + 活动窗格高亮
- [ ] 面包屑点击/chevron 子目录跳转/⌘L 补全/拖文件到分段
- [ ] 侧边栏书签拖入-排序-重命名-删除，卷推出，iCloud Drive 可浏览
- [ ] 暂存架拖入→批量复制/移动/AirDrop，重启保留
- [ ] 复制多 GB 夹具树：实时字节进度、可取消、冲突四选项、⌘Z 撤销废纸篓
- [ ] 空格 Quick Look、方向键连续预览
- [ ] 终端 `touch` 新文件 ≤0.5s 出现在窗格
- [ ] **4 窗格空闲 `top` 采样 CPU ≈0%**（附真实采样输出于 README）
- [ ] 设为默认后 `open ~/Downloads` 弹 NSpace；文件路径 open → 父目录+选中
- [ ] 重启恢复上次窗格/标签/路径；中文系统下全中文 UI

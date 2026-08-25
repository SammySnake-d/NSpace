# NSpace

原生 macOS 多窗格文件管理器——QSpace Pro 的开源风格替代品，为 macOS 27 而生。**性能是第一卖点：空闲 CPU ≈ 0%。**

![版本](https://img.shields.io/badge/version-0.6.0-blue) 纯 AppKit · Swift 6 严格并发 · 无 Xcode 构建（SwiftPM + CLT）

## 功能一览（v0.6.x）

- **多窗格布局**：单窗格 / 双列 / 双行 / 三列 / 四宫格（⌃⌘1..5 或工具栏切换），Tab/⇧Tab 循环窗格焦点，活动窗格高亮
- **工作区标签**：⌘T 新建（每个标签 = 完整分屏布局，QSpace 语义），可拖出成独立窗口；窗格内标签栏为可选项（显示菜单开启，⌥⌘T/⌥⌘W）
- **地址栏**：可点面包屑 + chevron 子目录下拉 + ⌘L 路径编辑（实时补全）+ 分段拖放投递
- **左侧边栏**：暂存架（拖入暂存→批量复制/移动/AirDrop，跨启动持久化）、个人收藏、自定义书签（拖入/重排/重命名）、卷列表（容量/推出）
- **文件操作**：拷贝/剪切/粘贴/拷贝路径 ⌘⇧C/重命名（行内，失败原子回滚）/制作副本/废纸篓+⌘Z 撤销/新建文件夹/F5/F6 跨窗格复制移动；操作队列进度窗（可取消）；冲突四选项（替换/跳过/两者保留/合并+应用到全部）
- **拖拽**：与 Finder/其他 App 互拖；同卷移动/跨卷复制/⌥ 强制复制；spring-loaded 悬停进入
- **Quick Look**：空格多格式预览，方向键连续预览，多选批量预览
- **实时刷新**：FSEvents ≤1s 自动刷新；**后台标签/窗格全部挂起监听（零功耗）**，恢复按 mtime 比对
- **按需信息**：可见目录行异步回填文件夹大小；图片/视频/PDF 升级真实缩略图；底部状态栏（项目数/选中数/可用空间）
- **双击走系统默认打开方式**（zip → 你设置的解压工具）
- **替代 Finder**：设置（⌘,）里一键"设为默认文件夹打开程序"——`open` 命令与第三方 App 打开文件夹都会呼出 NSpace
- 中文为主双语 UI；深浅色自动跟随

开发中：聚焦搜索（Spotlight + 独家隐藏文件通道）、图标网格/分栏视图、会话完整恢复。规划见 `TODO.md`，历史见 `CHANGELOG.md`。

## 构建与运行（无需 Xcode，只需 Command Line Tools）

```bash
./scripts/run.sh            # 构建并启动
./scripts/run.sh install    # 安装到 /Applications 并注册 LaunchServices
./scripts/test.sh           # 全量测试（CLT 环境的 swift-testing 参数已封装）
```

产物：`build/NSpace.app`（版本号取自 `VERSION`，构建号 = git 提交数）。

## 权限说明（TCC / 完全磁盘访问）

- 非沙盒应用。首次访问 桌面/文稿/下载/外置卷 时系统会弹一次授权。
- 需要浏览全部位置（如 ~/Library、其他用户目录）：系统设置 → 隐私与安全性 → 完全磁盘访问 → 勾选 NSpace（设置窗口内有直达按钮）。
- 默认 ad-hoc 签名：**每次重新构建 TCC 授权会重置**。要让授权持久，用钥匙串助理创建自签代码签名证书后：`SIGN_IDENTITY="证书名" ./scripts/build-app.sh`。

## 已知限制（诚实清单）

- `NSWorkspace.activateFileViewerSelecting`（部分 App 的"在 Finder 中显示"）由系统硬编码发给 Finder，无法拦截——QSpace 同样如此。能接管的是 LaunchServices 打开文件夹的全部路径。
- 全文搜索依赖 Spotlight 索引；隐藏文件仅支持按文件名搜索（Spotlight 不索引隐藏文件，NSpace 用自建扫描通道补齐）。

## 架构（供贡献者）

按可组合执行元架构的原子论构建，执法由 `meta-doctor` + `scripts/pod-lint-swift.sh` + pre-commit 机检（见 `META_COMPLIANCE.json` / `spec.md`）：

```
Sources/
├── NSpaceContracts/   # 契约词汇表（值类型/协议，唯一共享面）
├── NSpaceKernel/      # 操作内核：排队/取消/进度/Run 状态机（零业务分支）
├── Pods/<胶囊>/       # 语义原子节点：Contract.swift 唯一 public 面 + 私有实现
│   ├── DirectoryReader / Transfer / LocalOps      # 读目录 / 复制移动 / 重命名新建废纸篓
│   ├── DirectoryWatch / FolderSize / IconThumb    # FSEvents / 目录大小 / 缩略图
│   ├── PathComplete / VolumeInfo                  # 路径补全 / 卷信息
│   └── BookmarkStore / StashStore / SessionStore  # 书签 / 暂存架 / 会话（各自唯一 Commit Owner）
├── NSpaceApp/         # 展示层（纯代码 AppKit；严禁直接写文件——一切经 OperationSpec 交内核）
└── NSpaceProbe/       # CLI 探针：每胶囊一个子命令，绕过 UI 单独驱动（不进 .app）
Tests/<胶囊>Tests/     # 黑盒测试：只经公开契约，真实临时夹具，无 Fake Mock
```

探针示例：`nspace-probe list /usr/bin` · `nspace-probe copy SRC DST --progress` · `nspace-probe watch DIR` · `nspace-probe size DIR` · `nspace-probe thumb IMG --size 128`

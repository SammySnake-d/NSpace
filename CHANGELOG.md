# Changelog

本项目遵循 [语义化版本](https://semver.org/lang/zh-CN/)。0.y.z 为开发期版本：每完成一个里程碑 bump minor 并打 git tag。

## [0.4.0] - 2026-08-25

### 新增
- 多窗格布局：单窗格/双列/双行/三列/四宫格，⌃⌘1..5 或工具栏分段控件切换，切布局保留窗格状态
- 每窗格独立多标签页：⌘T 新建、⌘W 关闭、中键关闭、胶囊样式、hover 显关闭钮
- Tab / ⇧Tab 循环窗格焦点，活动窗格地址栏高亮描色
- 工具栏（unified 样式）布局切换器（SF Symbols 图标 + tooltip）

### 修复
- 四宫格/多列布局某行列塌陷：NSSplitView 按子视图旧 frame 比例分配空间，复用窗格携带旧尺寸导致塌陷——加入 split 前显式预设等分 frame

## [0.3.0] - 2026-08-25

### 新增
- 面包屑地址栏：分段点击跳转、chevron 弹出该级子目录菜单、点击空白或 ⌘L 进入编辑模式
- 路径编辑器：输入即补全（PathComplete 胶囊：~ 展开/大小写不敏感/仅目录）、Enter 导航、无效路径原位抖动、Esc 取消
- 浏览历史：返回 ⌘[ / 前进 ⌘] / 上层文件夹 ⌘↑（每标签独立历史栈）

### 修复
- 内存爆炸（数秒膨胀至 4.4GB、窗口无法创建）：面包屑用 deletingLastPathComponent 向根遍历成死循环——macOS 对 "/" 返回 "/.."，永不等于自身；改为按 path 组件正向构建，并修正 BrowserState 同款隐患

## [0.2.0] - 2026-08-25

### 新增
- 单窗格文件列表：view-based NSTableView（固定行高/行复用），名称/修改日期/大小/种类可排序列
- 双击文件按系统默认打开方式打开（zip→Bandizip 等）；双击文件夹窗格内导航
- ⌘⇧. 显示/隐藏隐藏文件、⌘R 刷新、空文件夹/无权限原位空态
- UTType 图标与种类串缓存、相对日期格式化

## [0.1.0] - 2026-08-25

### 新增
- 元架构合规基线：META_COMPLIANCE.json（spec/backend/frontend）、spec.md 七节、pod-lint-swift.sh、pre-commit 执法（meta-doctor + pod-lint + 测试）
- 无 Xcode 构建管线：SwiftPM + build-app.sh 组装 .app + 签名；CoreGraphics 生成图标；CLT swift-testing 宏插件/rpath 固化（scripts/test.sh）
- OperationKernel：业务中立操作内核（排队/取消/进度切面/Run 状态机原子提交/AsyncStream 投影）
- DirectoryReader 胶囊：resource key 预取 + Finder 式排序 + 代际 token
- Transfer 胶囊：预扫描→冲突裁决（替换/跳过/两者保留/合并）→copyfile 字节级进度 + APFS 克隆快路径 + 同卷 rename + 协作式取消（无半成品）
- nspace-probe CLI 探针：list / copy 子命令（三级验收阶梯）

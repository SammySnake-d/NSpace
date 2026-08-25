# Product

<!-- impeccable:product-schema 1 -->

## Platform

macos-native（AppKit 全代码 UI；不在 web/ios/android 枚举内，如实记录。设计语言以 macOS 桌面惯例为底线）

## Stack

Swift 6 + AppKit 纯编程式 UI，SwiftPM 无 Xcode 构建（CLT），可组合执行元架构（pods/胶囊 + META_COMPLIANCE + meta-doctor 门禁）。UI 渲染只能用 AppKit 视图层能力（layer-backed NSView / Core Animation / NSVisualEffectView / SF Symbols / NSWorkspace 文件图标），无 web 技术栈。

## Users

主用户：项目所有者本人——macOS 27 上的重度文件管理用户，QSpace Pro 付费用户（因 QSpace 卡顿/高 CPU 而自建替代品）；终端（iTerm）+ 多窗格并用的开发者式工作流。开源后目标受众：同类 power user——嫌 Finder 信息密度低、要多窗格/暂存架/键盘直达的人。

## Product Purpose

原生 macOS 文件管理器，替代 Finder 与 QSpace：多窗格（单/双/三/四）布局、窗口级工作区标签、暂存架、聚焦搜索（含隐藏文件通道，超越 QSpace）、归档、书签侧栏、Space 预览。成功标准：交互密度与功能对齐 QSpace，性能显著优于它（北极星：四窗格闲置 CPU 0.0%）。

## Positioning

「QSpace 的功能，Finder 的原生性，谁都没有的性能」——直接子级 FSEvents 过滤 + 后台窗格挂起做到闲置零成本，这是 QSpace 在 macOS 27 上做不到的。开源差异化（用户 2026-08-26 原话）：完全自绘 UI/UX、最大程度定制化、"开源的时候比较有特色"——视觉身份本身是卖点之一。

## Operating Context

长时间常驻的桌面工具：与 iTerm、Bandizip 等共存；深/浅色都要好（跟随系统）；双击压缩包等一律交系统默认程序；作为 public.folder 默认处理程序被第三方 App 唤起。多窗格同屏 + 侧栏 + 暂存架是常态画面。

## Capabilities and Constraints

- 结构拓扑已定（不属于视觉方向可变项）：左列 = 暂存架(顶) + 书签/iCloud/卷分组侧栏，全高贯通；右列 = 自绘顶部甲板（工作区标签条 + 工具条 + 地址栏）+ 窗格矩阵 + 底部状态栏。M17 决策：弃系统 NSToolbar，整条顶栏自绘。
- Operate 模式硬约束：信息密度 ≥ QSpace（用户反复点名占空比）；表达不得遮蔽任务/状态/惯用可供性。
- 元架构门禁：BG-1（展示层禁写文件 API）、FG-1..FG-6（无假按钮/做工不变量）、外部化配置（主题色/字号/外观已在 Preferences，新令牌一律走外部化）、隐性语义 > 显性文字（图标优先）。
- 性能北极星不可回退：四窗格闲置 0.0% CPU；自绘不得引入常驻重绘。
- 快捷键全部走 KeyBindings 注册表，不硬编码。

## Brand Commitments

名称 NSpace。图标已有（scripts/make-icns.sh 生成）。用户明确绑定的视觉承诺（2026-08-26 原话，永久生效）：
- **配色用当前主题系统**（Theme.accent / Preferences.appearanceMode / accentColorHex），拒绝"花里胡哨的 web 配色"——彩色世界方向已被用户否决，视觉标准 = 原生 macOS 专业工具（Finder 的材质语言 × QSpace 的密度），特色走结构、布局与做工，不走色彩。
- 自绘定制与原生**混合**（"像 QSpace 一样原生和自定义混合，比如全局搜索就可以用现在已经实现的这个原生组件"）——身份定制集中在顶部甲板/窗格/暂存架/侧栏等日常主画面；搜索面板、设置窗、系统对话框、Quick Look 等原生已好用的组件保持原生。
- 开源可辨识度（"有特色"）；QSpace 是功能/密度基准，不是视觉模仿对象（推断标注：此前"做成像 QSpace 一模一样"针对的是暂存架交互密度，2026-08-26 的完全自绘决定取代了视觉上照抄 QSpace 的路线）。

## Evidence on Hand

真实运行的 v0.8.0 app（build/NSpace.app）；UISelfTest 自渲染截图管线 + scripts/ui-smoke.sh 回归；用户提供的 QSpace/Finder 截图若干（密度与布局基准）。无营销素材、无用户证言——开源 README 截图即门面。

## Product Principles

1. 密度即尊重：同屏幕展示更多列、更多行、更少留白，是对 power user 时间的尊重。
2. 零闲置成本：任何视觉方案先过北极星，装饰不得常驻烧 CPU。
3. 隐性语义直达：图标+微 tooltip 承载操作，文字只在不可图标化处出现。
4. 状态永远可见：哪个窗格有焦点、操作进行到哪、暂存架里有什么——扫一眼必须知道。
5. 外部化到底：视觉令牌（色/字号/密度）进 Preferences，用户可改，开源者可 fork 出自己的皮。

## Accessibility & Inclusion

键盘全可达（快捷键注册表）；深浅色双适配；可见焦点态。无已确认的额外标准要求（未定项，如实记录）。

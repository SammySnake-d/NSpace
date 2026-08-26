#!/usr/bin/env bash
# UI 冒烟：无需任何系统权限的自动化 UX 回归（frame 持久化端到端 + 视图/布局尺寸稳定
# + 任务窗空态 + 暂存入架 + 搜索面板）。产物 /tmp/nspace-ui/{report.txt,*.png}
set -uo pipefail
cd "$(dirname "$0")/.."
./scripts/build-app.sh >/dev/null 2>&1 || { echo "构建失败"; exit 1; }
pkill -x NSpace 2>/dev/null; sleep 0.5
rm -rf /tmp/nspace-ui

BIN=build/NSpace.app/Contents/MacOS/NSpace
# 阶段A：设定 frame 900x520 并退出（触发 autosave）
NSPACE_UITEST=1 NSPACE_UITEST_SETFRAME="900,520" "$BIN" >/dev/null 2>&1
# 阶段B：重启断言恢复 + 跑全场景
NSPACE_UITEST=1 NSPACE_UITEST_EXPECTFRAME="900,520" "$BIN" >/dev/null 2>&1
CODE=$?
echo "==== UI 冒烟报告 (exit=$CODE) ===="
cat /tmp/nspace-ui/report.txt 2>/dev/null || echo "(无报告)"
echo "截图: $(ls /tmp/nspace-ui/*.png 2>/dev/null | wc -l | tr -d ' ') 张 → /tmp/nspace-ui/"

# M17 新增断言存在性校验（防断言被误删/跑空即"绿"）：报告须含以下 PASS 行
REPORT=/tmp/nspace-ui/report.txt
require_pass() {
  if ! grep -qF "PASS $1" "$REPORT" 2>/dev/null; then
    echo "✗ 缺 M17 断言或未通过: $1"; CODE=1
  fi
}
require_pass "无 NSToolbar"
require_pass "甲板标签行高 40"
require_pass "甲板工具条行高 36"
require_pass "工作区标签条存在于甲板"
require_pass "版本徽章存在于甲板标签条"
require_pass "版本徽章无更新态文字"
require_pass "⌘T 新建工作区"
require_pass "⌘W 关闭工作区"
require_pass "侧栏列全高贯通"
require_pass "折叠/展开 3 轮窗口尺寸与右列布局不漂移"
require_pass "暂存架 contentGroup 居中"
require_pass "暂存架常态动作条隐藏"

# I-19/I-21 回归断言（v0.9.3）
require_pass "全局搜索面板含「包含隐藏文件」开关且可见"
require_pass "⌘W 分层：先关顶层设置窗"
require_pass "⌘W 分层：主窗工作区未被误关"
require_pass "⌘W 关闭后 MRU 回退到上一个活跃工作区"
require_pass "关最后窗口后 Dock 重开有窗"
# I-22 回归（v0.10.1）
require_pass "侧栏按钮折叠后再点可真展开"
# I-24b 回归（v0.11.0）
require_pass "分栏首列内容真渲染"
require_pass "列头排序真生效[name]"
require_pass "列头排序真生效[dateModified]"
require_pass "列头排序真生效[size]"
require_pass "列头排序真生效[kind]"
require_pass "列头排序真生效[created]"
require_pass "列头排序真生效[added]"
require_pass "目录右键打开=App 内导航"
require_pass "全局热键注册成功"
require_pass "全局热键呼出/隐藏切换真生效"

# M23 全功能自测矩阵（v0.11.0）：全部验「真实效果」而非「没崩溃」
require_pass "视图模式[list]对应视图真在层级且可见"
require_pass "视图模式[icons]对应视图真在层级且可见"
require_pass "视图模式[columns]对应视图真在层级且可见"
require_pass "布局 quad 真实呈现 4 窗格"
require_pass "布局 single 真实呈现 1 窗格"
require_pass "导航进入沙箱路径生效"
require_pass "导航进入子目录路径生效"
require_pass "导航后退路径真变回上级"
require_pass "导航前进路径真恢复"
require_pass "导航上层路径真变父级"
require_pass "新建窗格标签 → 标签数+1 且活动路径正确"
require_pass "关闭窗格标签 → 标签数复原"
require_pass "显示隐藏文件开关真实翻转模型状态"
require_pass "窗格标签栏开关真实翻转控制状态"
require_pass "新建文件夹真实落盘"
require_pass "制作副本真实落盘"
require_pass "重命名真实生效"
require_pass "移到废纸篓真实生效"
require_pass "沙箱守卫: 新建文件夹目标在自建夹具内"
require_pass "沙箱守卫: 制作副本源在自建夹具内"
require_pass "沙箱守卫: 重命名目标在自建夹具内"
require_pass "沙箱守卫: 移废纸篓目标在自建夹具内"
require_pass "拷贝路径 → 剪贴板内容正确"
require_pass "条目右键菜单含全部关键项"
require_pass "条目右键菜单诚实禁用：非归档选中无「解压」项"
require_pass "右键「复制」enabled 随选中态正确切换"
require_pass "空白区目录菜单项数=5 且含新建/粘贴/简介/终端"
require_pass "任务窗手动开→可见"
require_pass "任务窗手动关→隐藏"
require_pass "显示简介面板出现"
require_pass "显示简介面板可关闭"
require_pass "设置页[settings.tab.archive] makeView 无约束歧义"
require_pass "设置页[settings.tab.behavior] makeView 无约束歧义"
require_pass "设置页[settings.tab.permissions] makeView 无约束歧义"
require_pass "设置页[settings.tab.appearance] makeView 无约束歧义"
require_pass "快捷键注册表默认绑定读取正确"
require_pass "侧栏含书签分组且种子书签行"
# I-31 搜索结果行右键菜单（v0.13.x）
require_pass "搜索结果右键菜单 items>0 且含「拷贝路径」"
require_pass "搜索结果右键菜单含定位/加入暂存架/显示简介"
require_pass "搜索结果右键「拷贝路径」→ 剪贴板内容==该路径"

echo "==== M17 断言校验完毕 (exit=$CODE) ===="
exit $CODE

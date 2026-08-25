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

echo "==== M17 断言校验完毕 (exit=$CODE) ===="
exit $CODE

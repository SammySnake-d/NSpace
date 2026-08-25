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
exit $CODE

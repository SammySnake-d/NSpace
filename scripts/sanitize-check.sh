#!/usr/bin/env bash
# 公开资产脱敏门禁（I-35 事故后立法，挂 pre-push）：
# 敏感词表在 .sanitize-terms（gitignore，不入库——词表本身即敏感）；无词表则跳过（新环境不阻塞）。
# 扫描全部已跟踪文本文件；命中即拒推。图片无法机扫——横切规范要求人眼终审+演示夹具生成。
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
TERMS="$ROOT/.sanitize-terms"
[ -f "$TERMS" ] || { echo "· sanitize-check: 本机无词表，跳过（公开截图仍须人审）"; exit 0; }
hits=$( { git -C "$ROOT" grep -n -f "$TERMS" -- ':!*.png' ':!*.icns' || true; } | head -20)
if [ -n "$hits" ]; then
  echo "✗ sanitize-check: 命中敏感词，禁止推送：" >&2
  echo "$hits" >&2
  exit 1
fi
echo "✓ sanitize-check: 已跟踪文本零敏感词"

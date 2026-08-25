#!/usr/bin/env bash
# icon_1024.png → NSpace.icns（sips 尺寸阶梯 + iconutil，均为 CLT 自带）
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="Support/icon_1024.png"
SET="Support/icon.iconset"
[ -f "$SRC" ] || { echo "缺 $SRC，先跑: swift scripts/generate-icon.swift $SRC"; exit 1; }
rm -rf "$SET" && mkdir -p "$SET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$SRC" --out "$SET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d "$SRC" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o "Support/NSpace.icns"
echo "已生成 Support/NSpace.icns"

#!/usr/bin/env bash
# 构建并启动 NSpace；`./scripts/run.sh install` 拷贝到 /Applications 并注册 LaunchServices
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build-app.sh release

if [ "${1:-}" = "install" ]; then
  rm -rf /Applications/NSpace.app
  cp -R build/NSpace.app /Applications/
  LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
  "$LSREG" -f /Applications/NSpace.app
  echo "✓ 已安装 /Applications/NSpace.app 并注册 LaunchServices"
  open /Applications/NSpace.app
else
  open build/NSpace.app
fi

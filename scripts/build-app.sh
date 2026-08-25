#!/usr/bin/env bash
# NSpace 无 Xcode 构建管线：swift build → 组装 .app → 签名
# 用法: ./scripts/build-app.sh [debug|release]   (默认 release)
# 环境: SIGN_IDENTITY 可指自签证书使 TCC 授权跨构建持久；默认 "-"(ad-hoc)
set -euo pipefail
cd "$(dirname "$0")/.."

CONF="${1:-release}"
APP="build/NSpace.app"
BIN=".build/$CONF/NSpace"

swift build -c "$CONF"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/NSpace"

# 探针不进包（生产二进制隔离）
cp Support/Info.plist "$APP/Contents/Info.plist"
VERSION="$(cat VERSION | tr -d '[:space:]')"
BUILD_NUM="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUM" "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# 本地化与图标
cp -R Resources/zh-Hans.lproj Resources/en.lproj "$APP/Contents/Resources/"
if [ ! -f Support/NSpace.icns ]; then
  swift scripts/generate-icon.swift Support/icon_1024.png
  ./scripts/make-icns.sh
fi
cp Support/NSpace.icns "$APP/Contents/Resources/NSpace.icns"

codesign --force --sign "${SIGN_IDENTITY:--}" --identifier com.nspace.NSpace "$APP"
echo "✓ 已构建并签名 $APP (v$VERSION build $BUILD_NUM, sign=${SIGN_IDENTITY:-ad-hoc})"

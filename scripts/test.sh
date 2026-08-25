#!/usr/bin/env bash
# CLT-only 环境跑 swift-testing 的固化命令（无 Xcode 时宏插件与 rpath 需手动指认）：
#  - TestingMacros 插件在 CLT 的 plugins/testing/ 子目录，编译器默认不加载
#  - Testing.framework 与 lib_TestingInterop.dylib 不在默认 rpath
set -euo pipefail
cd "$(dirname "$0")/.."
CLT=/Library/Developer/CommandLineTools
exec swift test \
  -Xswiftc -plugin-path -Xswiftc "$CLT/usr/lib/swift/host/plugins/testing" \
  -Xlinker -rpath -Xlinker "$CLT/Library/Developer/Frameworks" \
  -Xlinker -rpath -Xlinker "$CLT/Library/Developer/usr/lib" \
  "$@"

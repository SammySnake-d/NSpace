#!/usr/bin/env bash
# NSpace 项目本地执法件：胶囊四公理的 Swift 栈实例（替换 META 的 Go 参考件 pod-lint.sh）。
# 另含 BG-1 展示层禁写权威状态的机检。挂 pre-commit；违反即退出 1。
set -uo pipefail
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
PODS="$ROOT/Sources/Pods"
APP="$ROOT/Sources/NSpaceApp"
rc=0

# ---- 胶囊四公理（Swift 适配，偏差已登记 META_COMPLIANCE.json） ----
if [ -d "$PODS" ]; then
  for pod in "$PODS"/*/; do
    [ -d "$pod" ] || continue
    name="$(basename "$pod")"

    # Axiom 3: 唯一对外契约面
    [ -f "$pod/Contract.swift" ] || { echo "✗ [$name] 缺 Contract.swift (Axiom 3 仅暴露统一契约)"; rc=1; }

    # Axiom 4: 自带物理自证（SwiftPM 强制 Tests/ 独立目录，等价执法：同名非空测试目录）
    tests="$ROOT/Tests/${name}Tests"
    if [ ! -d "$tests" ] || [ -z "$(find "$tests" -name '*.swift' -print -quit 2>/dev/null)" ]; then
      echo "✗ [$name] 缺非空 Tests/${name}Tests/ (Axiom 4 独立自带物理自证)"; rc=1
    fi

    # Axiom 2: 零全局可变状态（UserDefaults.standard / 自造全局单例；FileManager 是被控基质,不禁）
    hits="$(grep -rnE 'UserDefaults\.standard|static (var|let) shared' "$pod" 2>/dev/null | grep -vE ':[0-9]+:\s*//')"
    if [ -n "$hits" ]; then
      echo "✗ [$name] 全局单例/UserDefaults.standard (Axiom 2 构造注入):"; echo "$hits" | sed 's/^/      /'; rc=1
    fi

    # BG-11: 零侵入——胶囊严禁 import 其他胶囊（公共依赖只允许经 Kernel 契约层组合）
    others="$(ls "$PODS" | grep -v "^$name\$" | paste -sd'|' -)"
    if [ -n "$others" ]; then
      xhits="$(grep -rnE "^\s*import ($others)\b" "$pod" 2>/dev/null)"
      if [ -n "$xhits" ]; then
        echo "✗ [$name] 跨胶囊 import (BG-11 零侵入):"; echo "$xhits" | sed 's/^/      /'; rc=1
      fi
    fi
  done
fi

# ---- BG-1: 展示层禁写权威状态（NSpaceApp 内禁用写型 FileManager API 与直接 JSON 落盘） ----
if [ -d "$APP" ]; then
  whits="$(grep -rnE 'FileManager\.[a-zA-Z]*\.(copyItem|moveItem|removeItem|trashItem|createDirectory|createFile)|copyfile\(' "$APP" 2>/dev/null | grep -vE ':[0-9]+:\s*//')"
  if [ -n "$whits" ]; then
    echo "✗ [NSpaceApp] 展示层直接调用写型文件 API (BG-1，必须经 OperationSpec Command):"
    echo "$whits" | sed 's/^/      /'; rc=1
  fi
fi

[ $rc -eq 0 ] && echo "pod-lint-swift: 全部胶囊与展示层通过 ✓"
exit $rc

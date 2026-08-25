#!/usr/bin/env bash
# 确定性网格执法（BG-0 编译产物；规则源：frontend-design-methodology.md:84 「所有尺寸严格收敛于 4pt/8pt 阶梯」）
# 扫描 UI 尺寸常量（constraint constant / spacing / NSEdgeInsets 四边）：
#   豁免：4 的倍数；|值|≤2（发丝线与视错觉修正，同文档 :86 允许 1~2px 重心微调）；带小数（0.5 发丝线）。
#   遗留/有意例外登记 scripts/grid-lint-allow.txt（格式「文件名:数值」，行内 # 注释写理由），不登记即红。
set -euo pipefail
ROOT="${1:-$(git rev-parse --show-toplevel)}"
ALLOW="$ROOT/scripts/grid-lint-allow.txt"

# 默认增量模式：只查本次暂存的 Swift 文件（pre-commit 语义——改哪个文件就要收敛哪个文件）；
# GRID_LINT_ALL=1 = 全量审计（验收门/CI 用）。
if [ "${GRID_LINT_ALL:-0}" = "1" ]; then
    TARGETS="$ROOT/Sources"
else
    staged=$(git -C "$ROOT" diff --cached --name-only --diff-filter=ACM 2>/dev/null \
             | grep -E '^Sources/.*\.swift$' || true)
    if [ -z "$staged" ]; then echo "✓ grid-lint: 本次无 Sources Swift 变更"; exit 0; fi
    TARGETS=$(printf '%s\n' "$staged" | sed "s|^|$ROOT/|" | tr '\n' ' ')
fi

violations=$(grep -rnE '(equalToConstant:|constant:|spacing[[:space:]]*[:=]|NSEdgeInsets\()' \
    $TARGETS --include='*.swift' 2>/dev/null \
  | grep -v 'UISelfTest.swift' \
  | awk -F: '
    {
      file=$1; lineno=$2
      line=$0; sub(/^[^:]*:[^:]*:/, "", line)
      rest=line
      while (match(rest, /[a-zA-Z]+[[:space:]]*[:=][[:space:]]*-?[0-9]+(\.[0-9]+)?/)) {
        tok=substr(rest, RSTART, RLENGTH)
        rest=substr(rest, RSTART+RLENGTH)
        key=tok; sub(/[[:space:]]*[:=].*/, "", key)
        val=tok; sub(/^[a-zA-Z]+[[:space:]]*[:=][[:space:]]*/, "", val)
        low=tolower(key)
        if (low !~ /onstant$/ && key !~ /^(spacing|top|left|bottom|right)$/) continue
        if (val ~ /\./) continue                # 小数 = 发丝线，豁免
        a = val + 0; if (a < 0) a = -a
        if (a <= 2) continue                    # 视错觉修正豁免
        if (a % 4 == 0) continue                # 在阶梯上
        n=split(file, parts, "/"); base=parts[n]
        printf "%s:%s  %s = %s\n", base, lineno, key, val
      }
    }' | sort -u)

fail=0; out=""
while IFS= read -r v; do
  [ -z "$v" ] && continue
  base="${v%%:*}"
  num=$(printf '%s' "$v" | grep -oE '\-?[0-9]+$')
  if [ -f "$ALLOW" ] && grep -qE "^${base}:${num}([[:space:]]|#|$)" "$ALLOW"; then continue; fi
  out="${out}${v}\n"; fail=1
done <<< "$violations"

if [ "$fail" = "1" ]; then
  echo "✗ grid-lint: 以下 UI 尺寸偏离 4pt 阶梯且未登记 grid-lint-allow.txt（改成 4 的倍数，或登记并写明理由）:" >&2
  printf "%b" "$out" >&2
  exit 1
fi
echo "✓ grid-lint: UI 尺寸全部收敛 4pt 阶梯（或已登记例外）"

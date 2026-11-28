#!/usr/bin/env bash
# Isolated AppKit hit-testing regression; does not open or change user workspaces.
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nspace-tabbar.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -swift-version 6 \
  -module-cache-path "${SWIFTPM_MODULECACHE_OVERRIDE:-$PWD/.build/tabbar-module-cache}" \
  Sources/NSpaceApp/TabBarView.swift Tests/TabBarInteractionTests/main.swift \
  -o "$TEST_DIR/tab-bar-tests"
"$TEST_DIR/tab-bar-tests"

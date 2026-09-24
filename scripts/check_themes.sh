#!/bin/sh
# Compiles the app's theme engine on its own and runs the contrast check
# (scripts/themecheck/main.swift). Exits 1 if any look breaks WCAG AA.
set -eu
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
out=$(mktemp -d)
xcrun swiftc -O -o "$out/themecheck" \
  Yui/Sources/Theme/YuiTheme.swift Yui/Sources/Theme/AgentLook.swift scripts/themecheck/main.swift 2>&1 \
  | grep -v "^$" || true
"$out/themecheck"

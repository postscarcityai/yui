#!/bin/bash
# Stack check: does the app survive its first screens on a phone-sized main thread stack?
#
# Build 229 crashed on every phone the moment the chat drew (TestFlight crash
# AGjOqLXNI70o): the composer's SwiftUI type nested ~60 generics deep and the Swift
# runtime overflowed the 1 MB main-thread stack instantiating it. The simulator's
# main thread has 8 MB, so the sim and every UI test were fine. This builds the app
# optimized (-O, whole module, like an archive) with a smaller main stack than a phone
# (default 512 KB, half of one, for margin), then launches the demo account on the
# chat, Add agent and the agent list, and fails if the app dies.
#
#   scripts/stack_check.sh <sim udid> [stack bytes, hex]
set -euo pipefail
SIM=${1:?usage: scripts/stack_check.sh <sim udid> [stack bytes hex, default 0x80000]}
STACK=${2:-0x80000}
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "$(dirname "$0")/.."
DD=/tmp/yui-stack-check-dd
LOG=/tmp/yui-stack-check.log
xcodegen generate --quiet
echo "building -O with a $STACK main stack (log $LOG)"
xcodebuild build -project Yui.xcodeproj -scheme Yui -configuration Debug -destination "id=$SIM" \
  -derivedDataPath "$DD" SWIFT_OPTIMIZATION_LEVEL=-O SWIFT_COMPILATION_MODE=wholemodule \
  "OTHER_LDFLAGS=\$(inherited) -Wl,-stack_size,$STACK" > "$LOG" 2>&1 || { tail -20 "$LOG"; exit 1; }
APP="$DD/Build/Products/Debug-iphonesimulator/Yui.app"
otool -l "$APP/Yui" | grep -q "stacksize $((STACK))" || { echo "FAIL: stack size not linked"; exit 1; }
xcrun simctl install "$SIM" "$APP"

fail=0
run() {  # a launch that must stay up for 12 s
  local name=$1; shift
  xcrun simctl terminate "$SIM" com.yuigui.app 2>/dev/null || true
  xcrun simctl launch "$SIM" com.yuigui.app -yuiDemoAccount "$@" > /dev/null
  sleep 12
  if xcrun simctl spawn "$SIM" launchctl list 2>/dev/null | grep -q "UIKitApplication:com.yuigui.app"; then
    echo "PASS  $name"
  else
    echo "FAIL  $name (crashed: newest report in ~/Library/Logs/DiagnosticReports/Yui-*.ips)"; fail=1
  fi
}
run "first launch: Yui's thread with the composer" -yuiDemoFirstLaunch
run "a chat with screens" -yuiDemo -yuiDemoAgents
run "Add agent with the crew" -yuiDemoFirstLaunch -yuiDemoWithout arnold -yuiAgents -yuiAddAgent
run "the agent list" -yuiDemoFirstLaunch -yuiAgents
run "settings" -yuiDemoFirstLaunch -yuiSettings
xcrun simctl terminate "$SIM" com.yuigui.app 2>/dev/null || true
# Put the normal (debug) build back is up to the caller; this one is -O.
exit $fail

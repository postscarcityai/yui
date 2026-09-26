#!/bin/bash
# Typing speed on a long thread (YUI-99). Runs YuiUITests/TypingSpeedTests on a
# simulator with the app's perf log streaming, then prints the keystroke_render
# numbers (Perf.swift, PERF.md) and how often the chat's body ran while typing.
#   scripts/typing_speed.sh <sim udid> [--video out.mp4] [--skip-build] [--thread N]
# --thread: messages in the thread, odd (default 241); 1 is the control.
# Needs full Xcode. Leaves the log in build/typing-speed.log.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

udid=${1:?usage: typing_speed.sh <sim udid> [--video out.mp4] [--skip-build]}
shift
video="" build=1 thread=241
while [ $# -gt 0 ]; do
  case $1 in
    --video) video=$2; shift ;;
    --skip-build) build=0 ;;
    --thread) thread=$2; shift ;;
  esac
  shift
done

dd=build/typing-dd
log=build/typing-speed.log
mkdir -p build
[ -d Yui.xcodeproj ] || xcodegen generate >/dev/null
if [ $build = 1 ]; then
  xcodebuild -project Yui.xcodeproj -scheme Yui -destination "id=$udid" -derivedDataPath "$dd" \
    build-for-testing -quiet
fi

xcrun simctl spawn "$udid" log stream --level debug \
  --predicate 'subsystem == "com.yuigui.app" AND category == "perf"' >"$log" 2>&1 &
logger=$!
rec=""
if [ -n "$video" ]; then
  xcrun simctl io "$udid" recordVideo --codec h264 --force "$video" >/dev/null 2>&1 &
  rec=$!
fi
sleep 2

status=0
TEST_RUNNER_TYPING_THREAD=$thread xcodebuild -project Yui.xcodeproj -scheme Yui -destination "id=$udid" -derivedDataPath "$dd" \
  test-without-building -only-testing:YuiUITests/TypingSpeedTests >build/typing-speed-test.log 2>&1 || status=$?

sleep 1
[ -n "$rec" ] && kill -INT "$rec" && wait "$rec" 2>/dev/null || true
kill "$logger" 2>/dev/null || true
wait "$logger" 2>/dev/null || true

grep -E "Executed|error:|double-space" build/typing-speed-test.log | tail -5 || true
python3 - "$log" <<'EOF'
import re, sys
lines = open(sys.argv[1], errors="replace").read().splitlines()
keys, chat, thread, started = [], 0, 0, False
for l in lines:
    m = re.search(r"perf keystroke_render ([0-9.]+) ms", l)
    if m:
        started = True
        keys.append(float(m.group(1)))
    elif started and "body ChatView" in l:
        chat += 1
    elif started and "body thread" in l:
        thread += 1
if not keys:
    sys.exit("no keystroke_render lines: was Speed on and the build a Debug one?")
keys_sorted = sorted(keys)
def pct(p):
    return keys_sorted[min(len(keys_sorted) - 1, int(round(p * (len(keys_sorted) - 1))))]
print(f"keystrokes {len(keys)}  p50 {pct(0.5):.1f} ms  p95 {pct(0.95):.1f} ms  max {keys_sorted[-1]:.1f} ms")
print(f"while typing: ChatView body {chat} ({chat / len(keys):.2f} per key), thread {thread} ({thread / len(keys):.2f} per key)")
EOF
exit $status

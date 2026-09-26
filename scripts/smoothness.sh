#!/bin/bash
# Smoothness on a long thread (YUI-101). Writes a 500-row thread (text, markdown,
# long answers that fold, cards, two screens), runs YuiUITests/SmoothnessTests on a
# simulator with the app's perf log streaming, then prints one table: each PERF.md
# interval, taps, late frames and how often the thread's body ran, per step.
#   scripts/smoothness.sh <sim udid> [--video out.mp4] [--skip-build] [--dark] [--json out.json] [--optimized]
# --optimized: a Debug build (the launch flags need it) compiled -O, closer to a
# TestFlight build's speed. Its own derived data, so both kinds can sit side by side.
# SMOOTH_ONLY=swipe,open runs just those steps after the launch. Needs full Xcode. Leaves the log in build/smoothness.log.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

udid=${1:?usage: smoothness.sh <sim udid> [--video out.mp4] [--skip-build] [--dark] [--json out.json]}
shift
video="" build=1 appearance=light json="" opt=()
while [ $# -gt 0 ]; do
  case $1 in
    --video) video=$2; shift ;;
    --skip-build) build=0 ;;
    --dark) appearance=dark ;;
    --json) json=$2; shift ;;
    --optimized) opt=(SWIFT_OPTIMIZATION_LEVEL=-O SWIFT_COMPILATION_MODE=wholemodule) ;;
  esac
  shift
done

dd=build/smooth-dd
log=build/smoothness.log
out=build/smoothness-test.log
rows=$PWD/build/smooth-rows.json
[ ${#opt[@]} -gt 0 ] && dd=build/smooth-dd-opt
mkdir -p build
[ -d Yui.xcodeproj ] || xcodegen generate >/dev/null

python3 - "$rows" <<'EOF'
import json, sys
rows = []
def row(i, sender, body):
    rows.append({"id": f"00000000-0000-4000-8000-{i:012d}", "sender": sender, "body": body,
                 "kind": "text", "meta": None, "created_at": f"2026-09-25T10:{i // 60 % 60:02d}:{i % 60:02d}.000Z",
                 "handled_at": "2026-09-25T11:00:00.000Z" if sender == "user" else None})
fence = lambda lines: "```yui\n" + "\n".join(lines) + "\n```"
long = ("Here is the whole story, because you asked for all of it. " * 3 +
        "The lane pulled the card, the worker built it, the tests ran green in light and dark, " +
        "and the build went up to TestFlight with a list of what to try, so the next thing is yours to open on the phone.")
for i in range(1, 491):
    if i % 2:
        row(i, "user", f"Message {i}")
    elif i % 20 == 0:
        row(i, "agent", fence(["say Tabata time. Eight rounds, 20 on and 10 off.", "timer@hiit 20/10x8 Tabata", 'ask "Log it when you\'re done?"']))
    elif i % 30 == 0:
        row(i, "agent", fence(['choose "Which split today?" Push|Pull|Legs +other']))
    elif i % 14 == 0:
        row(i, "agent", f"**Build {i}** is ready.\n- Taps answer at once\n- Scrolling keeps up\n- `thread_open` is timed\n\nDetails on [yuigui.com](https://www.yuigui.com).")
    elif i % 26 == 0:
        row(i, "agent", long)
    else:
        row(i, "agent", f"Message {i}. Here's a longer answer so the thread fills the screen the way a real one does.")
row(491, "user", "Put the plan on a screen?")
row(492, "agent", fence([">2 card \"Plan\" body=\"Squats, then a walk.\"", ">3 list Shopping Eggs|Rice|Kimchi", "say On screens 2 and 3."]))
row(493, "user", "What's next?")
row(494, "agent", fence(["say Two things.", "timer@hiit 20/10x8 Tabata"]))
row(495, "user", "Which split?")
row(496, "agent", fence(['choose "Which split today?" Push|Pull|Legs +other']))
row(497, "user", "And then?")
row(498, "agent", "The newest answer, at the bottom of a long thread.")
json.dump(rows, open(sys.argv[1], "w"))
print(f"rows: {len(rows)}")
EOF

if [ $build = 1 ]; then
  xcodebuild -project Yui.xcodeproj -scheme Yui -destination "id=$udid" -derivedDataPath "$dd" \
    ${opt[@]+"${opt[@]}"} build-for-testing -quiet
fi

xcrun simctl spawn "$udid" log stream --level debug --style ndjson \
  --predicate 'subsystem == "com.yuigui.app" AND category == "perf"' >"$log" 2>&1 &
logger=$!
rec=""
if [ -n "$video" ]; then
  xcrun simctl io "$udid" recordVideo --codec h264 --force "$video" >/dev/null 2>&1 &
  rec=$!
fi
sleep 2

status=0
TEST_RUNNER_SMOOTH_ROWS=$rows TEST_RUNNER_SMOOTH_APPEARANCE=$appearance TEST_RUNNER_YUI_SHOTS=${YUI_SHOTS:-} TEST_RUNNER_SMOOTH_ONLY=${SMOOTH_ONLY:-} \
  xcodebuild -project Yui.xcodeproj -scheme Yui -destination "id=$udid" -derivedDataPath "$dd" \
  test-without-building -only-testing:YuiUITests/SmoothnessTests >"$out" 2>&1 || status=$?

sleep 1
[ -n "$rec" ] && kill -INT "$rec" && wait "$rec" 2>/dev/null || true
kill "$logger" 2>/dev/null || true
wait "$logger" 2>/dev/null || true

grep -E "Executed|error:" "$out" | tail -5 || true
python3 - "$log" "$out" "$json" <<'EOF'
import json, re, sys
from datetime import datetime
log, out, dest = sys.argv[1], sys.argv[2], sys.argv[3]
marks = {}
for l in open(out, errors="replace"):
    m = re.search(r"SMOOTH (\w+) (begin|end) ([0-9.]+)", l)
    if m: marks.setdefault(m.group(1), {})[m.group(2)] = float(m.group(3))
events = []
for l in open(log, errors="replace"):
    try: e = json.loads(l)
    except ValueError: continue
    msg, ts = e.get("eventMessage", ""), e.get("timestamp", "")
    try: t = datetime.strptime(ts, "%Y-%m-%d %H:%M:%S.%f%z").timestamp()
    except ValueError: continue
    events.append((t, msg))
if not events: sys.exit("no perf lines: was Speed on and the build a Debug one?")
def pct(xs, p):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(round(p * (len(xs) - 1))))] if xs else None
fmt = lambda v: "-" if v is None else f"{v:.0f}"
table = {}
print(f"{'step':8} {'secs':>5} {'hitch ms/s':>10} {'hitches':>7} {'taps':>4} {'tap p50':>7} {'tap max':>7} {'thread body':>11}  intervals (ms)")
for phase, m in marks.items():
    if "begin" not in m or "end" not in m: continue
    a, b = m["begin"], m["end"]
    inside = [msg for t, msg in events if a <= t <= b]
    hitch = [float(x.group(1)) for x in (re.search(r"perf hitch ([0-9.]+) ms", s) for s in inside) if x]
    taps = [float(x.group(1)) for x in (re.search(r"perf tap ([0-9.]+) ms", s) for s in inside) if x]
    ivs = {}
    for s in inside:
        x = re.search(r"perf (\w+) ([0-9.]+) ms", s)
        if x and x.group(1) not in ("hitch", "tap"): ivs.setdefault(x.group(1), []).append(float(x.group(2)))
    body = sum(1 for s in inside if s.endswith("body thread"))
    secs = b - a
    row = {"secs": round(secs, 1), "hitch_ms_per_s": round(sum(hitch) / secs, 1), "hitches": len(hitch),
           "taps": len(taps), "tap_p50": pct(taps, .5), "tap_max": max(taps) if taps else None,
           "thread_body": body, "intervals": {k: [round(v) for v in vs] for k, vs in ivs.items()}}
    table[phase] = row
    iv = "  ".join(f"{k} {'/'.join(str(v) for v in vs)}" for k, vs in row["intervals"].items())
    print(f"{phase:8} {secs:5.1f} {row['hitch_ms_per_s']:10.1f} {len(hitch):7} {len(taps):4} {fmt(row['tap_p50']):>7} {fmt(row['tap_max']):>7} {body:11}  {iv}")
if dest: json.dump(table, open(dest, "w"), indent=1)
EOF
exit $status

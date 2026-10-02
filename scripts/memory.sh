#!/bin/bash
# Memory over a scripted session (YUI-100). Writes a 500-row thread with galleries,
# decks, games and screens 2 to 12, runs YuiUITests/MemorySessionTests on a
# simulator with the app's footprint logged every second, runs `leaks` on the app at
# the test's start and end checkpoints, then prints the footprint per phase and the
# leak counts. Fails when the session ends more than MEM_MAX_GROWTH MB above its
# start (after one warm-up round), peaks above MEM_MAX_PEAK MB, or `leaks` finds more
# than MEM_MAX_NEW_LEAKS leaks at the end than at the start. Growth alone is noisy:
# the same build ended -10 and +10 MB in two runs, and a run that leaked 1946 blocks
# still passed it. The leak count is the steady signal.
#   scripts/memory.sh <sim udid> [--skip-build] [--json out.json] [--trace out.trace]
# --trace records an Allocations trace of the whole session with xctrace (big file).
# MEM_CYCLES (rounds after the warm-up, default 3) and MEM_IDLE (seconds, default 60)
# shape the session. Needs full Xcode. Run before every ship (yui-project skill, Releases).
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

udid=${1:?usage: memory.sh <sim udid> [--skip-build] [--json out.json] [--trace out.trace]}
shift
build=1 json="" trace=""
while [ $# -gt 0 ]; do
  case $1 in
    --skip-build) build=0 ;;
    --json) json=$2; shift ;;
    --trace) trace=$2; shift ;;
  esac
  shift
done
max_growth=${MEM_MAX_GROWTH:-15}
max_peak=${MEM_MAX_PEAK:-300}
max_new_leaks=${MEM_MAX_NEW_LEAKS:-100}

dd=${MEM_DD:-build/smooth-dd}
log=build/memory.log
out=build/memory-test.log
rows=$PWD/build/memory-rows.json
sync=$PWD/build/memory-sync
mkdir -p build
rm -rf "$sync" && mkdir -p "$sync"
[ -d Yui.xcodeproj ] || xcodegen generate >/dev/null

python3 - "$rows" <<'EOF'
import json, sys
rows = []
def row(i, sender, body):
    rows.append({"id": f"00000000-0000-4000-8000-{i:012d}", "sender": sender, "body": body,
                 "kind": "text", "meta": None, "created_at": f"2026-09-25T10:{i // 60 % 60:02d}:{i % 60:02d}.000Z",
                 "handled_at": "2026-09-25T11:00:00.000Z" if sender == "user" else None})
fence = lambda lines: "```yui\n" + "\n".join(lines) + "\n```"
pics = [f"/demo/g{n}.jpg" for n in range(1, 7)]
deck = ['deck "The week" +inline', 'page "Monday" body="Squats, then a walk."',
        'page "Wednesday" body="Pull day. Rows, curls and a long stretch after."',
        'page "Friday" points="Legs"|"Core"|"A slow run"', 'page "Sunday" body="Rest. Eat well."', 'end']
for i in range(1, 481):
    if i % 2:
        row(i, "user", f"Message {i}")
    elif i % 40 == 0:
        row(i, "agent", fence(["say Fresh renders.", 'gallery "Renders" ' + " ".join(pics[(i // 40) % 3:][:4]) + " layout=grid"]))
    elif i % 30 == 0:
        row(i, "agent", fence(deck))
    elif i % 50 == 0:
        row(i, "agent", fence(["say Your move.", 'game tictactoe "Beat me"']))
    elif i % 70 == 0:
        row(i, "agent", fence([f"image {pics[i % 6]} A render"]))
    elif i % 20 == 0:
        row(i, "agent", fence(["say Tabata time.", "timer@hiit 20/10x8 Tabata"]))
    elif i % 14 == 0:
        row(i, "agent", f"**Build {i}** is ready.\n- Taps answer at once\n- Scrolling keeps up\n- `thread_open` is timed\n\nDetails on [yuigui.com](https://www.yuigui.com).")
    else:
        row(i, "agent", f"Message {i}. Here's a longer answer so the thread fills the screen the way a real one does.")
row(481, "user", "Fill every screen?")
row(482, "agent", fence([
    '>2 card "Plan" body="Squats, then a walk."', ">3 list Shopping Eggs|Rice|Kimchi",
    '>4 gallery "Renders" ' + " ".join(pics[:4]) + " layout=grid", '>5 game memory "Match"',
    '>6 game tictactoe "Beat me"', f">7 image {pics[4]} A render", ">8 timer 25m Focus",
    '>9 card "Nine" body="Screen nine."', '>10 card "Ten" body="Screen ten."',
    '>11 card "Eleven" body="Screen eleven."', '>12 card "Twelve" body="Screen twelve."',
    "say Screens 2 to 12."]))
row(483, "user", "What's next?")
row(484, "agent", fence(["say Two things.", "timer@hiit 20/10x8 Tabata"]))
row(485, "user", "And then?")
row(486, "agent", "The newest answer, at the bottom of a long thread.")
json.dump(rows, open(sys.argv[1], "w"))
print(f"rows: {len(rows)}")
EOF

if [ $build = 1 ]; then
  xcodebuild -project Yui.xcodeproj -scheme Yui -destination "id=$udid" -derivedDataPath "$dd" \
    build-for-testing -quiet
fi

xcrun simctl spawn "$udid" log stream --level debug --style ndjson \
  --predicate 'subsystem == "com.yuigui.app" AND category == "perf"' >"$log" 2>&1 &
logger=$!

# The app on this simulator, by the path of its bundle.
app_pid() { pgrep -f "Devices/$udid/data/Containers/Bundle/Application/[^ ]*/Yui.app/Yui( |\$)" | head -1; }

# The test waits at each checkpoint for us: leaks, then let it go on.
(
  tracer=""
  for name in start end; do
    while [ ! -e "$sync/$name.go" ]; do sleep 1; [ -e "$sync/stop" ] && exit 0; done
    pid=$(app_pid || true)
    if [ -n "$pid" ]; then
      # leaks can catch SwiftUI mid-write ("Malloc enumeration ... failed"): try again.
      for try in 1 2 3 4 5; do
        # leaks exits 1 when it finds any, which would end this loop under set -e.
        leaks "$pid" >"build/memory-leaks-$name.txt" 2>&1 || true
        grep -q "total leaked bytes" "build/memory-leaks-$name.txt" && break
        sleep 3
      done
      if [ -n "$trace" ] && [ $name = start ]; then
        rm -rf "$trace"
        xcrun xctrace record --template Allocations --device "$udid" --attach "$pid" --output "$trace" \
          >build/memory-trace.log 2>&1 &
        tracer=$!
        sleep 8
      fi
      if [ $name = end ] && [ -n "$tracer" ]; then kill -INT "$tracer" 2>/dev/null; wait "$tracer" 2>/dev/null || true; fi
    else
      echo "no app process for $udid" >"build/memory-leaks-$name.txt"
    fi
    touch "$sync/$name.done"
  done
) &
watcher=$!
sleep 2

status=0
TEST_RUNNER_MEM_ROWS=$rows TEST_RUNNER_MEM_DIR=$sync TEST_RUNNER_MEM_CYCLES=${MEM_CYCLES:-3} TEST_RUNNER_MEM_IDLE=${MEM_IDLE:-60} \
  xcodebuild -project Yui.xcodeproj -scheme Yui -destination "id=$udid" -derivedDataPath "$dd" \
  test-without-building -only-testing:YuiUITests/MemorySessionTests >"$out" 2>&1 || status=$?

touch "$sync/stop"
sleep 1
kill "$watcher" "$logger" 2>/dev/null || true
wait "$watcher" "$logger" 2>/dev/null || true

grep -E "Executed|error:" "$out" | tail -5 || true
python3 - "$log" "$out" "$json" "$max_growth" "$max_peak" "$max_new_leaks" <<'EOF'
import json, re, sys
from datetime import datetime
log, out, dest, max_growth, max_peak, max_new = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4]), float(sys.argv[5]), int(sys.argv[6])
marks = []
for l in open(out, errors="replace"):
    m = re.search(r"MEM (\w+) ([0-9.]+)$", l.strip())
    if m: marks.append((m.group(1), float(m.group(2))))
samples = []
for l in open(log, errors="replace"):
    try: e = json.loads(l)
    except ValueError: continue
    x = re.search(r"perf mem_footprint ([0-9.]+) MB", e.get("eventMessage", ""))
    if not x: continue
    try: t = datetime.strptime(e.get("timestamp", ""), "%Y-%m-%d %H:%M:%S.%f%z").timestamp()
    except ValueError: continue
    samples.append((t, float(x.group(1))))
if not samples: sys.exit("no footprint lines: was the build a Debug one with -yuiMemEvery?")
def at(t):
    before = [mb for s, mb in samples if s <= t]
    return before[-1] if before else samples[0][1]
def leaks(name):
    try: text = open(f"build/memory-leaks-{name}.txt", errors="replace").read()
    except OSError: return None
    m = re.search(r"(\d+) leaks? for (\d+) total leaked bytes", text)
    fp = re.search(r"Physical footprint:\s+([0-9.]+)([KMG])", text)
    return {"leaks": int(m.group(1)) if m else None, "leaked_bytes": int(m.group(2)) if m else None,
            "footprint": fp.group(1) + fp.group(2) if fp else None}
peak = max(mb for _, mb in samples)
res = {"samples": len(samples), "peak_mb": peak, "marks": {n: at(t) for n, t in marks},
       "leaks": {n: leaks(n) for n in ("start", "end")}}
m = res["marks"]
print(f"{'mark':8} {'MB':>7}")
for n, t in marks: print(f"{n:8} {at(t):7.1f}")
print(f"peak     {peak:7.1f}")
for n, l in res["leaks"].items():
    if l: print(f"leaks {n}: {l['leaks']} leaks, {l['leaked_bytes']} bytes, footprint {l['footprint']}")
fail = []
if "start" in m and "end" in m:
    res["growth_mb"] = round(m["end"] - m["start"], 1)
    print(f"growth   {res['growth_mb']:7.1f}  (limit {max_growth:.0f})")
    if res["growth_mb"] > max_growth: fail.append(f"ended {res['growth_mb']} MB above its start (limit {max_growth:.0f})")
else:
    fail.append("the session never reached its end checkpoint")
ls, le = res["leaks"]["start"], res["leaks"]["end"]
if ls and le and ls["leaks"] is not None and le["leaks"] is not None:
    res["new_leaks"] = le["leaks"] - ls["leaks"]
    print(f"new leaks {res['new_leaks']:6d}  (limit {max_new})")
    if res["new_leaks"] > max_new: fail.append(f"{res['new_leaks']} new leaks over the session (limit {max_new})")
if peak > max_peak: fail.append(f"peaked at {peak:.0f} MB (limit {max_peak:.0f})")
res["ok"] = not fail
if dest: json.dump(res, open(dest, "w"), indent=1)
if fail: sys.exit("MEMORY CEILING: " + "; ".join(fail))
print("memory ceiling: ok")
EOF
exit $status

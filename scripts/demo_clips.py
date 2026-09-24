#!/usr/bin/env python3
"""Demo clips, one per preset (SOC-2, BIZ-4 part 5.3).

The `YuiDemoTests` UI test plays a scripted Yui Lines reply per preset on the
demo account while `simctl io recordVideo` captures the simulator. The test
writes when each scene starts and ends; this script trims the recording to
that, then composes a 9:16 (1080x1920) and a 16:9 (1920x1080) cut with the
caption burned in. Output, plus a clips.json manifest, goes to
yuigui/site/public/demo/clips/.

    python3 scripts/demo_clips.py                 # every clip
    python3 scripts/demo_clips.py timer chart     # just these
    python3 scripts/demo_clips.py --sim <udid>    # a simulator you already have

Run it on demand and after any card that adds a preset (add a test method and
a caption below). Nothing here touches the network or a real account.
"""
import argparse
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
HUB = Path(os.environ.get("YUIGUI", Path.home() / "dev/yuigui"))
OUT = HUB / "site/public/demo/clips"
LOGO = HUB / "brand/yui-logo-coral.png"
DD = Path(tempfile.gettempdir()) / "yui-clips-dd"
SIM_NAME = "YuiClips iPhone 18 Pro"
SIM_TYPE = "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro"
ENV = {**os.environ, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"}
ENV.pop("HERMES_HOME", None)
CREAM = "0xFFF9F0"

# name -> caption. Order is the order they record in. Each name has a
# `test<Name>` method in YuiUITests/YuiDemoTests.swift.
CLIPS = {
    "timer": "One line from your agent. A Tabata timer on your phone.",
    "choose": "Your agent asks. You tap an answer. No typing.",
    "pick": "Pick a few. Your agent gets the list.",
    "form": "A check-in form, drawn from one line of text.",
    "gallery": "Photos to choose from, right in the chat.",
    "compare": "Before and after, with every change marked.",
    "chart": "Numbers come back as a chart, not a paragraph.",
    "storyboard": "Reorder the storyboard. Your agent sees the new order.",
    "calc": "Drag the angle. Watch the range change.",
}


def run(cmd, **kw):
    return subprocess.run(cmd, env=ENV, check=True, **kw)


def simctl(*args, capture=False):
    r = run(["xcrun", "simctl", *args], capture_output=capture, text=True)
    return r.stdout if capture else None


def simulator(udid):
    """Our own simulator, so a clip never fights another test run for the screen."""
    if not udid:
        devices = json.loads(simctl("list", "devices", "available", "-j", capture=True))["devices"]
        udid = next((d["udid"] for ds in devices.values() for d in ds if d["name"] == SIM_NAME), None)
        if not udid:
            runtimes = json.loads(simctl("list", "runtimes", "available", "-j", capture=True))["runtimes"]
            ios = [r["identifier"] for r in runtimes if r["platform"] == "iOS"][-1]
            udid = simctl("create", SIM_NAME, SIM_TYPE, ios, capture=True).strip()
    boot = subprocess.run(["xcrun", "simctl", "boot", udid], env=ENV, capture_output=True, text=True)
    if boot.returncode and "insufficient system resources" in boot.stderr:
        # Too many simulators up already (other cards leave theirs booted): borrow one.
        devices = json.loads(simctl("list", "devices", "booted", "-j", capture=True))["devices"]
        booted = [d for ds in devices.values() for d in ds if "iPhone" in d["name"]]
        if not booted:
            sys.exit(boot.stderr.strip())
        pro = [d for d in booted if d["name"].endswith("iPhone 18 Pro")]
        udid = (pro or booted)[0]["udid"]
        print(f"no room to boot {SIM_NAME}, borrowing booted {(pro or booted)[0]['name']}")
    simctl("bootstatus", udid, "-b")
    simctl("ui", udid, "appearance", "light")
    simctl("status_bar", udid, "override", "--time", "9:41", "--batteryState", "charged", "--batteryLevel", "100",
           "--cellularMode", "active", "--cellularBars", "4", "--wifiBars", "3")
    return udid


def xcodebuild(action, udid, extra=(), log=None, env=None):
    cmd = ["xcodebuild", action, "-project", "Yui.xcodeproj", "-scheme", "Yui", "-destination", f"id={udid}",
           "-derivedDataPath", str(DD), *extra]
    with open(log, "w") as f:
        return subprocess.run(cmd, cwd=REPO, env=env or ENV, stdout=f, stderr=subprocess.STDOUT).returncode


def probe(path, entry):
    r = run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", entry, "-of", "csv=p=0",
             str(path)], capture_output=True, text=True)
    return r.stdout.strip().split("\n")[0]


def duration(path):
    r = run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(path)],
            capture_output=True, text=True)
    return round(float(r.stdout.strip()), 2)


def even(x):
    return int(round(x / 2) * 2)


def frame(tool, out, canvas, win, caption, layout):
    (W, H), (x, y, w, h) = canvas, win
    run([str(tool), str(out), str(W), str(H), str(x), str(y), str(w), str(h), str(round(w * 0.11)),
         caption, str(LOGO), layout])


def compose(raw, start, end, overlay, canvas, win, out):
    (W, H), (x, y, w, h) = canvas, win
    graph = (f"[0:v]fps=30,scale={w}:{h}:flags=lanczos,pad={W}:{H}:{x}:{y}:color={CREAM}[v];"
             f"[v][1:v]overlay=0:0,format=yuv420p")
    run(["ffmpeg", "-y", "-v", "error", "-ss", f"{start:.2f}", "-to", f"{end:.2f}", "-i", str(raw),
         "-i", str(overlay), "-filter_complex", graph, "-an", "-c:v", "libx264", "-preset", "slow", "-crf", "20",
         "-movflags", "+faststart", str(out)])


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("names", nargs="*", help=f"clips to record (default all: {' '.join(CLIPS)})")
    ap.add_argument("--sim", help="simulator udid (default: our own, created if missing)")
    ap.add_argument("--out", default=str(OUT))
    ap.add_argument("--keep", action="store_true", help="keep the raw recordings in the work dir")
    args = ap.parse_args()
    names = args.names or list(CLIPS)
    bad = [n for n in names if n not in CLIPS]
    if bad:
        sys.exit(f"unknown clip(s): {' '.join(bad)}")
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="yui-clips-"))
    marks = work / "marks"
    marks.mkdir()
    print(f"work dir {work}")

    udid = simulator(args.sim)
    print(f"simulator {udid}")
    run(["xcodegen", "generate", "--quiet"], cwd=REPO)
    tool = work / "clip_frame"
    run(["swiftc", "-O", str(REPO / "scripts/clip_frame.swift"), "-o", str(tool)])
    print("building for testing...")
    if xcodebuild("build-for-testing", udid, log=work / "build.log"):
        sys.exit(f"build failed, see {work / 'build.log'}")

    env = {**ENV, "TEST_RUNNER_YUI_CLIPS": str(marks)}
    manifest_path = out / "clips.json"
    manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else {}
    failed = []
    for name in names:
        print(f"[{name}] recording")
        raw = work / f"{name}-raw.mp4"
        rec = subprocess.Popen(["xcrun", "simctl", "io", udid, "recordVideo", "--codec=h264", "--force", str(raw)],
                               env=ENV, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        line = ""
        while "Recording started" not in line and rec.poll() is None:
            line = rec.stdout.readline()
        test = f"-only-testing:YuiUITests/YuiDemoTests/test{name[0].upper()}{name[1:]}"
        code = xcodebuild("test-without-building", udid, [test], log=work / f"{name}-test.log", env=env)
        stop = time.time()
        rec.send_signal(signal.SIGINT)
        rec.wait(timeout=60)
        mark = marks / f"{name}.json"
        if code or not mark.exists() or not raw.exists():
            print(f"[{name}] FAILED (test exit {code}), see {work / (name + '-test.log')}")
            failed.append(name)
            continue
        m = json.loads(mark.read_text())
        # Anchor on the END of the file: "Recording started" prints a second or
        # two before frames flow, so the start clock runs early. The end clock can
        # only be late by a static tail, which moves the cut earlier, into the hold.
        t0 = stop - duration(raw)
        start, end = max(0.0, m["start"] - t0 - 0.3), m["end"] - t0
        vw, vh = (int(v) for v in probe(raw, "stream=width,height").split(","))

        # 9:16: caption above, phone in the middle, wordmark below.
        ph = 1440
        pw = even(ph * vw / vh)
        portrait = ((1080, 1920), (even((1080 - pw) / 2), 300, pw, ph))
        # 16:9: wordmark and caption on the left, phone on the right.
        lh = 1000
        lw = even(lh * vw / vh)
        landscape = ((1920, 1080), (even(1920 - lw - 170), 40, lw, lh))

        entry = {"caption": CLIPS[name], "recorded": time.strftime("%Y-%m-%d")}
        for tag, (canvas, win), layout in (("9x16", portrait, "portrait"), ("16x9", landscape, "landscape")):
            overlay = work / f"{name}-{tag}.png"
            frame(tool, overlay, canvas, win, CLIPS[name], layout)
            dest = out / f"{name}-{tag}.mp4"
            compose(raw, start, end, overlay, canvas, win, dest)
            poster = out / f"{name}-{tag}.jpg"
            run(["ffmpeg", "-y", "-v", "error", "-sseof", "-1", "-i", str(dest), "-frames:v", "1", "-q:v", "3",
                 str(poster)])
            entry[tag] = {"src": f"/demo/clips/{dest.name}", "poster": f"/demo/clips/{poster.name}",
                          "seconds": duration(dest)}
        manifest[name] = entry
        print(f"[{name}] {entry['9x16']['seconds']}s -> {name}-9x16.mp4, {name}-16x9.mp4")
        if not args.keep:
            raw.unlink()

    manifest_path.write_text(json.dumps({k: manifest[k] for k in sorted(manifest, key=lambda k: list(CLIPS).index(k)
                                                                         if k in CLIPS else 99)}, indent=2) + "\n")
    subprocess.run(["xcrun", "simctl", "status_bar", udid, "clear"], env=ENV)
    if not args.keep and not failed:
        shutil.rmtree(work)
    if failed:
        sys.exit(f"failed: {' '.join(failed)} (logs in {work})")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Marketing videos (SOC-3): Yui in 15s, Yui Lines in 30s, your Hermes on your phone in 60s.

Two steps, so the edit can change without recording again:

    python3 scripts/promo_videos.py record [scene ...]   # simulator scenes -> WORK/raw
    python3 scripts/promo_videos.py build [video ...]    # cards + scenes -> yuigui/site/public/demo/videos

`record` plays each `YuiPromoTests` scene on the demo account while
`simctl io recordVideo` captures it (the same way scripts/demo_clips.py does),
and keeps the raw recording plus the moments the test marked. `build` draws the
title, terminal, benchmark and end cards with scripts/promo_card.swift (ffmpeg
here has no drawtext), cuts the scenes on the marks, and writes each video in
9:16 (1080x1920) and 16:9 (1920x1080), H.264, with a poster and videos.json.

Everything on screen is scripted: the demo account's placeholder pairing code
(the same 123456 yuigui.com/start shows), canned agent replies, no real host.
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

sys.path.insert(0, str(Path(__file__).resolve().parent))
import demo_clips as dc  # noqa: E402

REPO = dc.REPO
HUB = dc.HUB
OUT = HUB / "site/public/demo/videos"
OG = HUB / "site/public/og/screens"
WORK = Path(os.environ.get("YUI_PROMO_WORK", Path.home() / ".cache/yui-promo"))
RAW = WORK / "raw"
FPS = 30
SCENES = ["promo-timer", "promo-choose", "promo-chart", "promo-pair"]
TEST = {s: "testPromo" + s.split("-")[1].capitalize() for s in SCENES}


def record(names, sim):
    RAW.mkdir(parents=True, exist_ok=True)
    marks = WORK / "marks"
    marks.mkdir(parents=True, exist_ok=True)
    udid = dc.simulator(sim)
    print(f"simulator {udid}")
    dc.run(["xcodegen", "generate", "--quiet"], cwd=REPO)
    print("building for testing...")
    if dc.xcodebuild("build-for-testing", udid, log=WORK / "build.log"):
        sys.exit(f"build failed, see {WORK / 'build.log'}")
    env = {**dc.ENV, "TEST_RUNNER_YUI_CLIPS": str(marks)}
    failed = []
    for name in names:
        print(f"[{name}] recording")
        raw = RAW / f"{name}.mp4"
        rec = subprocess.Popen(["xcrun", "simctl", "io", udid, "recordVideo", "--codec=h264", "--force", str(raw)],
                               env=dc.ENV, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        line = ""
        while "Recording started" not in line and rec.poll() is None:
            line = rec.stdout.readline()
        test = f"-only-testing:YuiUITests/YuiPromoTests/{TEST[name]}"
        code = dc.xcodebuild("test-without-building", udid, [test], log=WORK / f"{name}-test.log", env=env)
        stop = time.time()
        rec.send_signal(signal.SIGINT)
        rec.wait(timeout=60)
        mark = marks / f"{name}.json"
        if code or not mark.exists() or not raw.exists():
            print(f"[{name}] FAILED (test exit {code}), see {WORK / (name + '-test.log')}")
            failed.append(name)
            continue
        # Anchor on the END of the file (see demo_clips.py): marks become seconds into the recording.
        t0 = stop - dc.duration(raw)
        m = {k: round(v - t0, 2) for k, v in json.loads(mark.read_text()).items()}
        m["size"] = dc.probe(raw, "stream=width,height")
        (RAW / f"{name}.json").write_text(json.dumps(m, indent=2) + "\n")
        print(f"[{name}] {dc.duration(raw)}s, marks {m}")
    subprocess.run(["xcrun", "simctl", "status_bar", udid, "clear"], env=dc.ENV)
    if failed:
        sys.exit(f"failed: {' '.join(failed)}")


# ---- the edit ---------------------------------------------------------------

BENCH = HUB / "site/content/benchmark.json"
PAIR_REPLY_AT = 1.6 + 0.5  # the demo reply lands 1.6 s after "Hi!", then streams


def bench_rows():
    """The benchmark totals, straight from the file the site shows (o200k, ten sample screens)."""
    t = json.loads(BENCH.read_text())["totals"]
    yl = t["yl"]["o200k"]
    x = lambda k: f"{t[k]['o200k'] / yl:.1f}x more"  # noqa: E731
    return [
        {"label": "Yui Lines", "value": yl, "note": ""},
        {"label": "JSON, minified", "value": t["min"]["o200k"], "note": x("min")},
        {"label": "JSON, pretty", "value": t["pretty"]["o200k"], "note": x("pretty")},
        {"label": "Component tree", "value": t["tree"]["o200k"], "note": x("tree")},
    ]


def ratio(k):
    t = json.loads(BENCH.read_text())["totals"]
    return f"{t[k]['o200k'] / t['yl']['o200k']:.1f}x"


INSTALL = "hermes plugins install postscarcityai/yui/hermes-plugin/yui --enable"
TIMER = "timer 20/10x8 Tabata +auto"
CHOOSE = 'choose "Which split today?" Push|Pull|Legs +other'
END_SMALL = "Open source. Built in public."

# Each video is a list of segments. Scenes cut a recording from a mark
# (seconds after it) for `dur` seconds; the rest are drawn cards.
VIDEOS = {
    "yui-15s": {
        "title": "Yui in 15 seconds",
        "what": "Ask your agent a question. It answers with a screen you can tap.",
        "poster": 2.6,
        "og": ("promo-timer", "start", 3.0),
        "segments": [
            {"t": "scene", "raw": "promo-timer", "mark": "start", "at": -0.6, "dur": 4.2,
             "caption": "You ask. Your agent answers with a screen."},
            {"t": "scene", "raw": "promo-choose", "mark": "tap", "at": -0.7, "dur": 4.3,
             "caption": "It asks back. You tap."},
            {"t": "scene", "raw": "promo-chart", "mark": "start", "at": 1.0, "dur": 3.8,
             "caption": "Numbers come back as a chart."},
            {"t": "end", "fill": 15, "text": "Your agents, answering with screens.", "url": "yuigui.com",
             "small": "iPhone beta. Bring your own Hermes."},
        ],
    },
    "yui-lines-30s": {
        "title": "Yui Lines in 30 seconds",
        "what": f"One line of Yui Lines becomes a screen. {ratio('min')} fewer tokens than minified JSON.",
        "poster": 9.0,
        "og": ("promo-choose", "tap", 0.0),
        "segments": [
            {"t": "title", "dur": 2.4, "text": "One line of text.", "accent": "One screen on your phone."},
            {"t": "type", "style": "light", "title": "Yui Lines", "lines": [TIMER], "cps": 16, "pre": 0.3,
             "hold": 1.0, "kicker": "Yui Lines", "caption": "Your agent sends one line."},
            {"t": "scene", "raw": "promo-timer", "mark": "start", "at": 1.1, "dur": 5.6,
             "caption": "Yui draws it. A real timer, running."},
            {"t": "type", "style": "light", "title": "Yui Lines", "lines": [CHOOSE], "cps": 26, "pre": 0.2,
             "hold": 0.8, "kicker": "Yui Lines", "caption": "Ask a question, get buttons."},
            {"t": "scene", "raw": "promo-choose", "mark": "tap", "at": -1.8, "dur": 5.4,
             "caption": "Tap. Your agent gets the answer."},
            {"t": "bars", "grow": 1.2, "hold": 5.0, "kicker": "Why a line, not JSON",
             "caption": f"{ratio('min')} fewer tokens than minified JSON.",
             "title": "Tokens for the same 10 screens",
             "footnote": "Same screens, same information in each format. o200k tokenizer. "
                         "Method and every number: yuigui.com/developers/benchmark"},
            {"t": "end", "fill": 30, "text": "Yui Lines is an open spec.", "url": "yuigui.com",
             "small": "Try it live in the playground."},
        ],
    },
    "your-hermes-60s": {
        "title": "Your Hermes on your phone in 60 seconds",
        "what": "Install the plugin, pair, and your own Hermes agent answers on your iPhone with a screen.",
        "poster": 2.0,
        "og": ("promo-pair", "hi", PAIR_REPLY_AT + 3.0),
        "segments": [
            {"t": "scene", "raw": "promo-pair", "mark": "hi", "at": PAIR_REPLY_AT + 0.3, "dur": 4.6,
             "caption": "Your own Hermes agent. On your iPhone."},
            {"t": "title", "dur": 3.0, "text": "Set it up in three steps.",
             "small": "You need a computer running Hermes."},
            {"t": "scene", "raw": "promo-pair", "mark": "start", "at": -0.5, "until": ("code", 3.2), "speed": 1.3,
             "kicker": "Step 1", "caption": "In Yui, add an agent. Get a code."},
            {"t": "type", "style": "dark", "title": "Terminal", "lines": [INSTALL], "cps": 30, "pre": 0.5,
             "hold": 2.4, "kicker": "Step 2", "caption": "On your computer, install the plugin."},
            {"t": "type", "style": "dark", "title": "Terminal", "keep": [INSTALL],
             "lines": ["hermes yui pair 123456", "hermes gateway restart"], "cps": 20, "pre": 0.4, "gap": 0.8,
             "hold": 2.4, "kicker": "Step 3", "caption": "Pair with the code. Restart the gateway."},
            {"t": "scene", "raw": "promo-pair", "mark": "connected", "at": -1.5, "dur": 4.5,
             "caption": "Connected."},
            {"t": "scene", "raw": "promo-pair", "mark": "chat", "at": -0.3, "until": ("hi", PAIR_REPLY_AT + 5.5),
             "caption": "Say hi. It answers with a screen."},
            {"t": "title", "dur": 5.0, "text": "Your agent.\nYour model.", "accent": "Your memory.",
             "small": "Yui is the screen. Your Hermes does the thinking."},
            {"t": "title", "dur": 4.0, "text": "Many agents?", "accent": "One app.",
             "small": "Each Hermes profile is one agent in Yui."},
            {"t": "end", "fill": 60, "text": "Your Hermes, on your phone.", "url": "yuigui.com/start",
             "small": "iPhone beta on TestFlight. " + END_SMALL},
        ],
    },
}


def geometry(tag, size):
    """Canvas, the phone window, and the card panel for one aspect ratio."""
    vw, vh = (int(v) for v in size.split(","))
    if tag == "9x16":
        ph = 1400
        pw = dc.even(ph * vw / vh)
        return (1080, 1920), (dc.even((1080 - pw) / 2), 330, pw, ph), (60, 380, 960, 1180), "portrait"
    lh = 1000
    lw = dc.even(lh * vw / vh)
    return (1920, 1080), (dc.even(1920 - lw - 170), 40, lw, lh), (860, 150, 960, 780), "landscape"


def encode(inputs, graph, dur, out, W, H):
    """One segment: H.264 30 fps, exact length, so segments concat without re-encoding."""
    # The crop pins the size: a frame now and then comes out of the overlay a row taller, and
    # rescaling it back smears two green rows along the bottom of the 16:9 cut.
    dc.run(["ffmpeg", "-y", "-v", "error", *inputs, "-filter_complex", graph + f",fps={FPS},crop={W}:{H}:0:0,format=yuv420p",
            "-t", f"{dur:.3f}", "-an", "-c:v", "libx264", "-preset", "slow", "-crf", "20", "-r", str(FPS),
            "-s", f"{W}x{H}", str(out)])


def stills(frames, out, W, H):
    """A run of (png, seconds) as a segment."""
    lst = out.with_suffix(".txt")
    lines = []
    for png, sec in frames:
        lines += [f"file '{png}'", f"duration {sec:.3f}"]
    lines.append(f"file '{frames[-1][0]}'")
    lst.write_text("\n".join(lines) + "\n")
    total = sum(s for _, s in frames)
    encode(["-f", "concat", "-safe", "0", "-i", str(lst)], "[0:v]null", total, out, W, H)
    return total


def build(names, out):
    names = names or list(VIDEOS)
    bad = [n for n in names if n not in VIDEOS]
    if bad:
        sys.exit(f"unknown video(s): {' '.join(bad)}")
    out.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="yui-promo-"))
    tool = work / "promo_card"
    dc.run(["swiftc", "-O", str(REPO / "scripts/promo_card.swift"), "-o", str(tool)])
    marks = {p.stem: json.loads(p.read_text()) for p in RAW.glob("*.json")}
    manifest_path = out / "videos.json"
    manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else {}
    size = next(iter(marks.values()))["size"]

    for name in names:
        v = VIDEOS[name]
        entry = {"title": v["title"], "what": v["what"], "made": time.strftime("%Y-%m-%d")}
        for tag in ("9x16", "16x9"):
            (W, H), phone, panel, layout = geometry(tag, size)
            base = {"w": W, "h": H, "layout": layout}
            segs, used = [], 0.0
            for i, s in enumerate(v["segments"]):
                seg = work / f"{name}-{tag}-{i:02d}.mp4"
                png = work / f"{name}-{tag}-{i:02d}.png"
                cap = {"caption": s.get("caption", ""), "kicker": s.get("kicker", "")}
                if s["t"] == "scene":
                    m = marks[s["raw"]]
                    start = m[s["mark"]] + s["at"]
                    dur = s["dur"] if "dur" in s else m[s["until"][0]] + s["until"][1] - start
                    dur = min(dur, m["end"] - start)
                    speed = s.get("speed", 1.0)
                    jobs = [{**base, **cap, "out": str(png), "kind": "frame", "win": list(phone),
                             "radius": round(phone[2] * 0.11)}]
                    dc.run([str(tool), _jobs(work, jobs), str(dc.LOGO)])
                    x, y, w, h = phone
                    # simctl writes frames only when the screen changes: fill to a constant rate first,
                    # then trim. Seeking the input would jump past a still moment to the next change.
                    graph = (f"[0:v]fps={FPS},trim=start={start:.3f}:duration={dur:.3f},setpts=(PTS-STARTPTS)/{speed},"
                             f"scale={w}:{h}:flags=lanczos,pad={W}:{H}:{x}:{y}:color={dc.CREAM}[v];[v][1:v]overlay=0:0")
                    encode(["-i", str(RAW / f"{s['raw']}.mp4"), "-loop", "1", "-i", str(png)], graph, dur / speed,
                           seg, W, H)
                    used += dur / speed
                elif s["t"] in ("title", "end"):
                    jobs = [{**base, "out": str(png), "kind": s["t"],
                             **{k: s[k] for k in ("text", "accent", "small", "url") if k in s}}]
                    dc.run([str(tool), _jobs(work, jobs), str(dc.LOGO)])
                    # The end card fills the video out to its length.
                    used += stills([(png, s["dur"] if "dur" in s else s["fill"] - used)], seg, W, H)
                elif s["t"] == "type":
                    frames, jobs = [], []
                    keep = list(s.get("keep", []))
                    step = max(1, round(s["cps"] / FPS * 2))  # a few characters every other frame
                    spec = {**base, **cap, "kind": "console", "win": list(panel), "style": s["style"],
                            "title": s["title"], "font": 46 if tag == "9x16" else 42, "all": keep + s["lines"]}

                    def state(lines, typed, sec, k=[0]):
                        k[0] += 1
                        p = work / f"{name}-{tag}-{i:02d}-{k[0]:04d}.png"
                        jobs.append({**spec, "out": str(p), "lines": lines, "typed": typed})
                        frames.append((p, sec))

                    state(keep + [""], 0, s["pre"])
                    for li, line in enumerate(s["lines"]):
                        if li:
                            state(keep + [""], 0, s.get("gap", 0.5) * 0.5)
                        for n in range(step, len(line) + step, step):
                            state(keep + [line], min(n, len(line)), step / s["cps"])
                        keep.append(line)
                        if li < len(s["lines"]) - 1:
                            frames[-1] = (frames[-1][0], frames[-1][1] + s.get("gap", 0.5) * 0.5)
                    frames[-1] = (frames[-1][0], frames[-1][1] + s["hold"])
                    dc.run([str(tool), _jobs(work, jobs), str(dc.LOGO)])
                    used += stills(frames, seg, W, H)
                elif s["t"] == "bars":
                    frames, jobs = [], []
                    n = round(s["grow"] * FPS / 2)
                    for f in range(n + 1):
                        p = work / f"{name}-{tag}-{i:02d}-{f:04d}.png"
                        t = f / n
                        jobs.append({**base, **cap, "out": str(p), "kind": "bars", "win": list(panel),
                                     "rows": bench_rows(), "progress": 1 - (1 - t) ** 3, "title": s["title"],
                                     "footnote": s["footnote"]})
                        frames.append((p, 2 / FPS))
                    frames[-1] = (frames[-1][0], s["hold"])
                    dc.run([str(tool), _jobs(work, jobs), str(dc.LOGO)])
                    used += stills(frames, seg, W, H)
                segs.append(seg)

            lst = work / f"{name}-{tag}.txt"
            lst.write_text("".join(f"file '{p}'\n" for p in segs))
            dest = out / f"{name}-{tag}.mp4"
            dc.run(["ffmpeg", "-y", "-v", "error", "-f", "concat", "-safe", "0", "-i", str(lst), "-c", "copy",
                    "-movflags", "+faststart", str(dest)])
            poster = out / f"{name}-{tag}.jpg"
            dc.run(["ffmpeg", "-y", "-v", "error", "-ss", str(v["poster"]), "-i", str(dest), "-frames:v", "1",
                    "-q:v", "3", str(poster)])
            entry[tag] = {"src": f"/demo/videos/{dest.name}", "poster": f"/demo/videos/{poster.name}",
                          "seconds": dc.duration(dest), "mb": round(dest.stat().st_size / 1e6, 1)}
            print(f"[{name}] {tag} {entry[tag]['seconds']}s {entry[tag]['mb']} MB -> {dest}")
        # The share link's preview (yuigui.com/s/<name>) shows one real screen from the video.
        raw, mk, at = v["og"]
        t = marks[raw][mk] + at
        dc.run(["ffmpeg", "-y", "-v", "error", "-i", str(RAW / f"{raw}.mp4"), "-vf",
                f"fps={FPS},trim=start={t:.2f},scale=444:-2,crop=444:926:0:(ih-926)/2", "-frames:v", "1", "-q:v", "3",
                str(OG / f"{name}.jpg")])
        manifest[name] = entry
    manifest_path.write_text(json.dumps({k: manifest[k] for k in VIDEOS if k in manifest}, indent=2) + "\n")
    shutil.rmtree(work)


def _jobs(work, jobs):
    p = work / "jobs.json"
    p.write_text(json.dumps(jobs))
    return str(p)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("record")
    r.add_argument("names", nargs="*")
    r.add_argument("--sim")
    b = sub.add_parser("build")
    b.add_argument("names", nargs="*")
    b.add_argument("--out", default=str(OUT))
    args = ap.parse_args()
    if args.cmd == "record":
        bad = [n for n in args.names if n not in SCENES]
        if bad:
            sys.exit(f"unknown scene(s): {' '.join(bad)}")
        record(args.names or SCENES, args.sim)
    else:
        build(args.names, Path(args.out))


if __name__ == "__main__":
    main()

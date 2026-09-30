#!/usr/bin/env python3
"""Score Yui replies: one line and a picture (VIS-1). Spec: yuigui/spec/CHANNEL.md "One line and a picture".

Reads the session stores of every Hermes profile on this machine
(`~/.hermes/profiles/*/state.db`, source `yui`), groups each person turn into
the replies the agent sent for it, and scores each turn:

  words    prose words outside the ```yui blocks (all bubbles of the turn)
  bubbles  text bubbles the app draws: prose paragraphs (a blank line or a block splits one)
  picture  a block with a drawing in Yui Lines: sketch, shapes, map, chart, stat
           or timeline (an image render does not count)
  filler   the first line opens with "so", "now", "however", an intro, an apology
  good     words <= LINE_WORDS and bubbles <= 1, and a drawing unless the reply is
           a bare line of TINY words or fewer (text PLUS a drawing, not pictures
           only: Chris 2026-09-30). No filler.

    python3 vis_score.py [--last 50] [--since 2026-09-30] [--json] [--profile yui] [--gated]

--gated scores the same turns as the plugin's one-line gate (yui/oneline.py, mode on) would send them.

Never prints message text; counts only.
"""

from __future__ import annotations

import json
import os
import re
import sqlite3
import sys
from datetime import datetime
from pathlib import Path

LINE_WORDS = 30
TINY = 12
FENCE = re.compile(r"```yui[^\n]*\n(.*?)(?:```|\Z)", re.S)
# A drawing made of Yui Lines. An image render does not count (Chris 2026-09-30: "draw on the screen using the YL framework").
PICTURE = {"sketch", "shapes", "map", "chart", "stat", "timeline"}
FILLER = re.compile(r"^(so|now|well|okay|ok|sure|alright|anyway|however|basically|overall|actually|great|got it|understood|agreed)\b[,.!]?\s"
                    r"|^(i'?ll|i will|let me|i wanted to|here'?s|here is)\b"
                    r"|\b(a few things|a couple of things|just to let you know|sorry about that|i apologi[sz]e)\b", re.I)
WORDS = re.compile(r"\S+")


def prose(body: str) -> str:
    text = FENCE.sub(" ", body or "")
    return "\n".join(l for l in text.split("\n") if l.strip() and not l.strip().startswith("MEDIA:"))


def has_picture(body: str) -> bool:
    for m in FENCE.finditer(body or ""):
        for ln in m.group(1).split("\n"):
            tok = re.sub(r"^[>~]\d*\s*", "", ln.strip()).split(" ", 1)[0].split("@", 1)[0]
            if tok in PICTURE:
                return True
    return False


def bubble_count(body: str) -> int:
    """Text bubbles the app draws: prose paragraphs, where a blank line or a ```yui block splits one."""
    n = 0
    for chunk in FENCE.sub("\x00", body or "").split("\x00"):
        n += sum(1 for para in re.split(r"\n\s*\n", chunk)
                 if any(l.strip() and not l.strip().startswith("MEDIA:") for l in para.split("\n")))
    return n


def score_turn(bodies: list[str]) -> dict:
    texts = [prose(b) for b in bodies]
    bubbles = sum(bubble_count(b) for b in bodies)
    words = sum(len(WORDS.findall(t)) for t in texts)
    pic = any(has_picture(b) for b in bodies)
    lead = next((l.strip() for t in texts for l in t.split("\n") if l.strip()), "")
    filler = bool(FILLER.search(lead))
    good = words <= LINE_WORDS and bubbles <= 1 and (pic or words <= TINY) and not filler
    return {"words": words, "bubbles": bubbles, "picture": pic, "filler": filler, "good": good}


def turns(db: Path, since: float = 0.0):
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True) if not (db.parent / (db.name + "-wal")).exists() \
        else sqlite3.connect(str(db))
    try:
        sess = con.execute("select id from sessions where source='yui'").fetchall()
        for (sid,) in sess:
            cur = None
            for role, content, ts in con.execute(
                    "select role, content, timestamp from messages where session_id=? and active=1 order by timestamp, id", (sid,)):
                if role == "user":
                    if cur and cur["bodies"]:
                        yield cur
                    cur = {"ts": ts, "bodies": [], "ask": (content or "").startswith("[yui]")}
                elif role == "assistant" and cur is not None and (content or "").strip():
                    cur["bodies"].append(content)
            if cur and cur["bodies"]:
                yield cur
    finally:
        con.close()


def gated(bodies: list[str]) -> list[str]:
    """The same bodies as the `on` gate in the plugin would send them (yui/oneline.py)."""
    import importlib.util
    spec = importlib.util.spec_from_file_location("oneline", Path(__file__).parent / "yui" / "oneline.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    out, prior = [], 0
    for b in bodies:
        new, drawn = mod.gate(b, prior, "on")
        prior += drawn
        if new.strip():
            out.append(new)
    return out


def collect(profile: str | None = None, since: float = 0.0, gate: bool = False) -> list[dict]:
    home = Path(os.environ.get("HERMES_HOME_ROOT") or Path.home() / ".hermes")
    out = []
    for p in sorted((home / "profiles").glob("*/state.db")):
        name = p.parent.name
        if profile and name != profile:
            continue
        for t in turns(p, since):
            if t["ts"] < since:
                continue
            s = score_turn(gated(t["bodies"]) if gate else t["bodies"])
            s.update(profile=name, ts=t["ts"])
            out.append(s)
    out.sort(key=lambda r: r["ts"])
    return out


def summary(rows: list[dict]) -> dict:
    n = len(rows)
    if not n:
        return {"turns": 0}
    g = sum(r["good"] for r in rows)
    return {"turns": n, "good": g, "pct_good": round(100 * g / n),
            "pct_picture": round(100 * sum(r["picture"] for r in rows) / n),
            "pct_one_bubble": round(100 * sum(r["bubbles"] <= 1 for r in rows) / n),
            "pct_filler": round(100 * sum(r["filler"] for r in rows) / n),
            "pct_over_30_words": round(100 * sum(r["words"] > LINE_WORDS for r in rows) / n),
            "median_words": sorted(r["words"] for r in rows)[n // 2],
            "avg_bubbles": round(sum(r["bubbles"] for r in rows) / n, 2)}


def main(argv: list[str]) -> int:
    def arg(name, default=None):
        return argv[argv.index(name) + 1] if name in argv else default
    last = int(arg("--last", 50))
    since = 0.0
    if arg("--since"):
        since = datetime.strptime(arg("--since"), "%Y-%m-%d").timestamp()
    rows = collect(arg("--profile"), since, "--gated" in argv)
    rows = rows[-last:] if last else rows
    res = {"all": summary(rows)}
    for prof in sorted({r["profile"] for r in rows}):
        res[prof] = summary([r for r in rows if r["profile"] == prof])
    if "--json" in argv:
        print(json.dumps(res, indent=1))
    else:
        for k, v in res.items():
            print(k, v)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

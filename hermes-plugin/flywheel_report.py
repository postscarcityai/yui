#!/usr/bin/env python3
"""Weekly preset-flywheel report (YUI-42). Spec: yuigui/spec/FLYWHEEL.md.

Reads the shape log yui/flywheel.py writes (<profile home>/yui/flywheel.jsonl)
and prints markdown: the custom shapes agents send most, by uses and by
distinct days, the ones that crossed the promotion bar, and the unknown words
agents reached for.

    python3 flywheel_report.py                     # full report, the yui profile's log
    python3 flywheel_report.py --log x.jsonl --since 7
    python3 flywheel_report.py --only-qualified    # prints nothing unless a shape crossed the bar (cron)

No dependencies. The log holds shapes, never values, so this report is safe to
paste anywhere.
"""

import argparse
import json
import os
import sys
from collections import defaultdict
from datetime import date, timedelta
from pathlib import Path

MIN_USES = 5
MIN_DAYS = 3
SPEC = "https://www.yuigui.com/developers/flywheel"


def default_log() -> Path:
    if os.environ.get("YUI_FLYWHEEL_LOG"):
        return Path(os.environ["YUI_FLYWHEEL_LOG"])
    home = os.environ.get("HERMES_HOME") or str(Path.home() / ".hermes" / "profiles" / "yui")
    return Path(home) / "yui" / "flywheel.jsonl"


def load(path: Path, since: int | None) -> list:
    floor = (date.today() - timedelta(days=since)).isoformat() if since else ""
    rows = []
    try:
        with path.open() as f:
            for line in f:
                try:
                    r = json.loads(line)
                except ValueError:
                    continue
                if isinstance(r, dict) and r.get("date", "") >= floor:
                    rows.append(r)
    except FileNotFoundError:
        pass
    return rows


def tally(rows: list) -> tuple[list, list]:
    shapes = defaultdict(lambda: {"uses": 0, "days": set(), "agents": set(), "shape": "", "last": ""})
    words = defaultdict(lambda: {"uses": 0, "days": set(), "agents": set()})
    for r in rows:
        if r.get("kind") == "custom" and r.get("hash"):
            s = shapes[r["hash"]]
            s["shape"] = r.get("shape", "")
            s["last"] = max(s["last"], r.get("date", ""))
        elif r.get("kind") == "word" and r.get("word"):
            s = words[r["word"]]
        else:
            continue
        s["uses"] += 1
        s["days"].add(r.get("date", ""))
        s["agents"].add(r.get("profile", ""))
    order = lambda kv: (-len(kv[1]["days"]), -kv[1]["uses"], kv[0])
    return sorted(shapes.items(), key=order), sorted(words.items(), key=order)


def qualifies(s: dict, min_uses: int, min_days: int) -> bool:
    return s["uses"] >= min_uses and len(s["days"]) >= min_days and s["shape"] != "!json"


def cell(text: str) -> str:
    return "`" + text.replace("|", "\\|") + "`"


def report(rows: list, *, min_uses: int, min_days: int, top: int, source: str) -> str:
    shapes, words = tally(rows)
    ready = [(h, s) for h, s in shapes if qualifies(s, min_uses, min_days)]
    days = sorted({r.get("date", "") for r in rows})
    customs = sum(s["uses"] for _, s in shapes)
    out = ["# Yui preset flywheel", ""]
    if not rows:
        out += [f"No rows in {source} yet. Turn it on with `yui: {{flywheel: true}}` in the profile config."]
        return "\n".join(out) + "\n"
    out += [f"{customs} custom lines in {len(shapes)} shapes, {sum(w['uses'] for _, w in words)} unknown words, "
            f"{days[0]} to {days[-1]}. Bar: {min_uses}+ uses on {min_days}+ days.", ""]
    out += [f"## Ready to promote ({len(ready)})", ""]
    if ready:
        out += ["| hash | uses | days | agents | shape |", "|---|---|---|---|---|"]
        out += [f"| {h} | {s['uses']} | {len(s['days'])} | {len(s['agents'])} | {cell(s['shape'])} |" for h, s in ready]
        out += ["", f"Next: the promotion checklist, {SPEC}"]
    else:
        out += ["Nothing crossed the bar yet."]
    out += ["", f"## Top custom shapes (by days, then uses, top {top})", ""]
    if shapes:
        out += ["| hash | uses | days | last seen | shape |", "|---|---|---|---|---|"]
        out += [f"| {h} | {s['uses']} | {len(s['days'])} | {s['last']} | {cell(s['shape'])} |"
                for h, s in shapes[:top]]
    else:
        out += ["No custom lines."]
    out += ["", "## Unknown words (heads that are not a preset yet)", ""]
    if words:
        out += ["| word | uses | days |", "|---|---|---|"]
        out += [f"| {cell(w)} | {s['uses']} | {len(s['days'])} |" for w, s in words[:top]]
    else:
        out += ["None."]
    return "\n".join(out) + "\n"


def nudge(rows: list, *, min_uses: int, min_days: int) -> str:
    """The short message the weekly cron sends to Yui. Empty when nothing crossed the bar."""
    shapes, _ = tally(rows)
    ready = [(h, s) for h, s in shapes if qualifies(s, min_uses, min_days)]
    if not ready:
        return ""
    lines = [f"{len(ready)} custom screen{'s' if len(ready) > 1 else ''} came up often enough to become a preset:"]
    lines += [f"- {h}: {s['uses']} uses on {len(s['days'])} days. {s['shape'][:160]}" for h, s in ready[:5]]
    lines += ["", f"Promotion checklist: {SPEC}. Say which one and it goes on the board."]
    return "\n".join(lines) + "\n"


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--log", type=Path, default=None, help="flywheel.jsonl (default: the yui profile's)")
    ap.add_argument("--since", type=int, default=None, help="only the last N days")
    ap.add_argument("--min-uses", type=int, default=MIN_USES)
    ap.add_argument("--min-days", type=int, default=MIN_DAYS)
    ap.add_argument("--top", type=int, default=15)
    ap.add_argument("--only-qualified", action="store_true",
                    help="print a short nudge only when a shape crossed the bar, else nothing")
    ap.add_argument("--out", type=Path, help="also write the report here")
    a = ap.parse_args(argv)
    log = a.log or default_log()
    rows = load(log, a.since)
    if a.only_qualified:
        sys.stdout.write(nudge(rows, min_uses=a.min_uses, min_days=a.min_days))
        return 0
    text = report(rows, min_uses=a.min_uses, min_days=a.min_days, top=a.top, source=str(log))
    if a.out:
        a.out.write_text(text)
    sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())

"""The preset flywheel (YUI-42). Spec: yuigui/spec/FLYWHEEL.md.

`custom {json}` is Yui Lines' escape hatch (YL.md section 6). When agents keep
sending the same custom shape, that shape should become a preset. This module
notes which shapes they send, so the repeats show up in a weekly report.

What gets written, per ```yui fence in an outgoing reply:
  - one row per `custom` line: its SHAPE only. The JSON type tree with key
    names and `type` names, never a value: every string is `s`, every number
    `n`, so no text, number, URL or id from the screen reaches the log.
  - one row per line whose head word is not a preset or core word (an agent
    reaching for a preset that does not exist yet). Only that one word.

Rows go to `<profile home>/yui/flywheel.jsonl`, on this machine only. Nothing
is uploaded. Off unless the profile's config.yaml says:

    yui:
      flywheel: true

Recording never raises: a broken log must not break a reply.
"""

import hashlib
import json
import os
import re
from datetime import datetime
from pathlib import Path

# Mirrors PRESETS and CORE in yuigui site/lib/yl/yl.mjs; the tests check them.
PRESETS = {
    "timer", "ask", "choose", "pick", "slide", "form",
    "list", "table", "card", "image", "camera", "mic",
    "gallery", "video", "compare", "storyboard",
    "chart", "stat", "math", "step", "calc",
    "deck", "page", "plan", "project", "narrate",
    "timeline", "done", "now", "next",
}
CORE = {"say", "custom", "save", "show", "forget", "clear", "end", "theme", "close"}

FENCE = re.compile(r"```yui[^\n]*\n(.*?)```", re.S)
# A name that looks like a field or a type, not like data. Keys that do not
# match (capitalised, spaced, numeric: often a person's data used as a map key)
# are written as `*`.
NAME = re.compile(r"[a-z][A-Za-z0-9_]{0,23}\Z")
WORD = re.compile(r"[a-z][a-z0-9_-]{0,23}\Z")
MAX_DEPTH = 6
MAX_KEYS = 16          # more keys than this reads as a map of data, not a component
MAX_ITEMS = 50         # array elements looked at
MAX_SHAPE = 400        # characters kept in the log (the hash covers the whole shape)

_enabled_cache: tuple = (None, False)   # (config mtime, enabled)


def home() -> Path:
    return Path(os.environ.get("HERMES_HOME") or Path.home() / ".hermes")


def log_path() -> Path:
    return Path(os.environ.get("YUI_FLYWHEEL_LOG") or home() / "yui" / "flywheel.jsonl")


def enabled() -> bool:
    """`yui.flywheel: true` in this profile's config.yaml (re-read when the file changes)."""
    global _enabled_cache
    cfg = home() / "config.yaml"
    try:
        mtime = cfg.stat().st_mtime
    except OSError:
        return False
    if _enabled_cache[0] == mtime:
        return _enabled_cache[1]
    on = False
    try:
        text = cfg.read_text()
        try:
            import yaml
            on = ((yaml.safe_load(text) or {}).get("yui") or {}).get("flywheel") is True
        except ImportError:  # pragma: no cover
            on = bool(re.search(r"^yui:\s*\n(?:[ \t]+.*\n)*?[ \t]+flywheel:\s*true\b", text, re.M))
    except Exception:
        on = False
    _enabled_cache = (mtime, on)
    return on


def shape(v, depth: int = 0) -> str:
    """The type tree of a JSON value. Key and `type` names survive, values never do."""
    if depth > MAX_DEPTH:
        return "…"
    if v is None:
        return "null"
    if isinstance(v, bool):
        return "b"
    if isinstance(v, (int, float)):
        return "n"
    if isinstance(v, str):
        return "s"
    if isinstance(v, list):
        return "[" + "|".join(sorted({shape(x, depth + 1) for x in v[:MAX_ITEMS]})) + "]"
    if isinstance(v, dict):
        t = v.get("type")
        head = (t if isinstance(t, str) and NAME.match(t) else "?") if "type" in v else ""
        keys = [k for k in v if k != "type"]
        if len(keys) > MAX_KEYS:
            return head + "{*:" + "|".join(sorted({shape(v[k], depth + 1) for k in keys[:MAX_ITEMS]})) + "}"
        parts = sorted({f"{k if NAME.match(k) else '*'}:{shape(v[k], depth + 1)}" for k in keys})
        return head + "{" + ",".join(parts) + "}"
    return "?"


def digest(sig: str) -> str:
    return hashlib.sha256(sig.encode()).hexdigest()[:12]


def scan(body: str) -> list:
    """Rows for every custom line and unknown head word in the body's ```yui fences."""
    rows = []
    for m in FENCE.finditer(body or ""):
        for raw in m.group(1).split("\n"):
            ln = raw.strip()
            if not ln or ln == "#" or ln.startswith("# ") or ln.startswith("~"):
                continue
            if ln.startswith(">"):  # `>S line` routes one line; `>S` alone just moves focus
                parts = ln.split(None, 1)
                if len(parts) < 2:
                    continue
                ln = parts[1].strip()
            parts = ln.split(None, 1)
            head = parts[0].split("@", 1)[0]
            if head == "custom":
                try:
                    sig = shape(json.loads(parts[1] if len(parts) > 1 else ""))
                except ValueError:
                    sig = "!json"  # bad JSON: an error line in the app
                rows.append({"kind": "custom", "hash": digest(sig), "shape": sig[:MAX_SHAPE]})
            elif head not in PRESETS and head not in CORE and WORD.match(head):
                rows.append({"kind": "word", "word": head})
    return rows


def record(body: str, profile: str | None = None) -> int:
    """Append this reply's rows when the flywheel is on. Returns how many were written."""
    try:
        if not enabled() or "```yui" not in (body or ""):
            return 0
        rows = scan(body)
        if not rows:
            return 0
        # The host's own day: the report counts distinct days.
        stamp = {"date": datetime.now().strftime("%Y-%m-%d"), "profile": profile or "default"}
        path = log_path()
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a") as f:
            f.write("".join(json.dumps({**stamp, **r}, ensure_ascii=False) + "\n" for r in rows))
        return len(rows)
    except Exception:
        return 0

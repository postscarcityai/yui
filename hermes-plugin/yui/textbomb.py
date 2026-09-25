"""Text bombs (YUI-79). Spec: yuigui/spec/CHANNEL.md "Reports and long answers".

Yui is a phone app, not a chat log: chat text over about 50 words should be a
`deck` or `plan` of pages instead, and the app folds anything longer into
"Read as pages". This module notes which agent or cron still sends walls, so
they can be fixed at the source.

What gets written, per outgoing message whose chat text (everything outside
```yui fences) runs over CAP words: one row with the date and time, the
profile, where it came from (`reply` to the person's turn, `handoff` from
another profile or a late send, `out-of-process` for cron and send_message
without the gateway, `cron` when that process is an agent cron run), the word
count, and whether the message carried a screen too. Never the text.

Rows go to `<profile home>/yui/textbombs.jsonl`, on this machine only, and a
warning goes to the gateway log. `python3 textbomb.py [--days 7]` prints the
tally. Recording never raises: a broken log must not break a reply.
"""

from __future__ import annotations

import json
import os
import re
import sys
from datetime import datetime, timedelta
from pathlib import Path

CAP = 60   # the guide says "about 50"; the app folds at the same 60
FENCE = re.compile(r"```yui[^\n]*\n.*?(?:```|\Z)", re.S)
WORDS = re.compile(r"\S+")


def home() -> Path:
    return Path(os.environ.get("HERMES_HOME") or Path.home() / ".hermes")


def log_path() -> Path:
    return Path(os.environ.get("YUI_TEXTBOMB_LOG") or home() / "yui" / "textbombs.jsonl")


def chat_words(body: str) -> int:
    """Words a person reads as chat bubbles: the body minus its ```yui fences and MEDIA: lines."""
    text = FENCE.sub(" ", body or "")
    text = "\n".join(ln for ln in text.split("\n") if not ln.strip().startswith("MEDIA:"))
    return len(WORDS.findall(text))


def record(body: str, profile: str | None = None, source: str = "reply", logger=None) -> int:
    """Log one row when the chat text runs over CAP. Returns its word count (0 when under)."""
    try:
        n = chat_words(body)
        if n <= CAP:
            return 0
        if source == "out-of-process" and os.environ.get("HERMES_CRON_SESSION"):
            source = "cron"
        now = datetime.now()
        row = {"date": now.strftime("%Y-%m-%d"), "time": now.strftime("%H:%M"),
               "profile": profile or "default", "source": source, "words": n,
               "screen": "```yui" in (body or "")}
        path = log_path()
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a") as f:
            f.write(json.dumps(row) + "\n")
        if logger:
            logger.warning("[yui] text bomb: %d words of chat text from %s (%s); "
                           "send it as a deck of pages (CHANNEL.md)", n, row["profile"], source)
        return n
    except Exception:
        return 0


def report(days: int = 7, path: Path | None = None) -> str:
    """Tally of the last `days` days: per profile and source, how many and the longest."""
    since = (datetime.now() - timedelta(days=days)).strftime("%Y-%m-%d")
    tally: dict = {}
    try:
        lines = (path or log_path()).read_text().splitlines()
    except OSError:
        lines = []
    for ln in lines:
        try:
            r = json.loads(ln)
        except ValueError:
            continue
        if r.get("date", "") < since:
            continue
        k = (r.get("profile", "?"), r.get("source", "?"))
        t = tally.setdefault(k, {"n": 0, "max": 0, "last": ""})
        t["n"] += 1
        t["max"] = max(t["max"], r.get("words", 0))
        t["last"] = max(t["last"], f"{r.get('date', '')} {r.get('time', '')}")
    if not tally:
        return f"No text bombs in the last {days} days."
    out = [f"Text bombs, last {days} days (chat text over {CAP} words):"]
    for (p, s), t in sorted(tally.items(), key=lambda kv: -kv[1]["n"]):
        out.append(f"  {p} {s}: {t['n']}, longest {t['max']} words, last {t['last']}")
    return "\n".join(out)


if __name__ == "__main__":
    d = 7
    if "--days" in sys.argv:
        d = int(sys.argv[sys.argv.index("--days") + 1])
    print(report(d))

"""One line and a picture (VIS-1). Spec: yuigui/spec/CHANNEL.md "One line and a picture".

Chris, 2026-09-30: replies came as three or four prose bubbles around a small
sketch, and the app folded them into text slides. The guide already says "show,
don't say", and agents do not always follow it, so this is the rule in code.

A reply breaks the rule when its chat text (outside the ```yui blocks) runs over
LINE_WORDS words, or draws more than one text bubble (a blank line or a block
splits one), or a second prose bubble follows in the same turn. `gate()` then
rewrites it before it sends:

  * one line: the first sentence, plus the question when there is one, cut
    short at a clause, LINE_WORDS at most, with an opening "so" or "now" dropped
    (caveman words);
  * the picture: the blocks stay as they are. When the reply had none, the
    other sentences become a `sketch` of short rows (the fallback; the guide
    is what should draw the picture in the first place);
  * a later prose bubble in the same turn gets no line, only the picture.

Modes (`yui.one_line` in config or YUI_ONE_LINE): `shadow` (default) logs what
it would change and sends the reply untouched; `on` sends the rewrite; `off`.
Rows go to `<profile home>/yui/oneline.jsonl`: counts and the action, never the
text. Replies with a code fence, or with no prose, are left alone. Recording
and rewriting never raise: a broken gate must not break a reply.
"""

from __future__ import annotations

import json
import os
import re
from datetime import datetime
from pathlib import Path
from typing import Optional

LINE_WORDS = 30
LINE_TARGET = 22         # the first sentence is cut near here
ROW_WORDS = 8
MAX_ROWS = 4
MODES = ("off", "shadow", "on")

FENCE = re.compile(r"```yui[^\n]*\n.*?(?:```|\Z)", re.S)
OTHER_FENCE = re.compile(r"```(?!yui)")
WORDS = re.compile(r"\S+")
SENTENCE = re.compile(r"(?<=[.!?])\s+(?=[A-Z0-9(\"'`])")
CLAUSE = re.compile(r"[,;:\u2014]|\s-\s")
# A drawing made of Yui Lines. A rendered image does not count: Chris, 2026-09-30, "draw on the screen using the YL framework".
PICTURE = {"sketch", "shapes", "map", "chart", "stat", "timeline"}
# Caveman words: an opening filler word goes ("So, the build is ready." -> "The build is ready.").
FILLER_LEAD = re.compile(r"^(so|now|well|okay|ok|sure|alright|anyway|however|basically|overall|actually|got it|understood|agreed)\b[,.!]?\s+", re.I)
DANGLING = {"and", "or", "but", "the", "a", "an", "of", "to", "in", "on", "at", "for", "by", "with", "because", "that",
            "which", "is", "are", "was", "were", "so", "as", "from", "it", "its", "into", "than", "then", "if", "when"}
ACK_ONLY = re.compile(r"^(got it|understood|agreed|okay|ok|sure|alright)[.!]*$", re.I)
MARKUP = re.compile(r"^\s*(?:#{1,6}\s+|[-*•]\s+|\d+[.)]\s+)")


def mode(config_extra: Optional[dict] = None) -> str:
    m = (os.environ.get("YUI_ONE_LINE") or (config_extra or {}).get("one_line") or "shadow")
    m = str(m).strip().lower()
    return m if m in MODES else "shadow"


def home() -> Path:
    return Path(os.environ.get("HERMES_HOME") or Path.home() / ".hermes")


def log_path() -> Path:
    return Path(os.environ.get("YUI_ONELINE_LOG") or home() / "yui" / "oneline.jsonl")


def _paragraphs(text: str) -> list[str]:
    return [p.strip() for p in re.split(r"\n\s*\n", text) if any(
        l.strip() and not l.strip().startswith("MEDIA:") for l in p.split("\n"))]


def measure(body: str) -> dict:
    """Words and bubbles of the chat text, and whether a block draws a picture."""
    words = bubbles = 0
    for chunk in FENCE.sub("\x00", body or "").split("\x00"):
        paras = _paragraphs(chunk)
        bubbles += len(paras)
        words += sum(len(WORDS.findall(p)) for p in paras if not p.startswith("MEDIA:"))
    pic = False
    for m in FENCE.finditer(body or ""):
        for ln in m.group(0).split("\n")[1:]:
            tok = re.sub(r"^[>~]\d*\s*", "", ln.strip()).split(" ", 1)[0].split("@", 1)[0]
            if tok in PICTURE:
                pic = True
    paras = [p for c in FENCE.sub("\x00", body or "").split("\x00") for p in _paragraphs(c)]
    lead = paras[0] if paras else ""
    return {"words": words, "bubbles": bubbles, "picture": pic, "filler": bool(FILLER_LEAD.match(lead))}


def violates(m: dict, prior: int = 0) -> bool:
    return m["bubbles"] > 0 and (m["words"] > LINE_WORDS or m["bubbles"] > 1 or prior > 0 or m["filler"])


def _unfill(s: str) -> str:
    t = FILLER_LEAD.sub("", s, count=1)
    return t[:1].upper() + t[1:] if t != s else s


def _clip(s: str, n: int) -> str:
    """At most n words, cut at the last clause inside the limit, never with an ellipsis
    and never ending on a dangling "and" or "the"."""
    w = s.split()
    if len(w) <= n:
        return s.strip().rstrip(",;:")
    head = " ".join(w[:n])
    cut = [m.start() for m in CLAUSE.finditer(head)]
    if cut and cut[-1] >= len(head) // 2:
        head = head[:cut[-1]]
    words = head.split()
    while len(words) > 2 and (words[-1].lower().strip(",;:") in DANGLING
                              or (words[-1][:1].isdigit() and words[-2].lower() in DANGLING)):
        words.pop()
    return " ".join(words).rstrip(",;:-\u2014") + ("." if s.rstrip().endswith(".") else "")


def _sentences(text: str) -> list[str]:
    out = []
    for p in _paragraphs(text):
        for ln in p.split("\n"):
            ln = MARKUP.sub("", ln).strip()
            if ln:
                out += [s.strip() for s in SENTENCE.split(ln) if s.strip()]
    return out


def _q(s: str) -> str:
    return '"' + " ".join(s.split()).replace("\\", "").replace('"', "'") + '"'


def rewrite(body: str, prior: int = 0) -> Optional[str]:
    """The reply as one line and its picture, or None when it should go as written."""
    if not body or OTHER_FENCE.search(FENCE.sub(" ", body)):
        return None
    m = measure(body)
    if not violates(m, prior):
        return None
    fences = [f.group(0).rstrip() for f in FENCE.finditer(body)]
    sents = _sentences(FENCE.sub(" ", body))
    if not sents:
        return None
    head = None
    title = "The short version"
    for p in _paragraphs(FENCE.sub(" ", body)):
        h = re.match(r"\s*#{1,6}\s+(.+)", p)
        if h:
            title = _clip(h.group(1), 4).rstrip(".")
            break
    rest = list(sents)
    while len(rest) > 1 and ACK_ONLY.match(rest[0]):  # "Got it." on its own says nothing
        rest.pop(0)
    line = ""
    if prior == 0:
        first = rest.pop(0)
        line = _clip(_unfill(first), LINE_TARGET)
        ask = next((s for s in rest if s.endswith("?")), None)
        if ask and not line.endswith("?") and len(line.split()) + len(ask.split()) <= LINE_WORDS:
            line += " " + ask
            rest.remove(ask)
        head = line
    out = [head] if head else []
    if m["picture"] or not rest:
        out += fences  # the picture stays; extra prose goes (it was said by the picture or the line)
    else:
        rows = [_clip(s, ROW_WORDS).rstrip(".") for s in rest[:MAX_ROWS]]
        sketch = [f"sketch {_q(title)} frame=bubble"] + [f"row {_q(r)}" for r in rows]
        out += fences + ["```yui\n" + "\n".join(sketch) + "\n```"]
    return "\n".join(out).strip() or None


def record(before: dict, after: Optional[dict], action: str, profile: str, source: str, logger=None) -> None:
    try:
        now = datetime.now()
        row = {"date": now.strftime("%Y-%m-%d"), "time": now.strftime("%H:%M"), "profile": profile or "default",
               "source": source, "action": action, "words": before["words"], "bubbles": before["bubbles"],
               "picture": before["picture"]}
        if after:
            row.update(words_after=after["words"], bubbles_after=after["bubbles"], picture_after=after["picture"])
        p = log_path()
        p.parent.mkdir(parents=True, exist_ok=True)
        with p.open("a") as f:
            f.write(json.dumps(row) + "\n")
        if logger:
            logger.info("[yui] one-line %s: %d words, %d bubbles", action, before["words"], before["bubbles"])
    except Exception:
        pass


def gate(body: str, prior: int, mode_: str, profile: str = "", source: str = "reply", logger=None) -> tuple[str, int]:
    """(body to send, text bubbles it draws). `prior` is the prose bubbles already sent in this turn."""
    try:
        before = measure(body)
        if mode_ == "off" or not violates(before, prior):
            return body, before["bubbles"]
        new = rewrite(body, prior)
        if new is None:
            return body, before["bubbles"]
        after = measure(new)
        if mode_ == "on":
            record(before, after, "rewrote", profile, source, logger)
            return new, after["bubbles"]
        record(before, after, "would-rewrite", profile, source, logger)
        return body, before["bubbles"]
    except Exception:
        return body, 0


def report(days: int = 7, path: Optional[Path] = None) -> str:
    since = (datetime.now().timestamp() - days * 86400)
    n = 0
    tally: dict = {}
    try:
        lines = (path or log_path()).read_text().splitlines()
    except OSError:
        lines = []
    for ln in lines:
        try:
            r = json.loads(ln)
            if datetime.strptime(r["date"], "%Y-%m-%d").timestamp() < since - 86400:
                continue
        except (ValueError, KeyError):
            continue
        k = (r.get("profile", "?"), r.get("action", "?"))
        tally[k] = tally.get(k, 0) + 1
        n += 1
    if not n:
        return f"No one-line rewrites in the last {days} days."
    return "\n".join([f"One-line gate, last {days} days:"] + [f"  {p} {a}: {c}" for (p, a), c in sorted(tally.items())])


if __name__ == "__main__":
    import sys
    d = int(sys.argv[sys.argv.index("--days") + 1]) if "--days" in sys.argv else 7
    print(report(d))

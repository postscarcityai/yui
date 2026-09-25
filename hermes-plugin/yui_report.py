#!/usr/bin/env python3
"""Reports as screens, not walls (YUI-79). Spec: yuigui/spec/CHANNEL.md "Reports and long answers".

For host scripts and crons that post into Yui (build pings, board reports,
watchers): one short line, one card with what happened, and the detail behind
it as a deck of pages, one idea per page. Plain Python 3.9, no dependencies,
so /usr/bin/python3 in a cron script can run it.

    echo '{"line": "Build 82 is ready.",
           "card": {"title": "Build 82", "body": "A2A agents join Yui", "cta": "Open TestFlight", "url": "https://..."},
           "deck": "What's in build 82",
           "pages": [{"title": "INT-18", "body": "...", "img": "https://..."},
                     {"title": "Tests", "points": ["a", "b"]}]}' \\
        | python3 yui_report.py

    python3 yui_report.py --fold "Title" < long.txt   # any long text as a line plus pages

Page bodies are cut to whole sentences near PAGE_WORDS; a body that runs
longer becomes more pages under the same title ("INT-18 (2/3)").
"""

import json
import re
import sys

PAGE_WORDS = 60     # a page is read on a phone in a few seconds
LINE_WORDS = 25     # the chat line above the card
MAX_PAGES = 12
SENTENCE = re.compile(r"(?<=[.!?;])\s+(?=[A-Z0-9(\"'])")


def q(s) -> str:
    """A Yui Lines quoted string: double quotes, backslash escapes, one line."""
    s = " ".join(str(s).split())
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def words(s: str) -> int:
    return len(str(s).split())


def clip(s: str, n: int) -> str:
    """The first n words, cut at a sentence end when one is close, else with an ellipsis."""
    w = str(s).split()
    if len(w) <= n:
        return " ".join(w)
    head = " ".join(w[:n])
    end = max(head.rfind(". "), head.rfind("; "), head.rfind(": "))
    if end > len(head) // 2:
        return head[:end + 1].rstrip(";:") if head[end] != "." else head[:end + 1]
    return head.rstrip(",;:") + "…"


def sentences(text: str) -> list:
    return [s.strip() for s in SENTENCE.split(" ".join(str(text).split())) if s.strip()]


def chunks(text: str, size: int = PAGE_WORDS) -> list:
    """Paragraphs first, then sentences, packed to about `size` words; a giant sentence splits at words."""
    out = []
    for para in re.split(r"\n\s*\n", str(text).strip()):
        cur = []
        for s in sentences(para):
            w = s.split()
            while len(w) > size * 3 // 2:              # one enormous sentence
                if cur:
                    out.append(" ".join(cur)); cur = []
                out.append(" ".join(w[:size])); w = w[size:]
            if cur and len(cur) + len(w) > size:
                out.append(" ".join(cur)); cur = []
            cur += w
        if cur:
            out.append(" ".join(cur))
    return [c for c in out if c]


def pages(items) -> list:
    """[{title, body | points}] -> page dicts, long bodies spread over numbered pages."""
    out = []
    for it in items:
        title = it.get("title") or "More"
        if it.get("points"):
            out.append({"title": title, "points": [clip(p, 20) for p in it["points"]][:8]})
            continue
        parts = chunks(it.get("body", "")) or [""]
        for i, part in enumerate(parts):
            t = title if len(parts) == 1 else f"{title} ({i + 1}/{len(parts)})"
            out.append({"title": t, "body": part, "img": it.get("img") if i == 0 else None})
    return out[:MAX_PAGES]


def page_line(p: dict) -> str:
    if p.get("points"):
        return f"page {q(p['title'])} points=" + "|".join(q(x.replace("|", "/")) for x in p["points"])
    img = f" img={p['img']}" if p.get("img") else ""
    return f"page {q(p['title'])} body={q(p['body'])}{img}"


def render(r: dict) -> str:
    """The message: a chat line, then one ```yui fence with the card and the deck."""
    yl = []
    c = r.get("card")
    if c:
        ln = f"card {q(c['title'])}"
        if c.get("body"):
            ln += f" body={q(clip(c['body'], 30))}"
        if c.get("cta"):
            ln += f" cta={q(c['cta'])}"
            if c.get("url"):
                ln += f" url={c['url']}"
        yl.append(ln)
    ps = pages(r.get("pages") or [])
    if ps:
        yl.append(f"deck {q(r.get('deck') or 'Details')} +inline")
        yl += [page_line(p) for p in ps]
        yl.append("end")
    msg = clip(r.get("line", ""), LINE_WORDS)
    if yl:
        msg = (msg + "\n" if msg else "") + "```yui\n" + "\n".join(yl) + "\n```"
    return msg


def fold(title: str, text: str) -> str:
    """Any long text: its first sentence as the line, the rest as pages."""
    ss = sentences(text)
    if words(text) <= LINE_WORDS * 2:
        return " ".join(str(text).split())
    return render({"line": clip(ss[0] if ss else title, LINE_WORDS), "deck": title,
                   "pages": [{"title": title, "body": text}]})


def main(argv) -> int:
    if len(argv) > 1 and argv[1] == "--fold":
        print(fold(argv[2] if len(argv) > 2 else "Details", sys.stdin.read()))
        return 0
    print(render(json.load(sys.stdin)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

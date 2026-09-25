"""Presets the person's phone can draw (beta feedback ANJPrtB7CHynwGR5mqNVPSM).

The channel guide teaches every preset, but a phone runs whatever build it
has. Build 96 got a `sketch` and drew each line as a red "unknown preset"
with the raw Yui Lines under it. yui-push records each phone's app build and
yui-connect's session hands the host the oldest one (`app_build`). Before a
reply goes out, `downgrade` turns every preset that build cannot draw into
something it can:

  * in the chat: plain words (a sketch's rows as a list, struck and bold
    marks in markdown, which bubbles draw since build 94);
  * inside a deck or plan: a `page` whose points are those rows.

An unknown build (no phone has said yet) counts as older than all of them.
`note` is the line added to the agent's turn so it skips them to begin with.
"""
import re
from typing import Dict, List, Optional

# First app build whose parser knows each preset (git rev-list --count of the
# commit that added it to Packages/YuiLines/Sources/YuiLines/Presets.swift).
MIN_BUILD: Dict[str, int] = {
    "timeline": 69, "done": 69, "now": 69, "next": 69,  # b14ea17
    "game": 71,                                          # 36ecded
    "sketch": 104, "row": 104, "after": 104,             # d7214ee (YUI-84)
    "menu": 115,                                         # YUI-86: the drawer's lists; dropped before
}
GROUPS = {"sketch": {"row", "after"}, "timeline": {"done", "now", "next"}}
MEMBER_OF = {m: head for head, ms in GROUPS.items() for m in ms}
STORY = {"deck", "plan"}  # a sketch in these is the picture of a page
QUIET = {"menu"}  # draws nothing in the chat: dropped on old builds, never named in the note

FENCE = re.compile(r"```yui[^\n]*\n(.*?)```", re.DOTALL)
TOKEN = re.compile(r'[+\w-]+="(?:[^"\\]|\\.)*"(?:\|"(?:[^"\\]|\\.)*")*|"(?:[^"\\]|\\.)*"|\S+')
SCREEN = re.compile(r"^(>\S+\s+)")


# The oldest build among the person's phones, from the adapter's last session.
# `known` stays False until a session arrives: no note before then.
PHONE = {"known": False, "build": None}


def seen(session: dict) -> None:
    PHONE.update(known=True, build=session.get("app_build"))


def turn_note(user_message=None, platform="", **_):
    """pre_llm_call: on the Yui channel, tell the agent what the phone can't draw."""
    if platform != "yui" or not PHONE["known"]:
        return None
    n = note(PHONE["build"])
    return {"context": n} if n else None


def too_new(build: Optional[int]) -> set:
    """Presets `build` cannot draw (all gated ones when the build is unknown)."""
    return {p for p, n in MIN_BUILD.items() if build is None or build < n}


def note(build: Optional[int]) -> str:
    """A line for the agent's turn, or "" when the phone draws everything."""
    heads = sorted({MEMBER_OF.get(p, p) for p in too_new(build) - QUIET})
    if not heads:
        return ""
    which = f"build {build}" if build else "an older build"
    return (f"[yui] This person's Yui app ({which}) cannot draw {', '.join(heads)} yet: "
            "don't send those. Say it in words or use another preset.")


def _unquote(t: str) -> str:
    if len(t) >= 2 and t[0] == t[-1] == '"':
        return t[1:-1].replace('\\"', '"')
    return t


def _split(line: str) -> tuple:
    """(screen prefix, preset, positional words, props, flags) of one line."""
    m = SCREEN.match(line)
    prefix = m.group(1) if m else ""
    toks = TOKEN.findall(line[len(prefix):])
    head = toks[0] if toks else ""
    preset = re.match(r"~?([a-z]*)", head).group(1)
    words, props, flags = [], {}, set()
    for t in toks[1:]:
        if t.startswith("+"):
            flags.add(t[1:])
        elif re.match(r"[\w-]+=", t):
            k, _, v = t.partition("=")
            props[k] = v
        else:
            words.append(_unquote(t))
    return prefix, head, preset, words, props, flags


def _row_md(words, props, flags) -> str:
    label = " ".join(words).strip() or "…"
    if "x" in flags:
        label = f"~~{label}~~"
    elif "hi" in flags or "button" in flags:
        label = f"**{label}**"
    n = _unquote(props.get("note", ""))
    return f"- {label}" + (f" ({n})" if n else "")


def _row_point(words, props, flags) -> str:
    label = " ".join(words).strip() or "…"
    if "x" in flags:
        label = f"Out: {label}"
    elif "hi" in flags:
        label = f"New: {label}"
    n = _unquote(props.get("note", ""))
    return label + (f" ({n})" if n else "")


def _group_text(lines: List[str]) -> str:
    """Plain markdown for one gated group (or a lone gated line)."""
    out: List[str] = []
    for i, line in enumerate(lines):
        _, _, preset, words, props, flags = _split(line)
        title = " ".join(words).strip()
        if preset == "sketch":
            if title:
                out.append(f"**{title}**")
            if any(_split(l)[2] == "after" for l in lines[i + 1:]):
                out.append("Before:")
        elif preset == "after":
            out.append("After:")
        elif preset == "row":
            out.append(_row_md(words, props, flags))
        elif preset == "timeline":
            if title:
                out.append(f"**{title}**")
        elif preset in ("done", "now", "next"):
            at = _unquote(props.get("at", ""))
            out.append(f"- {preset.capitalize()}: {title}" + (f" ({at})" if at else ""))
        elif preset == "game":
            out.append("There's a game here. Update Yui to play it.")
    return "\n".join(out).strip()


def _group_page(lines: List[str]) -> str:
    """A sketch inside a deck or plan, as a page with the rows as points."""
    _, _, preset, words, _, _ = _split(lines[0])
    title = " ".join(words).strip() if preset == "sketch" else ""
    points, phase = [], ""
    for line in lines:
        _, _, p, w, pr, fl = _split(line)
        if p == "sketch" and any(_split(l)[2] == "after" for l in lines):
            phase = "Before: "
        elif p == "after":
            phase = "After: "
        elif p == "row":
            points.append(phase + _row_point(w, pr, fl) if phase and not fl & {"x", "hi"} else _row_point(w, pr, fl))
    if not points:
        return ""
    quoted = "|".join('"' + p.replace('"', "'") + '"' for p in points)
    return f'page "{(title or "The picture").replace(chr(34), chr(39))}" points={quoted}'


def _fence(block: str, gated: set) -> List[tuple]:
    """Split one fence body into ("yui", lines) and ("text", str) parts."""
    lines = block.split("\n")
    parts: List[tuple] = []
    cur: List[str] = []
    story = False  # inside a deck/plan group
    i = 0
    while i < len(lines):
        line = lines[i]
        _, head, preset, _, _, _ = _split(line)
        if preset in STORY and not head.startswith("~"):
            story = True
        elif preset == "end":
            story = False
        if preset not in gated:
            cur.append(line)
            i += 1
            continue
        if head.startswith("~"):  # a patch on something the phone never drew
            i += 1
            continue
        group = [line]
        members = GROUPS.get(preset, set())
        i += 1
        while members and i < len(lines) and _split(lines[i])[2] in members:
            group.append(lines[i])
            i += 1
        if story and preset in ("sketch", "row", "after"):
            page = _group_page(group)
            if page:
                cur.append(SCREEN.match(line).group(1) + page if SCREEN.match(line) else page)
            continue
        text = _group_text(group)
        if cur and any(l.strip() for l in cur):
            parts.append(("yui", cur))
        cur = []
        if text:
            parts.append(("text", text))
    if any(l.strip() for l in cur):
        parts.append(("yui", cur))
    return parts


def downgrade(body: str, build: Optional[int]) -> str:
    """`body` with every preset `build` cannot draw turned into what it can."""
    gated = too_new(build)
    if not gated or "```yui" not in body:
        return body

    def one(m: re.Match) -> str:
        parts = _fence(m.group(1).rstrip("\n"), gated)
        out = []
        for kind, v in parts:
            out.append("```yui\n" + "\n".join(v).strip("\n") + "\n```" if kind == "yui" else v)
        return "\n\n".join(out)

    out = FENCE.sub(one, body)
    return re.sub(r"\n{3,}", "\n\n", out).strip()

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

  * a `flow` (YUI-155, feedback AMLn-Gg3): the plan it walks by default, the
    same questions and one submit.

  * a `draw` (the agent's own SVG, docs/STAGE-REDESIGN.md): its words only, the
    title and the caption; the markup up to its `end` is dropped.

  * marks (YUI-276): a `shapes` group with a `venn`, `contour`, `region`,
    `doodle`, `tap` or `swipe` shape, or with `img=`, and any `shapes` inside a
    `plan`: its words, the title, the labels in order and the caption (a page of
    them in a deck or plan). `bend=` needs nothing: an older build draws the
    line straight. Gesture marks over a `mock` (its `shape` lines) become a line
    each, "Tap Hold to talk: hold", after the mock or among its points. A saved flow is looked up in the starter
    flows (starter_flows.json, from yuigui by sync_flows.py).

An unknown build (no phone has said yet) counts as older than all of them.
`note` is the line added to the agent's turn so it skips them to begin with.
A reply that promises questions but is left with nothing to tap gets one
(`somewhere_to_go`): a full-screen answer never dead-ends.
"""
import json
import re
from pathlib import Path
from typing import Dict, List, Optional

try:
    from . import yuilines
except ImportError:  # loaded by path in tests
    import yuilines

SHAPES_BUILD = 131  # the YUI-104 app commit (git rev-list --count)
# YUI-113: a deck page's picture can be shapes, math, chart, stat or calc. Older
# parsers end the deck at the first of those, so `lift` moves them out of it.
DECK_PICTURES_BUILD = 158
MUSIC_BUILD = 175  # YUI-116 step 2: loop and drums drawn and played (56b38a3)
KEYS_BUILD = 177  # YUI-116 step 3: keys and chords drawn and played (2b26871)
TUNER_BUILD = 205  # YUI-116 step 4: tuner and metronome drawn and played (7b18b14)
MAP_BUILD = 219  # YUI-158 step 2: maps drawn and pinched (the app commit's count)
# DRAW-2: no build draws `diagram` (Mermaid) or `mock` (a UI from parts) yet. Set this to
# the DRAW-2 app commit's count (git rev-list --count) when it lands. Until then it is a
# sentinel, so every phone gets the words and agents are told to skip them.
DRAW_BUILD = 1_000_000
# YUI-115: the app runs flows from this build (the runtime commit's count); older builds get a plan.
FLOW_BUILD = 414
# The stage redesign: `draw`, the agent's own SVG up to `end` (docs/STAGE-REDESIGN.md), and
# YUI-276's marks (venn, contour, region and doodle shapes, `shapes img=`, a plan that takes
# `shapes`). Builds are numbered by commit count (git rev-list --count, scripts/testflight.sh).
# `draw` reached main at 450 (ac0f3a9, the merge of pull request 6); no build between it and
# 466 was ever made from main, so 466 gates it. The marks reached main with the merge of pull
# request 7 (92fffc7), whose count is 492: main had moved on to 461 by then, so a build numbered
# 466 to 491 can exist without them. Older builds get the words.
FREE_DRAW_BUILD = 466
MARKS_BUILD = 492
# YUI-89: agent tables on the phone (`table create|drop`, `put`, `query`; spec/TABLES.md). The app
# store, views and delete reached main at 428 (7b182c7); 450 is the first VALID build from it.
TABLES_BUILD = 450
# MOTION-1: the app plays `motion` films (a streamed block of scenes, yuigui spec/MOTION.md 0.5). The
# MotionView and parser are not on a VALID build yet, so this is a sentinel: every phone gets the sketch
# below and agents are told to skip it. Set it to the app commit's count (git rev-list --count) once the
# build that plays films goes VALID.
MOTION_BUILD = 1_000_000
MARK_KINDS = {"venn", "contour", "region", "doodle", "tap", "swipe"}

# First app build whose parser knows each preset (git rev-list --count of the
# commit that added it to Packages/YuiLines/Sources/YuiLines/Presets.swift).
MIN_BUILD: Dict[str, int] = {
    "timeline": 69, "done": 69, "now": 69, "next": 69,  # b14ea17
    "game": 71,                                          # 36ecded
    "sketch": 104, "row": 104, "after": 104,             # d7214ee (YUI-84)
    "menu": 115,                                         # YUI-86: the drawer's lists; dropped before
    "shapes": SHAPES_BUILD, "shape": SHAPES_BUILD,       # YUI-104: shapes that move
    "loop": MUSIC_BUILD, "drums": MUSIC_BUILD,           # YUI-116 step 2: a beat and pads
    "keys": KEYS_BUILD, "chords": KEYS_BUILD,            # YUI-116 step 3: a keyboard and chord buttons
    "tuner": TUNER_BUILD, "metronome": TUNER_BUILD,      # YUI-116 step 4: a tuner and a click
    "map": MAP_BUILD, "area": MAP_BUILD, "pin": MAP_BUILD, "route": MAP_BUILD,  # YUI-158: places on a map
    "diagram": DRAW_BUILD, "mock": DRAW_BUILD, "part": DRAW_BUILD,  # DRAW-2: a Mermaid diagram, a UI mock
    "flow": FLOW_BUILD,                                  # YUI-115: older builds get a plan
    "motion": MOTION_BUILD,                              # MOTION-1: a film of the agent's own drawing; older builds get a sketch
    "draw": FREE_DRAW_BUILD,                             # the agent's own SVG: older builds get its words
    "tablecmd": TABLES_BUILD, "put": TABLES_BUILD, "query": TABLES_BUILD,  # YUI-89: agent tables
}
GROUPS = {"sketch": {"row", "after"}, "timeline": {"done", "now", "next"}, "shapes": {"shape"},
          "map": {"area", "pin", "route"}, "mock": {"part", "shape"}}
# A `shape` is a member of a mock too (its gesture marks, YUI-276), but on its own it
# belongs to `shapes`: the first group that names a member wins.
MEMBER_OF: Dict[str, str] = {}
for _head, _ms in GROUPS.items():
    for _m in _ms:
        MEMBER_OF.setdefault(_m, _head)
STORY = {"deck", "plan"}  # a sketch in these is the picture of a page
QUIET = {"menu"}  # draws nothing in the chat: dropped on old builds, never named in the note
MADE_OVER = {"flow"}  # the plugin turns it into a preset the phone runs: agents keep sending it

FENCE = re.compile(r"```yui[^\n]*\n(.*?)```", re.DOTALL)
TOKEN = re.compile(r'[+\w-]+="(?:[^"\\]|\\.)*"(?:\|"(?:[^"\\]|\\.)*")*|"(?:[^"\\]|\\.)*"|\S+')
SCREEN = re.compile(r"^(>\S+\s+)")


# The oldest build among the person's phones, from the adapter's last session.
# `known` stays False until a session arrives: no note before then.
# `users`: the same for each client holding a live grant (YUI-97), by user id.
PHONE = {"known": False, "build": None, "users": {}}


def seen(session: dict) -> None:
    PHONE.update(known=True, build=session.get("app_build"), users=dict(session.get("app_builds") or {}))


def build_for(user_id: Optional[str], owner: Optional[str]) -> Optional[int]:
    """The oldest build on this person's phones: the owner's, or a client's own
    (unknown = older than every gated preset)."""
    if not user_id or user_id == owner:
        return PHONE["build"]
    return PHONE["users"].get(user_id)


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
    heads = sorted({"table create" if MEMBER_OF.get(p, p) == "tablecmd" else MEMBER_OF.get(p, p)
                    for p in too_new(build) - QUIET - MADE_OVER})
    marks = build is None or build < MARKS_BUILD
    if not heads and not marks:
        return ""
    what = ", ".join(heads)
    if marks:
        what = (what + "; " if what else "") + "venn, contour, region, doodle, tap or swipe shapes, shapes img=, or shapes over a mock"
    which = f"build {build}" if build else "an older build"
    return (f"[yui] This person's Yui app ({which}) cannot draw {what} yet: "
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
    if preset == "table" and words[:1] in (["create"], ["drop"]):  # `table` is also the grid component
        preset = "tablecmd"
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
        elif preset == "loop":
            name = " ".join(w for w in words if not re.fullmatch(r"\d+(bpm)?", w, re.I)).strip()
            out.append(f"There's a beat here{': ' + name if name else ''}. Update Yui to play it.")
        elif preset == "drums":
            out.append("There are drum pads here. Update Yui to play them.")
        elif preset == "keys":
            out.append(f"There's a keyboard here{' in ' + title if title else ''}. Update Yui to play it.")
        elif preset == "chords":
            out.append(f"There are chord buttons here{': ' + title.replace('|', ' ') if title else ''}. Update Yui to play them.")
        elif preset == "tuner":
            inst = next((w.lower() for w in words[:1] if w.lower() in ("guitar", "ukulele", "bass")), "")
            out.append(f"There's a tuner here{' for ' + inst if inst else ''}. Update Yui to use it.")
        elif preset == "metronome":
            bpm = next((w for w in words if re.fullmatch(r"\d+", w)), _unquote(props.get("bpm", "")))
            out.append(f"There's a metronome here{' at ' + bpm + ' bpm' if bpm else ''}. Update Yui to use it.")
        elif preset == "shapes":
            if title:
                out.append(f"**{title}**")
            chain = _shapes_chain(lines[i + 1:])
            if chain:
                out.append(chain)
            cap = _unquote(props.get("caption", ""))
            if cap:
                out.append(cap)
        elif preset == "map":
            if title:
                out.append(f"**{title}**")
            places = _map_places(lines[i + 1:])
            if places:
                out.append("; ".join(places))
            cap = _unquote(props.get("caption", ""))
            if cap:
                out.append(cap)
        elif preset == "diagram":
            title_, points, cap, source = _diagram_words(lines[i:])[1:]
            if title_:
                out.append(f"**{title_}**")
            out.extend(f"- {p}" for p in points)
            if source:
                out.append("```mermaid\n" + source + "\n```")
            if cap:
                out.append(cap)
        elif preset == "mock":
            if title:
                out.append(f"**{title}**")
            out.extend(f"- {p}" for p in _mock_parts(lines[i + 1:]) + _mark_lines(lines[i + 1:]))
        elif preset == "part" and i == 0:
            out.extend(f"- {p}" for p in _mock_parts(lines))
        elif preset in ("area", "pin", "route") and i == 0:
            places = _map_places(lines)
            if places:
                out.append("; ".join(places))
        elif preset == "shape" and i == 0:
            chain = _shapes_chain(lines)
            if chain:
                out.append(chain)
    return "\n".join(out).strip()


CONNECT = {"line", "arrow"}


def _shapes_chain(lines: List[str]) -> str:
    """A diagram's labels in line order, an arrow between two shapes an arrow joins
    (You → Board → Lane), a comma between the rest."""
    out = ""
    joined = False
    for line in lines:
        _, _, preset, words, props, _ = _split(line)
        if preset != "shape" or not words:
            continue
        kind = words[0].lower()
        label = " ".join(words[1:]).strip() or _unquote(props.get("label", ""))
        if kind == "venn":
            # As describe() in yuigui's shapes.mjs: "Chat and Drawing overlap: Yui".
            sets = [x for x in _unquote(props.get("sets", "")).split("|") if x][:3]
            if sets:
                both = f"{', '.join(sets[:-1])} and {sets[-1]} overlap" if len(sets) > 1 else sets[0]
                label = both + (f": {label}" if label else "")
        if kind in CONNECT:
            if not props.get("from") and not props.get("to"):
                joined = True
            continue
        if kind == "path" or not label:
            continue
        out += (" → " if joined else ", ") + label if out else label
        joined = False
    return out


LATLON = re.compile(r"-?\d+(\.\d+)?,-?\d+(\.\d+)?")


def _map_places(lines: List[str]) -> List[str]:
    """A map's place names in line order (spec: the Telegram fallback): an area's
    label with its country codes, a pin's label, a route's label with the pins
    it stops at. Bare lat,lon places are left out."""
    pins, out = {}, []
    for line in lines:
        head, preset, words = _split(line)[1:4]
        if preset == "pin" and "@" in head:
            pins[head.split("@", 1)[1]] = " ".join(w for w in words if not LATLON.fullmatch(w))
    for line in lines:
        preset, words, props = _split(line)[2:5]
        if preset == "area":
            codes = [c for w in words for c in w.split("|") if re.fullmatch(r"[A-Z]{2,3}", c)]
            codes += [c for c in _unquote(props.get("codes", "")).split("|") if c]
            label = " ".join(w for w in words if "|" not in w and not re.fullmatch(r"[A-Z]{2,3}", w)
                             and not LATLON.fullmatch(w)).strip()
            if label and codes:
                out.append(f"{label} ({', '.join(codes)})")
            elif label or codes:
                out.append(label or ", ".join(codes))
        elif preset == "pin":
            label = " ".join(w for w in words if not LATLON.fullmatch(w)).strip() or _unquote(props.get("label", ""))
            if label:
                out.append(label)
        elif preset == "route":
            stops = next((w.split("|") for w in words if "|" in w), _unquote(props.get("pts", "")).split("|"))
            label = " ".join(w for w in words if "|" not in w).strip() or _unquote(props.get("label", ""))
            via = [pins[x] for x in stops if pins.get(x)]
            text = label + (f", {' to '.join(via)}" if len(via) >= 2 else "")
            if text:
                out.append(text)
    return out


def _map_page(lines: List[str]) -> str:
    """A map inside a deck or plan, as a page with its places as points."""
    _, _, preset, words, props, _ = _split(lines[0])
    title = " ".join(words).strip() if preset == "map" else ""
    points = _map_places(lines if preset != "map" else lines[1:])
    cap = _unquote(props.get("caption", "")) if preset == "map" else ""
    if not points and not cap:
        return ""
    page = f'page "{(title or "The map").replace(chr(34), chr(39))}"'
    if cap:
        page += ' body="' + cap.replace('"', "'") + '"'
    if points:
        page += " points=" + "|".join('"' + p.replace('"', "'") + '"' for p in points)
    return page


def _words_page(title: str, cap: str, points: List[str], default: str) -> str:
    """A picture's words as a page of a deck or plan: its title, the caption as the
    body, the lines as points."""
    if not points and not cap:
        return ""
    page = f'page "{(title or default).replace(chr(34), chr(39))}"'
    if cap:
        page += ' body="' + cap.replace('"', "'") + '"'
    if points:
        page += " points=" + "|".join('"' + p.replace('"', "'") + '"' for p in points)
    return page


def _diagram_words(lines: List[str]) -> tuple:
    """(lines it takes, title, points, caption, source) for the diagram whose head is
    lines[0]. The Mermaid after it is read by the hub parser, which also knows where
    the diagram's own `end` is. Flowchart and state: one `A -> B: label` per edge
    (a node with no edge on its own); sequence: `Alice -> Bob: text`, notes and
    blocks as lines. Anything else (pie, gantt...) comes back as its `source`."""
    p = yuilines.Parser()
    head = p.line(lines[0])
    if not head or head.get("op") != "add":
        return 1, "", [], "", ""
    title, cap = head["props"].get("title", ""), head["props"].get("caption", "")
    used, graph = len(lines), None
    for k in range(1, len(lines)):
        op = p.line(lines[k])
        if op and op.get("op") == "patch" and op.get("target") == head["id"]:
            used, graph = k + 1, op["props"]
            break
        if op:  # not Mermaid: the diagram stayed empty, this line is YL
            used = k
            break
    else:
        op = p.finish()
        graph = op["props"] if op and op.get("op") == "patch" else None
    if not graph:
        return used, title, [], cap, ""
    if graph.get("type") == "other":
        return used, title, [], cap, graph.get("source", "")
    return used, title, _graph_lines(graph), cap, ""


def _draw_extent(lines: List[str], i: int) -> int:
    """Index just past the draw whose head is lines[i], read the way every Yui Lines
    parser reads it: blank lines after the head are skipped, a first line that does
    not open a tag (`<`) leaves the draw empty (that line is YL), and otherwise the
    markup runs to a line that is only `end`, or to the end of the fence."""
    started = False
    for k in range(i + 1, len(lines)):
        t = lines[k].strip()
        if t == "end":
            return k + 1
        if not started:
            if not t:
                continue
            if not t.startswith("<"):
                return i + 1
            started = True
    return len(lines)


def _draw_words(lines: List[str]) -> tuple:
    """(lines it takes, title, caption) for the draw whose head is lines[0]."""
    _, _, _, words, props, _ = _split(lines[0])
    return _draw_extent(lines, 0), " ".join(words).strip(), _unquote(props.get("caption", ""))


def _graph_lines(g: dict) -> List[str]:
    if g.get("type") == "sequence":
        names = {a["id"]: a.get("label") or a["id"] for a in g.get("actors", [])}
        out = []
        for s in g.get("steps", []):
            t = s.get("type")
            if t == "msg":
                arrow = "<->" if s.get("both") else "->"
                out.append(f"{names.get(s['from'], s['from'])} {arrow} {names.get(s['to'], s['to'])}: {s.get('text', '')}".rstrip(": "))
            elif t == "note":
                out.append(f"Note ({', '.join(names.get(x, x) for x in s.get('on', []))}): {s.get('text', '')}")
            elif t == "open":
                out.append(f"{s.get('block', '').capitalize()}: {s.get('text', '')}".rstrip(": "))
        return out
    names = {}
    for n in g.get("nodes", []):
        names[n["id"]] = n.get("label") or {"start": "Start", "end": "End"}.get(n.get("shape"), n["id"])
    out, seen = [], set()
    for e in g.get("edges", []):
        seen.update((e["from"], e["to"]))
        arrow = "<->" if e.get("both") else "--" if e.get("plain") else "->"
        out.append(f"{names.get(e['from'], e['from'])} {arrow} {names.get(e['to'], e['to'])}"
                   + (f": {e['label']}" if e.get("label") else ""))
    return [names[i] for i in names if i not in seen] + out


def _mock_parts(lines: List[str]) -> List[str]:
    """A mock's parts in screen order (nav first, tabs last, then sheet, alert and
    keyboard), one line each: `Nav: Agents`, `Row: Basil, Groceries and meals`,
    `Button: New agent`. A highlighted part ends `(new)`, a struck one `(out)`,
    a note `(note: ...)`; a dimmed one is plain."""
    parts = [op["props"] for op in yuilines.parse("\n".join(lines))
             if op.get("op") == "add" and op.get("preset") == "part"]
    rank = lambda k: 0 if k == "nav" else 2 if k == "tabs" else 3 if k in ("sheet", "alert", "keyboard") else 1
    first = {}
    for k in ("nav", "tabs"):
        first[k] = next((p for p in parts if p.get("kind") == k), None)
    parts = [p for p in parts if p.get("kind") not in first or p is first[p.get("kind")]]
    out = []
    for p in sorted(parts, key=lambda p: rank(p.get("kind", "text"))):  # stable: line order within a rank
        kind = p.get("kind", "text")
        if kind in ("divider", "space"):
            continue
        items = p.get("items") or []
        bits = [p.get("text", ""), p.get("sub", ""), p.get("value", "") or p.get("ph", ""), p.get("body", ""),
                p.get("action", ""), ", ".join(items) if kind in ("tabs", "segmented", "grid", "sheet", "alert") else ""]
        line = ", ".join(str(b) for b in bits if b)
        if kind in ("tabs", "segmented") and p.get("tab") not in (None, ""):
            tab = str(p["tab"])
            tab = items[int(tab) - 1] if tab.isdigit() and 0 < int(tab) <= len(items) else tab
            line += f" ({tab} selected)"
        if kind == "toggle" and p.get("on"):
            line += " (on)"
        mark = " (new)" if p.get("hi") else " (out)" if p.get("x") else ""
        note = f" (note: {p['note']})" if p.get("note") else ""
        out.append(f"{kind.capitalize()}{': ' + line if line else ''}{mark}{note}")
    return out


def _mark_lines(lines: List[str]) -> List[str]:
    """A mock's gesture marks (its `shape` lines, YUI-276) in words, one each:
    `Tap Hold to talk: hold`, `Swipe left from Hold to talk: slide to cancel`,
    `Arrow to Hold to talk: drop here to lock`, `Circled Total`. A place that is a
    part's id reads as that part's words; a bare x,y names no part."""
    names = {}
    for line in lines:
        head, preset, words = _split(line)[1:4]
        if preset == "part" and "@" in head:
            names[head.split("@", 1)[1]] = " ".join(words[1:]).strip() or (words[0] if words else "")
    out = []
    for line in lines:
        _, _, preset, words, props, _ = _split(line)
        if preset != "shape" or not words:
            continue
        kind = words[0].lower()
        label = " ".join(words[1:]).strip() or _unquote(props.get("label", ""))
        place = lambda k: names.get(_unquote(props.get(k, "")), "")
        on = place("at") or place("from")
        if kind == "tap":
            text = "Tap" + (f" {on}" if on else "")
        elif kind == "swipe":
            way = _unquote(props.get("dir", ""))
            text = "Swipe" + (f" {way}" if way else "") + (f" from {on}" if on else "") + (f" to {place('to')}" if place("to") else "")
        elif kind in ("arrow", "line"):
            text = "Arrow" + (f" to {place('to')}" if place("to") else "") + (f" from {place('from')}" if place("from") and not place("to") else "")
        elif kind == "doodle":
            text = "Circled" + (f" {on}" if on else "")
        else:
            text = ""
        line_ = text + (f": {label}" if text and label else label)
        if line_ and line_ not in ("Arrow", "Circled"):
            out.append(line_)
    return out


def _mock_page(lines: List[str]) -> str:
    """A mock inside a deck or plan, as a page with its parts as points."""
    _, _, preset, words, _, _ = _split(lines[0])
    title = " ".join(words).strip() if preset == "mock" else ""
    body = lines[1:] if preset == "mock" else lines
    return _words_page(title, "", _mock_parts(body) + _mark_lines(body), "The screen")


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


# ---------- flows as plans (YUI-155) ----------
# Something to tap when a reply promised questions and nothing else is left.
FALLBACK = 'ask@go "Want me to ask you here, one at a time?" "Yes, ask me"|"Not now"'
MERMAID = re.compile(r"\s*(flowchart|graph)(\s|$)")
STEP_NOTE = re.compile(r"^\s*%%\s*(\w+)\s*:\s*(.*)$")
VARIANT_ADD = re.compile(r"^\s*add\s+(\w+)\s+after\s+\w+\s*:\s*(.*)$")
_SAVED: Optional[dict] = None


def _saved_flows() -> dict:
    global _SAVED
    if _SAVED is None:
        _SAVED = json.loads((Path(__file__).resolve().parent / "starter_flows.json").read_text())
    return _SAVED


def _slug(s: str) -> str:
    return re.sub(r"[^a-z0-9]+", "", str(s or "").lower())


def _is_step(text: str) -> bool:
    return (text.split() or [""])[0] in yuilines.FLOW_STEPS


def _raw_steps(source: str, into: Optional[dict] = None) -> dict:
    """Each step's line as written, by node id: `%% id: <line>`, or `add id after x: <line>`
    in a variant (the last one wins, as in the parser)."""
    raw = dict(into or {})
    for line in source.split("\n"):
        m = STEP_NOTE.match(line) or VARIANT_ADD.match(line)
        if m and _is_step(m.group(2).strip()):
            raw[m.group(1)] = m.group(2).strip()
    return raw


def _graph(ops: list) -> Optional[dict]:
    patch = next((o for o in ops if o["op"] == "patch"), None)
    return patch["props"] if patch else None


def _saved_flow(name: str, depth: int = 0) -> Optional[dict]:
    """A saved flow by name (a starter, or a variant followed back to its base):
    {g, raw, title, submit, id}, or None."""
    saved = _saved_flows()
    s = _slug(name)
    f = next((f for f in saved["flows"] if _slug(f["name"]) == s or _slug(f["title"]) == s), None)
    if f:
        g = _graph(yuilines.parse(f'flow@{f["id"]}\n{f["source"]}\nend'))
        return {"g": yuilines.resolve("flow", g), "raw": _raw_steps(f["source"]),
                "title": f["title"], "submit": f["submit"], "id": f["id"]}
    v = next((v for v in saved["variants"] if _slug(v["name"]) == s), None)
    if not v or depth >= 5:
        return None
    return _variant(v["base"], v["name"], v["lines"], depth, v["id"])


def _variant(base: str, as_: str, lines: str, depth: int = 0, fid: str = "") -> Optional[dict]:
    b = _saved_flow(base, depth + 1)
    if not b:
        return None
    changes = (_graph(yuilines.parse(f"flow {base} as={as_}\n{lines}\nend")) or {}).get("changes") or []
    return {"g": yuilines.flow_variant(b["g"], changes), "raw": _raw_steps(lines, b["raw"]),
            "title": yuilines.variant_name(as_)["title"], "submit": b["submit"], "id": fid or b["id"]}


def _label_step(g: dict, sid: str) -> str:
    """A step written as the node's label (`energy[choose Energy? Low|OK|High]`)."""
    m = re.search(r"\b" + re.escape(sid) + r"\s*[\[({]+(.+?)[\])}]+", g.get("source") or "")
    t = m.group(1).replace("#quot;", '"').strip() if m else ""
    return t if _is_step(t) else ""


def _flow_extent(lines: List[str], i: int) -> int:
    """Index just past the flow whose head is lines[i]: an inline chart runs to its
    own `end` (subgraphs have theirs), a variant to `end`, a saved flow is one line."""
    j = i + 1
    while j < len(lines) and lines[j].strip().startswith("%%"):
        j += 1
    inline = j < len(lines) and MERMAID.match(lines[j])
    if not inline and not re.search(r"(^|\s)as=", lines[i]):
        return i + 1
    depth = 0
    for k in range(i + 1, len(lines)):
        t = lines[k].strip()
        if inline and re.match(r"subgraph(\s|$)", t):
            depth += 1
        elif t == "end":
            if depth == 0:
                return k + 1
            depth -= 1
    return len(lines)


def flow_plan(group: List[str]) -> List[str]:
    """A flow (head, and its chart or variant lines) as the plan it walks by
    default: every step on the path no answer has changed yet, keyed by node id,
    one submit. [] when there is nothing to run (no saved flow by that name)."""
    prefix = SCREEN.match(group[0]).group(1) if SCREEN.match(group[0]) else ""
    body = [group[0][len(prefix):]] + group[1:]
    ops = yuilines.parse("\n".join(body))
    head = next((o for o in ops if o["op"] == "add" and o.get("preset") == "flow"), None)
    if not head:
        return []
    props = head.get("props") or {}
    g = _graph(ops)
    if g and "nodes" in g:  # inline
        f = {"g": yuilines.resolve("flow", g), "raw": _raw_steps(g.get("source") or ""),
             "title": props.get("title") or "", "submit": "", "id": "flow"}
    elif props.get("as"):
        f = _variant(props.get("title") or "", props["as"], "\n".join(body[1:]))
    else:
        f = _saved_flow(props.get("title") or "")
    if not f:
        return []
    fg = f["g"]
    first = yuilines.flow_first(fg)
    walk = [first] + yuilines.flow_ahead(fg, {}, first) if first else []
    steps = []
    for sid in walk:
        raw = f["raw"].get(sid) or _label_step(fg, sid)
        if not raw:
            continue
        preset, _, rest = raw.partition(" ")
        steps.append(raw if preset == "page" else f"{preset.split('@')[0]}@{sid} {rest}".rstrip())
    if not steps:
        return []
    explicit = re.match(r"flow@(\S+)", body[0].strip())
    fid = explicit.group(1) if explicit else f["id"]
    title = f["title"]  # a saved flow's `title` prop is its name, so the saved title wins
    plan = f"plan@{fid}" + (' "' + title.replace('"', "'") + '"' if title else "")
    submit = props.get("submit") or f["submit"]
    if submit:
        plan += ' submit="' + submit.replace('"', "'") + '"'
    if props.get("review") is False:
        plan += " review=off"
    if props.get("inline"):
        plan += " +inline"
    return [prefix + plan] + steps + ["end"]


ACTS = {"ask", "choose", "pick", "slide", "form", "camera", "mic", "plan", "flow", "deck", "narrate",
        "timer", "game", "calc", "query", "loop", "drums", "keys", "chords", "tuner", "metronome"}
PROMISE = re.compile(r"\b((a few|some|two|three|four|five|\d+|couple of|these|my|quick) (quick |short )?questions"
                     r"|questions (first|for you)|interview|quiz you|step by step|walk you through|one at a time)\b", re.I)


def somewhere_to_go(body: str) -> str:
    """A reply whose words promise questions or steps, with a screen that has
    nothing to tap, gets FALLBACK instead of a bare headline (feedback AMLn-Gg3)."""
    blocks = FENCE.findall(body)
    if not blocks or not PROMISE.search(FENCE.sub(" ", body)):
        return body
    for block in blocks:
        for line in block.split("\n"):
            _, head, preset, _, props, _ = _split(line)
            if preset in ACTS or props.keys() & {"cta", "url", "open"}:
                return body
    return body.rstrip() + "\n\n```yui\n" + FALLBACK + "\n```"


def _needs_marks(group: List[str], in_plan: bool) -> bool:
    """Whether a shapes group (or a lone shape) needs a YUI-276 build: a mark kind,
    a picture under it, or a place in a plan."""
    _, _, preset, _, props, _ = _split(group[0])
    if preset == "shapes" and ("img" in props or in_plan):
        return True
    return any(_split(l)[2] == "shape" and (_split(l)[3][:1] or [""])[0].lower() in MARK_KINDS for l in group)


def _marks_words(group: List[str]) -> tuple:
    """(title, the labels in order, caption) of a shapes group or a lone shape."""
    _, _, preset, words, props, _ = _split(group[0])
    if preset != "shapes":
        return "", _shapes_chain(group), ""
    return " ".join(words).strip(), _shapes_chain(group[1:]), _unquote(props.get("caption", ""))


SAY = re.compile(r"""api\.say\(\s*(?:"((?:[^"\\]|\\.)*)"|'((?:[^'\\]|\\.)*)'|`([^`]*)`)""")
SENTENCE = re.compile(r"(?<=[.!?])\s+|(?<=[;:])\s+")
ROW_WORDS = 12
MOTION_ROWS = 6


def _motion_extent(lines: List[str], i: int) -> int:
    """Lines used by the motion block at `i`: its head, and when scenes follow, up to the `end` line."""
    j = i + 1
    nxt = next((x for x in lines[j:] if x.strip()), "")
    if not nxt.startswith("==="):
        return j
    while j < len(lines) and lines[j].strip() != "end":
        j += 1
    return min(j + 1, len(lines))


def _motion_words(lines: List[str]) -> tuple:
    """(title, points) for a film an older phone cannot play: the `say` cues of its scenes in order, or, when
    the line is still the agent's own ask, the ask cut into sentences."""
    _, _, _, words, props, _ = _split(lines[0])
    ask = " ".join(words).strip()
    sentences = [x.strip() for x in SENTENCE.split(ask) if x.strip()]
    title_ = (sentences[0] if sentences else "").rstrip(".")
    title_ = (title_[:55] + "...") if len(title_) > 58 else title_
    points: List[str] = []
    for m in SAY.finditer("\n".join(lines[1:])):
        t = next(g for g in m.groups() if g is not None)
        t = t.replace("\\'", "'").replace('\\"', '"').strip()
        if t:
            points.append(t)
    points = [" ".join(p.split()[:ROW_WORDS]).rstrip(",;:") + ("..." if len(p.split()) > ROW_WORDS else "") for p in (points or sentences[1:])]
    return title_, points[:MOTION_ROWS]


def _motion_sketch(lines: List[str]) -> List[str]:
    title_, points = _motion_words(lines)
    out = [f"sketch {json.dumps(title_ or 'Picture', ensure_ascii=False)} frame=bubble"]
    out += [f"row {json.dumps(p, ensure_ascii=False)}" for p in points]
    return out if points else [f"say {title_}"] if title_ else []


def _fence(block: str, gated: set, marks: bool = False) -> List[tuple]:
    """Split one fence body into ("yui", lines) and ("text", str) parts. `marks`: the
    phone predates MARKS_BUILD."""
    lines = block.split("\n")
    parts: List[tuple] = []
    cur: List[str] = []
    story = False  # inside a deck/plan group
    in_plan = False  # and that group is a plan
    i = 0
    while i < len(lines):
        line = lines[i]
        _, head, preset, _, _, _ = _split(line)
        if marks and preset == "mock" and "mock" not in gated and not head.startswith("~"):
            j = i + 1
            while j < len(lines) and _split(lines[j])[2] in GROUPS["mock"] and not _split(lines[j])[1].startswith("~"):
                j += 1
            group = lines[i:j]
            shapes_ = [l for l in group[1:] if _split(l)[2] == "shape"]
            if shapes_:
                cur.extend(l for l in group if _split(l)[2] != "shape")
                words_ = _mark_lines(group)
                i = j
                if words_:
                    parts.append(("yui", cur))
                    cur = []
                    parts.append(("text", "\n".join(f"- {w}" for w in words_)))
                continue
        if marks and preset in ("shapes", "shape") and not head.startswith("~"):
            j = i + 1
            if preset == "shapes":
                while j < len(lines) and _split(lines[j])[2] == "shape" and not _split(lines[j])[1].startswith("~"):
                    j += 1
            group = lines[i:j]
            if _needs_marks(group, story and in_plan):
                title_, chain, cap = _marks_words(group)
                i = j
                if story:
                    page = _words_page(title_, cap, [chain] if chain else [], "The picture")
                    if page:
                        cur.append(SCREEN.match(line).group(1) + page if SCREEN.match(line) else page)
                    continue
                text = "\n".join(([f"**{title_}**"] if title_ else []) + ([chain] if chain else []) + ([cap] if cap else []))
                if cur and any(l.strip() for l in cur):
                    parts.append(("yui", cur))
                cur = []
                if text:
                    parts.append(("text", text))
                continue
        if preset == "motion" and "motion" in gated and not head.startswith("~"):
            end = _motion_extent(lines, i)
            group = lines[i:end]
            i = end
            if len(group) == 1 and "film" in _split(group[0])[4]:
                continue  # the closing row of a film that never played: nothing to say
            if story:
                title_, points = _motion_words(group)
                page = _words_page(title_, "", points, "The picture")
                if page:
                    cur.append(SCREEN.match(line).group(1) + page if SCREEN.match(line) else page)
                continue
            sketch = _motion_sketch(group)
            if sketch:
                cur.extend(sketch)
            continue
        if preset == "flow" and "flow" in gated and not head.startswith("~"):
            end = _flow_extent(lines, i)
            cur.extend(flow_plan(lines[i:end]) or [FALLBACK])
            i = end
            continue
        if preset in STORY and not head.startswith("~"):
            story = True
            in_plan = preset == "plan"
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
        if preset == "draw":
            used, title_, cap = _draw_words(lines[i:])
            i += used
            if story:
                page = _words_page(title_, cap, [], "The drawing")
                if page:
                    cur.append(SCREEN.match(line).group(1) + page if SCREEN.match(line) else page)
                continue
            text = "\n".join(([f"**{title_}**"] if title_ else []) + ([cap] if cap else []))
            if cur and any(l.strip() for l in cur):
                parts.append(("yui", cur))
            cur = []
            if text:
                parts.append(("text", text))
            continue
        if preset == "diagram":
            used, title_, points, cap, source = _diagram_words(lines[i:])
            i += used
            if story:
                page = _words_page(title_, cap, points, "The diagram")
                if page:
                    cur.append(SCREEN.match(line).group(1) + page if SCREEN.match(line) else page)
                continue
            text = "\n".join(([f"**{title_}**"] if title_ else []) + [f"- {x}" for x in points]
                             + (["```mermaid\n" + source + "\n```"] if source else []) + ([cap] if cap else []))
            if cur and any(l.strip() for l in cur):
                parts.append(("yui", cur))
            cur = []
            if text:
                parts.append(("text", text))
            continue
        i += 1
        while members and i < len(lines) and _split(lines[i])[2] in members:
            group.append(lines[i])
            i += 1
        if story and preset in ("sketch", "row", "after", "map", "area", "pin", "route", "mock", "part"):
            page = (_map_page(group) if preset in GROUPS["map"] | {"map"}
                    else _mock_page(group) if preset in ("mock", "part") else _group_page(group))
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


PICTURES = {"shapes", "math", "chart", "stat", "calc"}  # a deck page's picture since YUI-113
OLD_DECK = {"page", "ask", "choose", "pick", "sketch", "row", "after"}  # what an older deck holds


def _lift(block: str) -> str:
    """One fence body for a phone older than DECK_PICTURES_BUILD: every picture a
    deck holds comes out of it, in order, the way guide v25 laid a lesson out on
    the stage (feedback APSw0dsa): the diagram, math, chart and stat before the
    deck, the deck as a card among them (`+inline`), the calc after it."""
    lines = block.split("\n")
    out: List[str] = []
    deck = None  # index in `out` of the open deck's head
    before: List[str] = []  # pictures that go in front of the deck
    after: List[str] = []   # calcs that go after it
    lifted = False

    def close(ended=False):
        nonlocal deck, before, after
        if deck is not None and (before or after):
            head = out[deck]
            if not re.search(r"(^|\s)\+inline(\s|$)", head):
                head = head.rstrip() + " +inline"
            out[deck:deck + 1] = before + [head]
            # `end` first, or a newer parser takes the calc back into the deck.
            out.extend(after if ended or not after else ["end"] + after)
        deck, before, after = None, [], []

    i = 0
    while i < len(lines):
        line = lines[i]
        t = line.strip()
        prefix, head, preset, _, _, _ = _split(line)
        if deck is not None and not head.startswith("~") and not prefix:
            if preset in PICTURES:
                group = [line]
                i += 1
                while preset == "shapes" and i < len(lines) and _split(lines[i])[2] == "shape" and not _split(lines[i])[0]:
                    group.append(lines[i])
                    i += 1
                (after if preset == "calc" else before).extend(group)
                lifted = True
                continue
            if not t or t.startswith("#") or preset in OLD_DECK:
                out.append(line)
                i += 1
                continue
            if preset == "end":
                out.append(line)
                i += 1
                close(ended=True)
                continue
        if deck is not None:
            close()
        if preset == "deck" and not head.startswith("~"):
            deck = len(out)
        out.append(line)
        i += 1
    close()
    return "\n".join(out) if lifted else block


def downgrade(body: str, build: Optional[int]) -> str:
    """`body` with every preset `build` cannot draw turned into what it can."""
    if "```yui" not in body:
        return body
    if build is None or build < DECK_PICTURES_BUILD:
        body = FENCE.sub(lambda m: "```yui\n" + _lift(m.group(1).rstrip("\n")) + "\n```", body)
    gated = too_new(build)
    marks = build is None or build < MARKS_BUILD
    if not gated and not marks:
        return body

    def one(m: re.Match) -> str:
        parts = _fence(m.group(1).rstrip("\n"), gated, marks)
        out = []
        for kind, v in parts:
            out.append("```yui\n" + "\n".join(v).strip("\n") + "\n```" if kind == "yui" else v)
        return "\n\n".join(out)

    out = FENCE.sub(one, body)
    return somewhere_to_go(re.sub(r"\n{3,}", "\n\n", out).strip())

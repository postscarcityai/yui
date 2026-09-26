"""Restyle Yui by asking (YUI-96). Spec: yuigui/spec/RESTYLE.md, sections 3, 5, 7, 8.

An owned agent may offer a look for the whole app with one `theme app` line
(`theme app autumn`); the app shows a preview and only the person's tap
applies it. The host keeps that line away from two places:

  * a phone that cannot draw the preview: a build that does not know
    `theme app` would read `theme app accent=...` as the agent's own theme
    and restyle the agent. Below yui_limits `restyle_min_build` (read with the
    session token after each session; unknown counts as too old, like an
    unknown app build) the line is dropped and the agent's next turn gets
    one note saying the app cannot restyle yet;
  * a turn that is not the owner's (a shared agent, YUI-95): dropped
    silently. Shared agents never restyle.

The channel guide's sentence about it sits between RESTYLE_OPEN and
RESTYLE_CLOSE in CHANNEL.md. It is cut out of the fixed guide (the platform
hint every turn gets) and added to the per-turn prompt only on the owner's
turns on a phone at or above restyle_min_build, so the agent is not taught
the line anywhere it would be dropped.

The app's tap on the preview card arrives as `[yui] restyle theme
choice=apply name=autumn scope=app` (keys sorted, like every tap); `tap_text`
reads it back the way the spec writes it: `[yui] restyle theme app
choice=apply name=autumn`.
"""
import re
from typing import Optional, Tuple

RESTYLE_OPEN = "<!-- restyle:"   # the marker line reads `<!-- restyle: owned agents, phones at or above restyle_min_build -->`
RESTYLE_CLOSE = "<!-- /restyle -->"
BLOCK = re.compile(re.escape(RESTYLE_OPEN) + r"[^\n]*-->\n(.*?)" + re.escape(RESTYLE_CLOSE) + r"\n?", re.S)

FENCE = re.compile(r"```yui([^\n]*)\n(.*?)```", re.S)
LINE = re.compile(r"^\s*(?:>\S+\s+)?theme\s+app(?:\s|$)")
TAP = re.compile(r"^\[yui\] restyle theme (.*)$")
TOKEN = re.compile(r'[+\w-]+="(?:[^"\\]|\\.)*"|"(?:[^"\\]|\\.)*"|\S+')

# yui_limits restyle_min_build, from the adapter's last session. None: not read yet.
LIMIT = {"min_build": None}


def split_guide(body: str) -> Tuple[str, str]:
    """(the guide without the restyle block, the block's text as one line for the turn)."""
    m = BLOCK.search(body)
    if not m:
        return body, ""
    text = " ".join(l.strip() for l in m.group(1).strip().splitlines())
    return BLOCK.sub("", body), re.sub(r"^[-*]\s+", "", text)


def allowed(owner: bool, build: Optional[int], min_build: Optional[int] = None) -> bool:
    """True when `theme app` may go out (and be taught): the owner's turn, a phone new enough."""
    min_build = LIMIT["min_build"] if min_build is None else min_build
    return bool(owner) and build is not None and min_build is not None and build >= min_build


def has_line(body: str) -> bool:
    return any(LINE.match(l) for m in FENCE.finditer(body) for l in m.group(2).split("\n"))


def gate(body: str, owner: bool, build: Optional[int], min_build: Optional[int] = None) -> Tuple[str, Optional[str]]:
    """(body, why): `theme app` lines dropped unless allowed. why is None (nothing
    dropped), "shared" (not the owner's turn) or "old" (the phone can't restyle yet)."""
    if "```yui" not in body or not has_line(body) or allowed(owner, build, min_build):
        return body, None

    def one(m: re.Match) -> str:
        kept = [l for l in m.group(2).split("\n") if not LINE.match(l)]
        if not any(l.strip() for l in kept):
            return ""
        return "```yui" + m.group(1) + "\n" + "\n".join(kept).strip("\n") + "\n```"

    out = re.sub(r"\n{3,}", "\n\n", FENCE.sub(one, body)).strip()
    return out, ("old" if owner else "shared")


def note(build: Optional[int]) -> str:
    """One plain line for the agent's next turn after an old phone's line was dropped."""
    which = f"build {build}" if build else "an older build"
    return (f"[yui] note: this person's Yui app ({which}) cannot restyle the whole app yet, so your "
            "`theme app` line was not shown. Don't send it again; if it comes up, an app update brings it.")


def tap_text(body: str) -> str:
    """`[yui] restyle theme choice=apply name=autumn scope=app` as the spec reads it:
    `[yui] restyle theme app choice=apply name=autumn`. Anything else unchanged."""
    first, nl, rest = body.partition("\n")
    m = TAP.match(first.strip())
    if not m:
        return body
    toks = TOKEN.findall(m.group(1))
    if "scope=app" not in toks:
        return body
    toks = [t for t in toks if t != "scope=app"]
    order = {"choice": 0, "name": 1}
    toks.sort(key=lambda t: order.get(t.partition("=")[0], 2))  # stable: the rest keep their order
    return " ".join(["[yui] restyle theme app"] + toks) + nl + rest

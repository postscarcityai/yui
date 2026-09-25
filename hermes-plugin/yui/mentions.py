"""@mentions between the person's agents (YUI-44). Spec: yuigui/spec/RELAY.md "Mentions".

The database does the routing (migration 20260925030000_yui_mentions.sql).
This module is the host's two small jobs:

  1. Out. A reply to a turn the person started may @ another of the person's
     agents: `handles_in(reply)` finds the @handles in its text (not inside
     ```yui fences or code), and the adapter sends them as meta.mentions.
     Yui honours them only for a turn the person started, one hop.

  2. In. When the person @s another agent from this agent's thread, this agent
     is not asked (the row lands handled), and the other agent's answer is
     copied into this thread. `notes(rows)` turns those rows into lines this
     agent reads first on its next turn, so it knows what was said here.

A mention that reaches this agent needs nothing here: it is an ordinary row
of the person's, starting `[yui] mention from=<handle> by=person|agent`,
with the other thread's recent lines quoted.
"""

import re
from typing import Iterable, List

HANDLE = re.compile(r"(?<![\w@.])@([a-z0-9][a-z0-9-]{0,31})\b", re.I)
FENCE = re.compile(r"```.*?(```|\Z)", re.S)
INLINE_CODE = re.compile(r"`[^`\n]*`")
MAX_MENTIONS = 3
NOTE_CHARS = 600


def handles_in(text: str, own: Iterable[str] = ()) -> List[str]:
    """@handles in the reply's words, lowercased, in order, at most three,
    never the agent's own. Fenced screens and code don't count."""
    plain = INLINE_CODE.sub(" ", FENCE.sub(" ", text or ""))
    skip = {h.lower() for h in own if h}
    out: List[str] = []
    for m in HANDLE.finditer(plain):
        h = m.group(1).lower().rstrip("-")
        if h and h not in skip and h not in out:
            out.append(h)
        if len(out) == MAX_MENTIONS:
            break
    return out


def plain(body: str, n: int = NOTE_CHARS) -> str:
    """One line: the app's `[yui] ...` header dropped, screens as [screen]."""
    body = re.sub(r"^\[yui\] (mention|reply) [^\n]*\n?", "", body or "")
    body = FENCE.sub("[screen]", body)
    body = " ".join(body.split())
    return body if len(body) <= n else body[: n - 1] + "…"


def is_context(row: dict) -> bool:
    meta = row.get("meta") or {}
    return "mention" in meta or "mention_reply" in meta


def notes(rows: List[dict]) -> List[str]:
    """Lines for this agent's next turn, oldest first, from its thread's mention rows."""
    out: List[str] = []
    for r in rows:
        meta = r.get("meta") or {}
        if "mention" in meta and r.get("sender") == "user":
            m = meta["mention"] or {}
            name = m.get("name") or m.get("handle") or "another agent"
            out.append(f"[yui] note: in this thread the person asked {name}, not you: {plain(r.get('body', ''))}")
        elif "mention_reply" in meta:
            m = meta["mention_reply"] or {}
            name = m.get("name") or m.get("handle") or "Another agent"
            if m.get("status"):
                continue  # "Coach is asleep": the app talking, not news for this agent
            out.append(f"[yui] note: {name} answered here: {plain(r.get('body', ''))}")
    return out

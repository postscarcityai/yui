"""Group threads on the host (YUI-93). Spec: yuigui/spec/GROUPS.md.

The database does the routing (migration 20260925070000_yui_groups.sql): who
answers, copies, handoffs on the hop budget, the guard, Let it and Stop. A
row that asks this agent is an ordinary row of the person's, starting
`[yui] group "<title>" thread=<id> ... hop=<n> from=<who>`, with the group's
last lines quoted, so it needs nothing here to be answered.

What the host adds is notes. This agent cannot read the other members' rows
(no connector ever can), so on a turn that answers a group row it asks
yui_group_notes() for what else happened in that group since its last turn
there, one line each, and reads them first:

    [yui] note: in Race week the person asked Sage, not you: plan Saturday
    [yui] note: in Race week, Sage answered: Rest Friday. [screen]

@handles in its reply need nothing new either: mentions.handles_in() fills
meta.mentions as for a mention, and the database routes them by the group's
budget instead of as a depth-1 mention.
"""

from typing import Dict, List

MAX_THREADS = 3  # a backlog that spans more groups than this gets notes for the newest


def threads_in(rows: List[dict]) -> List[str]:
    """Group ids this turn answers, newest last, at most MAX_THREADS."""
    out: List[str] = []
    for r in rows:
        tid = r.get("thread_id") or ((r.get("meta") or {}).get("group") or {}).get("thread")
        if tid:
            if tid in out:
                out.remove(tid)
            out.append(tid)
    return out[-MAX_THREADS:]


def notes(rows: List[Dict]) -> List[str]:
    """Lines for this agent's next turn, oldest first, from yui_group_notes() rows."""
    out: List[str] = []
    for r in rows:
        title = r.get("title") or "the group"
        words = " ".join((r.get("words") or "").split())  # already one plain line, 600 at most
        kind = r.get("kind")
        if kind == "asked":
            who = r.get("to_names") or "another agent"
            out.append(f"[yui] note: in {title} the person asked {who}, not you: {words}")
        elif kind == "answered" and words:
            out.append(f"[yui] note: in {title}, {r.get('name') or 'another agent'} answered: {words}")
        elif kind == "stopped":
            out.append(f"[yui] note: in {title} the person pressed Stop. Hand nothing more on for what came before it.")
    return out

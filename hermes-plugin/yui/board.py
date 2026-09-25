"""Board order from the app, no agent turn (YUI-66). Spec: yuigui/spec/YL.md, timeline.

A `timeline ... +reorder board=<assignee>` lets the person drag the queued rows
into a new order. Save sends one event row:

    meta = {"id": "war", "preset": "timeline",
            "value": {"order": ["t_61ac254a", "YUI-66", ...], "board": "yui"}}

The adapter hands it here instead of to the agent. Each key is a row's `key`
(the war room gives the kanban task id), else its `tag` (a card id like
YUI-66), else its text. Only queued cards move (todo, ready, scheduled) that
are this profile's or nobody's yet (a backlog card waits unassigned until it
is briefed); another agent's cards, running, blocked and done cards keep their
place. The new order becomes kanban priority (higher pulls first): the cards
trade the priority slots they already hold, so a reorder of the top of the
queue never sinks a card under ones that were not on screen. One transaction,
a `reprioritized` event per card, and the dispatcher and the lane driver pull
in the order the person set.
"""

import re
from typing import List, Optional

QUEUED = ("todo", "ready", "scheduled")
MAX_KEYS = 50


def order_of(row: dict) -> Optional[tuple]:
    """(board, [keys]) when the row is a timeline's saved board order, else None."""
    if row.get("kind") != "event":
        return None
    meta = row.get("meta") or {}
    v = meta.get("value") or {}
    if meta.get("preset") != "timeline" or not isinstance(v, dict):
        return None
    board, keys = v.get("board"), v.get("order")
    if not isinstance(board, str) or not board or not isinstance(keys, list):
        return None
    keys = [str(k).strip() for k in keys if isinstance(k, (str, int, float)) and str(k).strip()]
    return (board, keys[:MAX_KEYS]) if keys else None


def _match(key: str, tasks: List[dict]) -> List[dict]:
    """Tasks a row key names: a task id, a card id at the start of the title, or the title text."""
    exact = [t for t in tasks if t["id"] == key]
    if exact:
        return exact
    card = re.compile(r"^" + re.escape(key) + r"(?![\w-])", re.I)
    by_card = [t for t in tasks if card.match(t["title"])]
    if by_card or re.fullmatch(r"[A-Za-z]+-\d+", key):
        return by_card  # a card id never falls back to text: YUI-6 is not YUI-66
    low = key.lower()
    return [t for t in tasks if low in t["title"].lower()]


def plan(board: str, keys: List[str], tasks: List[dict]) -> dict:
    """What a saved order does to the board. Pure, so it can be tested without a DB.

    tasks: every card on the board (id, title, status, priority).
    Returns {"moves": [{id, title, from, to}], "order": [ids], "skipped": [{key, why}]}.
    The cards trade the priority slots they hold (highest slot to the first
    key); tied slots are nudged apart from the bottom up so the order is strict.
    """
    mine = [t for t in tasks if t.get("assignee", board) in (board, None)]
    picked, skipped, seen = [], [], set()
    for key in keys:
        hits = _match(key, mine)
        queued = [t for t in hits if t["status"] in QUEUED]
        if not hits:
            skipped.append({"key": key, "why": "not on the board"})
        elif not queued:
            skipped.append({"key": key, "why": hits[0]["status"]})
        elif len(queued) > 1:
            skipped.append({"key": key, "why": "matches %d cards" % len(queued)})
        elif queued[0]["id"] in seen:
            skipped.append({"key": key, "why": "listed twice"})
        else:
            seen.add(queued[0]["id"])
            picked.append(queued[0])
    moves = []
    if picked:
        slots = sorted((int(t.get("priority") or 0) for t in picked), reverse=True)
        for i in range(len(slots) - 2, -1, -1):
            slots[i] = max(slots[i], slots[i + 1] + 1)
        for t, new in zip(picked, slots):
            if new != int(t.get("priority") or 0):
                moves.append({"id": t["id"], "title": t["title"], "from": int(t.get("priority") or 0), "to": new})
    return {"moves": moves, "order": [t["id"] for t in picked], "skipped": skipped,
            "titles": {t["id"]: t["title"] for t in picked}}


def apply(board: str, keys: List[str], db_path=None) -> dict:
    """Write the saved order to the Hermes kanban board as priority. Returns plan()'s result."""
    from hermes_cli import kanban_db as kb  # the gateway runs inside hermes-agent

    with kb.connect_closing(db_path) as conn:
        rows = conn.execute(
            "SELECT id, title, status, priority, assignee FROM tasks "
            "WHERE (assignee = ? OR assignee IS NULL) AND status != 'archived'", (board,)).fetchall()
        tasks = [dict(zip(("id", "title", "status", "priority", "assignee"), r)) for r in rows]
        result = plan(board, keys, tasks)
        if result["moves"]:
            with kb.write_txn(conn):
                for m in result["moves"]:
                    # Only while still queued: a card a worker claimed a moment ago keeps its place.
                    cur = conn.execute("UPDATE tasks SET priority = ? WHERE id = ? AND status IN (%s)"
                                       % ",".join("?" * len(QUEUED)), (m["to"], m["id"], *QUEUED))
                    if cur.rowcount:
                        kb._append_event(conn, m["id"], "reprioritized", {"priority": m["to"], "by": "yui-app"})
                    else:
                        m["raced"] = True
            result["moves"] = [m for m in result["moves"] if not m.get("raced")]
    return result


def card_name(title: str) -> str:
    m = re.match(r"^([A-Z]+-\d+)", title)
    return m.group(1) if m else title.split(":")[0][:40]


def names(result: dict) -> List[str]:
    return [card_name(result["titles"].get(i, i)) for i in result["order"]]


def reply(result: dict) -> str:
    """The short line the person sees in the thread."""
    order = names(result)
    if not order:
        why = "; ".join(f"{s['key']}: {s['why']}" for s in result["skipped"][:4])
        return f"Couldn't reorder the board. {why}." if why else "Couldn't reorder the board."
    head = "Board order saved: " + ", ".join(order) + "." if result["moves"] else \
        "Board order was already " + ", ".join(order) + "."
    if result["skipped"]:
        head += " Left in place: " + ", ".join(f"{s['key']} ({s['why']})" for s in result["skipped"][:4]) + "."
    return head


def note(result: dict) -> str:
    """What the agent reads on its next turn."""
    return ("[yui] board order changed in the app (already applied to kanban priority, no reply needed): "
            + ", ".join(names(result)))

"""One-tap answers from the war room, no agent turn (YUI-73).

The war room's Needs you panel draws each card that waits on the person as a
`choose` whose id is `need-<task id>`:

    choose@need-t_049464c4 "YUI-60: pick a direction" "a: board kit"|"Park it"

A tap sends one event row:

    meta = {"id": "need-t_049464c4", "preset": "choose",
            "value": {"choice": "a: board kit"}}

A card that wants a typed answer ("or say skip") is a one-field form instead,
`form@need-<task id> "YUI-56: ..." answer:text! submit=Send`, which sends
`{"form": {"answer": "..."}}`.

The adapter hands it here instead of to the agent. The answer lands on the
card as a comment, and a blocked card goes back to the queue (ready, or todo
while a parent is unfinished), so the worker that respawns reads the answer
first. Only this profile's cards and unassigned ones, only for the paired
owner. A changed answer (`changed: true`) comments again; the card is already
back in the queue by then.
"""

import re
from typing import Optional

ID = re.compile(r"^need-(t_[0-9a-f]{4,})$")
AUTHOR = "chris (yui-app)"


def answer_of(row: dict) -> Optional[dict]:
    """{task, choice, typed, changed} when the row is a Needs you answer, else None."""
    if row.get("kind") != "event":
        return None
    meta = row.get("meta") or {}
    v = meta.get("value") or {}
    m = ID.match(str(meta.get("id") or ""))
    if not m or meta.get("preset") not in ("choose", "form") or not isinstance(v, dict):
        return None
    form = meta["preset"] == "form"
    choice = (v.get("form") or {}).get("answer") if form and isinstance(v.get("form"), dict) else v.get("choice")
    if not isinstance(choice, str) or not choice.strip():
        return None
    return {"task": m.group(1), "choice": " ".join(choice.split())[:500],
            "typed": form or bool(v.get("other")), "changed": bool(v.get("changed"))}


def card_name(title: str) -> str:
    m = re.match(r"^([A-Z]+-\d+)", title or "")
    return m.group(1) if m else (title or "").split(":")[0][:40]


def comment(ans: dict) -> str:
    how = "typed" if ans["typed"] else "tapped"
    head = "ANSWER CHANGED" if ans["changed"] else "ANSWER"
    return f"{head} (Chris, {how} in the Yui war room): {ans['choice']}"


def apply(board: str, ans: dict, db_path=None) -> dict:
    """Comment the answer on the card and unblock it. Returns what happened."""
    from hermes_cli import kanban_db as kb  # the gateway runs inside hermes-agent

    with kb.connect_closing(db_path) as conn:
        row = conn.execute("SELECT title, status, assignee FROM tasks WHERE id = ?", (ans["task"],)).fetchone()
        if row is None:
            return {"ok": False, "why": "not on the board", "card": ans["task"]}
        title, status, assignee = row[0], row[1], row[2]
        out = {"card": card_name(title), "task": ans["task"], "choice": ans["choice"], "was": status}
        if assignee not in (board, None):
            return {**out, "ok": False, "why": f"{assignee}'s card"}
        if status in ("archived", "done"):
            return {**out, "ok": False, "why": status}
        kb.add_comment(conn, ans["task"], AUTHOR, comment(ans))
        unblocked = status == "blocked" and kb.unblock_task(conn, ans["task"])
        now = conn.execute("SELECT status FROM tasks WHERE id = ?", (ans["task"],)).fetchone()[0]
        return {**out, "ok": True, "unblocked": bool(unblocked), "status": now}


def reply(r: dict) -> str:
    """The short line the person sees in the thread."""
    if not r.get("ok"):
        return f"Couldn't answer {r.get('card') or 'that card'}: {r.get('why')}."
    if r["unblocked"]:
        where = "back in the queue" if r["status"] == "ready" else "waiting on its parent card"
        return f"Sent to {r['card']}: {r['choice']}. It's {where}."
    return f"Noted on {r['card']}: {r['choice']}."


def note(r: dict) -> str:
    """What the agent reads on its next turn."""
    return (f"[yui] Chris answered {r['card']} ({r['task']}) in the war room: {r['choice']!r} "
            f"(already on the card as a comment{', card unblocked' if r.get('unblocked') else ''}; no reply needed)")

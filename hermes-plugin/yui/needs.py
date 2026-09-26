"""One-tap answers from the war room, no agent turn (YUI-73).

The war room's Needs you panel draws each card that waits on the person as a
`choose` whose id is `need-<task id>`:

    choose@need-t_049464c4 "YUI-60: pick a direction" "a: board kit"|"Park it"

A tap sends one event row:

    meta = {"id": "need-t_049464c4", "preset": "choose",
            "value": {"choice": "a: board kit"}}

A card that wants a typed answer is the same `choose` with `+other` (Type your
own), which sends `{"choice": "...", "other": true}`. Older war rooms sent a
one-field form, `form@need-<task id> "..." answer:text! submit=Send`, which
sends `{"form": {"answer": "..."}}`; that still lands.

The adapter hands it here instead of to the agent. The answer lands on the
card as a comment, and a blocked card goes back to the queue (ready, or todo
while a parent is unfinished), so the worker that respawns reads the answer
first. Only this profile's cards and unassigned ones, only for the paired
owner. A changed answer (`changed: true`) comments again; the card is already
back in the queue by then.

Two answers ride every ask (t_f493137c): "You decide" hands the call back to
the worker (pick the option you recommend and go) and unblocks like any
answer. "Not yet" says the person has not done what the ask assumes (a browser
step, "how did it go"): it lands on the card as a comment and the card stays
blocked, so no worker respawns into nothing; a later real answer unblocks it.

After an answer the war room redraws (feedback ANP2Pn6z: "I respond to cards and
they don't go away"): the adapter runs the war room generator with --refresh,
so the answered card leaves the page at once instead of at the next board sync.
refresh_cmd() finds it; no script, no redraw.
"""

import os
import re
import sys
from pathlib import Path
from typing import List, Optional

ID = re.compile(r"^need-(t_[0-9a-f]{4,})$")
AUTHOR = "chris (yui-app)"
YOU_DECIDE = "You decide"
NOT_YET = "Not yet"


def is_(choice: str, word: str) -> bool:
    return choice.strip().rstrip(".").lower() == word.lower()


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


def refresh_cmd(board: str) -> Optional[List[str]]:
    """The war room redraw for this board: $YUI_WAR_ROOM, else the profile's own
    scripts/yui_war_room.py. None when there is none (a host without a war room)."""
    path = os.environ.get("YUI_WAR_ROOM") or str(Path.home() / ".hermes/profiles" / board / "scripts/yui_war_room.py")
    return [sys.executable, path, "--refresh"] if board and Path(path).is_file() else None


def card_name(title: str) -> str:
    m = re.match(r"^([A-Z]+-\d+)", title or "")
    return m.group(1) if m else (title or "").split(":")[0][:40]


def comment(ans: dict) -> str:
    how = "typed" if ans["typed"] else "tapped"
    who = f"(Chris, {how} in the Yui war room)"
    if not ans["typed"] and is_(ans["choice"], NOT_YET):
        return f"NOT YET {who}: he hasn't done this yet. The card stays blocked until he answers."
    head = "ANSWER CHANGED" if ans["changed"] else "ANSWER"
    if not ans["typed"] and is_(ans["choice"], YOU_DECIDE):
        return f"{head} {who}: You decide. Pick the option you recommend and go."
    return f"{head} {who}: {ans['choice']}"


def apply(board: str, ans: dict, db_path=None) -> dict:
    """Comment the answer on the card and unblock it ("Not yet" leaves it blocked). Returns what happened."""
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
        wait = not ans["typed"] and is_(ans["choice"], NOT_YET)
        unblocked = not wait and status == "blocked" and kb.unblock_task(conn, ans["task"])
        now = conn.execute("SELECT status FROM tasks WHERE id = ?", (ans["task"],)).fetchone()[0]
        return {**out, "ok": True, "unblocked": bool(unblocked), "status": now, "waiting": wait}


def reply(r: dict) -> str:
    """The short line the person sees in the thread."""
    if not r.get("ok"):
        return f"Couldn't answer {r.get('card') or 'that card'}: {r.get('why')}."
    if r.get("waiting"):
        return f"Noted on {r['card']}: not yet. It stays in Needs you until you've done it."
    if r["unblocked"] and is_(r["choice"], YOU_DECIDE):
        return f"{r['card']} will pick what it recommends and go."
    if r["unblocked"]:
        where = "back in the queue" if r["status"] == "ready" else "waiting on its parent card"
        return f"Sent to {r['card']}: {r['choice']}. It's {where}."
    return f"Noted on {r['card']}: {r['choice']}."


def note(r: dict) -> str:
    """What the agent reads on its next turn."""
    return (f"[yui] Chris answered {r['card']} ({r['task']}) in the war room: {r['choice']!r} "
            f"(already on the card as a comment{', card unblocked' if r.get('unblocked') else ''}; no reply needed)")

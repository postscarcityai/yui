"""Talk about this (YUI-69). Spec: yuigui/spec/TALK-ABOUT.md.

The person opens an item in Controls (spec/CONTROLS.md), taps Talk about
this, and the chat opens with the item pinned above the composer. What they
send starts with one line naming the item:

    [yui] attach section=soul id=SOUL.md rev=b41c09
    Less playful when I'm working.

The line is a reference. Before the agent reads the turn, expand() swaps it
for the item as Controls reads it (the same `get`, the same secret
redaction), once per rev per thread; later messages about the same rev carry
only the line. A redacted item comes with `readonly=yes`. Anyone but the
owner gets the words alone: the line is stripped, the item never read.

The agent never writes the item. It proposes: the `yui_propose` tool, or
`hermes -p <profile> yui propose ...` on hosts whose model has no Hermes
tools (the claude shim). propose() checks the change with the Controls rules
(controls.Host.handle(dry=True)) and refuses a key-shaped value, a read-only
item and a turn the owner did not start. An accepted proposal gets an id
(p-3) and is drawn into the thread from the host's own file: the agent's
`why`, then a before and after `sketch` and `choose@prop-p-3`.

The taps come back as events and are taken here with no agent turn:
Apply runs the Controls write with the proposal's rev (trash copy, log line
with via "talk"), and a receipt card lands; a rev that moved gets the
conflict card with Ask again, which sends the item again as the person's
message. Keep it as is writes nothing. The agent reads a one-line note on its
next turn either way.

State (proposals, which revs a thread has read, the latest turn) lives in
<profile home>/yui/talk.json, shared by the gateway and the CLI.
"""

from __future__ import annotations

import difflib
import fcntl
import json
import re
import time
from contextlib import contextmanager
from pathlib import Path
from typing import Callable, Optional

try:
    from . import controls
except ImportError:  # run as a script or loaded by path in tests
    import controls  # type: ignore[no-redef]

APPLY_WORDS = ("Apply", "Forget", "Delete", "Switch off", "Switch on", "Pause", "Resume", "Run now")
KEEP_WORDS = ("Keep it as is", "Keep it")
AGAIN_WORDS = "Propose that again against the current file."
EXPIRE_SECONDS = 7 * 86400
TURN_SECONDS = 2 * 3600       # a proposal must come from a turn the owner started this recently
MAX_ROWS = 14                 # rows a sketch draws before it folds the rest
LABELS = {"soul": "Personality", "memory": "Memory", "skills": "Skill", "schedules": "Schedule", "model": "Model"}

_ATTACH = re.compile(r"\[yui\] attach section=(\S+) id=(\S+) rev=(\S+)\r?\n")
_SECTION = re.compile(r"[a-z]{1,20}")
_REV = re.compile(r"[A-Za-z0-9]{1,64}")
PROP = re.compile(r"^prop-(p-\d{1,6})$")
AGAIN = re.compile(r"^again-(p-\d{1,6})$")


class Refused(Exception):
    pass


def read_attach(body: str) -> Optional[dict]:
    """{section, id, rev, words} for a message about an item (yl.mjs readAttach), else None."""
    m = _ATTACH.match(body or "")
    if not m:
        return None
    section, iid, rev = m.groups()
    if (not _SECTION.fullmatch(section) or not controls.ID.match(iid) or ".." in iid
            or not _REV.fullmatch(rev)):
        return None
    return {"section": section, "id": iid, "rev": rev, "words": body[m.end():]}


def attach_body(section: str, iid: str, rev: str, words: str) -> str:
    return f"[yui] attach section={section} id={iid} rev={rev}\n{words}"


def keyish(text: str) -> bool:
    """A value the host's redaction would hide, or a token shape: never goes through the phone."""
    return controls.redact(text or "")[1]


def _q(s: str) -> str:
    """A quoted YL value."""
    s = " ".join(str(s).split())
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def _cut(s: str, n: int = 90) -> str:
    s = " ".join(str(s).split())
    return s if len(s) <= n else s[: n - 1].rstrip() + "…"


def _show(line: str) -> str:
    """A file line as a sketch row reads it: no heading marks."""
    return _cut(re.sub(r"^#{1,6}\s+", "", line.strip()))


class Talk:
    """One profile's Talk about this. `host` is its controls.Host."""

    def __init__(self, host: "controls.Host", clock: Callable[[], float] = time.time):
        self.host = host
        self.clock = clock
        self.path = host.home / "yui" / "talk.json"

    # -- state ----------------------------------------------------------------

    @contextmanager
    def _state(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with open(self.path.with_suffix(".lock"), "a+") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            try:
                st = json.loads(self.path.read_text(encoding="utf-8")) if self.path.exists() else {}
            except ValueError:
                st = {}
            st.setdefault("next", 1)
            st.setdefault("seen", {})
            st.setdefault("proposals", {})
            yield st
            cutoff = self.clock() - EXPIRE_SECONDS
            st["proposals"] = {k: p for k, p in st["proposals"].items() if p.get("at", 0) >= cutoff}
            tmp = self.path.with_name(".talk.json.tmp")
            tmp.write_text(json.dumps(st, indent=1), encoding="utf-8")
            tmp.replace(self.path)

    def proposal(self, pid: str) -> Optional[dict]:
        with self._state() as st:
            return st["proposals"].get(pid)

    # -- the turn ---------------------------------------------------------------

    def turn(self, *, agent: str, user: str, key: str, owner: bool, owner_user: str = "") -> None:
        """The gateway starts a turn: whose it is, and the owner's thread a proposal goes to."""
        with self._state() as st:
            st["turn"] = {"agent": agent, "user": user, "key": key, "owner": bool(owner), "at": self.clock()}
            if owner_user:
                st["owner_user"] = owner_user

    def expand(self, text: str, *, key: str, owner: bool, profile: str = "") -> str:
        """The turn's text for one of the person's rows: the attach line with the item under it
        (once per rev), the line alone (same rev again), or only the words (not the owner)."""
        a = read_attach(text)
        if not a:
            return text
        if not owner:
            return a["words"]
        section, iid = a["section"], a["id"]
        ans, _ = self.host.handle({"v": controls.V, "op": "get", "section": section, "id": iid}, owner=True)
        if not ans.get("ok"):
            head = f"[yui] attach section={section} id={iid} rev={a['rev']} missing=yes"
            return f"{head}\n(The host can't read it now: {ans.get('message')})\n{a['words']}"
        rev, item = ans["rev"], ans.get("item") or {}
        ro = bool(item.get("read_only")) or "w" not in controls.SECTIONS.get(section, "")
        head = f"[yui] attach section={section} id={iid} rev={rev} readonly={'yes' if ro else 'no'}"
        slot = f"{section}/{iid}"
        with self._state() as st:
            seen = st["seen"].setdefault(key, {})
            if seen.get(slot) == rev:
                return f"{head}\n{a['words']}"
            seen[slot] = rev
        name = self.title(section, iid, item)
        how = (f"(Read only: talk about it, but don't propose a change{': part of it is hidden on the host' if item.get('read_only') else ''}.)"
               if ro else
               "(To change it, propose, never edit the file: the yui_propose tool, or "
               f"`hermes -p {profile or 'PROFILE'} yui propose --section {section} --id {iid} --rev {rev} "
               "--text-file FILE --why \"...\"` (--verb, --delete for the rest). The host draws the before and "
               "after with Apply for the person; add nothing else about it.)")
        return f"{head}\n--- {name} (current) ---\n{self.text_of(section, item)}\n--- end ---\n{how}\n{a['words']}"

    @staticmethod
    def title(section: str, iid: str, item: dict) -> str:
        if section in ("soul", "skills") and iid:
            return "SOUL.md" if section == "soul" else (item.get("title") or iid)
        if section == "schedules":
            return item.get("title") or iid
        if section == "memory":
            return _cut(controls._first_line(item.get("text") or "") or "A memory", 40)
        return "Model and tools" if section == "model" else iid

    @staticmethod
    def text_of(section: str, item: dict) -> str:
        if section == "schedules":
            state = "paused" if item.get("paused") else "on"
            return (f"name: {item.get('title')}\nwhen: {item.get('when')} (cron: {item.get('schedule')})\n"
                    f"state: {state}\nprompt:\n{item.get('text') or ''}")
        if section == "model":
            tools = ", ".join(t.get("name", "") for t in item.get("toolsets") or [])
            return f"model: {item.get('model')}\nprovider: {item.get('provider')}\ntoolsets: {tools or 'none'}"
        if section == "channels":
            return f"{item.get('title')}: {'live' if item.get('live') else 'not connected'}"
        text = item.get("text") or ""
        if section == "skills":
            text = f"switched {'on' if item.get('enabled', True) else 'off'}\n{text}"
        return text

    # -- proposing ----------------------------------------------------------------

    def propose(self, section: str, iid: str, rev: str, *, value: Optional[dict] = None, verb: str = "",
                delete: bool = False, why: str = "", chat: Optional[str] = None,
                send: Callable[[str, str, str], Optional[str]]) -> dict:
        """Check a change and draw it for the person. `send(agent_id, user_id, body)` writes the row.
        `chat` is the session's chat id when the caller knows it (the tool); else the latest turn.
        Returns {"ok": True, "id": "p-3", ...} or {"ok": False, "error", "message"}."""
        try:
            with self._state() as st:
                turn, owner_user = dict(st.get("turn") or {}), st.get("owner_user") or ""
            if chat:  # the tool knows its session: a shared thread's chat id is `<agent>~<user>`
                turn = {**turn, "key": chat, "owner": "~" not in chat, "agent": chat.split("~")[0],
                        "at": turn.get("at", 0) if turn.get("key") == chat else self.clock()}
            if not turn.get("owner") or self.clock() - turn.get("at", 0) > TURN_SECONDS:
                raise Refused("Only the owner's own chat can propose a change to this agent.")
            user = owner_user or turn.get("user")
            if not user or not turn.get("agent"):
                raise Refused("No thread to draw the proposal in. Answer in the chat first.")
            why = " ".join(str(why or "").split())[:300]
            if keyish(why):
                raise Refused("The reason looks like it holds a key. Nothing that looks like a key goes through the phone.")
            req = {"v": controls.V, "section": section, "id": iid, "rev": rev}
            n = sum(bool(x) for x in (value is not None, verb, delete))
            if n != 1:
                raise Refused("Give exactly one of value (a change), verb (pause, resume, run, enable, disable) or delete.")
            if value is not None:
                if not isinstance(value, dict):
                    raise Refused('value is an object: {"text": "..."} (a schedule may also carry "schedule").')
                if any(isinstance(v, str) and keyish(v) for v in value.values()):
                    raise Refused("That text looks like it holds a key. Keys are changed on the host "
                                  "(hermes setup), never through the phone.")
                req.update(op="put", value=value)
            elif verb:
                req.update(op="act", verb=verb)
            else:
                req.update(op="delete", confirmed=True)
            cur, _ = self.host.handle({"v": controls.V, "op": "get", "section": section, "id": iid}, owner=True)
            if cur.get("ok") and (cur.get("item") or {}).get("read_only"):
                raise Refused(controls.MESSAGES["read_only"])
            ans, _ = self.host.handle(req, owner=True, dry=True)
            if not ans.get("ok"):
                msg = ans.get("message") or ans.get("error")
                if ans.get("error") == "conflict":
                    msg = (f"It changed on the host since you read it. The current rev is {ans.get('rev')}: "
                           "read it again (the person can tap Talk about this) and propose against that.")
                raise Refused(msg)
            item = ans.get("item") or {}
            with self._state() as st:
                pid = f"p-{st['next']}"
                st["next"] += 1
                for p in st["proposals"].values():  # one live proposal per item
                    if p["section"] == section and p["id"] == iid and p["state"] in ("open", "kept", "conflict"):
                        p["state"] = "replaced"
                st["proposals"][pid] = {"pid": pid, "section": section, "id": iid, "req": req, "why": why,
                                        "title": self.title(section, iid, item), "agent": turn["agent"],
                                        "user": user, "state": "open", "at": self.clock()}
            try:
                mid = send(turn["agent"], user, self.draw(req, item, why, pid))
            except Refused:
                raise
            except Exception as e:
                self._set(pid, "unsent")
                raise Refused(f"Couldn't reach Yui to draw it ({type(e).__name__}). Try again in a minute.")
            return {"ok": True, "id": pid, "message_id": mid,
                    "say": "Drawn in the chat with Apply and Keep it as is. Add nothing else about it."}
        except Refused as e:
            return {"ok": False, "error": "refused", "message": str(e)}

    # -- the picture ------------------------------------------------------------------

    def draw(self, req: dict, item: dict, why: str, pid: str) -> str:
        """The agent's why, then the before and after and the choose, built from the host's item."""
        section, op = req["section"], req["op"]
        name = self.title(section, req["id"], item)
        rows_before, rows_after = self._rows(req, item, name)
        lines = [f"sketch {_q(name)} frame=window before=Now"] + rows_before + ["after Proposed"] + rows_after
        if op == "delete":
            word = "Forget" if section == "memory" else "Delete"
            ask = "Forget this? It won't be remembered next time." if section == "memory" else f"Delete {name}?"
            lines.append(f"choose@prop-{pid} {_q(ask)} {word}|\"Keep it\"")
        elif op == "act":
            word = {"pause": "Pause", "resume": "Resume", "run": "Run now", "enable": "Switch on",
                    "disable": "Switch off"}[req["verb"]]
            lines.append(f"choose@prop-{pid} {_q(word + '?')} {_q(word)}|\"Keep it as is\"")
        else:
            lines.append(f"choose@prop-{pid} \"Apply this change?\" Apply|\"Keep it as is\"")
        head = (why + "\n\n") if why else ""
        return head + "```yui\n" + "\n".join(lines) + "\n```"

    def _rows(self, req: dict, item: dict, name: str) -> tuple[list, list]:
        section, op = req["section"], req["op"]
        if op == "delete":
            return [f"row {_q(_cut(name))}"], [f"row {_q(_cut(name))} +x note=\"{'forgotten' if section == 'memory' else 'deleted'}\""]
        if op == "act":
            verb = req["verb"]
            if section == "skills":
                was = "on" if item.get("enabled", True) else "off"
                now = "off" if verb == "disable" else "on"
                return [f"row {_q(f'{name}: {was}')}"], [f"row {_q(f'{name}: {now}')} +hi"]
            when = item.get("when") or item.get("schedule") or ""
            was = f"{name}: paused" if item.get("paused") else f"{name}: runs {when}"
            now = {"pause": f"{name}: paused", "resume": f"{name}: runs {when}", "run": f"{name}: runs once now"}[verb]
            return [f"row {_q(_cut(was))}"], [f"row {_q(_cut(now))} +hi"]
        value = req.get("value") or {}
        before, after = [], []
        if section == "schedules" and "schedule" in value:
            try:
                shown = (self.host.cron.parse_schedule(value["schedule"].strip()) or {}).get("display") or value["schedule"]
            except Exception:
                shown = value["schedule"]
            before.append(f"row {_q(_cut(name + ': ' + (item.get('when') or '')))} +x")
            after.append(f"row {_q(_cut(name + ': ' + controls.when_in_words(shown)))} +hi note=\"new time\"")
        if "text" in value:
            b, a = self._diff(item.get("text") or "", value["text"])
            before += b
            after += a
        return before or [f"row {_q(_cut(name))} +dim"], after or [f"row {_q(_cut(name))} +dim"]

    @staticmethod
    def _diff(old: str, new: str) -> tuple[list, list]:
        """Changed lines and a line of context each side; long runs fold into "N lines unchanged"."""
        a = [ln for ln in old.splitlines() if ln.strip() and ln.strip() != "---"]
        b = [ln for ln in new.splitlines() if ln.strip() and ln.strip() != "---"]
        before, after = [], []
        sm = difflib.SequenceMatcher(a=a, b=b, autojunk=False)
        ops = sm.get_opcodes()
        for k, (tag, i1, i2, j1, j2) in enumerate(ops):
            if tag == "equal":
                n = i2 - i1
                first, last = k == 0, k == len(ops) - 1
                keep = [] if n == 0 else list(range(i1, i2))
                if n > 2:
                    keep = ([] if first else [i1]) + ([] if last else [i2 - 1])
                    gap = n - len(keep)
                    rows = []
                    if not first:
                        rows.append(f"row {_q(_show(a[i1]))} +dim")
                    rows.append(f"row \"{gap} line{'s' if gap != 1 else ''} unchanged\" +dim")
                    if not last:
                        rows.append(f"row {_q(_show(a[i2 - 1]))} +dim")
                else:
                    rows = [f"row {_q(_show(a[i]))} +dim" for i in keep]
                before += rows
                after += rows
                continue
            before += [f"row {_q(_show(x))} +x note=\"removed\"" if i == i1 else f"row {_q(_show(x))} +x"
                       for i, x in zip(range(i1, i2), a[i1:i2])]
            after += [f"row {_q(_show(x))} +hi note=\"new\"" if j == j1 else f"row {_q(_show(x))} +hi"
                      for j, x in zip(range(j1, j2), b[j1:j2])]
        return Talk._fold(before), Talk._fold(after)

    @staticmethod
    def _fold(rows: list) -> list:
        if len(rows) <= MAX_ROWS:
            return rows
        return rows[: MAX_ROWS - 1] + [f"row \"{len(rows) - MAX_ROWS + 1} more lines\" +dim"]

    # -- taps ---------------------------------------------------------------------------

    @staticmethod
    def tap_of(row: dict) -> Optional[dict]:
        """{kind: choose|again, pid, choice} for a tap on a proposal, else None."""
        if row.get("kind") != "event":
            return None
        meta = row.get("meta") or {}
        tid = str(meta.get("id") or "")
        v = meta.get("value") if isinstance(meta.get("value"), dict) else {}
        m = PROP.match(tid)
        if m and meta.get("preset") == "choose" and isinstance(v.get("choice"), str):
            return {"kind": "choose", "pid": m.group(1), "choice": v["choice"].strip()}
        m = AGAIN.match(tid)
        if m and meta.get("preset") == "card":
            return {"kind": "again", "pid": m.group(1)}
        return None

    def take(self, tap: dict, *, who: str, agent: str) -> dict:
        """Apply or keep. {reply: YL/text for the thread or None, note: for the agent or None,
        applied: {section, id} or None}. The caller has checked the owner."""
        pid = tap["pid"]
        with self._state() as st:
            p = st["proposals"].get(pid)
            if p is None:
                return {"reply": "That proposal is gone. Ask again in the chat.", "note": None}
            state = p["state"]
        choice = tap["choice"]
        if choice in KEEP_WORDS:
            if state == "applied":
                return {"reply": "Already applied. Change it in Controls, or ask again.", "note": None}
            self._set(pid, "kept")
            return {"reply": None, "note": f"[yui] Proposal {pid} kept as is."}
        if choice not in APPLY_WORDS:
            return {"reply": None, "note": None}
        if state == "applied":
            return {"reply": None, "note": None}  # a second tap on Apply: nothing new
        if state == "replaced":
            return {"reply": "Replaced by a newer proposal.", "note": None}
        ans, _ = self.host.handle(p["req"], owner=True, who=who, agent=agent, via="talk", proposal=pid)
        if ans.get("ok"):
            self._set(pid, "applied")
            label = LABELS.get(p["section"], "Settings")
            verb = {"put": "updated", "act": "updated", "delete": "forgotten" if p["section"] == "memory" else "deleted"}[p["req"]["op"]]
            what = p["why"] or p["title"]
            card = (f"card {_q(f'{label} {verb}')} {_q(_cut(what, 120))} tag=Applied "
                    f"sub=\"just now · from this chat\"")
            return {"reply": f"```yui\n{card}\n```", "applied": {"section": p["section"], "id": p["id"]},
                    "note": f"[yui] Applied in Controls: {p['title']} {verb} (your proposal {pid})."}
        if ans.get("error") == "conflict":
            self._set(pid, "conflict")
            card = (f"card@again-{pid} {_q(p['title'] + ' changed on your Mac since this was proposed')} "
                    f"\"Nothing was written. Ask again to get a proposal against the current version.\" "
                    f"cta=\"Ask again\"")
            return {"reply": f"```yui\n{card}\n```", "note": None}
        return {"reply": ans.get("message") or "The host couldn't do that.", "note": None}

    def again(self, pid: str) -> Optional[str]:
        """Ask again: the person's message that attaches the item's current rev, or None."""
        p = self.proposal(pid)
        if p is None:
            return None
        ans, _ = self.host.handle({"v": controls.V, "op": "get", "section": p["section"], "id": p["id"]}, owner=True)
        if not ans.get("ok"):
            return None
        return attach_body(p["section"], p["id"], ans["rev"], AGAIN_WORDS)

    def _set(self, pid: str, state: str) -> None:
        with self._state() as st:
            if pid in st["proposals"]:
                st["proposals"][pid]["state"] = state


# -- the tool and the CLI ------------------------------------------------------------

SCHEMA = {
    "name": "yui_propose",
    "description": (
        "Propose a change to one of your own settings the person is talking about in Yui (a message that "
        "starts with `[yui] attach section= id= rev= readonly=no`). The host checks it and draws the before "
        "and after with Apply for the person; you never write the file. Use the rev you were given. One of "
        "value (a change), verb or delete."),
    "parameters": {
        "type": "object",
        "properties": {
            "section": {"type": "string", "enum": ["soul", "memory", "skills", "schedules"]},
            "id": {"type": "string", "description": "the item's id from the attach line"},
            "rev": {"type": "string", "description": "the rev from the attach line"},
            "value": {"type": "object", "description": 'the whole new text: {"text": "..."}; a schedule may '
                                                       'carry {"schedule": "30 7 * * 1-5"} too'},
            "verb": {"type": "string", "enum": ["pause", "resume", "run", "enable", "disable"]},
            "delete": {"type": "boolean"},
            "why": {"type": "string", "description": "one short line the person reads above the change"},
        },
        "required": ["section", "id", "rev", "why"],
    },
}


def profile_home() -> Path:
    import os
    return Path(os.environ.get("HERMES_HOME") or Path.home() / ".hermes")


def rest_sender() -> Callable[[str, str, str], Optional[str]]:
    """Write an agent row into a thread over REST with this machine's connector token (any process)."""
    try:
        from . import compat, connector
    except ImportError:
        import compat  # type: ignore[no-redef]
        import connector  # type: ignore[no-redef]
    import urllib.request

    def send(agent_id: str, user_id: str, body: str) -> Optional[str]:
        token = connector.load().get("token")
        if not token:
            raise Refused("This machine is not paired with Yui.")
        s, sess = connector.call({"action": "session"}, token)
        if s != 200:
            raise Refused("Yui can't be reached right now. Try again in a minute.")
        body = compat.downgrade(body, sess.get("app_build"))
        req = urllib.request.Request(
            f"{connector.SUPABASE_URL}/rest/v1/yui_messages", method="POST",
            data=json.dumps({"user_id": user_id, "agent_id": agent_id, "sender": "agent", "body": body,
                             "kind": "text"}).encode(),
            headers={"content-type": "application/json", "apikey": connector.PUBLISHABLE,
                     "prefer": "return=representation", "authorization": f"Bearer {sess['access_token']}"})
        with urllib.request.urlopen(req, timeout=20) as r:
            return json.loads(r.read())[0]["id"]
    return send


def tool_handler(args: dict, **kw) -> str:
    """yui_propose, for hosts whose model calls Hermes tools."""
    try:
        from gateway.session_context import get_session_env
        chat = get_session_env("HERMES_SESSION_CHAT_ID") or None
        platform = get_session_env("HERMES_SESSION_PLATFORM")
    except Exception:
        chat, platform = None, ""
    if platform and platform != "yui":
        return json.dumps({"ok": False, "error": "refused", "message": "Only on the Yui channel."})
    t = Talk(controls.Host(profile_home()))
    out = t.propose(str(args.get("section") or ""), str(args.get("id") or ""), str(args.get("rev") or ""),
                    value=args.get("value"), verb=str(args.get("verb") or ""), delete=bool(args.get("delete")),
                    why=str(args.get("why") or ""), chat=chat, send=rest_sender())
    return json.dumps(out)


def cmd_propose(args) -> int:
    """hermes -p <profile> yui propose --section soul --id SOUL.md --rev b41c09 --text-file f --why "..." """
    value = None
    if args.text_file or args.text is not None or args.schedule:
        value = {}
        if args.text_file:
            value["text"] = Path(args.text_file).read_text(encoding="utf-8")
        elif args.text is not None:
            value["text"] = args.text
        if args.schedule:
            value["schedule"] = args.schedule
    t = Talk(controls.Host(profile_home()))
    out = t.propose(args.section, args.id, args.rev, value=value, verb=args.verb or "", delete=args.delete,
                    why=args.why or "", send=rest_sender())
    print(json.dumps(out))
    return 0 if out.get("ok") else 3


def add_cli(sub) -> None:
    p = sub.add_parser("propose", help="propose a change to a setting the person is talking about (Talk about this)")
    p.add_argument("--section", required=True, choices=["soul", "memory", "skills", "schedules"])
    p.add_argument("--id", required=True)
    p.add_argument("--rev", required=True)
    p.add_argument("--text-file", help="the whole new text, from a file")
    p.add_argument("--text", help="the whole new text")
    p.add_argument("--schedule", help="a new time for a schedule, e.g. '30 7 * * 1-5'")
    p.add_argument("--verb", choices=["pause", "resume", "run", "enable", "disable"])
    p.add_argument("--delete", action="store_true")
    p.add_argument("--why", help="one short line the person reads above the change")
    p.set_defaults(fn=cmd_propose)

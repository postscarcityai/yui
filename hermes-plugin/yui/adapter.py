"""Yui platform adapter (Hermes plugin). Spec: yuigui/spec/RELAY.md.

Yui is a phone app. To Hermes it is a messaging platform like Telegram: each
Hermes profile that is registered as a Yui agent gets one thread in the app,
and keeps one brain and memory across Telegram and Yui.

Transport: the gateway dials OUT to Supabase (PROOF). No inbound ports.
  1. The machine's connector token (~/.hermes/yui/connector.json, from
     `hermes -p <profile> yui pair <code>`) is traded at `yui-connect`
     (action=session) for a 60-minute JWT with role `yui_connector`. RLS lets
     that role read the user's messages and write agent replies, only in
     threads of agents bound to this connector. Never the service key.
  2. Realtime (postgres_changes on yui_messages) wakes the adapter; it then
     reads the person's rows the agent has not finished (handled_at is null),
     oldest first. A slow poll covers Realtime gaps. Each row is marked
     delivered_at when it goes to the agent and handled_at when the agent's
     turn on it completes (YUI-28), so a gateway killed mid-turn gets the
     message again on restart, and a turn that already answered is not run
     twice (replies carry meta.turn, the rows they answer).
  3. Replies are inserted as sender='agent'. Text outside ```yui fences is a
     chat bubble; each ```yui block is Yui Lines the app renders as presets.
     The adapter never parses or rewrites them. Each reply gets its id here;
     one that cannot be written (network down, Mac waking) waits in
     outbox.py's file and goes out in order when Yui is reachable again.
  4. Taps arrive as kind='event' rows whose body is `[yui] <id> <preset>
     key=value ...` (what the agent reads) and whose meta holds the
     structured event. A reaction is one too (`[yui] react msg=<id> emoji=👍
     meaning="build it"`, then the reacted message quoted; spec
     yuigui/spec/REACTIONS.md) and passes through like any other turn.
     A reply (YUI-68) is a text row whose body the app starts with
     `[yui] reply to=<row id> from=agent quote="..."`; it passes through too.
  5. A heartbeat every 45 s keeps the agent "online" in the app. A clean stop
     says goodbye (action=bye), so the app shows offline, not asleep. Each
     of them names the profile this gateway serves (`serving`, YUI-64), so
     presence is per agent: a profile paired on a computer whose gateway for
     it never started reads "not listening yet" instead of online.
  6. Every agent message is pushed to the user's phones (yui-push
     action=notify): "<Agent> has something for you in Yui" for handoffs,
     a text preview for replies. The tap opens yui://agent/<id>/thread.
     A reply of only patches (connector.quiet, YUI-75) gets no push.
     Any profile with this plugin can hand off from another channel
     (send_message target "yui"), even one with no Yui agent of its own:
     it lands in the user's first agent's thread, signed with its name.

  7. Media (YUI-21, media.py): local files and generator URLs inside ```yui
     fences are uploaded to the private yui-media bucket and swapped for
     signed URLs before the row is written; send_image/send_image_file/
     send_video do the same. The person's photos (camera, form photo fields)
     arrive as bucket paths in events and are downloaded to local files the
     agent can open, and handed to vision as media.

  8. Flywheel (YUI-42, flywheel.py): with `yui.flywheel: true` in the
     profile's config, every `custom {json}` line in a reply is noted by its
     shape only (type tree and key names, never a value) in
     <profile home>/yui/flywheel.jsonl, so repeated shapes can become presets.

  9. Board order (YUI-66, board.py): a timeline's saved order with
     board=<this profile> is applied to kanban priority here, with no agent
     turn, and only for the paired owner. The person gets a one-line
     confirmation (no push); the agent reads a note on its next turn.

 10. One-tap answers (YUI-73, needs.py): a `choose@need-<task id>` answer
     from the war room's Needs you panel is commented on that kanban card
     and unblocks it, with no agent turn, only for the paired owner. Same
     confirmation and note as a board order.

 11. Mentions (YUI-44, mentions.py): Yui routes @mentions in the database. A
     reply to the person's turn that @s another of their agents carries
     meta.mentions; this agent's next turn starts with notes on what other
     agents were asked and answered in its thread.

 12. Text bombs (YUI-79, textbomb.py): a message whose chat text (outside
     ```yui fences) runs over 60 words is noted by profile, source and word
     count, never its text, in <profile home>/yui/textbombs.jsonl, with a
     warning in the gateway log. The app folds it into "Read as pages".

The channel guide (CHANNEL.md, synced verbatim from yuigui/spec/CHANNEL.md by
../sync_channel.py) is this platform's system-prompt hint, so it is in the
system prompt on every turn on the Yui channel, and only there.
"""

import asyncio
import json
import logging
import os
import random
import time
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

try:
    import httpx
    HTTPX_AVAILABLE = True
except ImportError:  # pragma: no cover
    httpx = None  # type: ignore[assignment]
    HTTPX_AVAILABLE = False

try:
    import websockets
    WEBSOCKETS_AVAILABLE = True
except ImportError:  # pragma: no cover
    websockets = None  # type: ignore[assignment]
    WEBSOCKETS_AVAILABLE = False

from gateway.config import Platform, PlatformConfig
from gateway.platforms.base import (BasePlatformAdapter, MessageEvent, MessageType, ProcessingOutcome,
                                    SendResult)

from . import board, connector, flywheel, media, mentions, needs, outbox, textbomb
from . import commands as slash

logger = logging.getLogger(__name__)

HERE = Path(__file__).resolve().parent
REST = f"{connector.SUPABASE_URL}/rest/v1"
REALTIME = (connector.SUPABASE_URL.replace("https://", "wss://")
            + f"/realtime/v1/websocket?apikey={connector.PUBLISHABLE}&vsn=1.0.0")
HEARTBEAT_SECONDS = 45
HANDOFF_AFTER_SECONDS = 15 * 60  # no inbound this long: a send is a handoff, not a reply
POLL_SECONDS = 20            # catch-up poll while Realtime is healthy
POLL_SECONDS_DEGRADED = 3    # while Realtime is down
REFRESH_MARGIN_SECONDS = 10 * 60
PHX_HEARTBEAT_SECONDS = 25
MAX_MESSAGE_LENGTH = 32000   # matches the yui_messages body check; never split a ```yui fence
OUTBOX_BACKOFF_MAX = 60      # seconds between resends while Yui is unreachable
FAILURE_ACK_SECONDS = 5      # a failed turn is acked only if the gateway is still up after this
TURN_TIMEOUT_SECONDS = 30 * 60  # a turn that never reports back stops holding the queue
NEW_AGENT_LOOKBACK_SECONDS = 24 * 3600  # a just-paired agent still answers what was sent before its gateway came up


def load_guide() -> tuple[str, str]:
    """(version, text) of the bundled channel guide."""
    raw = (HERE / "CHANNEL.md").read_text()
    first, _, body = raw.partition("\n")
    version = first.split("yui-channel-guide", 1)[1].split()[0] if "yui-channel-guide" in first else "unknown"
    return version, body.strip()


def platform_hint() -> str:
    version, body = load_guide()
    return f"Yui channel guide {version}\n\n{body}"


STYLE_WORDS = {
    "screen": {"full": "full-screen layouts", "chat": "compact in-chat screens"},
    "buttons": {"stack": "stacked buttons", "row": "buttons in a row"},
}


def look_prompt(agent: dict) -> str:
    """Per-turn note on this agent's own look (YUI-20). The app wears it while the
    person is in this thread; `theme` lines change it (spec YL.md, "theme")."""
    look = agent.get("theme") or {}
    parts = []
    if look.get("preset"):
        parts.append(f"set {look['preset']}")
    for k in ("accent", "bg", "radius", "font", "weight", "motion"):
        if look.get(k):
            parts.append(f"{k}={look[k]}")
    desc = ", ".join(parts) if parts else "your own default (seeded from your name)"
    lines = [f"Your look in Yui: {desc}. Change it with a `theme` line only when asked."]
    style = look.get("style") or {}
    if style:
        prefs = []
        for k, v in style.items():
            prefs.append(STYLE_WORDS.get(k, {}).get(v) or f"{v} {'galleries' if k == 'gallery' else k + 's'}")
        lines.append("Screens you prefer (use them as your defaults): " + ", ".join(prefs) + ".")
    return "\n".join(lines)


def new_agent_floor() -> str:
    """Cursor for an agent this host has never served. Pairing and the gateway
    restart are separate steps, and the user often says hi in between; starting
    at "now" skipped those messages for good (TestFlight AMiI7ezKx6x1KcexlzOKYJc:
    R0SS paired at 22:36, gateway restarted later, "Did we stall?" never
    answered). Only unhandled user rows are fetched, so this replays nothing
    that was already answered."""
    return (datetime.now(tz=timezone.utc) - timedelta(seconds=NEW_AGENT_LOOKBACK_SECONDS)).isoformat()


def _parse_ts(s: str | None) -> datetime:
    if not s:
        return datetime.now(tz=timezone.utc)
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        return datetime.now(tz=timezone.utc)


def check_requirements() -> bool:
    return HTTPX_AVAILABLE


def is_connected(config) -> bool:
    return bool(connector.load().get("token"))


def validate_config(config) -> bool:
    return is_connected(config)


class YuiAdapter(BasePlatformAdapter):
    """One Hermes profile's thread(s) in the Yui app."""

    MAX_MESSAGE_LENGTH = MAX_MESSAGE_LENGTH

    def __init__(self, config: PlatformConfig):
        super().__init__(config=config, platform=Platform("yui"))
        extra = config.extra or {}
        # "Gateway shutting down, your task will be interrupted" is not true on
        # Yui: an interrupted turn is replayed after the restart (YUI-28). Off
        # unless the profile's YAML sets it.
        if "gateway_restart_notification" not in extra:
            config.gateway_restart_notification = False
        # Which Yui agents this gateway serves: the ones whose remote_ref is
        # this profile's name (override with platforms.yui.extra.remote_ref).
        self._remote_ref: str = (extra.get("remote_ref") or os.getenv("YUI_REMOTE_REF")
                                 or connector.current_profile() or "default")
        self._client: Optional["httpx.AsyncClient"] = None
        self._tasks: List[asyncio.Task] = []
        self._token: str = ""
        self._token_exp: float = 0.0
        self._user_id: str = ""
        self._agents: Dict[str, dict] = {}      # agent id -> {id, name, handle, remote_ref}
        self._all_agents: List[dict] = []       # every agent on this machine's connector (outbound)
        self._last_inbound: Dict[str, float] = {}
        self._realtime_ok = False
        self._fetch_lock = asyncio.Lock()
        self._inbound = asyncio.Event()
        # Delivery (YUI-28). The cursor is only a floor now: a new agent starts
        # a day back (new_agent_floor), not from old history.
        self._cursor_file = self._state_dir() / "cursor.json"
        self._cursor: Dict[str, str] = {}
        # One turn at a time per agent: rows that arrive while it works wait
        # here and go in together as the next turn, in order. Hermes' own busy
        # handling would interrupt the turn and keep only the newest message.
        self._dispatched: set = set()                 # row ids this process has taken
        self._queue: Dict[str, List[dict]] = {}       # agent id -> rows waiting for the next turn
        self._busy: Dict[str, tuple] = {}             # agent id -> (row ids of the running turn, started)
        self._turns: Dict[int, tuple] = {}            # id(event) -> (agent id, row ids)
        self._acks: set = set()                       # handled, not yet written
        self._outbox = outbox.Outbox(self._state_dir() / "outbox.jsonl")
        self._outbox_wake = asyncio.Event()
        self._notes: Dict[str, List[str]] = {}       # agent id -> notes for its next turn (board order)
        self._commands_sent: Optional[str] = None    # fingerprint of the /command list Yui has (YUI-61)

    # Inbound is authorized upstream: RLS on yui_messages only ever shows this
    # connector the threads of its own paired user.
    @property
    def authorization_is_upstream(self) -> bool:
        return True

    # -- state ----------------------------------------------------------------

    @staticmethod
    def _state_dir() -> Path:
        home = Path(os.environ.get("HERMES_HOME") or Path.home() / ".hermes")
        return home / "yui"

    def _load_cursor(self) -> None:
        try:
            self._cursor = json.loads(self._cursor_file.read_text())
        except (FileNotFoundError, ValueError):
            self._cursor = {}

    def _save_cursor(self) -> None:
        self._cursor_file.parent.mkdir(parents=True, exist_ok=True)
        tmp = self._cursor_file.with_suffix(".tmp")
        tmp.write_text(json.dumps(self._cursor))
        os.replace(tmp, self._cursor_file)

    # -- lifecycle ------------------------------------------------------------

    async def connect(self, *, is_reconnect: bool = False) -> bool:
        if not HTTPX_AVAILABLE:
            logger.warning("[yui] httpx missing")
            return False
        if not connector.load().get("token"):
            self._set_fatal_error("yui_not_paired",
                                  "This machine is not paired with Yui. In the app: Agents > Add agent, "
                                  f"then `hermes -p {self._remote_ref} yui pair <code>`.", retryable=False)
            return False
        self._client = httpx.AsyncClient(timeout=httpx.Timeout(20.0))
        # Load the floors BEFORE the session: it registers the agents, and an
        # agent that looks new gets a fresh floor, which would skip whatever
        # older messages this gateway missed while it was down.
        self._load_cursor()
        try:
            await self._refresh_session()
        except Exception as e:
            logger.error("[yui] session failed: %s", e)
            await self._client.aclose()
            self._client = None
            return False
        floor = new_agent_floor()
        for aid in self._agents:
            # First run for an agent: its last day of unanswered messages, not all history.
            self._cursor.setdefault(aid, floor)
        self._save_cursor()
        await self._report_commands()
        self._mark_connected()
        self._tasks = [
            asyncio.create_task(self._heartbeat_loop()),
            asyncio.create_task(self._poll_loop()),
            asyncio.create_task(self._outbox_loop()),
        ]
        if WEBSOCKETS_AVAILABLE:
            self._tasks.append(asyncio.create_task(self._realtime_loop()))
        logger.info("[yui] connected as profile %s; agents: %s", self._remote_ref,
                    ", ".join(f"{a['name']} ({aid[:8]})" for aid, a in self._agents.items()) or "none yet")
        return True

    async def disconnect(self) -> None:
        self._running = False
        self._mark_disconnected()
        if self._client:
            try:  # goodbye: the app shows offline at once instead of asleep
                await asyncio.wait_for(self._connect_call({"action": "bye", "serving": self._serving}), 5)
            except Exception as e:
                logger.info("[yui] goodbye not sent: %s", e)
        for t in self._tasks:
            t.cancel()
        for t in self._tasks:
            try:
                await t
            except (asyncio.CancelledError, Exception):
                pass
        self._tasks = []
        if self._client:
            await self._client.aclose()
            self._client = None
        logger.info("[yui] disconnected")

    # -- session + registry ---------------------------------------------------

    async def _connect_call(self, body: dict) -> dict:
        r = await self._client.post(connector.BASE, json=body, headers={
            "apikey": connector.PUBLISHABLE,
            "authorization": f"Bearer {connector.load().get('token', '')}",
            "user-agent": "hermes-yui",
        })
        data = r.json() if r.content else {}
        if r.status_code == 401:
            self._set_fatal_error("yui_unauthorized", "Yui rejected this machine's connector token "
                                  "(host removed in the app?). Pair again.", retryable=False)
        if r.status_code >= 300:
            raise RuntimeError(f"yui-connect {body.get('action')}: {r.status_code} {data.get('error')}")
        return data

    def _set_agents(self, agents: list) -> None:
        self._all_agents = list(agents)
        mine = {a["id"]: a for a in agents if a.get("remote_ref") == self._remote_ref}
        added = set(mine) - set(self._agents)
        self._agents = mine
        if added:
            floor = new_agent_floor()
            for aid in added:
                self._cursor.setdefault(aid, floor)
            self._save_cursor()
            logger.info("[yui] now serving %s", ", ".join(mine[a]["name"] for a in added))

    async def _refresh_session(self) -> None:
        data = await self._connect_call({"action": "session", "serving": self._serving})
        self._token = data["access_token"]
        self._token_exp = _parse_ts(data["expires_at"]).timestamp()
        self._user_id = data["user_id"]
        self._set_agents(data.get("agents") or [])
        save_session_cache(data)

    async def _heartbeat_loop(self) -> None:
        while self._running:
            await asyncio.sleep(HEARTBEAT_SECONDS)
            try:
                if self._token_exp - time.time() < REFRESH_MARGIN_SECONDS:
                    await self._refresh_session()  # the realtime loop pushes the new token
                else:
                    data = await self._connect_call({"action": "heartbeat", "serving": self._serving})
                    self._set_agents(data.get("agents") or [])
                await self._report_commands()
            except asyncio.CancelledError:
                raise
            except Exception as e:
                logger.warning("[yui] heartbeat: %s", e)

    async def _report_commands(self) -> None:
        """Tell Yui which /commands this profile takes (YUI-61), the composer's
        suggestions: on start, when it serves a new agent, and when the list
        changes (a skill installed, a plugin command added). Never fatal."""
        if not self._agents:
            return
        try:
            cmds = await asyncio.to_thread(slash.registry)
            if cmds is None:
                return
            fp = slash.fingerprint(cmds) + ":" + ",".join(sorted(self._agents))
            if fp == self._commands_sent:
                return
            await self._connect_call({"action": "commands", "remote_ref": self._remote_ref, "commands": cmds})
            self._commands_sent = fp
            logger.info("[yui] reported %d commands for %s", len(cmds), self._remote_ref)
        except Exception as e:
            logger.warning("[yui] commands not reported: %s", e)

    @property
    def _serving(self) -> List[str]:
        """The profiles whose threads this gateway reads: its own."""
        return [self._remote_ref]

    def _rest_headers(self) -> dict:
        return {"apikey": connector.PUBLISHABLE, "authorization": f"Bearer {self._token}"}

    # -- inbound --------------------------------------------------------------

    async def _poll_loop(self) -> None:
        while self._running:
            try:
                await self._fetch_new()
            except asyncio.CancelledError:
                raise
            except Exception as e:
                logger.warning("[yui] fetch: %s", e)
            try:
                await asyncio.wait_for(self._wake_inbound(),
                                       POLL_SECONDS if self._realtime_ok else POLL_SECONDS_DEGRADED)
            except asyncio.TimeoutError:
                pass

    async def _wake_inbound(self) -> None:
        await self._inbound.wait()
        self._inbound.clear()

    def _poke(self) -> None:
        self._inbound.set()

    async def _fetch_new(self) -> None:
        async with self._fetch_lock:
            await self._flush_acks()
            for aid in list(self._agents):
                floor = self._cursor.get(aid) or datetime.now(tz=timezone.utc).isoformat()
                r = await self._client.get(f"{REST}/yui_messages", headers=self._rest_headers(), params={
                    "select": "id,user_id,agent_id,sender,body,kind,meta,created_at,delivered_at",
                    "agent_id": f"eq.{aid}", "sender": "eq.user", "handled_at": "is.null",
                    "created_at": f"gt.{floor}", "order": "created_at.asc,id.asc", "limit": "200",
                })
                if r.status_code == 401:
                    await self._refresh_session()
                    return
                r.raise_for_status()
                for row in r.json():
                    if row["id"] in self._dispatched:
                        continue  # queued or in the running turn
                    self._dispatched.add(row["id"])
                    if row.get("delivered_at") and await self._answered(row):
                        # An earlier run answered it and died before the ack.
                        logger.info("[yui] %s was answered before a restart, not replaying", row["id"][:8])
                        self._acks.add(row["id"])
                        continue
                    if await self._board_order(aid, row) or await self._need_answer(aid, row):
                        continue
                    self._queue.setdefault(aid, []).append(row)
                await self._pump(aid)
            await self._flush_acks()
            if len(self._dispatched) > 5000:
                live = {r["id"] for rows in self._queue.values() for r in rows}
                live |= {i for ids, _ in self._busy.values() for i in ids}
                self._dispatched = live | self._acks

    async def _pump(self, aid: str) -> None:
        """Start the agent's next turn with everything waiting, unless it is mid-turn."""
        busy = self._busy.get(aid)
        if busy and time.time() - busy[1] > TURN_TIMEOUT_SECONDS:
            logger.warning("[yui] turn on %s never finished, moving on", ", ".join(i[:8] for i in busy[0]))
            self._busy.pop(aid, None)
            busy = None
        waiting = self._queue.get(aid) or []
        if not waiting:
            return
        # Commands (/stop, /new) go straight in, even mid-turn, and never replay.
        commands = [r for r in waiting if r.get("kind") == "text" and r["body"].lstrip().startswith("/")]
        for row in commands:
            waiting.remove(row)
            self._acks.add(row["id"])
            await self._mark([row["id"]], "delivered_at")
            await self._dispatch([row])
        if busy or not waiting:
            return
        rows, self._queue[aid] = list(waiting), []
        ids = [r["id"] for r in rows]
        self._busy[aid] = (ids, time.time())
        await self._mark(ids, "delivered_at")
        await self._dispatch(rows)

    async def _board_order(self, aid: str, row: dict) -> bool:
        """A timeline's saved board order (YUI-66): straight to kanban priority, no turn.
        False when the row is not one, or names another profile's board (then the agent gets it)."""
        found = board.order_of(row)
        if not found or found[0] != self._remote_ref:
            return False
        name, keys = found
        await self._mark([row["id"]], "delivered_at")
        if row.get("user_id") != self._user_id:
            text = "Only the owner can reorder this board."
        else:
            try:
                result = await asyncio.to_thread(board.apply, name, keys)
                text = board.reply(result)
                if result["order"]:
                    self._notes.setdefault(aid, []).append(board.note(result))
                logger.info("[yui] board order %s: %d moved, %d left in place", row["id"][:8],
                            len(result["moves"]), len(result["skipped"]))
            except Exception as e:
                logger.warning("[yui] board order %s: %s", row["id"][:8], e)
                text = "Couldn't reach the board to save that order. Try again in a minute."
        await self._confirm(aid, row, text)
        return True

    async def _need_answer(self, aid: str, row: dict) -> bool:
        """A one-tap answer from the war room's Needs you panel (YUI-73): straight onto the card, no turn."""
        ans = needs.answer_of(row)
        if not ans or not self._remote_ref:
            return False
        await self._mark([row["id"]], "delivered_at")
        if row.get("user_id") != self._user_id:
            text = "Only the owner can answer these cards."
        else:
            try:
                result = await asyncio.to_thread(needs.apply, self._remote_ref, ans)
                text = needs.reply(result)
                if result.get("ok"):
                    self._notes.setdefault(aid, []).append(needs.note(result))
                logger.info("[yui] needs-you answer %s on %s: %s", row["id"][:8], ans["task"],
                            "ok" if result.get("ok") else result.get("why"))
            except Exception as e:
                logger.warning("[yui] needs-you answer %s: %s", row["id"][:8], e)
                text = "Couldn't reach the board to send that answer. Try again in a minute."
        await self._confirm(aid, row, text)
        return True

    async def _confirm(self, aid: str, row: dict, text: str) -> None:
        """One line back for a tap the gateway handled itself, named by the row so a restart never replays it."""
        reply = {"id": str(uuid.uuid4()), "user_id": self._user_id, "agent_id": aid, "sender": "agent",
                 "body": text, "kind": "text", "meta": {"turn": [row["id"]], "board": True}}
        # A confirmation of the person's own tap: no push.
        if await self._write_row(reply) == "retry":
            await asyncio.to_thread(self._outbox.add, reply, None, False)
            self._outbox_wake.set()
        self._acks.add(row["id"])

    async def _answered(self, row: dict) -> bool:
        """True when an agent reply already names this row in its meta.turn:
        written, or still waiting in the outbox."""
        waiting = await asyncio.to_thread(self._outbox.items)
        if any(row["id"] in ((i["row"].get("meta") or {}).get("turn") or []) for i in waiting):
            return True
        r = await self._client.get(f"{REST}/yui_messages", headers=self._rest_headers(), params={
            "select": "id", "agent_id": f"eq.{row['agent_id']}", "sender": "eq.agent",
            "meta->turn": f'cs.["{row["id"]}"]', "limit": "1",
        })
        return r.status_code == 200 and bool(r.json())

    async def _mark(self, ids: List[str], column: str) -> bool:
        """Set delivered_at or handled_at on the person's rows. Best effort."""
        params = {"id": f"in.({','.join(ids)})"}
        if column == "delivered_at":
            params["delivered_at"] = "is.null"  # keep the first pickup time
        try:
            r = await self._client.patch(f"{REST}/yui_messages", params=params,
                                         json={column: datetime.now(tz=timezone.utc).isoformat()},
                                         headers={**self._rest_headers(), "prefer": "return=minimal"})
            if r.status_code >= 300:
                logger.warning("[yui] mark %s: %s %s", column, r.status_code, r.text[:120])
            return r.status_code < 300
        except Exception as e:
            logger.warning("[yui] mark %s: %s", column, e)
            return False

    async def _flush_acks(self) -> None:
        if not self._acks or not self._client:
            return
        ids = sorted(self._acks)
        if await self._mark(ids, "handled_at"):
            self._acks.difference_update(ids)

    async def on_processing_complete(self, event: MessageEvent, outcome: ProcessingOutcome) -> None:
        aid, ids = self._turns.pop(id(event), (None, []))
        if not aid:
            return
        if self._busy.get(aid, ((),))[0] == ids:
            self._busy.pop(aid, None)
        if outcome == ProcessingOutcome.SUCCESS:
            self._acks.update(ids)
            await self._flush_acks()
        else:
            # Shutdown cancels a running turn (as cancelled or failed). Ack only
            # if the gateway is still up a moment later, so a restart replays it.
            self._spawn(self._ack_later(ids))
        self._poke()  # rows that waited for this turn go next

    async def _ack_later(self, ids: List[str]) -> None:
        await asyncio.sleep(FAILURE_ACK_SECONDS)
        if self._running:
            self._acks.update(ids)
            await self._flush_acks()

    async def _dispatch(self, rows: List[dict]) -> None:
        """One turn for these rows (oldest first): a backlog reads as one message, line by line."""
        row = rows[-1]
        agent = self._agents.get(row["agent_id"], {})
        source = self.build_source(
            chat_id=row["agent_id"],
            chat_name=f"Yui: {agent.get('name', 'agent')}",
            chat_type="dm",
            user_id=row["user_id"],
            user_name="Yui user",
        )
        texts, photos, types = [], [], []
        for r in rows:
            text = r["body"]
            if media.USER_PATH.search(r["body"] + json.dumps(r.get("meta") or {})):
                text, p, t = await asyncio.to_thread(media.localize, r["body"], r.get("meta") or {},
                                                     self._token, logger)
                photos += p
                types += t
            texts.append(text)
        # Board orders saved since the last turn (YUI-66) and what other agents
        # were asked and answered in this thread (YUI-44): the agent reads them first.
        notes = self._notes.pop(row["agent_id"], [])
        if not texts[0].lstrip().startswith("/"):
            notes += await self._mention_notes(row["agent_id"], row.get("created_at"))
        if notes and not texts[0].lstrip().startswith("/"):
            texts = notes + texts
        event = MessageEvent(
            text="\n".join(texts),
            message_type=MessageType.PHOTO if photos else MessageType.TEXT,
            media_urls=photos,
            media_types=types,
            source=source,
            raw_message=row if len(rows) == 1 else rows,
            message_id=row["id"],
            timestamp=_parse_ts(row.get("created_at")),
            channel_prompt=look_prompt(agent),
        )
        self._last_inbound[row["agent_id"]] = time.time()
        for r in rows:
            logger.info("[yui] inbound %s %s: %s", r.get("kind"), r["id"][:8], r["body"][:80])
        if not event.is_command():
            self._turns[id(event)] = (row["agent_id"], [r["id"] for r in rows])
        await self.handle_message(event)

    async def _mention_notes(self, aid: str, upto: Optional[str]) -> List[str]:
        """Mentions of other agents from this thread, and their answers here,
        since this agent's last turn (YUI-44). Best effort: none on a failure."""
        key = f"mention:{aid}"
        floor = self._cursor.get(key) or self._cursor.get(aid) or new_agent_floor()
        params = {"select": "id,sender,body,meta,created_at", "agent_id": f"eq.{aid}",
                  "created_at": f"gt.{floor}", "order": "created_at.asc,id.asc", "limit": "20",
                  "or": "(meta->mention.not.is.null,meta->mention_reply.not.is.null)"}
        if upto:
            params["and"] = f'(created_at.lte."{upto}")'
        try:
            r = await self._client.get(f"{REST}/yui_messages", headers=self._rest_headers(), params=params)
            if r.status_code >= 300:
                logger.warning("[yui] mention notes: %s %s", r.status_code, r.text[:120])
                return []
            rows = r.json()
        except Exception as e:
            logger.warning("[yui] mention notes: %s", e)
            return []
        if rows:
            self._cursor[key] = rows[-1]["created_at"]
            await asyncio.to_thread(self._save_cursor)
        return mentions.notes(rows)

    async def _realtime_loop(self) -> None:
        """Phoenix channel on postgres_changes; any INSERT wakes the fetcher."""
        backoff = 1.0
        while self._running:
            ref = 0
            try:
                async with websockets.connect(REALTIME, ping_interval=None, open_timeout=15) as ws:
                    topic = f"realtime:yui-{self._remote_ref}"
                    token = self._token
                    ref += 1
                    await ws.send(json.dumps({
                        "topic": topic, "event": "phx_join", "ref": str(ref), "join_ref": "1",
                        "payload": {"access_token": token, "config": {
                            "broadcast": {"self": False}, "presence": {"key": ""},
                            "postgres_changes": [{"event": "INSERT", "schema": "public", "table": "yui_messages"}],
                        }},
                    }))
                    last_hb = time.monotonic()
                    while self._running:
                        if self._token != token:  # refreshed by the heartbeat loop
                            token = self._token
                            ref += 1
                            await ws.send(json.dumps({"topic": topic, "event": "access_token", "ref": str(ref),
                                                      "payload": {"access_token": token}}))
                        if time.monotonic() - last_hb > PHX_HEARTBEAT_SECONDS:
                            ref += 1
                            await ws.send(json.dumps({"topic": "phoenix", "event": "heartbeat",
                                                      "ref": str(ref), "payload": {}}))
                            last_hb = time.monotonic()
                        try:
                            raw = await asyncio.wait_for(ws.recv(), 5)
                        except asyncio.TimeoutError:
                            continue
                        msg = json.loads(raw)
                        ev, payload = msg.get("event"), msg.get("payload") or {}
                        if ev == "system" and payload.get("status") == "ok":
                            if not self._realtime_ok:
                                logger.info("[yui] realtime subscribed")
                            self._realtime_ok = True
                            backoff = 1.0
                            self._poke()  # catch up on anything sent while down
                        elif ev == "postgres_changes":
                            rec = (payload.get("data") or {}).get("record") or {}
                            if rec.get("sender") == "user" and rec.get("agent_id") in self._agents:
                                self._poke()
                        elif ev in ("phx_error", "phx_close") or (ev == "system" and payload.get("status") == "error"):
                            raise RuntimeError(f"realtime {ev}: {payload}")
                        elif ev == "phx_reply" and payload.get("status") == "error":
                            raise RuntimeError(f"realtime join refused: {payload.get('response')}")
            except asyncio.CancelledError:
                raise
            except Exception as e:
                if self._realtime_ok:
                    logger.warning("[yui] realtime down, polling every %ss: %s", POLL_SECONDS_DEGRADED, e)
                self._realtime_ok = False
            await asyncio.sleep(backoff + random.random())
            backoff = min(backoff * 2, 60.0)

    # -- outbound -------------------------------------------------------------

    async def _insert(self, agent_id: str, body: str, sender: Optional[str] = None) -> SendResult:
        if not self._client:
            return SendResult(success=False, error="not connected")
        body = body.strip()
        if not body:
            return SendResult(success=True, message_id=None)
        if len(body) > MAX_MESSAGE_LENGTH:
            body = body[:MAX_MESSAGE_LENGTH]
        flywheel.record(body, connector.current_profile())  # custom shapes only, off unless yui.flywheel
        textbomb.record(body, connector.current_profile(), "handoff" if sender else "reply", logger)
        body = await asyncio.to_thread(media.rewrite, body, lambda src: self._host(agent_id, src), logger)
        row = {"id": str(uuid.uuid4()), "user_id": self._user_id, "agent_id": agent_id, "sender": "agent",
               "body": body, "kind": "text"}
        turn = (self._busy.get(agent_id) or (None,))[0]
        if turn and not sender:
            row["meta"] = {"turn": turn}  # the rows this reply answers (restart dedupe)
            # @another agent in a reply to the person (YUI-44): Yui hands it on, one hop.
            found = mentions.handles_in(body, own=[(self._agents.get(agent_id) or {}).get("handle")])
            if found:
                row["meta"]["mentions"] = found
        handoff = bool(sender) or time.time() - self._last_inbound.get(agent_id, 0) > HANDOFF_AFTER_SECONDS
        mid = row["id"]
        # Older replies still waiting go first: never overtake them.
        queued = await asyncio.to_thread(len, self._outbox)
        result = "retry" if queued else await self._write_row(row)
        if result == "drop":
            return SendResult(success=False, error="Yui refused the reply")
        if result == "retry":
            await asyncio.to_thread(self._outbox.add, row, sender, handoff)
            self._outbox_wake.set()
            logger.info("[yui] outbound %s queued (%s waiting): %s", mid[:8], queued + 1,
                        body[:80].replace("\n", " | "))
            return SendResult(success=True, message_id=mid)
        logger.info("[yui] outbound %s: %s", mid[:8], body[:80].replace("\n", " | "))
        if not connector.quiet(body):  # patches only (YUI-75): nothing new to look at, no push
            self._spawn(self._notify(mid, sender, handoff))
        return SendResult(success=True, message_id=mid)

    def _spawn(self, coro) -> None:
        self._tasks.append(asyncio.create_task(coro))
        self._tasks = [t for t in self._tasks if not t.done()]

    async def _write_row(self, row: dict) -> str:
        """"sent" (or already there), "retry" (try again later) or "drop" (Yui refused it)."""
        try:
            if self._token_exp - time.time() < 60:
                await self._refresh_session()
            for attempt in (1, 2):
                r = await self._client.post(f"{REST}/yui_messages", json=row, headers={
                    **self._rest_headers(), "prefer": "return=minimal"})
                if r.status_code < 300 or r.status_code == 409:
                    return "sent"  # 409: an earlier try got through before its answer was lost
                if r.status_code == 401 and attempt == 1:
                    await self._refresh_session()
                    continue
                if r.status_code in (401, 408, 425, 429) or r.status_code >= 500:
                    logger.warning("[yui] send %s: %s, will retry", row["id"][:8], r.status_code)
                    return "retry"
                logger.warning("[yui] send %s refused %s: %s", row["id"][:8], r.status_code, r.text[:200])
                return "drop"
        except asyncio.CancelledError:
            raise
        except Exception as e:
            logger.warning("[yui] send %s: %s, will retry", row["id"][:8], e)
        return "retry"

    async def _outbox_loop(self) -> None:
        """Deliver queued replies oldest first, backing off quietly while Yui is unreachable."""
        backoff = 1.0
        while self._running:
            try:
                item = await asyncio.to_thread(self._outbox.peek)
                if not item:
                    backoff = 1.0
                    self._outbox_wake.clear()
                    try:  # out-of-process senders append without waking us: look again soon
                        await asyncio.wait_for(self._outbox_wake.wait(), 15)
                    except asyncio.TimeoutError:
                        pass
                    continue
                row = item["row"]
                result = await self._write_row(row)
                if result == "retry":
                    await asyncio.sleep(backoff + random.random())
                    backoff = min(backoff * 2, OUTBOX_BACKOFF_MAX)
                    continue
                await asyncio.to_thread(self._outbox.pop, row["id"])
                backoff = 1.0
                if result == "sent":
                    logger.info("[yui] outbound %s delivered from the outbox after %.0fs", row["id"][:8],
                                time.time() - item.get("queued_at", time.time()))
                    if not connector.quiet(row.get("body", "")):  # patches only: no push (YUI-75)
                        self._spawn(self._notify(row["id"], item.get("sender"), item.get("handoff", False)))
            except asyncio.CancelledError:
                raise
            except Exception as e:
                logger.warning("[yui] outbox: %s", e)
                await asyncio.sleep(5)

    def _host(self, agent_id: str, src: str) -> str:
        return media.host(self._token, self._user_id, agent_id, src)

    async def _notify(self, message_id: str, sender: Optional[str], handoff: bool) -> None:
        """Push the message to the user's phones. Best effort: the thread has it either way."""
        try:
            r = await self._client.post(connector.PUSH, json=connector.notify_body(message_id, sender, handoff),
                                        headers={"apikey": connector.PUBLISHABLE,
                                                 "authorization": f"Bearer {connector.load().get('token', '')}"})
            data = r.json() if r.content else {}
            logger.info("[yui] push %s: %s/%s phones%s", message_id[:8], data.get("delivered", 0),
                        data.get("devices", 0), f" ({r.status_code} {data.get('error')})" if r.status_code >= 300 else "")
        except Exception as e:
            logger.warning("[yui] push %s failed: %s", message_id[:8], e)

    def _agent_for(self, chat_id: str) -> tuple[Optional[str], Optional[str]]:
        """(agent id, sending profile's name when the thread is another agent's)."""
        agents = self._all_agents or list(self._agents.values())
        a, sender = connector.pick_agent(agents, self._remote_ref, chat_id)
        return (a["id"] if a else None), sender

    async def send(self, chat_id: str, content: str, reply_to: Optional[str] = None,
                   metadata: Optional[Dict[str, Any]] = None) -> SendResult:
        aid, sender = self._agent_for(chat_id)
        if not aid:
            return SendResult(success=False, error=f"no Yui agent {chat_id!r} for profile {self._remote_ref}")
        return await self._insert(aid, content, sender)

    async def send_image(self, chat_id: str, image_url: str, caption: Optional[str] = None,
                         reply_to: Optional[str] = None, metadata: Optional[Dict[str, Any]] = None) -> SendResult:
        # A picture is a Yui Lines `image` component; send() re-hosts the file.
        return await self.send(chat_id, media_fence("image", image_url, caption), reply_to, metadata)

    async def send_image_file(self, chat_id: str, image_path: str, caption: Optional[str] = None,
                              reply_to: Optional[str] = None, metadata: Optional[Dict[str, Any]] = None,
                              **kwargs) -> SendResult:
        return await self.send(chat_id, media_fence("image", image_path, caption), reply_to, metadata)

    async def send_video(self, chat_id: str, video_path: str, caption: Optional[str] = None,
                         reply_to: Optional[str] = None, metadata: Optional[Dict[str, Any]] = None,
                         **kwargs) -> SendResult:
        return await self.send(chat_id, media_fence("video", video_path, caption), reply_to, metadata)

    async def send_typing(self, chat_id: str, metadata=None) -> None:
        return None

    async def get_chat_info(self, chat_id: str) -> Dict[str, Any]:
        a = next((x for x in self._all_agents if x.get("id") == chat_id), self._agents.get(chat_id, {}))
        return {"name": f"Yui: {a.get('name', chat_id)}", "type": "dm", "chat_id": chat_id}


def save_session_cache(session: dict) -> None:
    """Who this host serves (no tokens), so a send while Yui is unreachable can queue."""
    try:
        path = outbox.state_dir() / "session.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        agents = [{k: a.get(k) for k in ("id", "name", "handle", "remote_ref")} for a in session.get("agents") or []]
        tmp = path.with_suffix(".tmp")
        tmp.write_text(json.dumps({"user_id": session.get("user_id"), "agents": agents}))
        os.replace(tmp, path)
    except OSError:
        pass


def load_session_cache() -> dict:
    try:
        return json.loads((outbox.state_dir() / "session.json").read_text())
    except (FileNotFoundError, ValueError):
        return {}


def media_fence(preset: str, src: str, caption: Optional[str] = None) -> str:
    src = src.replace(" ", "%20") if src.startswith(("http://", "https://")) else src
    line = f"{preset} {src}" + (f" {json.dumps(caption)}" if caption else "")
    return f"```yui\n{line}\n```"


# -- out-of-process delivery (cron, send_message without the gateway) ---------

async def _standalone_send(pconfig, chat_id: str, message: str, *, thread_id: Optional[str] = None,
                           media_files: Optional[List[str]] = None, force_document: bool = False) -> Dict[str, Any]:
    token = connector.load().get("token")
    if not token:
        return {"error": "yui: this machine is not paired"}
    ref = ((getattr(pconfig, "extra", None) or {}).get("remote_ref") or os.getenv("YUI_REMOTE_REF")
           or connector.current_profile() or "default")
    async with httpx.AsyncClient(timeout=20.0) as c:
        try:
            r = await c.post(connector.BASE, json={"action": "session"},
                             headers={"apikey": connector.PUBLISHABLE, "authorization": f"Bearer {token}"})
            s = r.json() if r.status_code < 300 else None
            if r.status_code in (401, 403):
                return {"error": f"yui session: HTTP {r.status_code}"}
        except httpx.HTTPError:
            s = None
        if s is None:
            # Yui unreachable (the Mac just woke, the network is down): queue it
            # for this profile's gateway, which delivers it when Yui is back.
            cache = load_session_cache()
            target, sender = connector.pick_agent(cache.get("agents") or [], ref, chat_id)
            if not target or not cache.get("user_id") or media_files:
                return {"error": "yui: unreachable, try again when online"}
            mid = str(uuid.uuid4())
            outbox.Outbox().add({"id": mid, "user_id": cache["user_id"], "agent_id": target["id"],
                                 "sender": "agent", "body": message.strip()[:MAX_MESSAGE_LENGTH], "kind": "text"},
                                sender, True)
            return {"success": True, "platform": "yui", "chat_id": target["id"], "message_id": mid, "queued": True}
        save_session_cache(s)
        target, sender = connector.pick_agent(s.get("agents") or [], ref, chat_id)
        if not target:
            return {"error": f"yui: no agent {chat_id!r} for profile {ref}"}
        files = [f[0] if isinstance(f, (tuple, list)) else f for f in (media_files or [])]  # (path, is_voice)
        body = "\n\n".join([message.strip()] + [
            media_fence("video" if f.lower().endswith((".mp4", ".mov", ".m4v")) else "image", f)
            for f in files if f.lower().rsplit(".", 1)[-1] in media.TYPES]).strip()
        flywheel.record(body, connector.current_profile())
        textbomb.record(body, connector.current_profile(), "out-of-process", logger)
        body = await asyncio.to_thread(
            media.rewrite, body, lambda src: media.host(s["access_token"], s["user_id"], target["id"], src), logger)
        row = {"id": str(uuid.uuid4()), "user_id": s["user_id"], "agent_id": target["id"], "sender": "agent",
               "body": body[:MAX_MESSAGE_LENGTH], "kind": "text"}
        mid = row["id"]
        try:
            r = await c.post(f"{REST}/yui_messages", json=row,
                             headers={"apikey": connector.PUBLISHABLE, "authorization": f"Bearer {s['access_token']}",
                                      "prefer": "return=minimal"})
            status = r.status_code
        except httpx.HTTPError:
            status = 0
        if status == 0 or status >= 500 or status == 429:
            outbox.Outbox().add(row, sender, True)
            return {"success": True, "platform": "yui", "chat_id": target["id"], "message_id": mid, "queued": True}
        if status >= 300 and status != 409:
            return {"error": f"yui send: HTTP {status}: {r.text[:200]}"}
        if connector.quiet(body):  # patches only (YUI-75): the page updates in place, no push
            logger.info("[yui] standalone send %s, patches only, no push", mid[:8])
            return {"success": True, "platform": "yui", "chat_id": target["id"], "message_id": mid, "pushed_to": 0}
        # Out of process (cron, another channel's session): always a handoff.
        p = await c.post(connector.PUSH, json=connector.notify_body(mid, sender, True),
                         headers={"apikey": connector.PUBLISHABLE, "authorization": f"Bearer {token}"})
        pushed = p.json() if p.content else {}
        logger.info("[yui] standalone send %s, push %s/%s phones", mid[:8], pushed.get("delivered", 0),
                    pushed.get("devices", 0))
        return {"success": True, "platform": "yui", "chat_id": target["id"], "message_id": mid,
                "pushed_to": pushed.get("delivered", 0)}


# -- CLI: hermes -p <profile> yui pair|add|heartbeat|status ---------------------

def _cli_setup(parser) -> None:
    connector.build_parser(parser, with_profile=False)


def _cli_handler(args) -> int:
    return connector.dispatch(args)


def register(ctx) -> None:
    # A profile has one Yui thread, so it is always the home channel (cron
    # delivery, cross-platform sends). `_agent_for` resolves the profile name.
    if connector.current_profile():
        os.environ.setdefault("YUI_HOME_CHANNEL", connector.current_profile())
    ctx.register_platform(
        name="yui",
        label="Yui",
        adapter_factory=lambda cfg: YuiAdapter(cfg),
        check_fn=check_requirements,
        validate_config=validate_config,
        is_connected=is_connected,
        required_env=[],
        install_hint="pair first: `hermes -p <profile> yui pair <code>` (code from the Yui app)",
        cron_deliver_env_var="YUI_HOME_CHANNEL",
        standalone_sender_fn=_standalone_send,
        max_message_length=MAX_MESSAGE_LENGTH,
        emoji="🐰",
        pii_safe=True,
        allow_update_command=False,
        platform_hint=platform_hint(),
    )
    from . import handoff
    ctx.register_hook("pre_gateway_dispatch", handoff.rewrite_slash)
    ctx.register_hook("pre_llm_call", handoff.inject_howto)
    ctx.register_command("yui", handoff.slash_command,
                         description="Hand what we're doing to the Yui app, with a push to your phone",
                         args_hint="[note]")
    ctx.register_cli_command(
        name="yui",
        help="Yui app: pair this profile, add it, check the connection",
        setup_fn=_cli_setup,
        handler_fn=_cli_handler,
        description="Connect this Hermes profile to the Yui app (spec: yuigui/spec/AGENTS.md).",
    )

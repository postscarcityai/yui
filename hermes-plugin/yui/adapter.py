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
     reads new user rows over REST past a saved cursor. A slow poll covers
     Realtime gaps and restarts, so nothing is lost or handled twice.
  3. Replies are inserted as sender='agent'. Text outside ```yui fences is a
     chat bubble; each ```yui block is Yui Lines the app renders as presets.
     The adapter never parses or rewrites them.
  4. Taps arrive as kind='event' rows whose body is `[yui] <id> <preset>
     key=value ...` (what the agent reads) and whose meta holds the
     structured event.
  5. A heartbeat every 45 s keeps the agent "connected" in the app.

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
from datetime import datetime, timezone
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
from gateway.platforms.base import BasePlatformAdapter, MessageEvent, MessageType, SendResult

from . import connector

logger = logging.getLogger(__name__)

HERE = Path(__file__).resolve().parent
REST = f"{connector.SUPABASE_URL}/rest/v1"
REALTIME = (connector.SUPABASE_URL.replace("https://", "wss://")
            + f"/realtime/v1/websocket?apikey={connector.PUBLISHABLE}&vsn=1.0.0")
HEARTBEAT_SECONDS = 45
POLL_SECONDS = 20            # catch-up poll while Realtime is healthy
POLL_SECONDS_DEGRADED = 3    # while Realtime is down
REFRESH_MARGIN_SECONDS = 10 * 60
PHX_HEARTBEAT_SECONDS = 25
MAX_MESSAGE_LENGTH = 32000   # matches the yui_messages body check; never split a ```yui fence


def load_guide() -> tuple[str, str]:
    """(version, text) of the bundled channel guide."""
    raw = (HERE / "CHANNEL.md").read_text()
    first, _, body = raw.partition("\n")
    version = first.split("yui-channel-guide", 1)[1].split()[0] if "yui-channel-guide" in first else "unknown"
    return version, body.strip()


def platform_hint() -> str:
    version, body = load_guide()
    return f"Yui channel guide {version}\n\n{body}"


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
        self._realtime_ok = False
        self._fetch_lock = asyncio.Lock()
        self._inbound = asyncio.Event()
        self._seen: Dict[str, float] = {}
        self._cursor_file = self._state_dir() / "cursor.json"
        self._cursor: Dict[str, str] = {}

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
        try:
            await self._refresh_session()
        except Exception as e:
            logger.error("[yui] session failed: %s", e)
            await self._client.aclose()
            self._client = None
            return False
        self._load_cursor()
        now = datetime.now(tz=timezone.utc).isoformat()
        for aid in self._agents:
            # First run for an agent: start from now, don't replay old history.
            self._cursor.setdefault(aid, now)
        self._save_cursor()
        self._mark_connected()
        self._tasks = [
            asyncio.create_task(self._heartbeat_loop()),
            asyncio.create_task(self._poll_loop()),
        ]
        if WEBSOCKETS_AVAILABLE:
            self._tasks.append(asyncio.create_task(self._realtime_loop()))
        logger.info("[yui] connected as profile %s; agents: %s", self._remote_ref,
                    ", ".join(f"{a['name']} ({aid[:8]})" for aid, a in self._agents.items()) or "none yet")
        return True

    async def disconnect(self) -> None:
        self._running = False
        self._mark_disconnected()
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
        mine = {a["id"]: a for a in agents if a.get("remote_ref") == self._remote_ref}
        added = set(mine) - set(self._agents)
        self._agents = mine
        if added:
            now = datetime.now(tz=timezone.utc).isoformat()
            for aid in added:
                self._cursor.setdefault(aid, now)
            self._save_cursor()
            logger.info("[yui] now serving %s", ", ".join(mine[a]["name"] for a in added))

    async def _refresh_session(self) -> None:
        data = await self._connect_call({"action": "session"})
        self._token = data["access_token"]
        self._token_exp = _parse_ts(data["expires_at"]).timestamp()
        self._user_id = data["user_id"]
        self._set_agents(data.get("agents") or [])

    async def _heartbeat_loop(self) -> None:
        while self._running:
            await asyncio.sleep(HEARTBEAT_SECONDS)
            try:
                if self._token_exp - time.time() < REFRESH_MARGIN_SECONDS:
                    await self._refresh_session()  # the realtime loop pushes the new token
                else:
                    data = await self._connect_call({"action": "heartbeat"})
                    self._set_agents(data.get("agents") or [])
            except asyncio.CancelledError:
                raise
            except Exception as e:
                logger.warning("[yui] heartbeat: %s", e)

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
            for aid in list(self._agents):
                since = self._cursor.get(aid) or datetime.now(tz=timezone.utc).isoformat()
                r = await self._client.get(f"{REST}/yui_messages", headers=self._rest_headers(), params={
                    "select": "id,user_id,agent_id,sender,body,kind,meta,created_at",
                    "agent_id": f"eq.{aid}", "sender": "eq.user",
                    "created_at": f"gt.{since}", "order": "created_at.asc", "limit": "50",
                })
                if r.status_code == 401:
                    await self._refresh_session()
                    return
                r.raise_for_status()
                for row in r.json():
                    self._cursor[aid] = row["created_at"]
                    self._save_cursor()
                    if row["id"] in self._seen:
                        continue
                    self._seen[row["id"]] = time.time()
                    await self._dispatch(row)
            if len(self._seen) > 2000:
                cutoff = time.time() - 3600
                self._seen = {k: v for k, v in self._seen.items() if v > cutoff}

    async def _dispatch(self, row: dict) -> None:
        agent = self._agents.get(row["agent_id"], {})
        source = self.build_source(
            chat_id=row["agent_id"],
            chat_name=f"Yui: {agent.get('name', 'agent')}",
            chat_type="dm",
            user_id=row["user_id"],
            user_name="Yui user",
        )
        event = MessageEvent(
            text=row["body"],
            message_type=MessageType.TEXT,
            source=source,
            raw_message=row,
            message_id=row["id"],
            timestamp=_parse_ts(row.get("created_at")),
        )
        logger.info("[yui] inbound %s %s: %s", row.get("kind"), row["id"][:8], row["body"][:80])
        await self.handle_message(event)

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

    async def _insert(self, agent_id: str, body: str) -> SendResult:
        if not self._client:
            return SendResult(success=False, error="not connected")
        body = body.strip()
        if not body:
            return SendResult(success=True, message_id=None)
        if len(body) > MAX_MESSAGE_LENGTH:
            body = body[:MAX_MESSAGE_LENGTH]
        if self._token_exp - time.time() < 60:
            await self._refresh_session()
        row = {"user_id": self._user_id, "agent_id": agent_id, "sender": "agent", "body": body, "kind": "text"}
        r = await self._client.post(f"{REST}/yui_messages", json=row, headers={
            **self._rest_headers(), "prefer": "return=representation"})
        if r.status_code >= 300:
            logger.warning("[yui] send failed %s: %s", r.status_code, r.text[:200])
            return SendResult(success=False, error=f"HTTP {r.status_code}: {r.text[:200]}")
        mid = (r.json() or [{}])[0].get("id")
        logger.info("[yui] outbound %s: %s", (mid or "")[:8], body[:80].replace("\n", " | "))
        return SendResult(success=True, message_id=mid)

    def _agent_for(self, chat_id: str) -> Optional[str]:
        if chat_id in self._agents:
            return chat_id
        # Home-channel style targets: the profile name or the agent handle.
        for aid, a in self._agents.items():
            if chat_id in (a.get("handle"), a.get("remote_ref"), a.get("name")):
                return aid
        return next(iter(self._agents), None) if not chat_id else None

    async def send(self, chat_id: str, content: str, reply_to: Optional[str] = None,
                   metadata: Optional[Dict[str, Any]] = None) -> SendResult:
        aid = self._agent_for(chat_id)
        if not aid:
            return SendResult(success=False, error=f"no Yui agent {chat_id!r} on profile {self._remote_ref}")
        return await self._insert(aid, content)

    async def send_image(self, chat_id: str, image_url: str, caption: Optional[str] = None,
                         reply_to: Optional[str] = None, metadata: Optional[Dict[str, Any]] = None) -> SendResult:
        # A picture is a Yui Lines `image` component.
        line = f"image {image_url}" + (f" {json.dumps(caption)}" if caption else "")
        return await self.send(chat_id, f"```yui\n{line}\n```", reply_to, metadata)

    async def send_typing(self, chat_id: str, metadata=None) -> None:
        return None

    async def get_chat_info(self, chat_id: str) -> Dict[str, Any]:
        a = self._agents.get(chat_id, {})
        return {"name": f"Yui: {a.get('name', chat_id)}", "type": "dm", "chat_id": chat_id}


# -- out-of-process delivery (cron, send_message without the gateway) ---------

async def _standalone_send(pconfig, chat_id: str, message: str, *, thread_id: Optional[str] = None,
                           media_files: Optional[List[str]] = None, force_document: bool = False) -> Dict[str, Any]:
    token = connector.load().get("token")
    if not token:
        return {"error": "yui: this machine is not paired"}
    ref = ((getattr(pconfig, "extra", None) or {}).get("remote_ref") or os.getenv("YUI_REMOTE_REF")
           or connector.current_profile() or "default")
    async with httpx.AsyncClient(timeout=20.0) as c:
        r = await c.post(connector.BASE, json={"action": "session"},
                         headers={"apikey": connector.PUBLISHABLE, "authorization": f"Bearer {token}"})
        if r.status_code >= 300:
            return {"error": f"yui session: HTTP {r.status_code}"}
        s = r.json()
        agents = [a for a in s.get("agents") or [] if a.get("remote_ref") == ref]
        target = next((a for a in agents if chat_id in (a["id"], a.get("handle"), a.get("remote_ref"))),
                      agents[0] if agents and not chat_id else None)
        if not target:
            return {"error": f"yui: no agent {chat_id!r} for profile {ref}"}
        r = await c.post(f"{REST}/yui_messages", json={
            "user_id": s["user_id"], "agent_id": target["id"], "sender": "agent",
            "body": message.strip()[:MAX_MESSAGE_LENGTH], "kind": "text"},
            headers={"apikey": connector.PUBLISHABLE, "authorization": f"Bearer {s['access_token']}",
                     "prefer": "return=representation"})
        if r.status_code >= 300:
            return {"error": f"yui send: HTTP {r.status_code}: {r.text[:200]}"}
        return {"success": True, "platform": "yui", "chat_id": target["id"], "message_id": r.json()[0]["id"]}


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
    ctx.register_cli_command(
        name="yui",
        help="Yui app: pair this profile, add it, check the connection",
        setup_fn=_cli_setup,
        handler_fn=_cli_handler,
        description="Connect this Hermes profile to the Yui app (spec: yuigui/spec/AGENTS.md).",
    )

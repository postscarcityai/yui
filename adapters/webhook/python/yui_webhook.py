#!/usr/bin/env python3
"""Yui webhook bridge (INT-2): any agent that answers an HTTP POST can talk in Yui.

Spec: yuigui/spec/RELAY.md (rows, acks, meta.turn) and spec/ADAPTERS.md path E.
This process runs next to your agent. It dials out to Yui (no inbound ports),
reads what the person sends, POSTs it to your webhook, and writes your answer
back into their thread, exactly once. Stdlib only, Python 3.10+.

    python3 yui_webhook.py pair 123456 [--ref my-agent] [--host-name "Build box"]
    python3 yui_webhook.py run --webhook http://127.0.0.1:8787/yui [--secret S]
    python3 yui_webhook.py send "Your report is ready" [--agent <id|handle|ref>]
    python3 yui_webhook.py guide        # print the channel guide your agent should read
    python3 yui_webhook.py status

Your webhook gets one POST per turn (JSON, see README.md) and answers with
{"reply": "..."} or {"replies": [...]} or plain text; an empty 2xx means no
reply. Anything else and the turn is tried again later, so a crash in your
agent never loses a message.

State (the connector token, a floor per agent, the reply outbox) lives in
~/.yui/webhook.json (mode 600), or --state / $YUI_WEBHOOK_STATE.
"""
import argparse, hashlib, hmac, json, os, random, signal, socket, sys, threading, time, urllib.error, urllib.parse, urllib.request, uuid
from datetime import datetime, timezone
from pathlib import Path

SUPABASE_URL = os.environ.get("YUI_SUPABASE_URL", "https://ewzzaoperdpxqxkshynx.supabase.co")
CONNECT = f"{SUPABASE_URL}/functions/v1/yui-connect"
PUSH = f"{SUPABASE_URL}/functions/v1/yui-push"
REST = f"{SUPABASE_URL}/rest/v1"
# Public client key (anon role only; it cannot read any yui_ table).
PUBLISHABLE = "sb_publishable_OhqLI7p27yiELT4tn8i7JA_TnnwPYsS"
UA = "yui-webhook-py/1"
HEARTBEAT_SECONDS = 45
REFRESH_MARGIN_SECONDS = 600   # the 60-minute session is renewed 10 minutes early
BACKOFF_MAX = 60
MAX_BODY = 32000


def now_iso() -> str:
    return datetime.now(tz=timezone.utc).isoformat()


def log(msg: str) -> None:
    print(f"{datetime.now().strftime('%H:%M:%S')} yui: {msg}", file=sys.stderr, flush=True)


class Refused(Exception):
    """Yui said no for good (bad token, removed host): stop, don't retry."""


class Retry(Exception):
    """Network or server trouble: try again later."""


# -- state ----------------------------------------------------------------------

class State:
    """One JSON file: {token, connector, floors: {agent: iso}, outbox: [...], acks: [...]}."""

    def __init__(self, path: Path):
        self.path = path
        self.lock = threading.Lock()
        try:
            self.data = json.loads(path.read_text())
        except (FileNotFoundError, ValueError):
            self.data = {}
        self.data.setdefault("floors", {})
        self.data.setdefault("outbox", [])
        self.data.setdefault("acks", [])

    def save(self) -> None:
        with self.lock:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            tmp = self.path.with_suffix(".tmp")
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w") as f:
                json.dump(self.data, f, indent=1)
            os.replace(tmp, self.path)


# -- HTTP -------------------------------------------------------------------------

def http(method: str, url: str, body=None, headers=None, timeout=20) -> tuple[int, object]:
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={
        "content-type": "application/json", "apikey": PUBLISHABLE, "user-agent": UA, **(headers or {})})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw) if raw else None
        except ValueError:
            return e.code, raw.decode(errors="replace")
    except (urllib.error.URLError, OSError, TimeoutError) as e:
        raise Retry(str(e)) from e


def connect_call(body: dict, token: str | None = None) -> dict:
    s, r = http("POST", CONNECT, body, {"authorization": f"Bearer {token}"} if token else None)
    if s in (401, 403):
        raise Refused(f"yui-connect {body['action']}: {s} {(r or {}).get('error') if isinstance(r, dict) else r}")
    if s >= 300:
        raise Retry(f"yui-connect {body['action']}: {s}")
    return r or {}


# -- pairing ----------------------------------------------------------------------

def host_name() -> str:
    return socket.gethostname().split(".")[0] or "My computer"


def pair(state: State, code: str, ref: str, name: str | None) -> dict:
    s, r = http("POST", CONNECT, {"action": "pair", "code": code, "remote_ref": ref,
                                  "host_name": name or host_name(), "kind": "http"},
                {"authorization": f"Bearer {state.data['token']}"} if state.data.get("token") else None)
    if s != 200:
        raise Refused(f"pair failed: {(r or {}).get('error', s) if isinstance(r, dict) else s}")
    if r.get("connector_token"):  # a new connector (first pairing, or another Yui account)
        state.data.update(token=r["connector_token"], connector=r["connector"], floors={}, outbox=[], acks=[])
    # Messages sent from the moment of pairing reach the agent, even before `run`.
    state.data["floors"].setdefault(r["agent"]["id"], now_iso())
    state.save()
    return r


# -- the bridge ---------------------------------------------------------------------

class Bridge:
    def __init__(self, state: State, webhook: str | None = None, secret: str | None = None,
                 interval: float = 2.0, webhook_timeout: float = 300):
        self.state, self.webhook, self.secret = state, webhook, secret
        self.interval, self.webhook_timeout = interval, webhook_timeout
        self.token = self.user_id = None
        self.token_exp = 0.0
        self.agents: dict = {}
        self.guide = {"version": "", "body": ""}
        self.running = True
        self.beat_lock = threading.Lock()
        self.retry_at: dict = {}   # agent id -> time its failed turn may run again
        self.backoff: dict = {}

    @property
    def ct(self) -> str:
        t = self.state.data.get("token")
        if not t:
            raise Refused("not paired: add an agent in the app, then run `pair <code>`")
        return t

    def rest_headers(self, extra=None) -> dict:
        return {"authorization": f"Bearer {self.token}", **(extra or {})}

    def session(self) -> None:
        r = connect_call({"action": "session"}, self.ct)
        self.token, self.user_id = r["access_token"], r["user_id"]
        self.token_exp = datetime.fromisoformat(r["expires_at"].replace("Z", "+00:00")).timestamp()
        self.guide = r.get("guide") or self.guide
        agents = {a["id"]: a for a in r.get("agents") or []}
        for aid in set(agents) - set(self.agents):
            if aid not in self.state.data["floors"]:  # an agent added later starts from now
                self.state.data["floors"][aid] = now_iso()
                self.state.save()
            log(f"serving {agents[aid]['name']} ({aid[:8]})")
        self.agents = agents

    def ensure_session(self) -> None:
        if not self.token or self.token_exp - time.time() < REFRESH_MARGIN_SECONDS:
            self.session()

    def rest(self, method: str, path: str, body=None, prefer: str | None = None) -> tuple[int, object]:
        s, r = http(method, f"{REST}/{path}", body, self.rest_headers({"prefer": prefer} if prefer else None))
        if s == 401:  # token expired under us: one fresh session, one more try
            self.session()
            s, r = http(method, f"{REST}/{path}", body, self.rest_headers({"prefer": prefer} if prefer else None))
        return s, r

    # -- acks (RELAY.md, Delivery) --

    def mark(self, ids: list, column: str) -> bool:
        q = f"yui_messages?id=in.({','.join(ids)})"
        if column == "delivered_at":
            q += "&delivered_at=is.null"  # keep the first pickup time
        try:
            s, _ = self.rest("PATCH", q, {column: now_iso()}, "return=minimal")
            return s < 300
        except Retry:
            return False

    def flush_acks(self) -> None:
        ids = list(self.state.data["acks"])
        if ids and self.mark(ids, "handled_at"):
            self.state.data["acks"] = [i for i in self.state.data["acks"] if i not in ids]
            self.state.save()

    def answered(self, row: dict) -> bool:
        """An earlier run already answered this row: a reply names it in meta.turn,
        written or still waiting in the outbox."""
        if any(row["id"] in (i["row"].get("meta") or {}).get("turn", []) for i in self.state.data["outbox"]):
            return True
        s, r = self.rest("GET", f"yui_messages?select=id&agent_id=eq.{row['agent_id']}&sender=eq.agent"
                                f"&meta->turn=cs.{urllib.parse.quote(json.dumps([row['id']]))}&limit=1")
        return s == 200 and bool(r)

    # -- agent to phone --

    def queue_reply(self, agent_id: str, text: str, turn: list | None, ack: list | None, handoff=False) -> str:
        row = {"id": str(uuid.uuid4()), "user_id": self.user_id, "agent_id": agent_id,
               "sender": "agent", "kind": "text", "body": text.strip()[:MAX_BODY]}
        if turn:
            row["meta"] = {"turn": turn}  # the rows this reply answers (restart dedupe)
        self.state.data["outbox"].append({"row": row, "ack": ack or [], "handoff": handoff,
                                          "queued_at": time.time()})
        self.state.save()  # on disk before the first try: a crash now still sends it
        return row["id"]

    def flush_outbox(self) -> None:
        """Oldest first; a reply that can't go yet holds the ones behind it."""
        while self.state.data["outbox"]:
            item = self.state.data["outbox"][0]
            s, r = self.rest("POST", "yui_messages", item["row"], "return=minimal")
            if s >= 300 and s != 409:  # 409: an earlier try got through
                if s in (408, 425, 429) or s >= 500:
                    raise Retry(f"reply {item['row']['id'][:8]}: {s}")
                log(f"Yui refused reply {item['row']['id'][:8]}: {s} {r}")
            self.state.data["outbox"].pop(0)
            self.state.data["acks"] += item["ack"]
            self.state.save()
            if s < 300:
                self.notify(item["row"]["id"], item["handoff"])

    def notify(self, message_id: str, handoff: bool) -> None:
        """Buzz the phone (yui-push skips it when the thread is already open)."""
        try:
            http("POST", PUSH, {"action": "notify", "message_id": message_id, "handoff": handoff},
                 {"authorization": f"Bearer {self.ct}"})
        except Retry:
            pass

    # -- phone to agent --

    def fetch(self, aid: str) -> list:
        floor = urllib.parse.quote(self.state.data["floors"].get(aid) or now_iso())
        s, r = self.rest("GET", "yui_messages?select=id,agent_id,body,kind,meta,created_at,delivered_at"
                                f"&agent_id=eq.{aid}&sender=eq.user&handled_at=is.null&created_at=gt.{floor}"
                                "&order=created_at.asc,id.asc&limit=200")
        if s != 200:
            raise Retry(f"read {aid[:8]}: {s}")
        pending = set(self.state.data["acks"])
        return [row for row in r if row["id"] not in pending]

    def turn_payload(self, agent: dict, rows: list) -> dict:
        return {
            "agent": {"id": agent["id"], "name": agent.get("name"), "handle": agent.get("handle"),
                      "ref": agent.get("remote_ref")},
            "turn": [r["id"] for r in rows],
            "text": "\n".join(r["body"] for r in rows),
            "messages": [{"id": r["id"], "kind": r["kind"], "body": r["body"],
                          "event": (r.get("meta") or None) if r["kind"] == "event" else None,
                          "created_at": r["created_at"]} for r in rows],
            "guide": self.guide,
        }

    def call_webhook(self, payload: dict) -> list | None:
        """The replies (maybe none), or None when the turn should be tried again."""
        raw = json.dumps(payload).encode()
        headers = {"content-type": "application/json", "user-agent": UA,
                   "x-yui-turn": hashlib.sha256(",".join(payload["turn"]).encode()).hexdigest()[:32]}
        if self.secret:
            ts = str(int(time.time()))
            sig = hmac.new(self.secret.encode(), f"{ts}.".encode() + raw, hashlib.sha256).hexdigest()
            headers.update({"x-yui-timestamp": ts, "x-yui-signature": f"sha256={sig}"})
        req = urllib.request.Request(self.webhook, data=raw, method="POST", headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=self.webhook_timeout) as r:
                body, ctype = r.read().decode("utf-8", "replace"), r.headers.get("content-type", "")
        except urllib.error.HTTPError as e:
            log(f"webhook answered {e.code}; trying this turn again later")
            return None
        except (urllib.error.URLError, OSError, TimeoutError) as e:
            log(f"webhook unreachable ({e}); trying this turn again later")
            return None
        if not body.strip():
            return []
        if "json" in ctype:
            try:
                data = json.loads(body)
            except ValueError:
                log("webhook sent bad JSON; trying this turn again later")
                return None
            if isinstance(data, dict):
                replies = data.get("replies") if "replies" in data else [data.get("reply")]
            else:
                replies = data if isinstance(data, list) else [data]
            return [str(x) for x in replies if isinstance(x, str) and x.strip()]
        return [body]

    def run_turns(self) -> None:
        for aid, agent in list(self.agents.items()):
            if self.retry_at.get(aid, 0) > time.time():
                continue
            rows = []
            for row in self.fetch(aid):
                if row.get("delivered_at") and self.answered(row):
                    log(f"{row['id'][:8]} was answered before a restart, not sending it again")
                    self.state.data["acks"].append(row["id"])
                    self.state.save()
                    continue
                rows.append(row)
            if not rows:
                continue
            ids = [r["id"] for r in rows]
            self.mark(ids, "delivered_at")
            log(f"turn for {agent['name']}: {len(rows)} message(s)")
            replies = self.call_webhook(self.turn_payload(agent, rows))
            if replies is None:
                wait = self.backoff[aid] = min(self.backoff.get(aid, 1) * 2, BACKOFF_MAX)
                self.retry_at[aid] = time.time() + wait + random.random()
                continue
            self.backoff.pop(aid, None)
            self.retry_at.pop(aid, None)
            if not replies:
                self.state.data["acks"] += ids
                self.state.save()
            for n, text in enumerate(replies):
                self.queue_reply(aid, text, ids, ids if n == len(replies) - 1 else None)
            self.flush_outbox()
            self.flush_acks()

    def heartbeat_loop(self) -> None:
        while self.running:
            time.sleep(HEARTBEAT_SECONDS)
            if not self.running:
                break
            with self.beat_lock:  # stop() waits for a beat in flight, so it can't land after the goodbye
                if not self.running:
                    break
                try:  # its own thread, so a slow webhook never makes the agent look asleep
                    connect_call({"action": "heartbeat"}, self.ct)
                except (Retry, Refused) as e:
                    log(f"heartbeat: {e}")

    def run(self) -> None:
        self.session()
        log(f"online as {self.state.data.get('connector', {}).get('name')}; guide {self.guide.get('version')}; "
            f"webhook {self.webhook}")
        threading.Thread(target=self.heartbeat_loop, daemon=True).start()
        backoff = 1.0
        while self.running:
            try:
                self.ensure_session()
                self.flush_outbox()
                self.flush_acks()
                self.run_turns()
                backoff = 1.0
                time.sleep(self.interval)
            except Retry as e:
                log(f"{e}; retrying in {backoff:.0f}s")
                time.sleep(backoff + random.random())
                backoff = min(backoff * 2, BACKOFF_MAX)

    def stop(self) -> None:
        with self.beat_lock:
            self.running = False
        try:  # goodbye: the app shows the agent offline at once, not asleep
            connect_call({"action": "bye"}, self.ct)
        except (Retry, Refused):
            pass


def pick(agents: dict, want: str | None) -> dict | None:
    if not want:
        return next(iter(agents.values()), None)
    want = want.lower()
    return next((a for a in agents.values()
                 if want in {str(a.get(k) or "").lower() for k in ("id", "handle", "remote_ref", "name")}), None)


# -- CLI ------------------------------------------------------------------------------

def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Yui webhook bridge: your HTTP agent, in Yui.")
    ap.add_argument("--state", default=os.environ.get("YUI_WEBHOOK_STATE") or str(Path.home() / ".yui/webhook.json"))
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("pair", help="claim the code from the app's Add agent")
    p.add_argument("code")
    p.add_argument("--ref", default="webhook", help="your name for this agent (letters, digits, . _ -)")
    p.add_argument("--host-name")
    r = sub.add_parser("run", help="bridge the person's messages to your webhook")
    r.add_argument("--webhook", default=os.environ.get("YUI_WEBHOOK_URL"), required=not os.environ.get("YUI_WEBHOOK_URL"))
    r.add_argument("--secret", default=os.environ.get("YUI_WEBHOOK_SECRET"), help="HMAC-sign every POST")
    r.add_argument("--interval", type=float, default=2.0, help="seconds between checks")
    r.add_argument("--timeout", type=float, default=300, help="seconds your agent gets per turn")
    s = sub.add_parser("send", help="send a message (a handoff) into an agent's thread")
    s.add_argument("text")
    s.add_argument("--agent", help="id, handle, ref or name (default: the first)")
    sub.add_parser("guide", help="print the channel guide")
    sub.add_parser("status", help="show the connector and its agents")
    args = ap.parse_args(argv)
    state = State(Path(args.state).expanduser())

    try:
        if args.cmd == "pair":
            r = pair(state, args.code, args.ref, args.host_name)
            print(f"paired: {r['agent']['name']} on {r['connector']['name']}. Next: yui_webhook.py run --webhook <url>")
            return 0
        if args.cmd == "guide":
            g = connect_call({"action": "guide"}).get("guide") or {}
            print(f"Yui channel guide {g.get('version')}\n\n{g.get('body', '')}")
            return 0
        b = Bridge(state, getattr(args, "webhook", None), getattr(args, "secret", None),
                   getattr(args, "interval", 2.0), getattr(args, "timeout", 300))
        if args.cmd == "status":
            b.session()
            print(f"connector: {state.data.get('connector', {}).get('name')} ({state.path}); agents: "
                  + (", ".join(f"{a['name']} ({a['remote_ref']})" for a in b.agents.values()) or "none"))
            return 0
        if args.cmd == "send":
            b.session()
            a = pick(b.agents, args.agent)
            if not a:
                sys.exit(f"no agent {args.agent!r} on this connector")
            mid = b.queue_reply(a["id"], args.text, None, None, handoff=True)
            try:
                b.flush_outbox()
            except Retry as e:
                log(f"{e}; it waits in the outbox and goes out with the next run")
            print(json.dumps({"message_id": mid, "agent": a["name"]}))
            return 0
        def on_term(*_):
            raise KeyboardInterrupt
        signal.signal(signal.SIGTERM, on_term)
        try:
            b.run()
        except KeyboardInterrupt:
            b.stop()
            log("stopped")
        return 0
    except Refused as e:
        print(f"yui: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())

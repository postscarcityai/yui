"""Key vault, host side (YUI-34 step 2). Spec: yuigui/spec/VAULT.md sections 3 and 4.

Two tools, neither of which ever holds a key:

  yui_key_ask(provider, for, est?, cap?)
      Asks the person to let this agent use one of their keys. It writes one
      control row (kind='control', sender='agent') for the app to draw as its own
      sheet, never a screen the agent draws:

          {"v": 1, "req": "k-19c4", "op": "key_ask", "provider": "fal",
           "for": "Draw your agent avatars", "est": "about 4 images a week", "cap": 5}

      Refused here, before anything is sent: an unknown provider, a `for` that is
      empty or over 80 characters, key-shaped text anywhere in the ask, a turn the
      owner did not start (a shared agent cannot ask for its client's keys), a
      provider the person declined in the last 24 hours, a second ask for the
      same provider while one is still waiting.

  vault_call(handle, path, body)
      POST <connector>/vault/v1/<handle>/<path> with this machine's own connection
      token. The connector checks the grant, the path and the cap, adds the real
      key and forwards to the provider's fixed host. What comes back is read to
      the model in plain words; every refusal (not_granted, cap_reached,
      path_not_allowed, key_rejected, once_used) says what to do next.

The person's answer comes back as a control row from them, op key_answer:

    {"v": 1, "req": "k-19c4", "op": "key_answer", "decision": "allow|once|deny",
     "provider": "fal", "handle": "vk_fal_3f9a", "cap": 5}

answer_line() turns it into the one line the agent reads on its next turn:

    [yui] Key access: fal allowed for "Draw your agent avatars", cap $5 a month, handle vk_fal_3f9a.
    [yui] Key access: fal not allowed.

A deny also starts the 24 hour no-nag here (the relay enforces the same rule; this
is the second lock and the reason the agent hears "declined today" at once).

State (open asks, declines) lives in <profile home>/yui/vault.json. Stdlib only.
"""

from __future__ import annotations

import fcntl
import json
import os
import re
import time
import urllib.error
import urllib.request
import uuid
from contextlib import contextmanager
from pathlib import Path
from typing import Callable, Optional

try:
    from . import connector, controls, talk
except ImportError:  # run as a script or loaded by path in tests
    import connector  # type: ignore[no-redef]
    import controls  # type: ignore[no-redef]
    import talk  # type: ignore[no-redef]

V = 1
PROVIDERS = ("fal", "replicate", "elevenlabs", "anthropic", "openai")
MAX_FOR = 80
MAX_EST = 80
MAX_CAP_DOLLARS = 1000
NO_NAG_SECONDS = 24 * 3600
WAIT_SECONDS = 3600            # an ask still unanswered this long can be asked again
TURN_SECONDS = talk.TURN_SECONDS
MAX_PATH = 300
MAX_BODY = 4 * 1024 * 1024
MAX_TEXT_BACK = 200_000
HANDLE = re.compile(r"^vk_[a-z]{2,20}_[0-9a-f]{4}$")
REQ = re.compile(r"^k-[0-9a-f]{4,12}$")

# Provider key shapes, on top of the host's own redaction (controls.KEYISH).
KEYSHAPE = re.compile(
    r"(\br8_[A-Za-z0-9]{16,}|\bsk-ant-[A-Za-z0-9_-]{8,}|\bsk-or-[A-Za-z0-9_-]{8,}|\bsk-[A-Za-z0-9_-]{16,}"
    r"|\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}:[0-9a-f]{16,}"
    r"|\bsk_[0-9a-f]{24,}|\bxi-[A-Za-z0-9_-]{16,})", re.I)

MESSAGES = {
    "provider": "provider is one of: " + ", ".join(PROVIDERS) + ".",
    "for": f"`for` is one short line the person reads, {MAX_FOR} characters at most.",
    "key": "That looks like it holds a key. Keys go in Yui's Settings > Keys, never through an agent.",
    "est": f"`est` is a few words, {MAX_EST} characters at most.",
    "cap": f"`cap` is a whole number of dollars a month, 1 to {MAX_CAP_DOLLARS}.",
    "owner": "Only the owner's own chat can ask for a key.",
    "thread": "No thread to ask in. Answer in the chat first.",
    "waiting": "That ask is still waiting for the person. Don't ask again yet.",
    "unreachable": "Couldn't reach Yui to ask. Try again in a minute.",
    "unpaired": "This machine is not paired with Yui.",
}

# What the agent should do about each refusal from the connector (spec section 5).
ERRORS = {
    "not_granted": "There is no live grant for that handle on this agent. Ask again once with yui_key_ask and a reason.",
    "cap_reached": "This month's cap on that key is spent. It resets on the 1st, or the person can raise it in your drawer. Tell them.",
    "path_not_allowed": "That endpoint is not on the provider's list. Nothing to tell the person: the call was wrong, fix the path.",
    "key_rejected": "The provider refused the key (revoked, or no credits). Tell the person it needs fixing in Settings > Keys.",
    "once_used": "The Allow once grant was already used. Ask again with yui_key_ask.",
}

SCHEMA = {
    "name": "yui_key_ask",
    "description": (
        "Ask the person to let you use one of their API keys (fal, replicate, elevenlabs, anthropic, openai) for a "
        "job that costs money. Yui draws the ask itself with Allow, Allow once and Don't allow; you never see the "
        "key. You hear the answer on your next turn as one `[yui] Key access: ...` line, with a handle like "
        "vk_fal_3f9a when allowed. Then call the provider with vault_call. `for` is one short line they read (80 "
        "characters). `est` (optional) is how much you expect to use, `cap` (optional) a suggested monthly cap in "
        "dollars. Never put a key, password or code in any of it, and never ask for one in chat. One ask at a time; "
        "after a Don't allow, don't ask for that provider again for a day."),
    "parameters": {
        "type": "object",
        "properties": {
            "provider": {"type": "string", "enum": list(PROVIDERS)},
            "for": {"type": "string", "description": "What you need it for, one line, 80 characters at most."},
            "est": {"type": "string", "description": "Optional: about how much, e.g. about 4 images a week."},
            "cap": {"type": "integer", "description": "Optional: suggested monthly cap in dollars."},
        },
        "required": ["provider", "for"],
    },
}

CALL_SCHEMA = {
    "name": "vault_call",
    "description": (
        "Call a provider through Yui's key vault with a handle you were given (vk_fal_3f9a), never a key. path is the "
        "provider's own path, e.g. `fal-ai/flux/dev`; body is the provider's own request body (an object). Yui's "
        "connector checks the grant, the path and the monthly cap, adds the real key and forwards to the provider's "
        "fixed host. Refusals come back in plain words: not_granted, cap_reached, path_not_allowed, key_rejected, "
        "once_used. Get a handle first with yui_key_ask."),
    "parameters": {
        "type": "object",
        "properties": {
            "handle": {"type": "string", "description": "The handle from the `[yui] Key access` line, like vk_fal_3f9a."},
            "path": {"type": "string", "description": "The provider's own request path, no host."},
            "body": {"type": "object", "description": "The provider's own request body."},
        },
        "required": ["handle", "path"],
    },
}


class Refused(Exception):
    pass


def keyish(text: str) -> bool:
    """Anything the host's redaction hides, or a provider key shape."""
    return bool(text) and (talk.keyish(text) or bool(KEYSHAPE.search(text)))


def scrub(text: str) -> str:
    """Key-shaped runs replaced in place (a response is one long line; hiding the whole line would hide the answer)."""
    return KEYSHAPE.sub("[hidden]", controls.KEYISH.sub("[hidden]", text or ""))


def state_path(home: Optional[Path] = None) -> Path:
    return (home or talk.profile_home()) / "yui" / "vault.json"


@contextmanager
def _state(home: Optional[Path] = None, clock: Callable[[], float] = time.time):
    path = state_path(home)
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path.with_suffix(".lock"), "a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            st = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
        except ValueError:
            st = {}
        st.setdefault("asks", {})
        st.setdefault("declined", {})
        yield st
        now = clock()
        st["asks"] = {k: a for k, a in st["asks"].items() if now - a.get("at", 0) < 7 * 86400}
        st["declined"] = {k: t for k, t in st["declined"].items() if now - t < NO_NAG_SECONDS}
        tmp = path.with_name(".vault.json.tmp")
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(json.dumps(st, indent=1))
        os.replace(tmp, path)


# -- the ask ------------------------------------------------------------------------

def declined_line(provider: str) -> str:
    return f"[yui] Key access: {provider} was declined today. Ask again tomorrow, or let them bring it up."


def build_ask(provider, for_, est=None, cap=None, req: Optional[str] = None) -> dict:
    """The key_ask meta, validated. Raises Refused with a plain message."""
    provider = str(provider or "").strip().lower()
    if provider not in PROVIDERS:
        raise Refused(MESSAGES["provider"])
    for_ = " ".join(str(for_ or "").split())
    if not for_ or len(for_) > MAX_FOR:
        raise Refused(MESSAGES["for"])
    meta = {"v": V, "req": req or "k-" + uuid.uuid4().hex[:4], "op": "key_ask", "provider": provider, "for": for_}
    if est not in (None, ""):
        est = " ".join(str(est).split())
        if len(est) > MAX_EST:
            raise Refused(MESSAGES["est"])
        meta["est"] = est
    if cap not in (None, ""):
        try:
            n = int(cap)
            ok = not isinstance(cap, bool) and n == float(cap) and 1 <= n <= MAX_CAP_DOLLARS
        except (TypeError, ValueError):
            ok = False
        if not ok:
            raise Refused(MESSAGES["cap"])
        meta["cap"] = n
    if any(keyish(str(v)) for k, v in meta.items() if k not in ("v", "req", "op", "provider", "cap")) \
            or keyish(provider):
        raise Refused(MESSAGES["key"])
    return meta


def rest_control_sender() -> Callable[[str, str, dict], Optional[str]]:
    """Write one control row from the agent into its owner's thread over REST with this machine's
    connector token (any process). No meta.turn: nothing about it wakes a mention or a group."""
    def send(agent_id: str, user_id: str, meta: dict) -> Optional[str]:
        token = connector.load().get("token")
        if not token:
            raise Refused(MESSAGES["unpaired"])
        s, sess = connector.call({"action": "session"}, token)
        if s != 200:
            raise Refused(MESSAGES["unreachable"])
        rid = str(uuid.uuid4())
        row = {"id": rid, "user_id": user_id, "agent_id": agent_id, "sender": "agent",
               "body": f"key access: {meta['provider']}", "kind": "control", "meta": meta}
        req = urllib.request.Request(
            f"{connector.SUPABASE_URL}/rest/v1/yui_messages", method="POST", data=json.dumps(row).encode(),
            headers={"content-type": "application/json", "apikey": connector.PUBLISHABLE,
                     "prefer": "return=minimal", "authorization": f"Bearer {sess['access_token']}"})
        with urllib.request.urlopen(req, timeout=20):
            pass
        return rid
    return send


def ask(provider, for_, est=None, cap=None, *, chat: Optional[str] = None, home: Optional[Path] = None,
        send: Optional[Callable[[str, str, dict], Optional[str]]] = None,
        clock: Callable[[], float] = time.time) -> dict:
    """Validate and send one key_ask. {"ok": True, "req", ...} or {"ok": False, "error", "message"}."""
    home = home or talk.profile_home()
    try:
        meta = build_ask(provider, for_, est, cap)
        t = talk.Talk(controls.Host(home), clock=clock)
        with t._state() as st:
            turn, owner_user = dict(st.get("turn") or {}), st.get("owner_user") or ""
        if chat:  # the tool knows its session: a shared thread's chat id is `<agent>~<user>`
            head = chat.split(":")[0]
            turn = {**turn, "key": chat, "owner": "~" not in head, "agent": head.split("~")[0],
                    "at": turn.get("at", 0) if turn.get("key") == chat else clock()}
        if not turn.get("owner") or clock() - turn.get("at", 0) > TURN_SECONDS:
            raise Refused(MESSAGES["owner"])
        user = owner_user or turn.get("user")
        if not user or not turn.get("agent"):
            raise Refused(MESSAGES["thread"])
        now = clock()
        with _state(home, clock) as st:
            if now - st["declined"].get(meta["provider"], 0) < NO_NAG_SECONDS:
                return {"ok": False, "error": "declined_today", "message": declined_line(meta["provider"])}
            for a in st["asks"].values():
                if a["provider"] == meta["provider"] and not a.get("answered") and now - a["at"] < WAIT_SECONDS:
                    raise Refused(MESSAGES["waiting"])
            st["asks"][meta["req"]] = {"provider": meta["provider"], "for": meta["for"], "at": now,
                                       "agent": turn["agent"], "user": user}
        try:
            mid = (send or rest_control_sender())(turn["agent"], user, meta)
        except Refused:
            _forget(meta["req"], home, clock)
            raise
        except Exception as e:
            _forget(meta["req"], home, clock)
            raise Refused(f"{MESSAGES['unreachable']} ({type(e).__name__})")
        return {"ok": True, "req": meta["req"], "message_id": mid,
                "say": "Yui is asking them now. The answer reaches you on your next turn as a "
                       "`[yui] Key access` line. Add nothing else about it."}
    except Refused as e:
        return {"ok": False, "error": "refused", "message": str(e)}


def _forget(req: str, home: Path, clock) -> None:
    with _state(home, clock) as st:
        st["asks"].pop(req, None)


# -- the answer ---------------------------------------------------------------------

def answer_of(row: dict) -> Optional[dict]:
    """The key_answer meta when the row is one from the person, else None. Anything malformed is None
    (it then falls through as an ordinary control row and is refused there)."""
    if row.get("kind") != "control" or row.get("sender", "user") != "user":
        return None
    m = row.get("meta")
    if not isinstance(m, dict) or m.get("op") != "key_answer" or m.get("v", V) != V:
        return None
    decision, provider = m.get("decision"), m.get("provider")
    if decision not in ("allow", "once", "deny") or provider not in PROVIDERS:
        return None
    if not isinstance(m.get("req"), str) or not REQ.match(m["req"]):
        return None
    handle = m.get("handle")
    if decision != "deny" and not (isinstance(handle, str) and HANDLE.match(handle) and handle.split("_")[1] == provider):
        return None
    cap = m.get("cap")
    if cap is not None and (isinstance(cap, bool) or not isinstance(cap, (int, float)) or cap < 0):
        return None
    return {"req": m["req"], "decision": decision, "provider": provider, "handle": handle if decision != "deny" else None,
            "cap": cap}


def dollars(cap) -> str:
    n = float(cap)
    return f"${int(n)}" if n == int(n) else f"${n:.2f}"


def answer_line(ans: dict, purpose: str = "") -> str:
    """The one line for the agent's next turn."""
    p = ans["provider"]
    if ans["decision"] == "deny":
        return f"[yui] Key access: {p} not allowed."
    what = f' for "{purpose}"' if purpose else ""
    cap = f", cap {dollars(ans['cap'])} a month" if ans.get("cap") is not None else ""
    if ans["decision"] == "once":
        return f"[yui] Key access: {p} allowed once{what}, one call, handle {ans['handle']}."
    return f"[yui] Key access: {p} allowed{what}{cap}, handle {ans['handle']}."


def take(ans: dict, *, home: Optional[Path] = None, clock: Callable[[], float] = time.time) -> str:
    """Settle an answer: mark the ask answered, start the no-nag on a deny, return the agent's line."""
    home = home or talk.profile_home()
    with _state(home, clock) as st:
        a = st["asks"].get(ans["req"]) or {}
        if a:
            a["answered"] = ans["decision"]
        if ans["decision"] == "deny":
            st["declined"][ans["provider"]] = clock()
        else:
            st["declined"].pop(ans["provider"], None)
        purpose = a.get("for", "")
    return answer_line(ans, purpose)


# -- the call -------------------------------------------------------------------------

def vault_base() -> str:
    """The connector's vault route. YUI_VAULT_BASE overrides; else the yui-vault Edge Function beside yui-connect."""
    return (os.getenv("YUI_VAULT_BASE") or f"{connector.SUPABASE_URL}/functions/v1/yui-vault").rstrip("/")


def clean_path(path) -> str:
    raw = str(path or "").strip()
    p = raw[1:] if raw.startswith("/") and not raw.startswith("//") else raw
    low = p.lower()
    if (not p or len(p) > MAX_PATH or any(c in p for c in "\\#@ \t\r\n\x00") or "://" in p or "//" in p
            or "%2e" in low or "%2f" in low or "%5c" in low or ".." in p.split("?")[0].split("/")):
        raise Refused("path is the provider's own path, like fal-ai/flux/dev: no host, no dots, no spaces.")
    return p


def call(handle, path, body=None, *, opener=None) -> tuple[int, dict, bytes, str]:
    """POST the connector. (status, json or {}, raw bytes, content type). Raises Refused before any call."""
    handle = str(handle or "").strip()
    if not HANDLE.match(handle):
        raise Refused("handle looks like vk_fal_3f9a. Get one with yui_key_ask.")
    path = clean_path(path)
    token = connector.load().get("token")
    if not token:
        raise Refused(MESSAGES["unpaired"])
    data = b"" if body is None else json.dumps(body).encode()
    if len(data) > MAX_BODY:
        raise Refused("That request body is too big.")
    req = urllib.request.Request(
        f"{vault_base()}/vault/v1/{handle}/{path}", data=data or b"{}", method="POST",
        headers={"content-type": "application/json", "apikey": connector.PUBLISHABLE, "user-agent": "yui-connect",
                 "authorization": f"Bearer {token}"})
    try:
        with (opener or urllib.request.urlopen)(req, timeout=120) as r:
            raw = r.read() or b""
            return r.status, _json(raw), raw, r.headers.get("content-type", "") if getattr(r, "headers", None) else ""
    except urllib.error.HTTPError as e:
        raw = e.read() or b""
        return e.code, _json(raw), raw, ""
    except (urllib.error.URLError, TimeoutError) as e:
        return 503, {"error": "unreachable", "message": scrub(str(e))}, b"", ""


def _json(raw: bytes) -> dict:
    try:
        v = json.loads(raw or b"{}")
        return v if isinstance(v, dict) else {"result": v}
    except ValueError:
        return {}


def result(handle, path, body=None, *, opener=None, home: Optional[Path] = None) -> dict:
    """What the model is told. Never raises."""
    try:
        status, j, raw, ctype = call(handle, path, body, opener=opener)
    except Refused as e:
        return {"ok": False, "error": "refused", "message": str(e)}
    if status >= 400:
        code = str(j.get("error") or f"http_{status}")
        say = ERRORS.get(code) or ("Yui can't be reached right now. Try again in a minute." if code == "unreachable"
                                   else f"The vault answered {status} ({code}).")
        return {"ok": False, "status": status, "error": code, "say": say}
    if not raw or "json" in ctype or "text" in ctype or _texty(raw):
        text = scrub(raw.decode("utf-8", "replace"))
        if len(text) > MAX_TEXT_BACK:
            return {"ok": True, "status": status, "body": text[:MAX_TEXT_BACK], "clipped": True}
        try:
            return {"ok": True, "status": status, "body": json.loads(text or "{}")}
        except ValueError:
            return {"ok": True, "status": status, "body": text}
    d = (home or talk.profile_home()) / "yui" / "vault-out"
    d.mkdir(parents=True, exist_ok=True)
    f = d / f"{int(time.time())}-{uuid.uuid4().hex[:6]}.bin"
    fd = os.open(f, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "wb") as fh:
        fh.write(raw)
    return {"ok": True, "status": status, "content_type": ctype, "bytes": len(raw), "file": str(f)}


def _texty(raw: bytes) -> bool:
    try:
        raw[:2000].decode("utf-8")
        return b"\x00" not in raw[:2000]
    except UnicodeDecodeError:
        return False


# -- tools + CLI ----------------------------------------------------------------------

def _session_chat() -> tuple[Optional[str], str]:
    try:
        from gateway.session_context import get_session_env
        return get_session_env("HERMES_SESSION_CHAT_ID") or None, get_session_env("HERMES_SESSION_PLATFORM") or ""
    except Exception:
        return None, ""


def tool_handler(args: dict, **kw) -> str:
    """yui_key_ask, for hosts whose model calls Hermes tools."""
    chat, platform = _session_chat()
    if platform and platform != "yui":
        return json.dumps({"ok": False, "error": "refused", "message": "Only on the Yui channel."})
    return json.dumps(ask(args.get("provider"), args.get("for"), args.get("est"), args.get("cap"), chat=chat))


def call_handler(args: dict, **kw) -> str:
    """vault_call, for hosts whose model calls Hermes tools."""
    return json.dumps(result(args.get("handle"), args.get("path"), args.get("body")))


def cmd_key_ask(args) -> int:
    out = ask(args.provider, getattr(args, "for_"), args.est, args.cap)
    print(json.dumps(out))
    return 0 if out.get("ok") else 3


def cmd_vault_call(args) -> int:
    body = json.loads(args.body) if args.body else None
    out = result(args.handle, args.path, body)
    print(json.dumps(out))
    return 0 if out.get("ok") else 1


def add_cli(sub) -> None:
    k = sub.add_parser("key-ask", help="ask the person to let this agent use one of their keys (yui_key_ask)")
    k.add_argument("provider", choices=list(PROVIDERS))
    k.add_argument("--for", dest="for_", required=True, help="what for, one line, 80 characters at most")
    k.add_argument("--est", help="about how much")
    k.add_argument("--cap", type=int, help="suggested monthly cap in dollars")
    k.set_defaults(fn=cmd_key_ask)
    c = sub.add_parser("vault-call", help="call a provider through the key vault with a handle (vault_call)")
    c.add_argument("handle")
    c.add_argument("path")
    c.add_argument("--body", help="the provider's request body, as JSON")
    c.set_defaults(fn=cmd_vault_call)

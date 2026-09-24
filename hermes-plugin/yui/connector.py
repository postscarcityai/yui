#!/usr/bin/env python3
"""Host side of the Yui agent registry (spec: yuigui/spec/AGENTS.md).

The `yui` Hermes plugin exposes these as `hermes -p <profile> yui pair|add|status`.
They also run without Hermes loaded:

    connector.py pair 123456 --profile yui     # code from the app's Add agent
    connector.py add --profile monk [--name Monk] [--color mint]
    connector.py heartbeat
    connector.py status
    connector.py media ~/out/frame.png "Frame 1" --profile monk   # send a picture
    connector.py media --prompt "storyboard frame: ..." --aspect 16:9  # render + send

One connector per machine: its token lives in ~/.hermes/yui/connector.json
(mode 600) and every profile on this machine shares it. Stdlib only.
"""
import argparse, json, os, socket, subprocess, sys, urllib.error, urllib.request
from pathlib import Path

SUPABASE_URL = "https://ewzzaoperdpxqxkshynx.supabase.co"
BASE = f"{SUPABASE_URL}/functions/v1/yui-connect"
# Public client key (anon role only; it cannot read any yui_ table).
PUBLISHABLE = "sb_publishable_OhqLI7p27yiELT4tn8i7JA_TnnwPYsS"
COLORS = ["lavender", "mint", "butter", "brand"]


def hermes_root() -> Path:
    """~/.hermes, even when HERMES_HOME points at a profile."""
    home = Path(os.environ.get("HERMES_HOME") or Path.home() / ".hermes")
    return home.parent.parent if home.parent.name == "profiles" else home


STATE = Path(os.environ.get("YUI_CONNECTOR_FILE") or hermes_root() / "yui" / "connector.json")


def current_profile() -> str | None:
    """The Hermes profile this process runs as (`default` for ~/.hermes)."""
    if os.environ.get("HERMES_PROFILE"):
        return os.environ["HERMES_PROFILE"]
    home = os.environ.get("HERMES_HOME")
    if not home:
        return None
    p = Path(home)
    return p.name if p.parent.name == "profiles" else "default"


def load() -> dict:
    try:
        return json.loads(STATE.read_text())
    except (FileNotFoundError, ValueError):
        return {}


def save(state: dict) -> None:
    STATE.parent.mkdir(parents=True, exist_ok=True)
    tmp = STATE.with_suffix(".tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(state, f, indent=2)
    os.replace(tmp, STATE)


def call(body: dict, token: str | None = None) -> tuple[int, dict]:
    headers = {"content-type": "application/json", "apikey": PUBLISHABLE, "user-agent": "yui-connect"}
    if token:
        headers["authorization"] = f"Bearer {token}"
    req = urllib.request.Request(BASE, data=json.dumps(body).encode(), method="POST", headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read() or b"{}")
        except ValueError:
            return e.code, {"error": f"http_{e.code}"}


def host_name() -> str:
    try:
        return subprocess.check_output(["/usr/sbin/scutil", "--get", "ComputerName"], text=True).strip()
    except (OSError, subprocess.CalledProcessError):
        return socket.gethostname().split(".")[0]


def show(agent: dict) -> str:
    return f"{agent['name']} (@{agent['handle']}, profile {agent.get('remote_ref')}, {agent['status']})"


def pair(code: str, profile: str, host: str | None = None) -> tuple[int, dict]:
    state = load()
    s, r = call({"action": "pair", "code": code, "remote_ref": profile,
                 "host_name": host or host_name(), "kind": "hermes"}, state.get("token"))
    if r.get("connector_token"):
        # New connector for this machine (first pairing, or a different Yui account).
        save({"token": r["connector_token"], "connector_id": r.get("connector", {}).get("id"),
              "name": r.get("connector", {}).get("name")})
    return s, r


def add(profile: str, name: str | None = None, color: str | None = None) -> tuple[int, dict]:
    token = load().get("token")
    if not token:
        return 401, {"error": "not_paired"}
    body = {"action": "add", "remote_ref": profile}
    if name:
        body["name"] = name
    if color:
        body["color"] = color
    return call(body, token)


def pick_agent(agents: list, ref: str, chat_id: str | None) -> tuple[dict | None, str | None]:
    """Which Yui thread a send from profile `ref` lands in, and who it is from.

    Own agents first (remote_ref == ref), then any agent on this machine by id,
    handle, profile or name. A bare target or the profile's own name (its home
    channel) falls back to the user's first agent when the profile has no Yui
    agent of its own: Urza on Telegram can still hand something to the phone.
    The second value names the sending profile when the thread is another
    agent's, so the push reads "Urza has something for you in Yui".
    """
    mine = [a for a in agents if a.get("remote_ref") == ref]
    want = (chat_id or "").strip().lower()
    if want:
        for pool in (mine, agents):
            for a in pool:
                if want in {str(a.get(k) or "").lower() for k in ("id", "handle", "remote_ref", "name")}:
                    return a, None if a.get("remote_ref") == ref else nice_name(ref)
    if not want or want in (ref.lower(), "home", "default"):
        if mine:
            return mine[0], None
        if agents:
            return agents[0], nice_name(ref)
    return None, None


def nice_name(ref: str) -> str:
    """"urza" -> "Urza", "sean-rush" -> "Sean Rush" (same rule as yui-connect)."""
    return " ".join(w[:1].upper() + w[1:] for w in ref.replace("_", "-").replace(".", "-").split("-") if w)[:40] or "Agent"


PUSH = f"{SUPABASE_URL}/functions/v1/yui-push"


def notify_body(message_id: str, sender: str | None, handoff: bool) -> dict:
    """Body for yui-push action=notify (the host just wrote `message_id`)."""
    body = {"action": "notify", "message_id": message_id, "handoff": handoff}
    if sender:
        body["from"] = sender
    return body


def heartbeat() -> tuple[int, dict]:
    token = load().get("token")
    if not token:
        return 401, {"error": "not_paired"}
    return call({"action": "heartbeat"}, token)


# -- CLI (shared with `hermes yui ...`) --------------------------------------

NOT_PAIRED = "this machine is not paired yet: add an agent in the app and run `pair <code>` first"


def _profile(args) -> str:
    p = getattr(args, "profile", None) or current_profile()
    if not p:
        sys.exit("which agent? pass --profile <hermes profile>")
    return p


def cmd_pair(args) -> int:
    s, r = pair(args.code, _profile(args), args.host_name)
    if s != 200:
        print(f"pair failed: {r.get('error', s)}", file=sys.stderr)
        return 1
    print(f"paired: {show(r['agent'])} on {r['connector']['name']}")
    return 0


def cmd_add(args) -> int:
    s, r = add(_profile(args), args.name, args.color)
    if r.get("error") == "not_paired":
        sys.exit(NOT_PAIRED)
    if s != 200:
        print(f"add failed: {r.get('error', s)}", file=sys.stderr)
        return 1
    print(("added: " if r["created"] else "already there: ") + show(r["agent"]))
    return 0


def cmd_heartbeat(args) -> int:
    s, r = heartbeat()
    if r.get("error") == "not_paired":
        sys.exit("not paired")
    if s != 200:
        print(f"heartbeat failed: {r.get('error', s)}", file=sys.stderr)
        return 1
    if getattr(args, "quiet", False):
        return 0
    print(f"{r['connector']['name']} online at {r['seen_at']}; agents: "
          + (", ".join(f"{a['name']} ({a['remote_ref']})" for a in r["agents"]) or "none"))
    return 0


def cmd_status(args) -> int:
    state = load()
    print(f"connector: {state.get('name') or 'not paired'} ({STATE})")
    return cmd_heartbeat(args) if state.get("token") else 0


def cmd_media(args) -> int:
    """Send a picture or video (a file, a URL, or one rendered from --prompt) into the thread."""
    try:
        from . import media
    except ImportError:  # run as a script
        import media
    token = load().get("token")
    if not token:
        sys.exit(NOT_PAIRED)
    s, sess = call({"action": "session"}, token)
    if s != 200:
        print(f"session failed: {sess.get('error', s)}", file=sys.stderr)
        return 1
    ref = _profile(args)
    target, sender = pick_agent(sess.get("agents") or [], ref, args.to)
    if not target:
        print(f"no Yui agent {args.to or ref!r} on this machine", file=sys.stderr)
        return 1
    try:
        src = args.src
        if args.prompt:
            src = media.generate(args.prompt, args.aspect, edit=args.src)
        if not src:
            sys.exit("give a file or URL, or --prompt")
        data, ctype = media.read_source(src)
        path = media.upload(sess["access_token"], sess["user_id"], target["id"], data, ctype)
        url = media.sign(sess["access_token"], path)
    except media.MediaError as e:
        print(f"media failed: {e}", file=sys.stderr)
        return 1
    preset = "video" if ctype.startswith("video/") else "image"
    line = f"{preset} {url}" + (f" {json.dumps(args.caption)}" if args.caption else "")
    body = ((args.text.strip() + "\n\n") if args.text else "") + f"```yui\n{line}\n```"
    req = urllib.request.Request(f"{SUPABASE_URL}/rest/v1/yui_messages", method="POST", data=json.dumps({
        "user_id": sess["user_id"], "agent_id": target["id"], "sender": "agent", "body": body, "kind": "text",
    }).encode(), headers={"content-type": "application/json", "apikey": PUBLISHABLE, "prefer": "return=representation",
                          "authorization": f"Bearer {sess['access_token']}"})
    with urllib.request.urlopen(req, timeout=20) as r:
        mid = json.loads(r.read())[0]["id"]
    ps, pushed = call_push(notify_body(mid, sender, True), token)
    print(json.dumps({"success": True, "message_id": mid, "agent": target["name"], "path": path,
                      "pushed_to": pushed.get("delivered", 0)}))
    return 0


def call_push(body: dict, token: str) -> tuple[int, dict]:
    req = urllib.request.Request(PUSH, data=json.dumps(body).encode(), method="POST", headers={
        "content-type": "application/json", "apikey": PUBLISHABLE, "authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, {}


def build_parser(ap: argparse.ArgumentParser, with_profile: bool = True) -> None:
    sub = ap.add_subparsers(dest="yui_cmd", required=True)
    p = sub.add_parser("pair", help="bind this Hermes profile to the agent the app just made")
    p.add_argument("code")
    p.add_argument("--host-name")
    p.set_defaults(fn=cmd_pair)
    a = sub.add_parser("add", help="register this profile on an already-paired machine")
    a.add_argument("--name")
    a.add_argument("--color", choices=COLORS)
    a.set_defaults(fn=cmd_add)
    h = sub.add_parser("heartbeat", help="mark this machine online")
    h.add_argument("--quiet", "-q", action="store_true")
    h.set_defaults(fn=cmd_heartbeat)
    st = sub.add_parser("status", help="show the connector and its agents")
    st.set_defaults(fn=cmd_status, quiet=False)
    m = sub.add_parser("media", help="send a picture or video into the thread; --prompt renders one first (fal)")
    m.add_argument("src", nargs="?", help="file or URL (with --prompt: the image to edit)")
    m.add_argument("caption", nargs="?")
    m.add_argument("--prompt", help="render with fal nano-banana-2 (FAL_KEY), then send")
    m.add_argument("--aspect", default="1:1", help="aspect ratio for --prompt, e.g. 16:9, 9:16")
    m.add_argument("--text", help="chat text to send above it")
    m.add_argument("--to", help="which Yui agent's thread (default: this profile's)")
    m.set_defaults(fn=cmd_media)
    if with_profile:
        for sp in (p, a, m):
            sp.add_argument("--profile", "-p", help="Hermes profile (default: the active one)")


def dispatch(args) -> int:
    return args.fn(args)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    build_parser(ap)
    return dispatch(ap.parse_args())


if __name__ == "__main__":
    sys.exit(main())

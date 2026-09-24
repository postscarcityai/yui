#!/usr/bin/env python3
"""Host side of the Yui agent registry (spec: yuigui/spec/AGENTS.md).

The YUI-7 Hermes plugin exposes these as `hermes -p <profile> yui pair|add`.
Until then, run it directly:

    yui_connect.py pair 123456 --profile yui     # code from the app's Add agent
    yui_connect.py add --profile monk [--name Monk] [--color mint]
    yui_connect.py heartbeat
    yui_connect.py status

One connector per machine: its token lives in ~/.hermes/yui/connector.json
(mode 600) and every profile on this machine shares it. Stdlib only.
"""
import argparse, json, os, socket, subprocess, sys, urllib.error, urllib.request
from pathlib import Path

BASE = "https://ewzzaoperdpxqxkshynx.supabase.co/functions/v1/yui-connect"
# Public client key (anon role only; it cannot read any yui_ table).
PUBLISHABLE = "sb_publishable_OhqLI7p27yiELT4tn8i7JA_TnnwPYsS"
STATE = Path(os.environ.get("HERMES_HOME", Path.home() / ".hermes")) / "yui" / "connector.json"


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


def profile(args) -> str:
    p = args.profile or os.environ.get("HERMES_PROFILE")
    if not p:
        sys.exit("which agent? pass --profile <hermes profile>")
    return p


def show(agent: dict) -> str:
    return f"{agent['name']} (@{agent['handle']}, profile {agent.get('remote_ref')}, {agent['status']})"


def cmd_pair(args) -> int:
    state = load()
    s, r = call({"action": "pair", "code": args.code, "remote_ref": profile(args),
                 "host_name": args.host_name or host_name(), "kind": "hermes"}, state.get("token"))
    if r.get("connector_token"):
        # New connector for this machine (first pairing, or a different Yui account).
        save({"token": r["connector_token"], "connector_id": r.get("connector", {}).get("id"),
              "name": r.get("connector", {}).get("name")})
    if s != 200:
        print(f"pair failed: {r.get('error', s)}", file=sys.stderr)
        return 1
    print(f"paired: {show(r['agent'])} on {r['connector']['name']}")
    return 0


def cmd_add(args) -> int:
    token = load().get("token")
    if not token:
        sys.exit("this machine is not paired yet: add an agent in the app and run `pair <code>` first")
    body = {"action": "add", "remote_ref": profile(args)}
    if args.name:
        body["name"] = args.name
    if args.color:
        body["color"] = args.color
    s, r = call(body, token)
    if s != 200:
        print(f"add failed: {r.get('error', s)}", file=sys.stderr)
        return 1
    print(("added: " if r["created"] else "already there: ") + show(r["agent"]))
    return 0


def cmd_heartbeat(args) -> int:
    token = load().get("token")
    if not token:
        sys.exit("not paired")
    s, r = call({"action": "heartbeat"}, token)
    if s != 200:
        print(f"heartbeat failed: {r.get('error', s)}", file=sys.stderr)
        return 1
    if args.quiet:
        return 0
    print(f"{r['connector']['name']} online at {r['seen_at']}; agents: "
          + (", ".join(f"{a['name']} ({a['remote_ref']})" for a in r["agents"]) or "none"))
    return 0


def cmd_status(args) -> int:
    state = load()
    print(f"connector: {state.get('name') or 'not paired'} ({STATE})")
    return cmd_heartbeat(args) if state.get("token") else 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("pair", help="bind a Hermes profile to the agent the app just made")
    p.add_argument("code")
    p.add_argument("--profile", "-p")
    p.add_argument("--host-name")
    p.set_defaults(fn=cmd_pair)
    a = sub.add_parser("add", help="register another profile on this already-paired machine")
    a.add_argument("--profile", "-p")
    a.add_argument("--name")
    a.add_argument("--color", choices=["lavender", "mint", "butter", "brand"])
    a.set_defaults(fn=cmd_add)
    h = sub.add_parser("heartbeat", help="mark this machine online")
    h.add_argument("--quiet", "-q", action="store_true")
    h.set_defaults(fn=cmd_heartbeat)
    st = sub.add_parser("status")
    st.set_defaults(fn=cmd_status, quiet=False)
    args = ap.parse_args()
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())

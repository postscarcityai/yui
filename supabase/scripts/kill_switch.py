#!/usr/bin/env python3
"""YUI-26 kill switch: stop one Yui account or one agent host, and bring it back.

    kill_switch.py status
    kill_switch.py suspend user <yui_users.id> --reason "spam"
    kill_switch.py suspend connector <yui_connectors.id> --reason "flooding"
    kill_switch.py restore user <id>
    kill_switch.py restore connector <id>

Suspending takes effect on the next request, including tokens minted before:
a suspended account cannot send, upload, manage agents, refresh its session or
connect a host; a suspended host cannot read, write, upload, connect or push.
Nothing is deleted, and the account's sessions survive, so `restore` puts it
all back. Rule: migration 20260924070000_yui_limits.sql, README "Limits".

Needs a Supabase access token (SUPABASE_ACCESS_TOKEN or the CLI's keychain
entry), like the tests. Prints ids only, never emails.
"""
import argparse, base64, json, os, re, subprocess, sys, urllib.error, urllib.request

REF = "ewzzaoperdpxqxkshynx"
UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")


def access_token() -> str:
    t = os.environ.get("SUPABASE_ACCESS_TOKEN")
    if t:
        return t
    raw = subprocess.check_output(["security", "find-generic-password", "-s", "Supabase CLI", "-w"]).decode().strip()
    return base64.b64decode(raw.removeprefix("go-keyring-base64:")).decode()


def sql(q: str):
    req = urllib.request.Request(f"https://api.supabase.com/v1/projects/{REF}/database/query",
                                 data=json.dumps({"query": q}).encode(), method="POST",
                                 headers={"authorization": f"Bearer {access_token()}",
                                          "content-type": "application/json", "user-agent": "yui-kill-switch"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        sys.exit(f"query failed: {e.code} {e.read().decode()[:300]}")


def lit(s: str) -> str:
    return "'" + s.replace("'", "''") + "'"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("status")
    for name in ("suspend", "restore"):
        p = sub.add_parser(name)
        p.add_argument("kind", choices=["user", "connector"])
        p.add_argument("id")
        if name == "suspend":
            p.add_argument("--reason", required=True)
    a = ap.parse_args()

    if a.cmd == "status":
        rows = sql("""select 'user' kind, id, suspended_at, suspended_reason from yui_users where suspended_at is not null
                      union all
                      select 'connector', id, suspended_at, suspended_reason from yui_connectors where suspended_at is not null
                      order by suspended_at""")
        print(f"{len(rows)} suspended")
        for r in rows:
            print(f"  {r['kind']:<9} {r['id']}  since {r['suspended_at']}  {r['suspended_reason'] or ''}")
        return 0

    if not UUID.match(a.id):
        sys.exit("id must be a uuid")
    on = a.cmd == "suspend"
    reason = lit(a.reason) if on else "null"
    r = sql(f"select public.yui_suspend({lit(a.kind)}, {lit(a.id)}::uuid, {str(on).lower()}, {reason}) at")
    print(f"{a.kind} {a.id} {'suspended at ' + r[0]['at'] if on else 'restored'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

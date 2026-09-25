#!/usr/bin/env python3
"""YUI-21 media sweep: retention first (YUI-26), then orphaned media.

Retention: public.yui_retention() deletes messages older than
message_retention_days (yui_limits, README "Limits") and expired
housekeeping rows. The pictures those messages used become orphans and go in
the media pass once the grace period has run.

An object is an orphan when its owner or agent is gone (account or agent
deleted, or yui-delete could not reach Storage), or when it is older than the
grace period and no message ever referenced it (an upload whose send failed,
or a message the person deleted). The rule lives in SQL:
public.yui_media_orphans(grace), migration 20260924040000_yui_media.sql.

Invites (YUI-56): a declined invite is deleted 30 days after it was declined
(yuigui.com/privacy says so).

Test builds (YUI-55): everything in the private `yui-builds` bucket older than
8 days goes too. Its signed links last 7 days, so nothing live is removed.

    media_sweep.py            # dry run: count and list
    media_sweep.py --delete   # apply retention, then remove orphans
    media_sweep.py --grace '6 hours'

Needs a Supabase access token (SUPABASE_ACCESS_TOKEN or the CLI's keychain
entry), like the tests. Keys are fetched at run time and never written down.
"""
import argparse, base64, json, os, subprocess, sys, urllib.error, urllib.request

REF = "ewzzaoperdpxqxkshynx"
BASE = f"https://{REF}.supabase.co"


def access_token() -> str:
    t = os.environ.get("SUPABASE_ACCESS_TOKEN")
    if t:
        return t
    raw = subprocess.check_output(["security", "find-generic-password", "-s", "Supabase CLI", "-w"]).decode().strip()
    return base64.b64decode(raw.removeprefix("go-keyring-base64:")).decode()


def http(method, url, headers, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method,
                                 headers={"content-type": "application/json", "user-agent": "yui-media-sweep", **headers})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            txt = r.read().decode()
            return r.status, json.loads(txt) if txt else None
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--delete", action="store_true")
    ap.add_argument("--grace", default="1 day")
    args = ap.parse_args()
    mgmt = {"authorization": f"Bearer {access_token()}"}
    s, rows = http("POST", f"https://api.supabase.com/v1/projects/{REF}/database/query", mgmt,
                   {"query": f"select * from public.yui_retention({'false' if args.delete else 'true'})"})
    if s >= 300:
        print(f"retention failed: {s} {rows}", file=sys.stderr)
        return 1
    print(("retention removed " if args.delete else "retention due: ")
          + ", ".join(f"{r['n_rows']} {r['what']}" for r in rows))
    where = "from public.yui_invites where status = 'declined' and declined_at < now() - interval '30 days'"
    s, rows = http("POST", f"https://api.supabase.com/v1/projects/{REF}/database/query", mgmt,
                   {"query": (f"with d as (delete {where} returning 1) select count(*) n from d" if args.delete
                              else f"select count(*) n {where}")})
    if s >= 300:
        print(f"invite retention failed: {s} {rows}", file=sys.stderr)
        return 1
    print(("removed " if args.delete else "due: ") + f"{rows[0]['n']} declined invite(s)")
    grace = args.grace.replace("'", "")
    s, rows = http("POST", f"https://api.supabase.com/v1/projects/{REF}/database/query", mgmt,
                   {"query": f"select public.yui_media_orphans('{grace}'::interval) as name"})
    if s >= 300:
        print(f"query failed: {s} {rows}", file=sys.stderr)
        return 1
    names = [r["name"] for r in rows]
    print(f"{len(names)} orphaned object(s) in yui-media (grace {grace})")
    for n in names[:20]:
        print("  " + n)
    s, rows = http("POST", f"https://api.supabase.com/v1/projects/{REF}/database/query", mgmt,
                   {"query": "select name from storage.objects where bucket_id = 'yui-builds'"
                             " and created_at < now() - interval '8 days'"})
    if s >= 300:
        print(f"builds query failed: {s} {rows}", file=sys.stderr)
        return 1
    builds = [r["name"] for r in rows]
    print(f"{len(builds)} old test build file(s) in yui-builds")
    if not args.delete or not (names or builds):
        return 0
    s, keys = http("GET", f"https://api.supabase.com/v1/projects/{REF}/api-keys?reveal=true", mgmt)
    secret = next(k["api_key"] for k in keys if k["type"] == "secret")
    removed = 0
    for bucket, objs in (("yui-media", names), ("yui-builds", builds)):
        for i in range(0, len(objs), 1000):
            s, r = http("DELETE", f"{BASE}/storage/v1/object/{bucket}",
                        {"apikey": secret, "authorization": f"Bearer {secret}"}, {"prefixes": objs[i:i + 1000]})
            if s >= 300:
                print(f"remove failed: {s} {r}", file=sys.stderr)
                return 1
            removed += len(r or [])
    print(f"removed {removed}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

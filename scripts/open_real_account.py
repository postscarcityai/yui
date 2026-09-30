#!/usr/bin/env python3
"""YUI-231: Open on Yui's card on a REAL account. Fresh throwaway account on the live backend (never
Chris's, never the demo account), chat first, then YuiUITests/OpenRealAccountTests.

  python3 scripts/open_real_account.py --sim UDID --out DIR [--appearance dark|light] [--build]

--build builds for testing first. The account is deleted at the end (0 rows left is printed)."""
import argparse, hashlib, os, secrets, subprocess, sys, uuid
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
ap = argparse.ArgumentParser()
ap.add_argument("--sim", required=True); ap.add_argument("--out", required=True)
ap.add_argument("--appearance", default="dark"); ap.add_argument("--build", action="store_true")
args = ap.parse_args()

exec(open(REPO / "supabase/tests/agents_test.py").read().split("results = []")[0])
OUT = Path(args.out); OUT.mkdir(parents=True, exist_ok=True)
DEV = {**os.environ, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"}
dest = ["-project", "Yui.xcodeproj", "-scheme", "Yui", "-destination", f"id={args.sim}", "-derivedDataPath", "build/dd"]
if args.build:
    subprocess.run(["xcodebuild", "build-for-testing", *dest], cwd=REPO, env=DEV, check=True,
                   stdout=open(OUT / "build.log", "w"), stderr=subprocess.STDOUT)
T = str(uuid.uuid4())
sql(f"insert into yui_users(id, apple_sub, timezone) values ('{T}','test.{T}','America/New_York')")
rt = secrets.token_urlsafe(32)
sql(f"insert into yui_sessions(user_id, refresh_hash, expires_at) values ('{T}','{hashlib.sha256(rt.encode()).hexdigest()}', now() + interval '1 day')")
print("account", T, flush=True)
env = {**DEV, "TEST_RUNNER_YUI_RT": rt, "TEST_RUNNER_YUI_USER": T, "TEST_RUNNER_YUI_SHOTS": str(OUT),
       "TEST_RUNNER_YUI_APPEARANCE": args.appearance}
code = 1
try:
    subprocess.run(["xcrun", "simctl", "ui", args.sim, "appearance", args.appearance], env=DEV)
    code = subprocess.run(["xcodebuild", "test-without-building", *dest, "-only-testing:YuiUITests/OpenRealAccountTests"],
                          cwd=REPO, env=env, stdout=open(OUT / "xcodebuild.log", "w"), stderr=subprocess.STDOUT).returncode
    print("xcodebuild exit", code)
finally:
    if code:  # a failing run: what the thread held, before the account goes
        try:
            rows = sql(f"select a.name, m.sender, left(m.body, 400) as body from yui_messages m join yui_agents a on a.id = m.agent_id where m.user_id = '{T}' order by m.created_at")
            (OUT / "thread.txt").write_text("\n".join(f"[{r['name']}/{r['sender']}] {r['body']}" for r in rows))
        except Exception as e:
            print("thread dump failed", e)
    left = sql("select " + " + ".join(f"(select count(*) from {t} where user_id = '{T}')" for t in
               ["yui_agents", "yui_messages", "yui_sessions", "yui_connectors", "yui_devices"]) + f" + (select count(*) from yui_users where id='{T}') as n")[0]["n"]
    if left:
        s, r = fn("yui-delete", {}, mint(T, ttl=300)); print("cleanup delete", s)
        sql(f"delete from yui_users where id = '{T}'")
        left = sql("select " + " + ".join(f"(select count(*) from {t} where user_id = '{T}')" for t in
                   ["yui_agents", "yui_messages", "yui_sessions", "yui_connectors", "yui_devices"]) + f" + (select count(*) from yui_users where id='{T}') as n")[0]["n"]
    print("rows left:", left, flush=True)
sys.exit(code)

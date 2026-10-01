#!/usr/bin/env python3
"""YUI-254: past chats in the drawer on a REAL account. A throwaway account on the live backend
(never Chris's, never the demo account) is seeded the way his is: one old first chat holding a long
history (130 rows, more than the 100 a thread opens on), a titled chat and an untitled one. Then
YuiUITests/PastChatsRealAccountTests runs against it. The account is deleted at the end.

  python3 scripts/past_chats_real_account.py --sim UDID --out DIR [--appearance dark|light] [--build]
"""
import argparse, hashlib, os, secrets, subprocess, sys, uuid
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
ap = argparse.ArgumentParser()
ap.add_argument("--sim", required=True); ap.add_argument("--out", required=True)
ap.add_argument("--appearance", default="dark"); ap.add_argument("--build", action="store_true")
ap.add_argument("--only", default="PastChatsRealAccountTests")
args = ap.parse_args()

exec(open(REPO / "supabase/tests/agents_test.py").read().split("results = []")[0])
OUT = Path(args.out); OUT.mkdir(parents=True, exist_ok=True)
DEV = {**os.environ, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"}
dest = ["-project", "Yui.xcodeproj", "-scheme", "Yui", "-destination", f"id={args.sim}", "-derivedDataPath", "build/dd"]
if args.build:
    subprocess.run(["xcodebuild", "build-for-testing", *dest], cwd=REPO, env=DEV, check=True,
                   stdout=open(OUT / "build.log", "w"), stderr=subprocess.STDOUT)
T = str(uuid.uuid4()); A = str(uuid.uuid4())
C1, C2, C3 = (str(uuid.uuid4()) for _ in range(3))
sql(f"insert into yui_users(id, apple_sub, timezone) values ('{T}','test.{T}','America/New_York')")
sql(f"insert into yui_agents(id, user_id, name, handle, kind, is_default) values ('{A}','{T}','Basil','basil','hermes', true)")
sql(f"insert into yui_crew_choice(user_id, picked_at, own) values ('{T}', now(), true)")  # long-time account: no crew picker
rt = secrets.token_urlsafe(32)
sql(f"insert into yui_sessions(user_id, refresh_hash, expires_at) values ('{T}','{hashlib.sha256(rt.encode()).hexdigest()}', now() + interval '1 day')")

def say(chat, sender, body, ago_minutes, first_row=False):
    meta = "'{}'::jsonb" if sender == "user" else f"jsonb_build_object('chat','{chat}')"
    col, val = ("chat_id, ", f"'{chat}', ") if sender == "user" else ("", "")
    return (f"insert into yui_messages(user_id, agent_id, {col}sender, body, meta, created_at) values "
            f"('{T}','{A}',{val}'{sender}','{body}',{meta}, now() - interval '{ago_minutes} minutes');")

# The first chat (the migration's backfill): 130 rows from 10 days ago, "Old question 1" first.
# The agent's first chat is made with the agent; the migration's backfill left it untitled.
C1 = sql(f"select id from yui_chats where agent_id='{A}' and is_first")[0]["id"]
rows = []
for i in range(1, 66):
    rows.append(say(C1, "user", f"Old question {i}", 14400 - i * 4))
    rows.append(say(C1, "agent", f"Old answer {i}", 14400 - i * 4 + 1))
sql("\n".join(rows))
# Two newer chats: one named, one that titles itself from its first ask.
sql(f"insert into yui_chats(id, user_id, agent_id, title, titled_by) values ('{C2}','{T}','{A}','Tuesday groceries','person');")
sql(say(C2, "user", "What should I buy for Tuesday", 3000) + say(C2, "agent", "Eggs, spinach, rice.", 2999))
sql(f"insert into yui_chats(id, user_id, agent_id) values ('{C3}','{T}','{A}');")
sql(say(C3, "user", "How much protein on rest days", 600) + say(C3, "agent", "About 1.6 grams per kilo.", 599))
print("account", T, "chats", sql(f"select count(*) n from yui_chat_list where user_id='{T}'")[0]["n"], flush=True)

env = {**DEV, "TEST_RUNNER_YUI_RT": rt, "TEST_RUNNER_YUI_USER": T, "TEST_RUNNER_YUI_SHOTS": str(OUT),
       "TEST_RUNNER_YUI_APPEARANCE": args.appearance, "TEST_RUNNER_YUI_AGENT": A}
code = 1
try:
    subprocess.run(["xcrun", "simctl", "ui", args.sim, "appearance", args.appearance], env=DEV)
    code = subprocess.run(["xcodebuild", "test-without-building", *dest, f"-only-testing:YuiUITests/{args.only}"],
                          cwd=REPO, env=env, stdout=open(OUT / "xcodebuild.log", "w"), stderr=subprocess.STDOUT).returncode
    print("xcodebuild exit", code)
finally:
    tabs = ["yui_agents", "yui_messages", "yui_chats", "yui_sessions", "yui_connectors", "yui_devices"]
    count = lambda: sql("select " + " + ".join(f"(select count(*) from {t} where user_id = '{T}')" for t in tabs)
                        + f" + (select count(*) from yui_users where id='{T}') as n")[0]["n"]
    sql(f"delete from yui_users where id = '{T}'")
    left = count()
    if left:
        fn("yui-delete", {}, mint(T, ttl=300)); sql(f"delete from yui_users where id = '{T}'"); left = count()
    print("rows left:", left, flush=True)
sys.exit(code)

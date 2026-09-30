#!/usr/bin/env python3
"""YUI-228 on a simulator: a fresh non-demo account picks Arnold, answers his intake, taps Send, and the built
week is on screen with no second wizard. Live backend. Times Send -> the week from the database.

    python3 supabase/tests/first_plan_live_sim_e2e.py --sim <udid> --out /tmp/yui228 --appearance dark

Needs the app built for testing (xcodebuild build-for-testing into build/dd, or let this build it). The
throwaway account is deleted at the end.
"""
import argparse, hashlib, os, secrets, subprocess, sys, time, uuid
from pathlib import Path
REPO = Path(__file__).resolve().parents[2]
exec(open(REPO / "supabase/tests/agents_test.py").read().split("results = []")[0])
ap = argparse.ArgumentParser()
ap.add_argument("--sim", required=True); ap.add_argument("--out", required=True)
ap.add_argument("--appearance", default="dark", choices=["dark", "light"])
ap.add_argument("--no-build", action="store_true")
args = ap.parse_args()
OUT = Path(args.out); SH = OUT / "shots"; SH.mkdir(parents=True, exist_ok=True)
DEV = {**os.environ, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"}
DEV.pop("HERMES_HOME", None)
T = str(uuid.uuid4())
sql(f"insert into yui_users(id, apple_sub, timezone) values ('{T}','test.{T}','America/New_York')")
rt = secrets.token_urlsafe(32)
sql(f"insert into yui_sessions(user_id, refresh_hash, expires_at) values ('{T}','{hashlib.sha256(rt.encode()).hexdigest()}', now() + interval '1 day')")
env = {**DEV, "TEST_RUNNER_YUI_RT": rt, "TEST_RUNNER_YUI_USER": T, "TEST_RUNNER_YUI_SHOTS": str(SH), "TEST_RUNNER_YUI_APPEARANCE": args.appearance}
rc = 1
for f in SH.iterdir(): f.unlink()
try:
    subprocess.run(["xcrun", "simctl", "ui", args.sim, "appearance", args.appearance], env=DEV)
    cmd = ["xcodebuild", "test" if not args.no_build else "test-without-building", "-project", "Yui.xcodeproj", "-scheme", "Yui",
           "-destination", f"id={args.sim}", "-derivedDataPath", "build/dd", "-only-testing:YuiUITests/LiveFirstPlanTests"]
    rc = subprocess.run(cmd, cwd=REPO, env=env, stdout=open(OUT / "xcodebuild.log", "w"), stderr=subprocess.STDOUT).returncode
    print("xcodebuild exit", rc, flush=True)
    arn = sql(f"select id from yui_agents where user_id='{T}' and name='Arnold'")
    if arn:
        a = arn[0]["id"]
        ev = sql(f"select created_at from yui_messages where user_id='{T}' and agent_id='{a}' and sender='user' order by created_at limit 1")
        built = sql(f"select created_at, body from yui_messages where user_id='{T}' and agent_id='{a}' and sender='agent' and body like 'Your week is built%' order by created_at limit 1")
        if ev and built:
            from datetime import datetime
            f = lambda s: datetime.fromisoformat(s.replace("Z", "+00:00"))
            secs = (f(built[0]["created_at"]) - f(ev[0]["created_at"])).total_seconds()
            (OUT / "seconds.txt").write_text(f"{secs:.1f}")
            print(f"Send to the built week: {secs:.1f}s (database timestamps)")
        agent_said = " ".join(r["body"] for r in sql(f"select body from yui_messages where user_id='{T}' and agent_id='{a}' and sender='agent'"))
        print("second wizard in the thread:", any(w in agent_said for w in ["Two things left", "Finish your split"]))
finally:
    sql(f"delete from yui_users where id = '{T}'")
    left = sql("select " + " + ".join(f"(select count(*) from {t} where user_id = '{T}')" for t in ["yui_agents", "yui_messages", "yui_sessions"]) + " as n")
    print("rows left:", left[0]["n"])
sys.exit(rc)

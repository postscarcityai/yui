#!/usr/bin/env python3
"""YUI-24 end to end: reply pushes on a simulator, with the app killed.

Makes a throwaway account with two agents on one fake host ("Home", the
default, and "Coach") and a fresh session, then runs
YuiUITests/PushHandoffTests/testReplyPushOpensThreadFromKilledApp and plays
the host side:

  1. app open on Home's thread: Home answers, yui-push skips the phone
     (presence), the answer shows in the thread, no banner.
  2. app killed: Coach answers, the push reaches the simulator, the tap
     cold-starts the app in Coach's thread with the answer's screen.

The account, its session and device rows are deleted at the end. Never uses
anyone's real account. Needs full Xcode and a simulator that gets sandbox
APNs tokens (Apple silicon).

    python3 supabase/tests/push_killed_e2e.py --sim <udid> --out /tmp/yui24-proof
"""
import argparse, json, os, secrets, subprocess, sys, time, uuid, hashlib
from pathlib import Path
exec(open(__file__.replace("push_killed_e2e.py", "agents_test.py")).read().split("results = []")[0])

ap = argparse.ArgumentParser()
ap.add_argument("--sim", required=True)
ap.add_argument("--out", default="/tmp/yui24-proof")
args = ap.parse_args()
OUT = Path(args.out); SHOTS = OUT / "shots"
SHOTS.mkdir(parents=True, exist_ok=True)
for f in SHOTS.iterdir(): f.unlink()
REPO = Path(__file__).resolve().parents[2]

results = []
def check(name, ok, detail=""):
    results.append(ok); print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  [{detail}]" if detail else ""), flush=True)

def push(body, token=None): return fn("yui-push", body, token)
def host(body, token=None): return fn("yui-connect", body, token)

def wait_file(name, secs, proc):
    end = time.time() + secs
    while time.time() < end:
        if (SHOTS / name).exists(): return True
        if proc.poll() is not None: return (SHOTS / name).exists()
        time.sleep(1)
    return False

T = str(uuid.uuid4())
sql(f"insert into yui_users(id, apple_sub) values ('{T}','test.{T}')")
tok = mint(T, ttl=1800)
ui = None
try:
    s, r = fn("yui-agents", {"action": "create", "name": "Home", "pair": True}, tok)
    home = r["agent"]["id"]
    s, p = host({"action": "pair", "code": r["pairing"]["code"], "remote_ref": "home", "host_name": "Test host"})
    ct = p["connector_token"]
    conn = sql(f"select id from yui_connectors where user_id='{T}'")[0]["id"]
    s, r = fn("yui-agents", {"action": "create", "name": "Coach", "remote_ref": "coach", "connector_id": conn}, tok)
    coach = r["agent"]["id"]
    host({"action": "heartbeat"}, ct)
    cta = host({"action": "session"}, ct)[1]["access_token"]
    check("throwaway account: Home (default) and Coach on one host", s == 200 and home != coach, f"{s}")

    rt = secrets.token_urlsafe(32)
    rh = hashlib.sha256(rt.encode()).hexdigest()
    sql(f"insert into yui_sessions(user_id, refresh_hash, expires_at) values ('{T}','{rh}', now() + interval '1 day')")

    def say(agent, body):
        s, r = rest("POST", "yui_messages", cta, {"user_id": T, "agent_id": agent, "sender": "agent",
                    "body": body, "kind": "text"}, prefer="return=representation")
        assert s in (200, 201), (s, r)
        return push({"action": "notify", "message_id": r[0]["id"]}, ct)

    env = {**os.environ, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer",
           "TEST_RUNNER_YUI_RT": rt, "TEST_RUNNER_YUI_USER": T, "TEST_RUNNER_YUI_SHOTS": str(SHOTS),
           "TEST_RUNNER_YUI_OTHER_AGENT": "Coach"}
    env.pop("HERMES_HOME", None)
    subprocess.run(["xcodegen", "generate", "--quiet"], cwd=REPO, env=env, check=True)
    ui = subprocess.Popen(["xcodebuild", "test", "-project", "Yui.xcodeproj", "-scheme", "Yui",
                           "-destination", f"id={args.sim}", "-derivedDataPath", "/tmp/yui24-dd",
                           "-only-testing:YuiUITests/PushHandoffTests/testReplyPushOpensThreadFromKilledApp"],
                          cwd=REPO, env=env, stdout=open(OUT / "xcodebuild.log", "w"), stderr=subprocess.STDOUT)

    check("app is open on Home's thread", wait_file("open", 900, ui))
    # Register + first presence land a few seconds after launch.
    dev = []
    for _ in range(60):
        dev = sql(f"select environment, active_agent_id, active_at is not null as on from yui_devices where user_id='{T}'")
        if dev and dev[0]["active_agent_id"] == home: break
        time.sleep(1)
    check("the app registered its sandbox token and reports Home's thread open",
          len(dev) == 1 and dev[0]["environment"] == "sandbox" and dev[0]["active_agent_id"] == home, f"{dev}")

    s, r = say(home, "Answered while you watch.")
    check("answer in the open thread: yui-push skips the phone", s == 200 and r["devices"] == 0 and r["skipped"] == 1, f"{s} {r}")
    (OUT / "notify-open.json").write_text(json.dumps(r, indent=2))

    check("test killed the app", wait_file("killed", 180, ui))
    # A kill from Xcode is not a swipe: no background moment. Presence expires in 90s.
    t0 = time.time()
    while time.time() - t0 < 100:
        d = sql(f"select active_at, extract(epoch from now() - active_at) as age from yui_devices where user_id='{T}'")[0]
        if d["active_at"] is None or float(d["age"]) > 90: break
        time.sleep(3)
    print(f"      presence gone after {time.time() - t0:.0f}s ({'cleared' if d['active_at'] is None else 'stale'})")
    s, r = say(coach, "Your plan for tomorrow is ready.\n```yui\nchoose \"Ready to start?\" \"Ship it\"|\"Not yet\"\n```")
    check("Coach answers with the app killed: APNs delivers to the simulator",
          s == 200 and r["devices"] == 1 and r["delivered"] == 1, f"{s} {r}")
    (OUT / "notify-killed.json").write_text(json.dumps(r, indent=2))

    rc = ui.wait(timeout=600)
    log = (OUT / "xcodebuild.log").read_text()
    check("UI test: no banner while open, banner when killed, tap opens Coach's thread",
          rc == 0 and "Executed 1 test, with 0 failures" in log, f"rc={rc}")
finally:
    if ui and ui.poll() is None: ui.kill()
    sql(f"delete from yui_users where id = '{T}'")
    left = sql("select " + " + ".join(f"(select count(*) from {t} where user_id = '{T}')" for t in
               ["yui_agents", "yui_messages", "yui_connectors", "yui_devices", "yui_sessions"]) + " as n")
    check("throwaway account deleted, zero rows left", left[0]["n"] == 0, f"{left}")

print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)

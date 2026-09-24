#!/usr/bin/env python3
"""YUI-25 end to end: a brand-new account's first run, on a simulator, recorded.

Makes a throwaway account with no agents and a fresh session, runs
YuiUITests/FirstRunTests and plays the host: when the test writes the pairing
code it pairs like `hermes yui pair <code>` does, heartbeats like a running
gateway, and answers the first "Hi!" with a screen. The screen recording and
screenshots land in --out. The account is deleted at the end. Never uses
anyone's real account.

    python3 supabase/tests/first_run_e2e.py --sim <udid> --out /tmp/yui25-proof
"""
import argparse, os, secrets, signal, subprocess, sys, time, uuid, hashlib
from pathlib import Path
exec(open(__file__.replace("first_run_e2e.py", "agents_test.py")).read().split("results = []")[0])

ap = argparse.ArgumentParser()
ap.add_argument("--sim", required=True)
ap.add_argument("--out", default="/tmp/yui25-proof")
ap.add_argument("--appearance", default="light", choices=["light", "dark"])
args = ap.parse_args()
OUT = Path(args.out); SHOTS = OUT / "shots"
SHOTS.mkdir(parents=True, exist_ok=True)
for f in SHOTS.iterdir(): f.unlink()
REPO = Path(__file__).resolve().parents[2]
DEV = {**os.environ, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"}
DEV.pop("HERMES_HOME", None)

results = []
def check(name, ok, detail=""):
    results.append(ok); print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  [{detail}]" if detail else ""), flush=True)

def host(body, token=None): return fn("yui-connect", body, token)

REPLY = ("Hi! I'm Nova, connected and ready. Here's my first screen for you:\n"
         "```yui\nchoose \"What should we try first?\" \"Plan my day\"|\"Start a timer\"\n```")

T = str(uuid.uuid4())
sql(f"insert into yui_users(id, apple_sub) values ('{T}','test.{T}')")
ui = rec = None
try:
    rt = secrets.token_urlsafe(32)
    rh = hashlib.sha256(rt.encode()).hexdigest()
    sql(f"insert into yui_sessions(user_id, refresh_hash, expires_at) values ('{T}','{rh}', now() + interval '1 day')")
    check("throwaway account: zero agents", sql(f"select count(*) as n from yui_agents where user_id='{T}'")[0]["n"] == 0)

    env = {**DEV, "TEST_RUNNER_YUI_RT": rt, "TEST_RUNNER_YUI_USER": T, "TEST_RUNNER_YUI_SHOTS": str(SHOTS),
           "TEST_RUNNER_YUI_APPEARANCE": args.appearance}
    subprocess.run(["xcodegen", "generate", "--quiet"], cwd=REPO, env=env, check=True)
    subprocess.run(["xcrun", "simctl", "ui", args.sim, "appearance", args.appearance], env=DEV)
    ui = subprocess.Popen(["xcodebuild", "test", "-project", "Yui.xcodeproj", "-scheme", "Yui",
                           "-destination", f"id={args.sim}", "-derivedDataPath", "/tmp/yui25-dd-test",
                           "-only-testing:YuiUITests/FirstRunTests"],
                          cwd=REPO, env=env, stdout=open(OUT / "xcodebuild.log", "w"), stderr=subprocess.STDOUT)
    # Record once the app is up (the build comes first).
    end = time.time() + 900
    while time.time() < end and ui.poll() is None and "Test Suite 'FirstRunTests' started" not in (OUT / "xcodebuild.log").read_text():
        time.sleep(1)
    video = OUT / "first-run.mp4"
    if video.exists(): video.unlink()
    rec = subprocess.Popen(["xcrun", "simctl", "io", args.sim, "recordVideo", "--codec=h264", "--force", str(video)],
                           env=DEV, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    code_file = SHOTS / "code"
    end = time.time() + 180
    while time.time() < end and not code_file.exists() and ui.poll() is None: time.sleep(1)
    check("app shows a pairing code", code_file.exists())
    code = code_file.read_text().strip()
    time.sleep(4)  # the person reads the steps, runs install
    s, p = host({"action": "pair", "code": code, "remote_ref": "nova", "host_name": "Test host"})
    check("host pairs with the code (hermes yui pair)", s == 200, f"{s}")
    ct = p["connector_token"]
    host({"action": "heartbeat"}, ct)

    agent = sql(f"select id from yui_agents where user_id='{T}'")[0]["id"]
    cta = host({"action": "session"}, ct)[1]["access_token"]
    got = []
    end = time.time() + 180
    while time.time() < end and ui.poll() is None:
        host({"action": "heartbeat"}, ct)
        got = sql(f"select body from yui_messages where user_id='{T}' and sender='user'")
        if got: break
        time.sleep(2)
    check("the person's first message reaches the host", bool(got), f"{got[:1]}")
    time.sleep(3)  # the agent thinks
    s, r = rest("POST", "yui_messages", cta, {"user_id": T, "agent_id": agent, "sender": "agent",
                "body": REPLY, "kind": "text"}, prefer="return=representation")
    check("agent answers with a screen", s in (200, 201), f"{s}")

    rc = ui.wait(timeout=300)
    log = (OUT / "xcodebuild.log").read_text()
    check("UI test: first run, add, pair, say hi, first screen", rc == 0 and "Executed 1 test, with 0 failures" in log, f"rc={rc}")
finally:
    if rec and rec.poll() is None:
        rec.send_signal(signal.SIGINT); rec.wait(timeout=30)
    if ui and ui.poll() is None: ui.kill()
    sql(f"delete from yui_users where id = '{T}'")
    left = sql("select " + " + ".join(f"(select count(*) from {t} where user_id = '{T}')" for t in
               ["yui_agents", "yui_messages", "yui_connectors", "yui_devices", "yui_sessions"]) + " as n")
    check("throwaway account deleted, zero rows left", left[0]["n"] == 0, f"{left}")

print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)

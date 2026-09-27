#!/usr/bin/env python3
"""YUI-134 end to end: a brand-new account finds hosted Yui and she answers, on a simulator.

Makes a throwaway account with a fresh session (nothing paired, no host running), runs
YuiUITests/NativeFirstLaunchLiveTests against the live backend and watches the database:
the crew is provisioned on first open, the person's tap reaches Yui, and yui-native writes
her answer. The first words of that answer go to --out/shots/replied so the test can find
them on screen. The account is deleted at the end. Never uses anyone's real account.

    python3 supabase/tests/native_first_launch_e2e.py --sim <udid> --out /tmp/yui134-proof
"""
import argparse, hashlib, os, re, secrets, signal, subprocess, sys, time, uuid
from pathlib import Path
exec(open(__file__.replace("native_first_launch_e2e.py", "agents_test.py")).read().split("results = []")[0])

ap = argparse.ArgumentParser()
ap.add_argument("--sim", required=True)
ap.add_argument("--out", default="/tmp/yui134-proof")
ap.add_argument("--appearance", default="light", choices=["light", "dark"])
args = ap.parse_args()

_sql = sql
def sql(q, tries=4):
    """The management API times out now and then; a poll should not end the run."""
    for i in range(tries):
        try: return _sql(q)
        except (OSError, RuntimeError) as e:
            if i == tries - 1: raise
            print(f"sql retry: {e}", flush=True); time.sleep(3)
OUT = Path(args.out); SHOTS = OUT / "shots"
SHOTS.mkdir(parents=True, exist_ok=True)
for f in SHOTS.iterdir(): f.unlink()
REPO = Path(__file__).resolve().parents[2]
DEV = {**os.environ, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"}
DEV.pop("HERMES_HOME", None)

results = []
def check(name, ok, detail=""):
    results.append(ok); print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  [{detail}]" if detail else ""), flush=True)

def session():
    rt = secrets.token_urlsafe(32)
    sql(f"insert into yui_sessions(user_id, refresh_hash, expires_at) values "
        f"('{T}','{hashlib.sha256(rt.encode()).hexdigest()}', now() + interval '1 day')")
    return rt

def first_words(body):
    """A stretch of Yui's answer the app draws as plain text: the first say line or prose line."""
    for line in body.splitlines():
        line = line.strip()
        if not line or line.startswith("```"): continue
        m = re.match(r'(?:say|card|choose|title)\s+"([^"]+)"', line)
        if m: line = m.group(1)
        elif re.match(r"^[a-z]+(@\S+)?\s", line): continue  # another Yui Line
        line = re.sub(r"[*_`#>\[\]]", "", line).strip()
        words = line.split()
        if len(words) >= 2: return " ".join(words[:4])
    return ""

T = str(uuid.uuid4())
sql(f"insert into yui_users(id, apple_sub) values ('{T}','test.{T}')")
ui = rec = None
try:
    check("throwaway account: zero agents, nothing paired",
          sql(f"select (select count(*) from yui_agents where user_id='{T}') + "
              f"(select count(*) from yui_connectors where user_id='{T}') as n")[0]["n"] == 0)
    rt, rt2 = session(), session()
    env = {**DEV, "TEST_RUNNER_YUI_RT": rt, "TEST_RUNNER_YUI_RT2": rt2, "TEST_RUNNER_YUI_USER": T,
           "TEST_RUNNER_YUI_SHOTS": str(SHOTS), "TEST_RUNNER_YUI_APPEARANCE": args.appearance}
    subprocess.run(["xcodegen", "generate", "--quiet"], cwd=REPO, env=env, check=True)
    subprocess.run(["xcrun", "simctl", "ui", args.sim, "appearance", args.appearance], env=DEV)
    log = OUT / "xcodebuild.log"
    ui = subprocess.Popen(["xcodebuild", "test", "-project", "Yui.xcodeproj", "-scheme", "Yui",
                           "-destination", f"id={args.sim}", "-derivedDataPath", "/tmp/yui134-dd-test",
                           "-only-testing:YuiUITests/NativeFirstLaunchLiveTests"],
                          cwd=REPO, env=env, stdout=open(log, "w"), stderr=subprocess.STDOUT)
    end = time.time() + 900
    while time.time() < end and ui.poll() is None and "Test Suite 'NativeFirstLaunchLiveTests' started" not in log.read_text():
        time.sleep(2)
    print("test started", flush=True)
    video = OUT / "native-first-launch.mp4"
    if video.exists(): video.unlink()
    rec = subprocess.Popen(["xcrun", "simctl", "io", args.sim, "recordVideo", "--codec=h264", "--force", str(video)],
                           env=DEV, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    # The app's first open provisions Yui and the crew (yui-agents list -> yui_native_provision).
    crew = []
    end = time.time() + 90
    while time.time() < end and ui.poll() is None:
        crew = sql(f"select name from yui_agents where user_id='{T}' order by sort nulls last")
        if crew: break
        time.sleep(2)
    names = [a["name"] for a in crew]
    check("first open provisions hosted Yui and the crew", "Yui" in names and len(names) >= 5, f"{names}")
    check("no connector token was ever handed out (no pairing)",
          sql(f"select count(*) as n from yui_pairings where user_id='{T}'")[0]["n"] == 0)

    # The person's tap reaches Yui; yui-native answers.
    yui = sql(f"select id from yui_agents where user_id='{T}' and name='Yui'")[0]["id"]
    asked = answer = None
    end = time.time() + 150
    while time.time() < end and ui.poll() is None:
        if not asked:
            q = sql(f"select created_at from yui_messages where user_id='{T}' and agent_id='{yui}' and sender='user' order by created_at limit 1")
            if q: asked = q[0]["created_at"]; print("person's message in", flush=True)
        else:
            a = sql(f"select body from yui_messages where user_id='{T}' and agent_id='{yui}' and sender='agent' "
                    f"and created_at > '{asked}' order by created_at limit 1")
            if a: answer = a[0]["body"]; break
        time.sleep(2)
    check("the person's first tap reaches Yui", bool(asked))
    check("hosted Yui answers", bool(answer), (answer or "")[:160].replace("\n", " | "))
    words = first_words(answer or "")
    (OUT / "answer.txt").write_text(answer or "")
    (SHOTS / "replied").write_text(words)
    print(f"looking for on screen: {words!r}", flush=True)

    rc = ui.wait(timeout=400)
    txt = log.read_text()
    check("UI test: sign in, Yui talking, tap, Yui answers, crew in the list",
          rc == 0 and "Executed 1 test, with 0 failures" in txt, f"rc={rc}")
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

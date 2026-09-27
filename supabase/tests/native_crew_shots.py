#!/usr/bin/env python3
"""YUI-135: a screenshot of every starter agent's first answer, in the app, on a new account.

Makes a throwaway account with a fresh session, launches the installed Yui on a simulator
signed in as it, relaunches it on each crew thread and screenshots it.
Checks the whole crew is there and each thread opens on its own first answer. The account
is deleted at the end. Needs a Yui build already installed on the simulator.

    python3 supabase/tests/native_crew_shots.py --sim <udid> --out /tmp/yui135-shots
"""
import argparse, hashlib, os, secrets, subprocess, sys, time, uuid
from pathlib import Path
exec(open(Path(__file__).resolve().parent.joinpath("agents_test.py")).read().split("results = []")[0])

ap = argparse.ArgumentParser()
ap.add_argument("--sim", required=True)
ap.add_argument("--out", default="/tmp/yui135-shots")
ap.add_argument("--appearance", default="light", choices=["light", "dark"])
args = ap.parse_args()
OUT = Path(args.out); OUT.mkdir(parents=True, exist_ok=True)
DEV = {**os.environ, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"}
CREW = ["Yui", "Arnold", "Basil", "Gouda", "Penny", "Quill"]

results = []
def check(name, ok, detail=""):
    results.append(ok); print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  [{detail}]" if detail else ""), flush=True)

def simctl(*a): return subprocess.run(["xcrun", "simctl", *a], env=DEV, capture_output=True, text=True)

T = str(uuid.uuid4())
sql(f"insert into yui_users(id, apple_sub) values ('{T}','test.{T}')")
try:
    s, _ = fn("yui-agents", {"action": "list"}, mint(T))
    agents = {a["name"]: a["id"] for a in sql(f"select id, name from yui_agents where user_id='{T}' and kind='hosted'")}
    check("a new account gets the whole crew", s == 200 and all(n in agents for n in CREW), f"{sorted(agents)}")
    rt = secrets.token_urlsafe(32)
    sql(f"insert into yui_sessions(user_id, refresh_hash, expires_at) values ('{T}','{hashlib.sha256(rt.encode()).hexdigest()}', now() + interval '1 day')")
    simctl("ui", args.sim, "appearance", args.appearance)
    simctl("terminate", args.sim, "com.yuigui.app")
    r = simctl("launch", args.sim, "com.yuigui.app", "-yuiRefreshToken", rt, "-yuiUserID", T, "-appearance", args.appearance)
    check("the app launches signed in", r.returncode == 0, r.stderr.strip()[:120])
    time.sleep(14)  # sign in, list agents, first thread
    for n in CREW:
        if n not in agents: continue
        # The session is in the keychain now; relaunch on that agent's thread (the saved
        # selectedAgent, set from the launch arguments), on the chat, not the stage. A deep link would
        # stop on "Open in Yui?".
        simctl("terminate", args.sim, "com.yuigui.app")
        simctl("launch", args.sim, "com.yuigui.app", "-selectedAgent", agents[n], "-yuiStageFirst", "NO",
               "-appearance", args.appearance)
        time.sleep(9)
        shot = OUT / f"{n.lower()}-first-{args.appearance}.png"
        r = simctl("io", args.sim, "screenshot", str(shot))
        check(f"{n}'s first answer, shot", r.returncode == 0 and shot.exists() and shot.stat().st_size > 50_000, shot.name)
finally:
    simctl("terminate", args.sim, "com.yuigui.app")
    sql(f"delete from yui_users where id = '{T}'")
    left = sql("select " + " + ".join(f"(select count(*) from {t} where user_id = '{T}')" for t in
               ["yui_agents", "yui_messages", "yui_sessions", "yui_connectors", "yui_devices"]) + " as n")
    check("throwaway account deleted, zero rows left", left[0]["n"] == 0, f"{left}")

print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)

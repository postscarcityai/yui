#!/usr/bin/env python3
"""YUI-95 end to end on the simulator: a throwaway invitee opens Yui and finds
the agent the owner shared, in its look, with its first message waiting;
after a revoke it is gone. Also: grant.py refuses the agent while its host
reports a shell. (YuiUITests/SharedAgentTests, light then dark, then revoked.)

A throwaway owner pairs a throwaway host (no gateway: the host only reports
its sandbox), saves a template with grant.py, and invites an @example.com
address with invite.py --no-testflight. The invitee account claims it the
way Sign in with Apple does (yui_claim_invite by verified email), then signs
in on the simulator. Everything is removed at the end.

    python3 supabase/tests/shared_agents_e2e.py --sim <udid> [--out DIR]
"""
import argparse, hashlib, json, os, secrets, subprocess, sys, time, uuid
from pathlib import Path
exec(open(__file__.replace("shared_agents_e2e.py", "agents_test.py")).read().split("results = []")[0])

results = []
def check(name, ok, detail=""):
    ok = bool(ok); results.append(ok); print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  [{detail}]" if detail else ""), flush=True)

ap = argparse.ArgumentParser()
ap.add_argument("--sim", required=True)
ap.add_argument("--out", default="/tmp/yui95-e2e")
args = ap.parse_args()
OUT = Path(args.out); OUT.mkdir(parents=True, exist_ok=True)
shots = OUT / "shots"; shots.mkdir(exist_ok=True)
for f in shots.iterdir():
    f.unlink()
REPO = Path(__file__).resolve().parents[2]
GRANT, INVITE = str(REPO / "supabase/scripts/grant.py"), str(REPO / "supabase/scripts/invite.py")
RUN = uuid.uuid4().hex[:8]
PROFILE, TPL = f"penny-{RUN}", f"client-{RUN}"
HELLO = "Hi Maya! I'm Penny, Sam's assistant. What can I take off your plate this week?"
SAFE = {"terminal": "off", "files": "off", "reach": [], "memory": "off", "runner": "api", "profile": "own", "extra_keys": 0}
O, T = str(uuid.uuid4()), str(uuid.uuid4())
EMAIL = f"yui-share-e2e-{RUN}@example.com"

def run(script, *a):
    p = subprocess.run([sys.executable, script, "--owner", O, *a], capture_output=True, text=True)
    return p.returncode, (p.stdout + p.stderr).strip()

try:
    sql(f"insert into yui_users(id, apple_sub, email) values ('{O}','test.{O}','owner-{RUN}@example.com'), ('{T}','test.{T}','{EMAIL}')")
    tokO = mint(O)
    s, r = fn("yui-agents", {"action": "create", "name": "Penny", "pair": True}, tokO)
    agent = r["agent"]["id"]
    s, r = fn("yui-connect", {"action": "pair", "code": r["pairing"]["code"], "remote_ref": PROFILE, "host_name": "Sam's Mac"})
    ct = r["connector_token"]
    fn("yui-connect", {"action": "heartbeat", "serving": [PROFILE],
                       "sandbox": {PROFILE: {**SAFE, "terminal": "local", "files": "host"}}}, ct)
    rc, out = run(GRANT, "template", "save", TPL, "--title", "Client default", "--agent", PROFILE)
    check("grant.py refuses the agent while its host has a shell (exit 3)", rc == 3 and "terminal: local shell" in out, out)
    fn("yui-connect", {"action": "heartbeat", "serving": [PROFILE], "sandbox": {PROFILE: SAFE}}, ct)
    rc, out = run(GRANT, "safe", PROFILE)
    check("the host now reports it client-safe", rc == 0, out[-80:])
    rc, out = run(GRANT, "template", "save", TPL, "--title", "Client default", "--agent", PROFILE,
                  "--look", f"{PROFILE}=candy", "--hello", f"{PROFILE}={HELLO}", "--by", "Sam")
    check("grant.py template save", rc == 0, out)
    subprocess.run([sys.executable, INVITE, "add", "--email", EMAIL, "--first", "Maya", "--last", "Test", "--template", TPL],
                   check=True, capture_output=True)
    subprocess.run([sys.executable, INVITE, "approve", EMAIL, "--no-testflight"], check=True, capture_output=True)
    got = sql(f"select * from public.yui_claim_invite('{T}'::uuid, null, '{EMAIL}')")
    check("the invitee claims the invite (as Sign in with Apple does)", got and got[0]["agent_template"] == TPL, got)
    g = sql(f"select theme, first_message from yui_agent_grants where user_id = '{T}' and revoked_at is null")
    check("the claim applied the template: one grant, candy, first message", len(g) == 1 and g[0]["theme"].get("preset") == "candy", g)

    rts = []
    for _ in range(3):  # one fresh session per launch
        rt = secrets.token_urlsafe(32)
        sql(f"insert into yui_sessions(user_id, refresh_hash, expires_at) values "
            f"('{T}', '{hashlib.sha256(rt.encode()).hexdigest()}', now() + interval '1 day')")
        rts.append(rt)
    env = {**os.environ, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer",
           "TEST_RUNNER_YUI_RTS": ",".join(rts), "TEST_RUNNER_YUI_USER": T, "TEST_RUNNER_YUI_SHOTS": str(shots),
           "TEST_RUNNER_YUI_HELLO": HELLO}
    subprocess.run(["xcodegen", "generate", "--quiet"], cwd=REPO, env=env, check=True)
    ui = subprocess.Popen(["xcodebuild", "test", "-project", "Yui.xcodeproj", "-scheme", "Yui",
                           "-destination", f"id={args.sim}", "-derivedDataPath", "/tmp/yui95-dd",
                           "-only-testing:YuiUITests/SharedAgentTests"],
                          cwd=REPO, env=env, stdout=open(OUT / "xcodebuild.log", "w"), stderr=subprocess.STDOUT)
    revoked = None
    while ui.poll() is None:
        if (shots / "need-revoke").exists() and not (shots / "revoke-ok").exists():
            revoked = run(GRANT, "revoke", PROFILE, EMAIL)
            (shots / "revoke-ok").touch()
        time.sleep(1)
    log_text = (OUT / "xcodebuild.log").read_text()
    check("SharedAgentTests ran and passed in the simulator",
          ui.returncode == 0 and "Executed 1 test, with 0 failures" in log_text,
          f"xcodebuild exit {ui.returncode}, log {OUT / 'xcodebuild.log'}")
    check("grant.py revoke ran mid-test", revoked and revoked[0] == 0, revoked)
    left = sql(f"select count(*)::int n from yui_agent_grants where user_id = '{T}' and revoked_at is null")[0]["n"]
    check("no live grant left", left == 0, left)
finally:
    sql(f"delete from yui_invites where email = '{EMAIL}'; delete from yui_users where id in ('{O}','{T}'); "
        f"delete from yui_pair_attempts where created_at > now() - interval '1 hour'")

print(f"\nshots: {shots}\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)

#!/usr/bin/env python3
"""YUI-56 end to end on the simulator: a signed-in throwaway account opens an
invite link and the app claims it (YuiUITests/InviteTests). Also runs the
signed-out test (link waits for Sign in with Apple, the Invite code sheet).
Throwaway account and an @example.com invite approved with --no-testflight;
both are removed at the end.

    python3 supabase/tests/invite_claim_e2e.py --sim <udid> [--shots DIR]
"""
import hashlib, os, secrets, subprocess, sys, uuid, json
exec(open(__file__.replace("invite_claim_e2e.py", "agents_test.py")).read().split("results = []")[0])

results = []
def check(name, ok, detail=""):
    ok = bool(ok); results.append(ok); print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  [{detail}]" if detail else ""), flush=True)

sim = sys.argv[sys.argv.index("--sim") + 1]
shots = sys.argv[sys.argv.index("--shots") + 1] if "--shots" in sys.argv else "/tmp/yui-invite-shots"
os.makedirs(shots, exist_ok=True)
root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
T, email = str(uuid.uuid4()), f"yui-invite-e2e-{uuid.uuid4().hex[:8]}@example.com"
try:
    rt = secrets.token_urlsafe(32)
    sql(f"insert into yui_users(id, apple_sub) values ('{T}', 'test.{T}')")
    sql(f"insert into yui_sessions(user_id, refresh_hash, expires_at) values ('{T}', '{hashlib.sha256(rt.encode()).hexdigest()}', now() + interval '1 day')")
    inv = [sys.executable, os.path.join(root, "supabase/scripts/invite.py")]
    subprocess.run(inv + ["add", "--email", email, "--first", "Sim", "--last", "Invitee"], check=True, capture_output=True)
    out = subprocess.run(inv + ["approve", email, "--no-testflight", "--json"], check=True, capture_output=True, text=True).stdout
    code = json.loads(out.strip().splitlines()[-1])["code"]
    env = {**os.environ, "TEST_RUNNER_YUI_RT": rt, "TEST_RUNNER_YUI_USER": T, "TEST_RUNNER_YUI_INVITE": code,
           "TEST_RUNNER_YUI_SHOTS": shots}
    p = subprocess.run(["xcodebuild", "test", "-scheme", "Yui", "-destination", f"id={sim}",
                        "-only-testing:YuiUITests/InviteTests", "-derivedDataPath", "build/dd"],
                       cwd=root, env=env, capture_output=True, text=True)
    tail = [l for l in p.stdout.splitlines() if "Test Case" in l or "error" in l.lower()][-6:]
    check("InviteTests pass (signed out + signed in)", p.returncode == 0, " | ".join(tail)[-400:])
    r = sql(f"select status, claimed_user_id from yui_invites where email = '{email}'")[0]
    check("the link claimed the invite for the signed-in account", r["status"] == "claimed" and r["claimed_user_id"] == T, r)
finally:
    sql(f"delete from yui_invites where email = '{email}'")
    sql(f"delete from yui_users where id = '{T}'")
    sql(f"delete from yui_rate_buckets where key = 'invite:u:{T}'")
print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)

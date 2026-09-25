#!/usr/bin/env python3
"""INT-19 end to end: an OAuth-only MCP client adds Yui with no token to copy.

On a fresh throwaway account (never a real one):

  1. the MCP TypeScript SDK's OAuth client (mcp_oauth_client.mjs) hits
     yui-mcp, gets the 401, discovers yui-oauth, registers itself and starts
     PKCE; /authorize sends it to www.yuigui.com/connect/<id>;
  2. the app runs in the simulator (YuiUITests/ConnectApprovalTests): it opens
     yui://connect/<id> like that page's Open Yui button, taps Allow (a new
     agent named after the client), and opens the new thread;
  3. the client trades the code for tokens, asks "Ready for a tabata?" with
     yui_show, the test taps Yes, the client answers with a timer.

Pass: the UI test passed, the client saw only its own thread, the rows are
agent rows via mcp on the new kind-mcp agent, and removing the computer in the
app kills the client's token. Screenshots land in --out.

    python3 supabase/tests/mcp_oauth_e2e.py --sim <udid> [--out DIR]

Needs full Xcode, node + npm, and a Supabase access token like the other
tests. The account and the registered client are deleted at the end.
"""
import argparse, json, os, shutil, subprocess, sys, tempfile, time, uuid
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
exec(open(HERE / "agents_test.py").read().split("results = []")[0])

ap = argparse.ArgumentParser()
ap.add_argument("--sim", required=True)
ap.add_argument("--out", default="/tmp/yui-int19-e2e")
ap.add_argument("--appearance", default="light")
args = ap.parse_args()
OUT = Path(args.out)
shots = OUT / "shots"
shutil.rmtree(shots, ignore_errors=True)
shots.mkdir(parents=True)
MCP = f"{BASE}/functions/v1/yui-mcp"

results = []
def check(name, ok, detail=""):
    ok = bool(ok); results.append(ok)
    print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  [{str(detail)[:300]}]" if detail else ""), flush=True)

work = Path(tempfile.mkdtemp(prefix="yui-int19-sdk-"))
p = subprocess.run(["npm", "i", "--prefix", str(work), "--silent", "@modelcontextprotocol/sdk@1"], capture_output=True, text=True)
check("MCP TypeScript SDK installed", p.returncode == 0, p.stderr[-200:])
shutil.copy(HERE / "mcp_oauth_client.mjs", work / "client.mjs")

T = str(uuid.uuid4())
sql(f"insert into yui_users(id, apple_sub) values ('{T}','test.{T}')")
tok = mint(T, ttl=3600)
ui = node = None
try:
    rt = secrets.token_urlsafe(32)
    sql(f"insert into yui_sessions(user_id, refresh_hash, expires_at) values "
        f"('{T}', '{hashlib.sha256(rt.encode()).hexdigest()}', now() + interval '1 day')")
    env = {**os.environ, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer",
           "TEST_RUNNER_YUI_RT": rt, "TEST_RUNNER_YUI_USER": T, "TEST_RUNNER_YUI_SHOTS": str(shots),
           "TEST_RUNNER_YUI_APPEARANCE": args.appearance}
    subprocess.run(["xcodegen", "generate", "--quiet"], cwd=REPO, env=env, check=True)
    ui = subprocess.Popen(["xcodebuild", "test", "-project", "Yui.xcodeproj", "-scheme", "Yui",
                           "-destination", f"id={args.sim}", "-derivedDataPath", "/tmp/yui-int19-dd",
                           "-only-testing:YuiUITests/ConnectApprovalTests"],
                          cwd=REPO, env=env, stdout=open(OUT / "xcodebuild.log", "w"), stderr=subprocess.STDOUT)
    print("  .. building and launching the app", flush=True)
    while not (shots / "ready").exists() and ui.poll() is None:
        time.sleep(2)
    check("the app is signed in", (shots / "ready").exists())

    t0 = time.time()
    node = subprocess.run(["node", str(work / "client.mjs")], cwd=work, capture_output=True, text=True, timeout=540,
                          env={**os.environ, "MCP_URL": MCP, "OUT_DIR": str(shots)})
    (OUT / "client.log").write_text(node.stdout + node.stderr)
    print("  " + "\n  ".join(node.stdout.strip().splitlines()), flush=True)
    res = json.loads((shots / "result.json").read_text()) if (shots / "result.json").exists() else {}
    check("the SDK's OAuth client connected and saw only its new thread", node.returncode == 0 and res.get("threads") == ["SDK Agent"],
          f"{time.time() - t0:.0f}s {res or node.stderr[-300:]}")
    check("the client read the Yes tap", "Yes" in res.get("tap", ""), res.get("tap"))

    ui.wait(300)
    log = (OUT / "xcodebuild.log").read_text()
    check("ConnectApprovalTests passed (sheet, Allow, thread, ask, Yes, timer)",
          ui.returncode == 0 and "Executed 1 test, with 0 failures" in log, f"exit {ui.returncode}, {OUT / 'xcodebuild.log'}")

    a = sql(f"select a.id, a.kind ak, c.kind ck, c.name cn from yui_agents a join yui_connectors c on c.id = a.connector_id "
            f"where a.user_id = '{T}' and a.name = 'SDK Agent'")
    check("Allow made a kind-mcp agent on a connector named after the client",
          len(a) == 1 and a[0]["ak"] == "mcp" and a[0]["ck"] == "mcp" and a[0]["cn"] == "SDK Agent", a)
    s, rows = rest("GET", f"yui_messages?select=sender,body,kind,meta&agent_id=eq.{a[0]['id'] if a else T}&order=created_at.asc,id.asc", tok)
    agent_rows = [m for m in rows if m["sender"] == "agent"]
    check("the ask and the timer are agent rows via mcp",
          len(agent_rows) == 2 and all(m["meta"].get("via") == "mcp" for m in agent_rows) and "timer 20/10x8" in agent_rows[-1]["body"],
          [m["body"] for m in agent_rows])
finally:
    if ui and ui.poll() is None:
        ui.kill()
    clients = [r["id"] for r in sql("select id from yui_oauth_clients where name = 'SDK Agent'")]
    s, _ = fn("yui-delete", {}, tok)
    if clients:
        sql("delete from yui_oauth_clients where id in (" + ",".join(f"'{c}'" for c in clients) + ")")
    left = sql(f"select (select count(*) from yui_users where id = '{T}') + "
               f"(select count(*) from yui_connectors where user_id = '{T}') + "
               f"(select count(*) from yui_oauth_tokens where user_id = '{T}') n")[0]["n"]
    check("throwaway account and client deleted, nothing left", s == 200 and left == 0 and clients, f"{s} {left} {len(clients)}")
    print(f"  shots: {shots}")

print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)

#!/usr/bin/env python3
"""INT-3 end to end: Claude Code draws a Yui screen on the simulator through MCP.

On a fresh throwaway account (never a real one):

  1. pair an agent as kind mcp with the app's code;
  2. `claude mcp add --transport http yui <yui-mcp> --header "Authorization: Bearer ..."`
     in a scratch folder (local scope, removed at the end);
  3. the app runs in the simulator (YuiUITests/MCPRoundTripTests) and plays
     the person: once the thread is on screen, `claude -p` asks "Ready for a
     tabata?" with yui_show, waits with yui_answers, the test taps Yes, and
     Claude answers with a 20/10x8 timer.

Pass: the UI test passed (it saw the ask, tapped Yes, saw the timer), the
thread holds Claude's screens as agent rows via mcp, and the tap is handled.
Screenshots land in --out.

    python3 supabase/tests/mcp_claude_e2e.py --sim <udid> [--out DIR] [--oauth]

--oauth (INT-7) adds Yui the way the Claude guide on yuigui.com/developers
says: `claude mcp add --transport http yui <url>` with no header, then
`claude mcp login yui --no-browser`. The authorize URL it prints goes to
www.yuigui.com/connect/<id>; the script approves it with the Add agent code,
as a person types it on that page, and pastes the redirect back. Claude Code
then holds its own OAuth tokens, and the round trip runs the same.

Needs full Xcode, the `claude` CLI and a Supabase access token like the other
tests. The account is deleted at the end.
"""
import argparse, hashlib, json, os, secrets, shutil, subprocess, sys, tempfile, time, uuid
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
exec(open(HERE / "agents_test.py").read().split("results = []")[0])

ap = argparse.ArgumentParser()
ap.add_argument("--sim", required=True)
ap.add_argument("--out", default="/tmp/yui-int3-e2e")
ap.add_argument("--model", default=None, help="claude --model (default: the CLI's)")
ap.add_argument("--oauth", action="store_true", help="add Yui over OAuth (claude mcp login), not a pasted token")
args = ap.parse_args()
OUT = Path(args.out)
shots = OUT / "shots"
shutil.rmtree(shots, ignore_errors=True)
shots.mkdir(parents=True)

results = []
def check(name, ok, detail=""):
    ok = bool(ok); results.append(ok)
    print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  [{str(detail)[:300]}]" if detail else ""), flush=True)

PROMPT = """You are connected to the person's phone through the yui MCP server.
1. Call yui_show with lines `ask "Ready for a tabata?" Yes|"Not now"` and text "Quick one.".
2. Call yui_answers with that screen_id and wait=25. Repeat until an answer arrives (at most 8 calls).
3. If they tapped Yes, call yui_show with lines `timer 20/10x8 Tabata`. If Not now, call yui_say with "Later then."
Then reply with one line saying what they chose."""

T = str(uuid.uuid4())
sql(f"insert into yui_users(id, apple_sub) values ('{T}','test.{T}')")
tok = mint(T, ttl=3600)
work = Path(tempfile.mkdtemp(prefix="yui-int3-claude-"))
cenv = {**os.environ, "USER": os.environ.get("USER") or "urzas"}
ui = None
try:
    s, r = fn("yui-agents", {"action": "create", "name": "Claude", "pair": True}, tok)
    agent = r["agent"]["id"]
    MCP = f"{BASE}/functions/v1/yui-mcp"
    if args.oauth:
        ct = "yui_at_***"  # nothing to scrub: Claude Code keeps its own tokens
        code = r["pairing"]["code"]
        p = subprocess.run(["claude", "mcp", "add", "--transport", "http", "yui", MCP], cwd=work, env=cenv, capture_output=True, text=True)
        check("claude mcp add --transport http, no header", p.returncode == 0, (p.stdout + p.stderr).strip())
        # A cold `mcp login` never calls the server, so it never sees the 401
        # that names Yui's metadata (under /functions/v1/yui-mcp; Supabase's
        # shared host root has no /.well-known of ours) and falls back to
        # {host}/register. `mcp get` makes the call and Claude Code keeps the
        # resource_metadata URL for the login. The guide says the same.
        p = subprocess.run(["claude", "mcp", "get", "yui"], cwd=work, env=cenv, capture_output=True, text=True, timeout=120)
        check("claude mcp get before login: needs authentication", "Needs authentication" in p.stdout, p.stdout[:200])
        # login wants a terminal (it prompts for the redirect URL), so give it a pty.
        import pty, re, select
        import fcntl, struct, termios
        master, slave = pty.openpty()
        # Wide enough that the authorize URL prints on one line.
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 50, 4000, 0, 0))
        login = subprocess.Popen(["claude", "mcp", "login", "yui", "--no-browser"], cwd=work, env={**cenv, "COLUMNS": "4000"},
                                 stdin=slave, stdout=slave, stderr=slave, close_fds=True)
        os.close(slave)
        buf, url = "", None
        def pump(secs):
            global buf
            end = time.time() + secs
            while time.time() < end:
                r, _, _ = select.select([master], [], [], 0.5)
                if r:
                    try: chunk = os.read(master, 65536).decode(errors="replace")
                    except OSError: return
                    buf += chunk
                elif login.poll() is not None:
                    return
        t0 = time.time()
        while time.time() - t0 < 60 and url is None and login.poll() is None:
            pump(1)
            # The terminal prints the URL as an OSC 8 hyperlink; strip escapes
            # on the whole buffer, since one can straddle two reads.
            clean = re.sub(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b\[[0-9;?]*[A-Za-z]", "", buf)
            m = re.search(r"https://\S+/yui-oauth/authorize\?\S*state=\S+", clean)
            if m:
                url = m.group(0)
        seen = re.sub(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b\[[0-9;?]*[A-Za-z]", "", buf).splitlines()
        check("claude mcp login prints Yui's authorize URL", url is not None, "\n".join(seen[-8:]))
        if url is None:
            raise SystemExit("no authorize URL")
        # What the browser would do: /authorize answers 302 to the connect page.
        class _NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, *a, **k): return None
        try:
            urllib.request.build_opener(_NoRedirect).open(urllib.request.Request(url, headers={"user-agent": "yui-tests"}))
            loc = ""
        except urllib.error.HTTPError as e:
            loc = e.headers.get("location", "")
        rid = loc.rsplit("/", 1)[1] if loc.startswith("https://www.yuigui.com/connect/") else None
        check("/authorize sends the browser to www.yuigui.com/connect/<id>", rid, loc)
        OAUTH = f"{BASE}/functions/v1/yui-oauth"
        s, r = http("POST", OAUTH, None, {"action": "code", "id": rid, "code": code})
        check("the connect page takes the Add agent code", s == 200 and r.get("status") == "approved"
              and r["agent"]["id"] == agent, (s, r))
        s, r = http("POST", OAUTH, None, {"action": "request", "id": rid})
        back = r.get("redirect", "")
        check("...and sends the browser back to Claude Code's callback", back.startswith("http://localhost"), back[:80])
        buf = ""
        os.write(master, (back + "\r").encode())
        t0 = time.time()
        while login.poll() is None and time.time() - t0 < 90:
            pump(1)
        if login.poll() is None:
            login.kill()
        out = re.sub(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b\[[0-9;?]*[A-Za-z]", "", buf)
        check("claude mcp login finished", login.returncode == 0, "\n".join((out or "").splitlines()[-6:]))
    else:
        s, r = fn("yui-connect", {"action": "pair", "code": r["pairing"]["code"], "remote_ref": "claude-code",
                                  "kind": "mcp", "host_name": "Claude Code"})
        ct = r["connector_token"]
        check("paired as kind mcp", s == 200 and ct.startswith("yui_ct_"), s)

        p = subprocess.run(["claude", "mcp", "add", "--transport", "http", "yui", MCP,
                            "--header", f"Authorization: Bearer {ct}"], cwd=work, env=cenv, capture_output=True, text=True)
        check("claude mcp add --transport http", p.returncode == 0, (p.stdout + p.stderr).replace(ct, "yui_ct_***").strip())
    p = subprocess.run(["claude", "mcp", "get", "yui"], cwd=work, env=cenv, capture_output=True, text=True, timeout=120)
    check("claude mcp get: connected", "Connected" in p.stdout or "✓" in p.stdout, p.stdout.replace(ct, "yui_ct_***")[:300])
    if args.oauth:
        k = sql(f"select c.kind, c.name from yui_connectors c join yui_agents a on a.connector_id = c.id where a.id = '{agent}'")
        check("the approval made a kind-mcp connection named after Claude Code", k and k[0]["kind"] == "mcp", k)

    rt = secrets.token_urlsafe(32)
    sql(f"insert into yui_sessions(user_id, refresh_hash, expires_at) values "
        f"('{T}', '{hashlib.sha256(rt.encode()).hexdigest()}', now() + interval '1 day')")
    env = {**os.environ, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer",
           "TEST_RUNNER_YUI_RT": rt, "TEST_RUNNER_YUI_USER": T, "TEST_RUNNER_YUI_SHOTS": str(shots)}
    subprocess.run(["xcodegen", "generate", "--quiet"], cwd=REPO, env=env, check=True)
    ui = subprocess.Popen(["xcodebuild", "test", "-project", "Yui.xcodeproj", "-scheme", "Yui",
                           "-destination", f"id={args.sim}", "-derivedDataPath", "/tmp/yui-int3-dd",
                           "-only-testing:YuiUITests/MCPRoundTripTests"],
                          cwd=REPO, env=env, stdout=open(OUT / "xcodebuild.log", "w"), stderr=subprocess.STDOUT)
    print("  .. building and launching the app", flush=True)
    while not (shots / "ready").exists() and ui.poll() is None:
        time.sleep(2)
    check("the app is signed in with the thread on screen", (shots / "ready").exists())

    cmd = ["claude", "-p", PROMPT, "--allowedTools", "mcp__yui__yui_show,mcp__yui__yui_answers,mcp__yui__yui_say",
           "--output-format", "json"] + (["--model", args.model] if args.model else [])
    t0 = time.time()
    p = subprocess.run(cmd, cwd=work, env=cenv, capture_output=True, text=True, timeout=540)
    (OUT / "claude.json").write_text(p.stdout.replace(ct, "yui_ct_***"))
    said = ""
    try:
        said = json.loads(p.stdout).get("result", "")
    except ValueError:
        pass
    check("claude -p finished and reports the Yes", p.returncode == 0 and "yes" in said.lower(),
          f"{time.time() - t0:.0f}s: {said or p.stderr[-300:]}")

    ui.wait(300)
    log = (OUT / "xcodebuild.log").read_text()
    check("MCPRoundTripTests passed in the simulator (ask seen, Yes tapped, timer seen)",
          ui.returncode == 0 and "Executed 1 test, with 0 failures" in log, f"exit {ui.returncode}, {OUT / 'xcodebuild.log'}")

    s, rows = rest("GET", "yui_messages?select=sender,body,kind,meta,handled_at"
                          f"&agent_id=eq.{agent}&order=created_at.asc,id.asc", tok)
    agent_rows = [m for m in rows if m["sender"] == "agent"]
    taps = [m for m in rows if m["sender"] == "user" and m["kind"] == "event"]
    check("Claude's ask and timer are agent rows written via mcp",
          len(agent_rows) >= 2 and all(m["meta"].get("via") == "mcp" for m in agent_rows)
          and "ask \"Ready for a tabata?\"" in agent_rows[0]["body"] and "timer 20/10x8" in agent_rows[-1]["body"],
          [m["body"] for m in agent_rows])
    check("the Yes tap reached Claude and is handled",
          any("Yes" in json.dumps(m["meta"]) and m["handled_at"] for m in taps), taps)
finally:
    if ui and ui.poll() is None:
        ui.kill()
    if args.oauth:
        subprocess.run(["claude", "mcp", "logout", "yui"], cwd=work, env=cenv, capture_output=True)
    subprocess.run(["claude", "mcp", "remove", "yui", "-s", "local"], cwd=work, env=cenv, capture_output=True)
    s, _ = fn("yui-delete", {}, tok)
    left = sql(f"select (select count(*) from yui_users where id = '{T}') + "
               f"(select count(*) from yui_connectors where user_id = '{T}') n")[0]["n"]
    check("throwaway account deleted, nothing left", s == 200 and left == 0, f"{s} {left}")
    print(f"  shots: {shots}")

print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)

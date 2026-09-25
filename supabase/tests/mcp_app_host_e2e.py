#!/usr/bin/env python3
"""INT-7 end to end: a Yui screen drawn inside an MCP Apps host, tap round trip.

The host is the MCP Apps reference host from modelcontextprotocol/ext-apps
(examples/basic-host), a checkout at --ext-apps with `npm install` and
`npm run build --workspace examples/basic-host` done. On a fresh throwaway
account (never a real one):

  1. pair an agent as kind mcp; a local proxy on :3001 adds its bearer token
     (the reference host has no header setting);
  2. the host lists yui-mcp's tools, calls yui_show, reads ui://yui/screen and
     draws it in its double-iframe sandbox;
  3. Playwright taps an option inside the drawn screen: the view hands the line
     to the host (ui/message) and calls the app-only yui_tap through the host.

Pass: the screen drew with the option buttons, the host logged the view's
message with the [yui] line, the thread holds the same event row a phone tap
writes (handled, since the host took the message), and the screen row is the
one yui_show wrote. Screenshots land in --out.

    python3 supabase/tests/mcp_app_host_e2e.py [--ext-apps ~/src/ext-apps] [--out DIR]
"""
import argparse, json, os, shutil, socketserver, subprocess, sys, threading, time, urllib.request, uuid
from pathlib import Path

HERE = Path(__file__).resolve().parent
exec(open(HERE / "agents_test.py").read().split("results = []")[0])
from http.server import BaseHTTPRequestHandler  # after the exec: agents_test defines http()

ap = argparse.ArgumentParser()
ap.add_argument("--ext-apps", default=str(Path.home() / "src/ext-apps"))
ap.add_argument("--out", default="/tmp/yui-int7-host")
args = ap.parse_args()
EXT = Path(args.ext_apps).expanduser()
HOSTDIR = EXT / "examples/basic-host"
OUT = Path(args.out)
OUT.mkdir(parents=True, exist_ok=True)
MCP = f"{BASE}/functions/v1/yui-mcp"
LINES = 'choose "Lunch?" Salad|Soup|Tacos\ntimer@t 25m Focus'

results = []
def check(name, ok, detail=""):
    ok = bool(ok); results.append(ok)
    print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  [{str(detail)[:400]}]" if detail else ""), flush=True)

TOKEN = {}
class Proxy(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, status, headers, body):
        self.send_response(status)
        for k, v in headers.items():
            if k.lower() not in ("content-length", "transfer-encoding", "connection", "content-encoding") and not k.lower().startswith("access-control-"):
                self.send_header(k, v)
        self.send_header("access-control-allow-origin", "*")
        self.send_header("access-control-expose-headers", "*")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("access-control-allow-origin", "*")
        self.send_header("access-control-allow-methods", "GET, POST, DELETE, OPTIONS")
        self.send_header("access-control-allow-headers", "*")
        self.send_header("content-length", "0")
        self.end_headers()
    def _fwd(self, method):
        n = int(self.headers.get("content-length") or 0)
        body = self.rfile.read(n) if n else None
        h = {k: v for k, v in self.headers.items() if k.lower() in ("content-type", "accept", "mcp-protocol-version")}
        h["authorization"] = f"Bearer {TOKEN['ct']}"
        req = urllib.request.Request(MCP, data=body, method=method, headers=h)
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                self._send(r.status, dict(r.headers), r.read())
        except urllib.error.HTTPError as e:
            self._send(e.code, dict(e.headers), e.read())
    def do_POST(self): self._fwd("POST")
    def do_GET(self): self._fwd("GET")
    def do_DELETE(self): self._send(405, {}, b"")

T = str(uuid.uuid4())
sql(f"insert into yui_users(id, apple_sub) values ('{T}','test.{T}')")
tok = mint(T, ttl=3600)
host = None
proxy = None
try:
    s, r = fn("yui-agents", {"action": "create", "name": "Claude", "pair": True}, tok)
    agent = r["agent"]["id"]
    s, r = fn("yui-connect", {"action": "pair", "code": r["pairing"]["code"], "remote_ref": "mcp-app-host",
                              "kind": "mcp", "host_name": "MCP Apps reference host"})
    TOKEN["ct"] = r["connector_token"]
    check("paired an MCP connection on a throwaway account", TOKEN["ct"].startswith("yui_ct_"))

    socketserver.ThreadingTCPServer.allow_reuse_address = True
    proxy = socketserver.ThreadingTCPServer(("127.0.0.1", 3001), Proxy)
    threading.Thread(target=proxy.serve_forever, daemon=True).start()

    env = {**os.environ, "SERVERS": json.dumps(["http://localhost:3001/mcp"])}
    host = subprocess.Popen([str(EXT / "node_modules/.bin/tsx"), "serve.ts"], cwd=HOSTDIR, env=env,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    for _ in range(60):
        try:
            urllib.request.urlopen("http://localhost:8080/api/servers", timeout=2); break
        except Exception:
            time.sleep(0.5)
    check("reference host up on :8080 (sandbox :8081)", host.poll() is None)

    shots = {}
    for theme, option in (("dark", "Soup"), ("light", "Tacos")):
        before = sql(f"select count(*) n from yui_messages where user_id = '{T}' and sender = 'agent'")[0]["n"]
        p = subprocess.run(["node", str(HERE / "mcp_app_host.cjs"), str(OUT), LINES, option, theme],
                           env={**os.environ, "PW": str(EXT / "node_modules/playwright")}, capture_output=True, text=True, timeout=180)
        out = json.loads(p.stdout.strip().splitlines()[-1]) if p.returncode == 0 and p.stdout.strip() else {}
        check(f"[{theme}] the host drew the Yui screen and the tap on {option} went out",
              p.returncode == 0 and out.get("status") == f"Sent: {option}", (p.returncode, out.get("status"), p.stderr[-600:]))
        check(f"[{theme}] the host got the view's ui/message with the [yui] line",
              f"[yui] n1 choose choice={option}" in (out.get("message") or ""), out.get("message"))
        after = sql(f"select count(*) n from yui_messages where user_id = '{T}' and sender = 'agent'")[0]["n"]
        rows = sql(f"select body, meta, handled_at is not null handled from yui_messages where user_id = '{T}' "
                   f"and sender = 'user' and body = '[yui] n1 choose choice={option}'")
        check(f"[{theme}] yui_show wrote one screen; the tap is the same event row a phone tap writes, handled",
              after == before + 1 and len(rows) == 1 and rows[0]["handled"]
              and rows[0]["meta"] == {"id": "n1", "preset": "choose", "value": {"choice": option}, "echo": option, "via": "mcp-app"},
              (before, after, rows))
    for f in ("host-screen.png", "host-tapped.png", "host-screen-light.png", "host-tapped-light.png"):
        check(f"screenshot {f}", (OUT / f).exists() and (OUT / f).stat().st_size > 10000, OUT / f)
finally:
    if host:
        host.terminate()
        try: host.wait(5)
        except Exception: host.kill()
    if proxy:
        proxy.shutdown()
    s, _ = fn("yui-delete", {}, tok)
    left = sql(f"select (select count(*) from yui_messages where user_id = '{T}') + "
               f"(select count(*) from yui_users where id = '{T}') + "
               f"(select count(*) from yui_connectors where user_id = '{T}') n")[0]["n"]
    check("throwaway account deleted, nothing left", s == 200 and left == 0, f"{s} {left}")

print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)

#!/usr/bin/env python3
"""INT-8 end to end: Yui as a ChatGPT connector, in an Apps-SDK-shaped host.

ChatGPT itself needs a person's browser, so this plays ChatGPT's side from the
OpenAI Apps SDK docs (auth, reference, UI) against the live server, on a fresh
throwaway account (never a real one):

  1. OAuth the way ChatGPT does it: POST with no token -> 401 -> the protected
     resource metadata -> the auth server metadata by the MCP spec's discovery
     order for an issuer with a path -> dynamic client registration with
     ChatGPT's callback as a confidential client -> /authorize with PKCE and
     resource=<the MCP URL> -> approved in the app -> the redirect carries code,
     state and iss -> /token with client_secret_post and resource.
  2. Tools the way ChatGPT reads them: the model's list leaves out private /
     app-only tools, every tool needs the oauth2 scheme we got, the template is
     found through openai/outputTemplate, the CSP comes from openai/widgetCSP.
  3. A host page (mcp_chatgpt_host.cjs drives it in Chromium) calls yui_show
     with the access token like the model would, mounts the template in a
     sandboxed iframe under a CSP built from openai/widgetCSP, and runs it two
     ways: the MCP Apps bridge (ChatGPT today) and window.openai only (ChatGPT's
     older Apps SDK API, no bridge). The host only lets the view call tools
     marked widgetAccessible. Playwright taps an option in the view.

Pass per mode: the screen drew, the tap reached the host as the person's next
message ([yui] line), the view's yui_tap went through the host, the thread
holds the same event row a phone tap writes (handled), no CSP violations.
Screenshots land in --out.

    python3 supabase/tests/mcp_chatgpt_e2e.py [--ext-apps ~/src/ext-apps] [--out DIR]

--ext-apps is only where Playwright lives (the INT-7 host e2e's checkout).
"""
import argparse, base64, hashlib, json, os, re, secrets, socketserver, subprocess, sys, threading, urllib.parse as up, urllib.request, uuid
from pathlib import Path

HERE = Path(__file__).resolve().parent
exec(open(HERE / "agents_test.py").read().split("results = []")[0])
from http.server import BaseHTTPRequestHandler  # after the exec: agents_test defines http()

ap = argparse.ArgumentParser()
ap.add_argument("--ext-apps", default=str(Path.home() / "src/ext-apps"))
ap.add_argument("--out", default="/tmp/yui-int8-chatgpt")
ap.add_argument("--port", type=int, default=3029)
args = ap.parse_args()
PW = Path(args.ext_apps).expanduser() / "node_modules/playwright"
OUT = Path(args.out)
OUT.mkdir(parents=True, exist_ok=True)
MCP = f"{BASE}/functions/v1/yui-mcp"
CB = "https://chatgpt.com/connector_platform_oauth_redirect"
LINES = 'choose "Lunch?" Salad|Soup|Tacos\ntimer@t 25m Focus'

results = []
def check(name, ok, detail=""):
    ok = bool(ok); results.append(ok)
    print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  [{str(detail)[:400]}]" if detail else ""), flush=True)

class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k): return None
_opener = urllib.request.build_opener(_NoRedirect)
UA = {"user-agent": "yui-tests chatgpt-shape"}

def req(url, data=None, headers=None, method=None):
    r = urllib.request.Request(url, data=data, method=method or ("POST" if data is not None else "GET"), headers={**UA, **(headers or {})})
    try:
        with _opener.open(r, timeout=60) as x:
            txt = x.read().decode(); status, h = x.status, dict(x.headers)
    except urllib.error.HTTPError as e:
        txt = e.read().decode(); status, h = e.code, dict(e.headers)
    try: body = json.loads(txt) if txt else None
    except ValueError: body = txt
    return status, h, body

def rpc(token, method, params=None, rid=1):
    h = {"content-type": "application/json", "accept": "application/json, text/event-stream"}
    if token: h["authorization"] = f"Bearer {token}"
    return req(MCP, json.dumps({"jsonrpc": "2.0", "id": rid, "method": method, "params": params or {}}).encode(), h)

ACCESS = {}
class Host(BaseHTTPRequestHandler):
    """The host's backend: serves the page and the template, and relays MCP
    calls with the access token (the page never holds it, like ChatGPT)."""
    def log_message(self, *a): pass
    def _send(self, status, ctype, body):
        self.send_response(status)
        self.send_header("content-type", ctype)
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def do_GET(self):
        if self.path.startswith("/?") or self.path == "/":
            self._send(200, "text/html; charset=utf-8", (HERE / "mcp_chatgpt_host.html").read_bytes())
        else:
            self._send(404, "text/plain", b"")
    def do_POST(self):
        n = int(self.headers.get("content-length") or 0)
        body = self.rfile.read(n)
        s, _, r = req(MCP, body, {"content-type": "application/json", "accept": "application/json, text/event-stream",
                                  "authorization": f"Bearer {ACCESS['at']}"})
        self._send(s, "application/json", json.dumps(r).encode())

T = str(uuid.uuid4())
sql(f"insert into yui_users(id, apple_sub) values ('{T}','test.{T}')")
tok = mint(T, ttl=3600)
server = None
client_id = None
try:
    # 1. OAuth, ChatGPT's way ------------------------------------------------------------
    s, h, _ = rpc(None, "initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "openai-mcp", "version": "1.0.0"}})
    www = h.get("WWW-Authenticate") or h.get("www-authenticate") or ""
    m = re.search(r'resource_metadata="([^"]+)"', www)
    check("no token: 401 whose WWW-Authenticate names the resource metadata", s == 401 and m, www)
    s, _, prm = req(m.group(1))
    check("protected resource metadata: resource is the MCP URL, one auth server, scope yui",
          s == 200 and prm["resource"] == MCP and len(prm["authorization_servers"]) == 1 and prm["scopes_supported"] == ["yui"], prm)
    issuer = prm["authorization_servers"][0]
    iu = up.urlparse(issuer)
    root = f"{iu.scheme}://{iu.netloc}"
    tried, meta = [], None
    for url in (f"{root}/.well-known/oauth-authorization-server{iu.path}", f"{root}/.well-known/openid-configuration{iu.path}",
                f"{issuer}/.well-known/openid-configuration"):
        s, _, body = req(url)
        tried.append((url.replace(root, ""), s))
        if s == 200 and isinstance(body, dict) and body.get("issuer") == issuer:
            meta = body; break
    check("auth server metadata found by the MCP spec's discovery order (issuer with a path)", meta, tried)
    check("metadata has what ChatGPT needs: S256, DCR, iss in the response, client_secret_post",
          "S256" in meta["code_challenge_methods_supported"] and meta.get("registration_endpoint")
          and meta.get("authorization_response_iss_parameter_supported") is True
          and "client_secret_post" in meta["token_endpoint_auth_methods_supported"], meta)
    s, _, reg = req(meta["registration_endpoint"], json.dumps({
        "client_name": "ChatGPT", "redirect_uris": [CB], "grant_types": ["authorization_code", "refresh_token"],
        "response_types": ["code"], "token_endpoint_auth_method": "client_secret_post", "scope": "yui"}).encode(),
        {"content-type": "application/json"})
    client_id, secret = reg.get("client_id"), reg.get("client_secret")
    check("DCR: ChatGPT registered as a confidential client with its callback", s == 201 and client_id and secret and reg["redirect_uris"] == [CB],
          (s, {k: v for k, v in reg.items() if k != "client_secret"}))
    verifier = secrets.token_urlsafe(48)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    state = secrets.token_urlsafe(16)
    q = {"response_type": "code", "client_id": client_id, "redirect_uri": CB, "state": state, "scope": "yui",
         "code_challenge": challenge, "code_challenge_method": "S256", "resource": MCP}
    s, h, _ = req(f"{meta['authorization_endpoint']}?{up.urlencode(q)}")
    loc = h.get("Location") or h.get("location") or ""
    rid = loc.rsplit("/", 1)[1] if loc.startswith("https://www.yuigui.com/connect/") else None
    check("authorize: the browser goes to yuigui.com/connect/<id>", s == 302 and rid, loc)
    s, r = http("POST", issuer, {"authorization": f"Bearer {tok}"}, {"action": "app_approve", "id": rid})
    check("approved in the app: a new agent named ChatGPT", s == 200 and r["agent"]["name"] == "ChatGPT", (s, r))
    agent_id = r["agent"]["id"]
    s, r = http("POST", issuer, None, {"action": "request", "id": rid})
    back = up.urlparse(r.get("redirect", ""))
    bq = dict(up.parse_qsl(back.query))
    check("the page sends the browser back to ChatGPT's callback with code, state and iss",
          f"{back.scheme}://{back.netloc}{back.path}" == CB and bq.get("code") and bq.get("state") == state and bq.get("iss") == issuer, r.get("redirect"))
    s, _, t = req(meta["token_endpoint"], up.urlencode({
        "grant_type": "authorization_code", "code": bq.get("code"), "redirect_uri": CB, "code_verifier": verifier,
        "client_id": client_id, "client_secret": secret, "resource": MCP}).encode(),
        {"content-type": "application/x-www-form-urlencoded"})
    ACCESS["at"] = t.get("access_token", "")
    check("token: client_secret_post + PKCE + resource gives access and refresh tokens",
          s == 200 and t.get("token_type") == "Bearer" and t.get("refresh_token") and ACCESS["at"], (s, t.get("error"), t.get("error_description")))
    s, _, t2 = req(meta["token_endpoint"], up.urlencode({
        "grant_type": "refresh_token", "refresh_token": t.get("refresh_token"), "client_id": client_id,
        "client_secret": secret, "resource": MCP}).encode(), {"content-type": "application/x-www-form-urlencoded"})
    ACCESS["at"] = t2.get("access_token", ACCESS["at"])
    check("refresh with resource (ChatGPT refreshes hourly) rotates the pair", s == 200 and t2.get("refresh_token") != t.get("refresh_token"), (s, t2.get("error")))

    # 2. Tools, ChatGPT's reading ----------------------------------------------------------
    s, _, r = rpc(ACCESS["at"], "initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                  "clientInfo": {"name": "openai-mcp", "version": "1.0.0"}, "_meta": {"openai/locale": "en-US"}})
    check("initialize with the OAuth token", s == 200 and r["result"]["serverInfo"]["name"] == "yui", (s, r))
    s, _, r = rpc(ACCESS["at"], "tools/list")
    tools = {x["name"]: x for x in r["result"]["tools"]}
    def model_sees(x):
        mm = x.get("_meta", {})
        return mm.get("openai/visibility") != "private" and "model" in mm.get("ui", {}).get("visibility", ["model"])
    check("the model's tool list leaves out the view-only yui_tap",
          sorted(n for n, x in tools.items() if model_sees(x)) == ["yui_answers", "yui_say", "yui_show", "yui_threads"], list(tools))
    check("every tool asks for oauth2 scope yui, which this grant has",
          all(any(sc.get("type") == "oauth2" and "yui" in sc.get("scopes", []) for sc in x.get("securitySchemes", [])) for x in tools.values()))
    tpl = tools["yui_show"]["_meta"].get("openai/outputTemplate")
    s, _, r = rpc(ACCESS["at"], "resources/read", {"uri": tpl})
    c0 = r["result"]["contents"][0]
    check("the template from openai/outputTemplate: MCP App HTML", tpl == "ui://yui/screen" and c0["mimeType"] == "text/html;profile=mcp-app"
          and "openai:set_globals" in c0["text"], (tpl, c0.get("mimeType")))
    check("openai/widgetCSP present (the host builds the frame's CSP from it)", "resource_domains" in c0["_meta"]["openai/widgetCSP"], c0["_meta"])

    # 3. The host --------------------------------------------------------------------------
    socketserver.ThreadingTCPServer.allow_reuse_address = True
    server = socketserver.ThreadingTCPServer(("127.0.0.1", args.port), Host)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    for mode, theme, option in (("bridge", "dark", "Soup"), ("openai", "light", "Tacos")):
        before = sql(f"select count(*) n from yui_messages where user_id = '{T}' and sender = 'agent'")[0]["n"]
        p = subprocess.run(["node", str(HERE / "mcp_chatgpt_host.cjs"), str(OUT), f"http://localhost:{args.port}", mode, theme, LINES, option],
                           env={**os.environ, "PW": str(PW)}, capture_output=True, text=True, timeout=180)
        out = json.loads(p.stdout.strip().splitlines()[-1]) if p.returncode == 0 and p.stdout.strip() else {}
        tag = f"[{mode}, {theme}]"
        check(f"{tag} the host drew the screen from the template and the tap on {option} went out",
              p.returncode == 0 and out.get("status") == f"Sent: {option}", (p.returncode, out.get("status"), p.stderr[-800:]))
        check(f"{tag} the tap reached the host as the person's next message",
              out.get("followups") == [f"[yui] n1 choose choice={option}"], out.get("followups"))
        check(f"{tag} the view called yui_tap through the host, and only that", out.get("viewCalls") == ["yui_tap"], out.get("viewCalls"))
        check(f"{tag} the host saw the path it was testing",
              (out.get("bridgeInit") is True) if mode == "bridge" else (out.get("bridgeInit") is False and out.get("openaiCalls", 0) >= 2), out)
        check(f"{tag} no CSP violations in the frame", out.get("cspErrors") == [], out.get("cspErrors"))
        after = sql(f"select count(*) n from yui_messages where user_id = '{T}' and sender = 'agent'")[0]["n"]
        rows = sql(f"select body, meta, agent_id, handled_at is not null handled from yui_messages where user_id = '{T}' "
                   f"and sender = 'user' and body = '[yui] n1 choose choice={option}'")
        check(f"{tag} one screen in the ChatGPT thread; the tap is the phone's event row, handled",
              after == before + 1 and len(rows) == 1 and rows[0]["handled"] and rows[0]["agent_id"] == agent_id
              and rows[0]["meta"] == {"id": "n1", "preset": "choose", "value": {"choice": option}, "echo": option, "via": "mcp-app"},
              (before, after, rows))
    for f in ("chatgpt-bridge-dark.png", "chatgpt-bridge-dark-tapped.png", "chatgpt-openai-light.png", "chatgpt-openai-light-tapped.png"):
        check(f"screenshot {f}", (OUT / f).exists() and (OUT / f).stat().st_size > 10000, OUT / f)
finally:
    if server:
        server.shutdown()
    s, _ = fn("yui-delete", {}, tok)
    if client_id:
        sql(f"delete from yui_oauth_clients where id = '{client_id}'")
    left = sql(f"select (select count(*) from yui_messages where user_id = '{T}') + "
               f"(select count(*) from yui_users where id = '{T}') + "
               f"(select count(*) from yui_connectors where user_id = '{T}') n")[0]["n"]
    check("throwaway account and client deleted, nothing left", s == 200 and left == 0, f"{s} {left}")

print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)

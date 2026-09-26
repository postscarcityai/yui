#!/usr/bin/env python3
"""INT-3 Yui MCP server (functions/yui-mcp) against PROOF (live).

On a fresh throwaway account (never a real one):

  A. auth: no token, a made-up token and a GET are refused; a Hermes
     connector's token is not an MCP token.
  B. pair with the app's code as kind mcp, like any host.
  C. MCP handshake: initialize, notifications/initialized, tools/list,
     prompts/get yui_guide, resources/read yui://guide.
  D. yui_show: bad lines are refused and nothing is written; good lines land
     as one agent row in the thread (a ```yui fence the app renders), readable
     with the person's own token, with the tap ids the parser gave.
  E. yui_answers: nothing yet, then a tap sent while the call waits comes back
     with its event JSON, marked delivered and handled, and only once; typed
     text comes back too.
  F. yui_say, yui_threads (unread count), a screen id from outside the token's
     threads is refused.
  H. OAuth (INT-19): 401 names the protected resource metadata; discovery
     of yui-oauth; dynamic client registration (bad redirect URIs refused);
     /authorize (unknown client, unregistered redirect, PKCE required, wrong
     resource); approval in the app (never onto a Hermes agent) and with a
     pairing code on the web page; /token with PKCE (wrong verifier, other
     client, code once); the token opens yui-mcp for that one agent; refresh
     rotation and reuse revoking the grant; removing the computer in the app
     kills its tokens; deny; expiry; confidential clients; RFC 7009 revoke;
     step 1 bearer tokens still work.
  I. MCP App (INT-7): the ui://yui/screen resource (HTML, mcp-app mime, CSP),
     yui_show names it and returns structuredContent, the app-only yui_tap
     writes the same event row a phone tap writes (only components on that
     screen, quiet events dropped), told_model marks it handled so
     yui_answers does not return it twice.
  J. ChatGPT shape (INT-8): every tool declares the OAuth securitySchemes,
     yui_show carries openai/outputTemplate and status lines, yui_tap is
     private + widgetAccessible, the screen resource carries openai/widgetCSP
     (the same domains), widgetDescription; calls carrying ChatGPT's client
     _meta work; DCR takes ChatGPT's two redirect URLs and /authorize takes
     its resource parameter.
  G. the rate limit: a burst past `mcp_burst` answers 429.

    python3 supabase/tests/mcp_test.py

Needs a Supabase access token like the other tests. The account is deleted at
the end.
"""
import json, subprocess, sys, threading, time, uuid
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

HERE = Path(__file__).resolve().parent
exec(open(HERE / "agents_test.py").read().split("results = []")[0])

MCP = f"{BASE}/functions/v1/yui-mcp"
results = []
def check(name, ok, detail=""):
    ok = bool(ok); results.append(ok)
    print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  [{str(detail)[:300]}]" if detail else ""), flush=True)

def mcp(body, token=None, method="POST"):
    h = {"accept": "application/json, text/event-stream"}
    if token: h["authorization"] = f"Bearer {token}"
    return http(method, MCP, h, body if method == "POST" else None)

_n = [0]
def rpc(token, method, params=None):
    _n[0] += 1
    s, r = mcp({"jsonrpc": "2.0", "id": _n[0], "method": method, **({"params": params} if params is not None else {})}, token)
    return s, r

def tool(token, name, args=None):
    s, r = rpc(token, "tools/call", {"name": name, "arguments": args or {}})
    assert s == 200 and "result" in r, (s, r)
    res = r["result"]
    text = res["content"][0]["text"]
    data = None
    if not res.get("isError"):
        data = json.loads(text.rsplit("\n", 1)[1])
    return res, text, data

print("== yl.mjs copy")
p = subprocess.run([sys.executable, str(HERE.parent / "scripts/sync_yl.py"), "--check"], capture_output=True, text=True)
check("the function's YL parser matches yuigui's", p.returncode == 0, (p.stdout + p.stderr).strip())

p = subprocess.run([sys.executable, str(HERE.parent / "scripts/sync_mcp_app.py"), "--check"], capture_output=True, text=True)
check("the function's MCP App copy matches yuigui's mcp-app", p.returncode == 0, (p.stdout + p.stderr).strip())

T = str(uuid.uuid4())
sql(f"insert into yui_users(id, apple_sub) values ('{T}','test.{T}')")
tok = mint(T, ttl=3600)
try:
    print("== A. auth")
    s, r = rpc(None, "initialize", {})
    check("no token: 401", s == 401 and r["error"]["code"] == -32001, (s, r))
    s, r = rpc("yui_ct_" + "x" * 43, "initialize", {})
    check("made-up connector token: 401", s == 401, (s, r))
    s, r = rpc(mint(T), "tools/list")
    check("an app token is not an MCP token: 401", s == 401, (s, r))
    s, r = mcp(None, "yui_ct_nope", method="GET")
    check("GET: 405 (stateless, no SSE)", s == 405, s)

    s, r = fn("yui-agents", {"action": "create", "name": "Hermes box", "pair": True}, tok)
    s, r = fn("yui-connect", {"action": "pair", "code": r["pairing"]["code"], "remote_ref": "int3-hermes", "kind": "hermes"})
    hermes_ct = r["connector_token"]
    s, r = rpc(hermes_ct, "tools/list")
    check("a Hermes connector token: 403 not_an_mcp_connector", s == 403 and "not_an_mcp_connector" in json.dumps(r), (s, r))

    print("== B. pair as kind mcp")
    s, r = fn("yui-agents", {"action": "create", "name": "Claude", "pair": True}, tok)
    agent = r["agent"]["id"]
    s, r = fn("yui-connect", {"action": "pair", "code": r["pairing"]["code"], "remote_ref": "claude",
                              "kind": "mcp", "host_name": "Claude Code"})
    ct = r.get("connector_token") or ""
    check("pairs with the app's code, token yui_ct_", s == 200 and ct.startswith("yui_ct_"), (s, r.get("connector")))
    k = sql(f"select c.kind ck, a.kind ak from yui_connectors c join yui_agents a on a.connector_id = c.id where a.id = '{agent}'")
    check("connector and agent are kind mcp", k == [{"ck": "mcp", "ak": "mcp"}], k)

    print("== C. handshake")
    s, r = rpc(ct, "initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                  "clientInfo": {"name": "mcp_test", "version": "1"}})
    res = r.get("result", {})
    check("initialize: version echoed, tools/prompts/resources, instructions",
          s == 200 and res.get("protocolVersion") == "2025-06-18" and res["serverInfo"]["name"] == "yui"
          and {"tools", "prompts", "resources"} <= set(res["capabilities"]) and "yui_show" in res.get("instructions", ""), r)
    s, r = rpc(ct, "initialize", {"protocolVersion": "1999-01-01"})
    check("unknown protocol version: server offers its own", r["result"]["protocolVersion"] in ("2025-06-18", "2025-11-25"), r)
    s, r = mcp({"jsonrpc": "2.0", "method": "notifications/initialized"}, ct)
    check("notifications/initialized: 202, no body", s == 202 and not r, (s, r))
    s, r = rpc(ct, "ping")
    check("ping", s == 200 and r["result"] == {}, r)
    s, r = rpc(ct, "tools/list")
    names = [t["name"] for t in r["result"]["tools"]]
    check("tools/list: the four tools plus the app-only yui_tap", names == ["yui_show", "yui_answers", "yui_say", "yui_threads", "yui_tap"], names)
    tl = {t["name"]: t for t in r["result"]["tools"]}
    check("yui_show names the MCP App, yui_tap is app-only",
          tl["yui_show"].get("_meta", {}).get("ui", {}).get("resourceUri") == "ui://yui/screen"
          and tl["yui_tap"]["_meta"]["ui"]["visibility"] == ["app"], [tl["yui_show"].get("_meta"), tl["yui_tap"].get("_meta")])
    show_desc = r["result"]["tools"][0]["description"]
    check("yui_show carries the short guide", "choose" in show_desc and "timer" in show_desc and "[yui] n1" in show_desc)
    s, r = rpc(ct, "prompts/get", {"name": "yui_guide"})
    g = r["result"]["messages"][0]["content"]["text"]
    check("prompt yui_guide: the channel guide, with the MCP preamble",
          "You are talking to someone in Yui" in g and g.startswith("You reach Yui through MCP tools"), g[:120])
    s, r = rpc(ct, "resources/read", {"uri": "yui://guide"})
    check("resource yui://guide: same text", r["result"]["contents"][0]["text"] == g)
    s, r = rpc(ct, "nope/nope")
    check("unknown method: -32601", r["error"]["code"] == -32601, r)

    def thread():
        s, r = rest("GET", "yui_messages?select=id,sender,body,kind,meta,delivered_at,handled_at"
                           f"&agent_id=eq.{agent}&order=created_at.asc,id.asc", tok)
        assert s == 200, (s, r)
        return r

    def user_says(text, kind="text", meta=None):
        row = {"id": str(uuid.uuid4()), "user_id": T, "agent_id": agent, "sender": "user", "body": text, "kind": kind}
        if meta: row["meta"] = meta
        s, r = rest("POST", "yui_messages", tok, row)
        assert s == 201, (s, r)
        return row["id"]

    print("== D. yui_show")
    before = len(thread())
    res, text, _ = tool(ct, "yui_show", {"lines": 'choose "Pick one" Coffee Walk\nbogus thing'})
    check("bad lines: isError with the parser's message, nothing written",
          res.get("isError") and 'unknown preset "bogus"' in text and len(thread()) == before, text)
    res, text, d = tool(ct, "yui_show", {"text": "Break time?", "lines": 'timer@brk 5m Break\nchoose "Then?" Coffee|Walk|Nap'})
    rows = thread()
    screen = rows[-1]
    check("good lines: one agent row, fenced for the app",
          not res.get("isError") and screen["id"] == d["screen_id"] and screen["sender"] == "agent"
          and screen["body"] == 'Break time?\n```yui\ntimer@brk 5m Break\nchoose "Then?" Coffee|Walk|Nap\n```'
          and screen["meta"] == {"via": "mcp"}, (text, screen))
    check("returns the tap ids the parser gave", d["ids"] == [{"id": "brk", "preset": "timer"}, {"id": "n1", "preset": "choose"}], d)
    res, text, d2 = tool(ct, "yui_show", {"lines": '```yui\nask "Ready?"\n```'})
    check("a fence around the lines comes off", thread()[-1]["body"] == '```yui\nask "Ready?"\n```', thread()[-1]["body"])
    # INT-22: the copy carries yl.mjs's imports, so the lines since agent
    # tables and the restyle parse here like in the app.
    newer = ('theme app autumn\ntable create meals Day:date Cal:number:kcal\nput meals Day=today Cal=640\n'
             'query@today meals where=Day=today sum=Cal as stat "Today"\n'
             'shapes "How an ask lands" caption="It ships to your phone."\nshape circle You\nshape arrow\nshape box Board +fill\nend')
    res, text, d = tool(ct, "yui_show", {"lines": newer})
    check("theme app, table create, put, query and shapes lines are accepted",
          not res.get("isError") and d and d["ids"][:2] == [{"id": "today", "preset": "query"}, {"id": "n1", "preset": "shapes"}], text)

    print("== E. yui_answers")
    res, text, d = tool(ct, "yui_answers", {"screen_id": screen["id"]})
    check("nothing yet", d["answers"] == [] and "Nothing new" in text, text)
    tap = {}
    def later():
        time.sleep(3)
        tap["id"] = user_says("[yui] n1 choose choice=Walk", "event",
                              {"id": "n1", "preset": "choose", "value": {"choice": "Walk"}, "echo": "Walk"})
    threading.Thread(target=later).start()
    t0 = time.time()
    res, text, d = tool(ct, "yui_answers", {"screen_id": screen["id"], "wait": 20})
    took = time.time() - t0
    check("a tap sent during the wait comes back before the wait ends",
          len(d["answers"]) == 1 and d["answers"][0]["id"] == tap.get("id") and 2 < took < 15, f"{took:.1f}s {d}")
    check("with its event JSON and the [yui] line",
          d["answers"][0]["event"] == {"id": "n1", "preset": "choose", "value": {"choice": "Walk"}, "echo": "Walk"}
          and text.startswith("[yui] n1 choose choice=Walk"), text)
    row = next(m for m in thread() if m["id"] == tap["id"])
    check("the tap is marked delivered and handled", row["delivered_at"] and row["handled_at"], row)
    res, text, d = tool(ct, "yui_answers", {"screen_id": screen["id"]})
    check("returned once only", d["answers"] == [], d)
    typed = user_says("make it tea")
    res, text, d = tool(ct, "yui_answers", {})
    check("typed text comes back without a screen id", [a["text"] for a in d["answers"]] == ["make it tea"]
          and "They wrote: make it tea" in text, text)

    print("== F. yui_say, yui_threads, scope")
    res, text, d = tool(ct, "yui_say", {"text": "Tea it is."})
    check("yui_say: a plain agent row", thread()[-1]["body"] == "Tea it is." and thread()[-1]["id"] == d["message_id"])
    user_says("one more")
    res, text, d = tool(ct, "yui_threads")
    check("yui_threads: the one thread, 1 unread", [(t["agent"], t["unread"]) for t in d["threads"]] == [("Claude", 1)], d)
    res, text, _ = tool(ct, "yui_answers", {"screen_id": str(uuid.uuid4())})
    check("a screen id outside its threads is refused", res.get("isError") and "No screen" in text, text)
    res, text, _ = tool(ct, "yui_show", {"lines": "say hi", "agent": "hermes-box"})
    check("an agent on another connector is out of reach", res.get("isError") and 'No agent "hermes-box"' in text, text)
    res, text, _ = tool(ct, "yui_show", {"lines": "say hi", "agent": "claude"})
    check("picking its own agent by ref works", not res.get("isError"), text)

    print("== I. MCP App (INT-7)")
    s, r = rpc(ct, "resources/list")
    check("resources/list: the guide and the screen", [(x["uri"], x["mimeType"]) for x in r["result"]["resources"]]
          == [("yui://guide", "text/markdown"), ("ui://yui/screen", "text/html;profile=mcp-app")], r)
    s, r = rpc(ct, "resources/read", {"uri": "ui://yui/screen"})
    c0 = r["result"]["contents"][0]
    check("ui://yui/screen: one HTML document with the bridge and the renderer",
          c0["mimeType"] == "text/html;profile=mcp-app" and c0["text"].startswith("<!doctype html>")
          and "ui/initialize" in c0["text"] and "yui_tap" in c0["text"] and "<script src" not in c0["text"], len(c0["text"]))
    csp = c0.get("_meta", {}).get("ui", {}).get("csp", {})
    check("its CSP loads images from Yui's storage and fal only, connects nowhere",
          csp.get("resourceDomains", [None])[0] == BASE and "connectDomains" not in csp, csp)

    print("== J. ChatGPT shape (INT-8)")
    SEC = [{"type": "oauth2", "scopes": ["yui"]}]
    check("every tool declares the OAuth securitySchemes, top level and in _meta",
          all(t.get("securitySchemes") == SEC and t.get("_meta", {}).get("securitySchemes") == SEC for t in tl.values()),
          {n: t.get("securitySchemes") for n, t in tl.items()})
    sm = tl["yui_show"]["_meta"]
    check("yui_show: openai/outputTemplate is the MCP App, with status lines under 64 characters",
          sm.get("openai/outputTemplate") == sm["ui"]["resourceUri"] == "ui://yui/screen"
          and 0 < len(sm.get("openai/toolInvocation/invoking", "")) <= 64 and 0 < len(sm.get("openai/toolInvocation/invoked", "")) <= 64, sm)
    tm = tl["yui_tap"]["_meta"]
    check("yui_tap: hidden from the model, callable from the view (private + widgetAccessible)",
          tm.get("openai/visibility") == "private" and tm.get("openai/widgetAccessible") is True, tm)
    check("the model tools have ChatGPT's annotations (readOnly, destructive, openWorld)",
          all({"readOnlyHint", "destructiveHint", "openWorldHint"} <= set(t.get("annotations", {})) for t in tl.values())
          and tl["yui_threads"]["annotations"]["readOnlyHint"] is True)
    m0 = c0.get("_meta", {})
    wcsp = m0.get("openai/widgetCSP", {})
    check("the screen: openai/widgetCSP names the same image domains, connects nowhere",
          wcsp.get("resource_domains") == csp.get("resourceDomains") and wcsp.get("connect_domains") == [], wcsp)
    check("the screen: widgetDescription and no border", "[yui]" in m0.get("openai/widgetDescription", "")
          and m0.get("openai/widgetPrefersBorder") is False and m0["ui"]["prefersBorder"] is False, m0)
    s, r = rpc(ct, "resources/list")
    check("resources/list carries the screen's _meta too",
          [x.get("_meta") for x in r["result"]["resources"] if x["uri"] == "ui://yui/screen"] == [m0], r["result"]["resources"][1].get("_meta"))
    s, r = rpc(ct, "tools/call", {"name": "yui_threads", "arguments": {},
                                  "_meta": {"openai/locale": "en-US", "openai/subject": "v1/abc", "openai/session": "v1/def",
                                            "openai/userLocation": {"country": "US", "timezone": "America/New_York"}}})
    check("a call carrying ChatGPT's client _meta works", s == 200 and not r["result"].get("isError"), r)

    res, text, d = tool(ct, "yui_show", {"text": "Lunch?", "lines": 'choose "Lunch?" Salad|Soup\ntimer@t 1m Steep'})
    sc = res.get("structuredContent") or {}
    app_screen = d["screen_id"]
    check("yui_show: structuredContent carries the screen id and the lines for the view",
          sc.get("screen_id") == app_screen and sc.get("lines") == 'choose "Lunch?" Salad|Soup\ntimer@t 1m Steep', sc)
    res, text, _ = tool(ct, "yui_tap", {"screen_id": app_screen, "event": {"id": "n9", "preset": "choose", "choice": "Salad"}})
    check("yui_tap: a component not on that screen is refused", res.get("isError") and "No choose with id n9" in text, text)
    res, text, _ = tool(ct, "yui_tap", {"screen_id": screen["id"], "event": {"id": "n1", "preset": "ask", "answer": "x"}})
    check("yui_tap: a component on another screen is refused", res.get("isError"), text)
    res, text, _ = tool(ct, "yui_tap", {"screen_id": str(uuid.uuid4()), "event": {"id": "n1", "preset": "choose", "choice": "Salad"}})
    check("yui_tap: a screen outside its threads is refused", res.get("isError") and "No screen" in text, text)
    n0 = len(thread())
    res, text, d = tool(ct, "yui_tap", {"screen_id": app_screen, "event": {"id": "t", "preset": "timer", "started": True}})
    check("yui_tap: a quiet event (timer started) writes nothing", d == {"sent": False} and len(thread()) == n0, (d, len(thread())))
    res, text, d = tool(ct, "yui_tap", {"screen_id": app_screen, "event": {"id": "n1", "preset": "choose", "choice": "Soup"}})
    row = next(m for m in thread() if m["id"] == d.get("message_id"))
    check("yui_tap: the same event row a phone tap writes",
          row["sender"] == "user" and row["kind"] == "event" and row["body"] == "[yui] n1 choose choice=Soup"
          and row["meta"] == {"id": "n1", "preset": "choose", "value": {"choice": "Soup"}, "echo": "Soup", "via": "mcp-app"}
          and not row["handled_at"], row)
    res, text, d = tool(ct, "yui_answers", {"screen_id": app_screen})
    check("yui_answers returns the embedded tap like a phone tap",
          [a["text"] for a in d["answers"]] == ["[yui] n1 choose choice=Soup"] and d["answers"][0]["event"]["echo"] == "Soup", d)
    res, text, d = tool(ct, "yui_tap", {"screen_id": app_screen, "told_model": True,
                                       "event": {"id": "n1", "preset": "choose", "choice": "Salad", "changed": True}})
    row = next(m for m in thread() if m["id"] == d.get("message_id"))
    check("told_model: written handled (the model already has it), changed flag kept",
          row["body"] == "[yui] n1 choose changed choice=Salad" and row["handled_at"] and row["delivered_at"], row)
    res, text, d = tool(ct, "yui_answers", {"screen_id": app_screen})
    check("...so yui_answers does not return it a second time", d["answers"] == [], d)
    res, text, d = tool(ct, "yui_tap", {"screen_id": app_screen, "event": {"id": "t", "preset": "timer", "done": True, "rounds": 1}})
    check("a finished timer goes back (done), no echo", d.get("sent") and d.get("line") == "[yui] t timer done rounds=1" and d.get("echo") is None, d)
    tool(ct, "yui_answers", {})

    print("== H. OAuth (INT-19)")
    import base64 as _b64, hashlib as _hl, secrets as _sec, urllib.parse as up
    OAUTH = f"{BASE}/functions/v1/yui-oauth"
    CB = "https://client.example.com/callback"

    class _NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *a, **k): return None
    _opener = urllib.request.build_opener(_NoRedirect)
    def get(url):
        try:
            with _opener.open(urllib.request.Request(url, headers={"user-agent": "yui-tests"})) as r:
                txt = r.read().decode(); return r.status, dict(r.headers), (json.loads(txt) if txt else None)
        except urllib.error.HTTPError as e:
            txt = e.read().decode()
            try: body = json.loads(txt)
            except ValueError: body = txt
            return e.code, dict(e.headers), body
    def form(path, fields, basic=None):
        h = {"content-type": "application/x-www-form-urlencoded", "user-agent": "yui-tests"}
        if basic: h["authorization"] = "Basic " + _b64.b64encode(basic.encode()).decode()
        req = urllib.request.Request(f"{OAUTH}{path}", data=up.urlencode(fields).encode(), method="POST", headers=h)
        try:
            with urllib.request.urlopen(req) as r:
                txt = r.read().decode(); return r.status, (json.loads(txt) if txt else None)
        except urllib.error.HTTPError as e:
            txt = e.read().decode()
            try: return e.code, json.loads(txt)
            except ValueError: return e.code, txt
    def pkce():
        v = _sec.token_urlsafe(48)
        return v, _b64.urlsafe_b64encode(_hl.sha256(v.encode()).digest()).rstrip(b"=").decode()
    def authorize(client_id, challenge, state="st-1", **extra):
        q = {"response_type": "code", "client_id": client_id, "redirect_uri": CB, "state": state,
             "code_challenge": challenge, "code_challenge_method": "S256", "scope": "yui", "resource": MCP, **extra}
        return get(f"{OAUTH}/authorize?{up.urlencode({k: v for k, v in q.items() if v is not None})}")
    def request_id(headers):
        loc = headers.get("Location") or headers.get("location") or ""
        return loc.rsplit("/", 1)[1] if loc.startswith("https://www.yuigui.com/connect/") else None
    def web(action, **kw):
        return http("POST", OAUTH, None, {"action": action, **kw})
    def app(action, token, **kw):
        return http("POST", OAUTH, {"authorization": f"Bearer {token}"}, {"action": action, **kw})
    def code_of(redirect):
        q = dict(up.parse_qsl(up.urlparse(redirect).query)); return q
    oauth_clients = []

    # discovery
    s, r = rpc(None, "initialize", {})
    req0 = urllib.request.Request(MCP, data=b"{}", method="POST", headers={"content-type": "application/json", "user-agent": "yui-tests"})
    try: urllib.request.urlopen(req0); www = ""
    except urllib.error.HTTPError as e: www = e.headers.get("www-authenticate", "")
    check("401 names the protected resource metadata", s == 401 and f'resource_metadata="{MCP}/.well-known/oauth-protected-resource"' in www, www)
    _, _, prm = get(MCP + "/.well-known/oauth-protected-resource")
    check("protected resource metadata: resource + yui-oauth", prm.get("resource") == MCP and prm.get("authorization_servers") == [OAUTH], prm)
    _, _, meta = get(OAUTH + "/.well-known/oauth-authorization-server")
    _, _, oidc = get(OAUTH + "/.well-known/openid-configuration")
    check("auth server metadata: issuer, S256, DCR, both discovery paths",
          meta.get("issuer") == OAUTH and meta.get("code_challenge_methods_supported") == ["S256"]
          and meta.get("registration_endpoint") == OAUTH + "/register" and oidc == meta, meta)

    # dynamic client registration
    s, r = http("POST", OAUTH + "/register", None, {"client_name": "Evil", "redirect_uris": ["http://evil.example.com/cb"]})
    check("DCR: plain http off loopback refused", s == 400 and r.get("error") == "invalid_redirect_uri", (s, r))
    s, r = http("POST", OAUTH + "/register", None, {"client_name": "Evil", "redirect_uris": ["javascript:alert(1)"]})
    check("DCR: javascript: refused", s == 400, (s, r))
    s, reg = http("POST", OAUTH + "/register", None, {"client_name": "Test Claude", "redirect_uris": [CB],
                  "grant_types": ["authorization_code", "refresh_token"], "token_endpoint_auth_method": "none"})
    cid = reg.get("client_id", "")
    oauth_clients.append(cid)
    check("DCR: public client registered, no secret", s == 201 and cid.startswith("yui_oc_") and "client_secret" not in reg, (s, reg))

    # ChatGPT registers with one of its two callbacks (Apps SDK auth docs) and
    # sends resource=<the MCP URL> on /authorize.
    for cb in ("https://chatgpt.com/connector_platform_oauth_redirect", "https://chatgpt.com/connector/oauth/cb_test123"):
        s, gr = http("POST", OAUTH + "/register", None, {"client_name": "ChatGPT", "redirect_uris": [cb],
                     "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"],
                     "token_endpoint_auth_method": "client_secret_post"})
        oauth_clients.append(gr.get("client_id", ""))
        check(f"DCR (ChatGPT): {cb.split('/', 3)[3]} registered as a confidential client",
              s == 201 and gr.get("client_secret") and gr.get("redirect_uris") == [cb], (s, {k: v for k, v in gr.items() if k != "client_secret"}))
        _, gch = pkce()
        q = {"response_type": "code", "client_id": gr.get("client_id"), "redirect_uri": cb, "state": "gpt",
             "code_challenge": gch, "code_challenge_method": "S256", "scope": "yui", "resource": MCP}
        s, h, _ = get(f"{OAUTH}/authorize?{up.urlencode(q)}")
        check("authorize (ChatGPT): its redirect and resource go to the connect page", s == 302 and request_id(h), h.get("Location"))
    check("auth server metadata: what ChatGPT reads (S256, DCR, iss in the response, token auth methods)",
          meta.get("authorization_response_iss_parameter_supported") is True and "client_secret_post" in meta.get("token_endpoint_auth_methods_supported", [])
          and "none" in meta.get("token_endpoint_auth_methods_supported", []) and prm.get("scopes_supported") == ["yui"], meta)

    # authorize
    v, ch = pkce()
    s, h, _ = authorize("yui_oc_nope" + "x" * 20, ch)
    check("authorize: unknown client goes to our error page", s == 302 and h.get("Location", "").endswith("/connect?error=unknown_client"), h.get("Location"))
    s, h, _ = get(f"{OAUTH}/authorize?" + up.urlencode({"response_type": "code", "client_id": cid, "redirect_uri": "https://evil.example.com/cb", "code_challenge": ch, "code_challenge_method": "S256"}))
    check("authorize: unregistered redirect_uri never redirected to", s == 302 and h.get("Location", "").endswith("/connect?error=bad_redirect"), h.get("Location"))
    s, h, _ = authorize(cid, ch, code_challenge_method="plain")
    loc = code_of(h.get("Location", ""))
    check("authorize: PKCE S256 required", s == 302 and loc.get("error") == "invalid_request" and loc.get("state") == "st-1", h.get("Location"))
    s, h, _ = authorize(cid, ch, resource="https://elsewhere.example.com/mcp")
    check("authorize: another resource refused", code_of(h.get("Location", "")).get("error") == "invalid_target", h.get("Location"))
    s, h, _ = authorize(cid, ch)
    rid = request_id(h)
    check("authorize: sends the browser to www.yuigui.com/connect/<id>", s == 302 and rid, h.get("Location"))
    s, r = web("request", id=rid)
    check("web: request pending, client name and site", s == 200 and r["status"] == "pending"
          and r["client"] == {"name": "Test Claude", "site": "client.example.com", "url": None} and "redirect" not in r, r)

    # the app hand-off
    s, r = app("app_request", mint(str(uuid.uuid4())), id=rid)
    check("app: a token for no account is refused", s == 401, (s, r))
    s, r = app("app_request", tok, id=rid)
    names = [a["name"] for a in r.get("agents", [])]
    check("app: offers MCP and unbound agents, never a Hermes one", s == 200 and "Claude" in names and "Hermes box" not in names
          and r["suggested_name"] == "Test Claude", r)
    hermes_agent = sql(f"select id from yui_agents where user_id = '{T}' and name = 'Hermes box'")[0]["id"]
    s, r = app("app_approve", tok, id=rid, agent_id=hermes_agent)
    check("app: approving onto a Hermes agent is refused", s == 400, (s, r))
    s, r = app("app_approve", tok, id=rid)
    oauth_agent = (r.get("agent") or {}).get("id")
    check("app: approve makes a new agent named after the client", s == 200 and r["status"] == "approved"
          and r["agent"]["name"] == "Test Claude", r)
    s, r = app("app_approve", tok, id=rid)
    check("app: a second approve is refused", s == 409, (s, r))
    k = sql(f"select c.kind ck, c.name cn, a.kind ak from yui_connectors c join yui_agents a on a.connector_id = c.id where a.id = '{oauth_agent}'")
    check("the grant is a kind-mcp connector named after the client", k == [{"ck": "mcp", "cn": "Test Claude", "ak": "mcp"}], k)
    s, r = web("request", id=rid)
    q = code_of(r.get("redirect", ""))
    check("web: first poll after approval redirects back with code, state, iss",
          r.get("redirect", "").startswith(CB + "?") and q.get("code", "").startswith("yui_ac_") and q.get("state") == "st-1" and q.get("iss") == OAUTH, r)
    s, r2 = web("request", id=rid)
    check("web: the code is handed out once", "redirect" not in r2, r2)
    code = q.get("code", "")

    # token
    s, r = form("/token", {"grant_type": "authorization_code", "code": code, "redirect_uri": CB, "client_id": cid, "code_verifier": pkce()[0]})
    check("token: a wrong code_verifier fails PKCE", s == 400 and r.get("error") == "invalid_grant" and "PKCE" in r.get("error_description", ""), (s, r))
    s, r = form("/token", {"grant_type": "authorization_code", "code": code, "redirect_uri": CB, "client_id": "yui_oc_" + "y" * 32, "code_verifier": v})
    check("token: another client can't use the code", s == 401 and r.get("error") == "invalid_client", (s, r))
    s, t1 = form("/token", {"grant_type": "authorization_code", "code": code, "redirect_uri": CB, "client_id": cid, "code_verifier": v})
    at, rt = t1.get("access_token", ""), t1.get("refresh_token", "")
    check("token: code + verifier gives access and refresh tokens", s == 200 and at.startswith("yui_at_") and rt.startswith("yui_rt_")
          and t1["token_type"] == "Bearer" and t1["expires_in"] == 3600, (s, {k: v for k, v in t1.items() if "token" not in k}))
    hashes = sql(f"select count(*) n from yui_oauth_tokens where token_hash in ('{hashlib.sha256(at.encode()).hexdigest()}','{hashlib.sha256(rt.encode()).hexdigest()}')")[0]["n"]
    plain = sql(f"select count(*) n from yui_oauth_tokens where token_hash like 'yui_%'")[0]["n"]
    check("only token hashes are stored", hashes == 2 and plain == 0, (hashes, plain))

    # the MCP server with an OAuth token
    s, r = rpc(at, "initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "oauth", "version": "1"}})
    check("MCP: the access token opens yui-mcp", s == 200 and r["result"]["serverInfo"]["name"] == "yui", (s, r))
    res, text, d = tool(at, "yui_threads")
    check("MCP: it serves only the approved agent", [t["agent"] for t in d["threads"]] == ["Test Claude"], d)
    res, text, d = tool(at, "yui_show", {"lines": 'ask "Ready?" Yes|No'})
    row = sql(f"select agent_id, meta->>'via' via from yui_messages where id = '{d['screen_id']}'") if d else []
    check("MCP: yui_show lands in that agent's thread", row == [{"agent_id": oauth_agent, "via": "mcp"}], row)

    # refresh rotation and reuse
    s, t2 = form("/token", {"grant_type": "refresh_token", "refresh_token": rt, "client_id": cid})
    check("refresh: rotates to a new pair", s == 200 and t2["refresh_token"] != rt and t2["access_token"] != at, (s, t2.get("error")))
    s, r = rpc(t2.get("access_token"), "ping")
    check("refresh: the new access token works", s == 200, (s, r))
    s, r = form("/token", {"grant_type": "refresh_token", "refresh_token": rt, "client_id": cid})
    check("refresh: an old refresh token played again is refused", s == 400 and r.get("error") == "invalid_grant" and "reused" in r["error_description"], (s, r))
    s, r = rpc(t2.get("access_token"), "ping")
    check("refresh: ...and that revokes the whole grant", s == 401, (s, r))
    s, r = form("/token", {"grant_type": "authorization_code", "code": code, "redirect_uri": CB, "client_id": cid, "code_verifier": v})
    check("token: a code works once", s == 400 and r.get("error") == "invalid_grant", (s, r))

    # the pairing-code way in, and revoke in the app
    v2, ch2 = pkce()
    _, h, _ = authorize(cid, ch2, state="st-2")
    rid2 = request_id(h)
    s, r = web("code", id=rid2, code="000000")
    check("web code: a wrong code is refused", s == 401 and r.get("error") == "invalid_or_expired_code", (s, r))
    s, r = fn("yui-agents", {"action": "create", "name": "Cursor", "pair": True}, tok)
    cursor_agent, pair_code = r["agent"]["id"], r["pairing"]["code"]
    s, r = web("code", id=rid2, code=pair_code)
    check("web code: Add agent's code approves for that agent", s == 200 and r["status"] == "approved" and r["agent"]["id"] == cursor_agent, (s, r))
    s, r = web("request", id=rid2)
    q2 = code_of(r.get("redirect", ""))
    s, t3 = form("/token", {"grant_type": "authorization_code", "code": q2.get("code", ""), "redirect_uri": CB, "client_id": cid, "code_verifier": v2})
    at3, rt3 = t3.get("access_token"), t3.get("refresh_token")
    res, text, d = tool(at3, "yui_threads")
    check("web code: the token serves the Cursor agent", s == 200 and [t["agent"] for t in d["threads"]] == ["Cursor"], d)
    conn = sql(f"select connector_id from yui_agents where id = '{cursor_agent}'")[0]["connector_id"]
    s, r = fn("yui-agents", {"action": "connector_revoke", "id": conn}, tok)
    s1, _ = rpc(at3, "ping")
    s2, r2 = form("/token", {"grant_type": "refresh_token", "refresh_token": rt3, "client_id": cid})
    check("removing the computer in the app kills its tokens", s == 200 and s1 == 401 and s2 == 400 and r2.get("error") == "invalid_grant", (s, s1, s2, r2))

    # deny, expiry, confidential clients, RFC 7009
    _, h, _ = authorize(cid, pkce()[1], state="st-3")
    s, r = web("deny", id=request_id(h))
    dq = code_of(r.get("redirect", ""))
    check("deny: back to the client with access_denied and state", dq.get("error") == "access_denied" and dq.get("state") == "st-3", r)
    _, h, _ = authorize(cid, pkce()[1])
    rid4 = request_id(h)
    sql(f"update yui_oauth_requests set expires_at = now() - interval '1 minute' where id = '{rid4}'")
    s, r = app("app_approve", tok, id=rid4)
    s2, r2 = web("request", id=rid4)
    check("an expired request can't be approved", s == 410 and r2["status"] == "expired", (s, r, r2))
    s, conf = http("POST", OAUTH + "/register", None, {"client_name": "Conf", "redirect_uris": [CB], "token_endpoint_auth_method": "client_secret_post"})
    oauth_clients.append(conf.get("client_id"))
    check("DCR: a confidential client gets a secret", s == 201 and conf.get("client_secret", "").startswith("yui_cs_"), (s, conf.get("token_endpoint_auth_method")))
    v5, ch5 = pkce()
    _, h, _ = authorize(conf["client_id"], ch5)
    rid5 = request_id(h)
    app("app_approve", tok, id=rid5, name="Conf agent")
    c5 = code_of(web("request", id=rid5)[1].get("redirect", "")).get("code")
    s, r = form("/token", {"grant_type": "authorization_code", "code": c5, "redirect_uri": CB, "client_id": conf["client_id"], "code_verifier": v5})
    check("token: a confidential client without its secret is refused", s == 401 and r.get("error") == "invalid_client", (s, r))
    s, t5 = form("/token", {"grant_type": "authorization_code", "code": c5, "redirect_uri": CB, "code_verifier": v5},
                 basic=f"{conf['client_id']}:{conf['client_secret']}")
    check("token: ...and with it (HTTP Basic) gets tokens", s == 200 and t5.get("access_token", "").startswith("yui_at_"), (s, t5.get("error")))
    s, _ = form("/revoke", {"token": t5.get("refresh_token", ""), "client_id": conf["client_id"], "client_secret": conf["client_secret"]})
    s1, _ = rpc(t5.get("access_token"), "ping")
    gone = sql(f"select revoked_at is not null r from yui_connectors c join yui_agents a on a.connector_id = c.id where a.user_id = '{T}' and a.name = 'Conf agent'")
    check("revoke (RFC 7009): a refresh token ends the grant", s == 200 and s1 == 401 and gone == [{"r": True}], (s, s1, gone))
    s, r = rpc(ct, "ping")
    check("step 1 bearer tokens still work beside OAuth", s == 200, (s, r))
    sql("delete from yui_oauth_clients where id in (" + ",".join(f"'{c}'" for c in oauth_clients if c) + ")")

    print("== G. rate limit")
    with ThreadPoolExecutor(16) as ex:
        codes = list(ex.map(lambda _: rpc(ct, "ping")[0], range(80)))
    check("a burst past mcp_burst (60) gets 429s", codes.count(429) >= 10 and set(codes) <= {200, 429},
          {c: codes.count(c) for c in set(codes)})
finally:
    s, _ = fn("yui-delete", {}, tok)
    left = sql(f"select (select count(*) from yui_messages where user_id = '{T}') + "
               f"(select count(*) from yui_users where id = '{T}') + "
               f"(select count(*) from yui_connectors where user_id = '{T}') + "
               f"(select count(*) from yui_oauth_tokens where user_id = '{T}') + "
               f"(select count(*) from yui_oauth_requests where user_id = '{T}') n")[0]["n"]
    check("throwaway account deleted, nothing left", s == 200 and left == 0, f"{s} {left}")

print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)

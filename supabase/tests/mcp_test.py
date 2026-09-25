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
    check("tools/list: the four tools", names == ["yui_show", "yui_answers", "yui_say", "yui_threads"], names)
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

    print("== G. rate limit")
    with ThreadPoolExecutor(16) as ex:
        codes = list(ex.map(lambda _: rpc(ct, "ping")[0], range(80)))
    check("a burst past mcp_burst (60) gets 429s", codes.count(429) >= 10 and set(codes) <= {200, 429},
          {c: codes.count(c) for c in set(codes)})
finally:
    s, _ = fn("yui-delete", {}, tok)
    left = sql(f"select (select count(*) from yui_messages where user_id = '{T}') + "
               f"(select count(*) from yui_users where id = '{T}') + "
               f"(select count(*) from yui_connectors where user_id = '{T}') n")[0]["n"]
    check("throwaway account deleted, nothing left", s == 200 and left == 0, f"{s} {left}")

print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)

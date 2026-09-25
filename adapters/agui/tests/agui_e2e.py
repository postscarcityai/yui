#!/usr/bin/env python3
"""INT-21 end to end: a Microsoft Agent Framework agent over AG-UI, in live Yui.

The agent is tests/sdk/maf_agui_agent.py: Agent Framework's own AG-UI endpoint
(add_agent_framework_fastapi_endpoint, agent-framework-ag-ui) on FastAPI, one
agent on local Ollama qwen2.5:7b (no key) whose instructions never mention
Yui. The bridge (yui-agui.ts) brings the rest in each RunAgentInput. On a
fresh throwaway account (never a real one):

  A. pair with the app's code; `pair` runs the agent once first, so a wrong
     URL fails before the code is spent; the state file is private.
  B. a turn: answered once, meta.turn names it, delivered and handled.
  C. a screen through the frontend tool: the model calls yui_show, the run
     ends there, and the reply has a ```yui fence the YL parser reads, with
     choices. The guide reached the model as a system message.
  D. the tap goes back as yui_show's tool result in the next run (not as the
     person's words) and is answered once; the call is closed.
  E. the next turn recalls the tap: the bridge keeps the AG-UI thread.
  F. kill -9 while the agent works: after a restart the same turn (same
     runId) runs again and is answered, once.
  G. a clean stop reads offline; every row handled and answered exactly once;
     no connector token in the bridge's log; the account is deleted.

    python3 adapters/agui/tests/agui_e2e.py

Needs Node 22.18+, uv, Ollama with qwen2.5:7b, and a Supabase access token
like supabase/tests.
"""
import json, os, signal, socket, subprocess, sys, tempfile, time, urllib.request, uuid
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
AGUI = REPO / "adapters/agui"
CLI = ["node", str(AGUI / "yui-agui.ts")]
YL = Path.home() / "dev/yuigui/site/lib/yl/yl.mjs"
SHOW_RETRIES = 3

exec(open(REPO / "supabase/tests/agents_test.py").read().split("results = []")[0])

results = []
def check(name, ok, detail=""):
    ok = bool(ok); results.append(ok)
    print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  [{detail}]" if detail else ""), flush=True)
def log(msg): print(f"  .. {msg}", flush=True)
def wait(cond, secs, what):
    end = time.time() + secs
    while time.time() < end:
        v = cond()
        if v:
            return v
        time.sleep(0.5)
    raise TimeoutError(what)

def yl_ops(text):
    """The YL parser's ops for every ```yui fence in a reply."""
    ops = []
    for fence in text.split("```yui\n")[1:]:
        fence = fence.split("```", 1)[0]
        js = f"import({json.dumps(str(YL))}).then(m => console.log(JSON.stringify(m.parse({json.dumps(fence)}))))"
        ops += json.loads(subprocess.check_output(["node", "-e", js], text=True))
    return ops

def free_port():
    with socket.socket() as so:
        so.bind(("127.0.0.1", 0))
        return so.getsockname()[1]


print("==== AG-UI: a Microsoft Agent Framework agent through the AG-UI bridge (INT-21)")
home = Path(tempfile.mkdtemp(prefix="yui-int21-agui-"))
state = home / "agui.json"
bridgelog = home / "bridge.log"
maflog = home / "maf.log"
mport = free_port()
URL = f"http://127.0.0.1:{mport}/"
T = str(uuid.uuid4())
tok = None
agent = None
maf = None
proc = [None]
ups = [0]

def say(text, kind="text", meta=None):
    row = {"id": str(uuid.uuid4()), "user_id": T, "agent_id": agent, "sender": "user", "body": text, "kind": kind}
    if meta:
        row["meta"] = meta
    s, r = rest("POST", "yui_messages", tok, row)
    assert s == 201, (s, r)
    log(f"app sent {text!r}")
    return row["id"]

def thread():
    s, r = rest("GET", "yui_messages?select=id,sender,body,kind,meta,delivered_at,handled_at"
                       f"&agent_id=eq.{agent}&order=created_at.asc,id.asc", tok)
    assert s == 200, (s, r)
    return r

def replies_to(rid):
    return [m for m in thread() if m["sender"] == "agent" and rid in ((m.get("meta") or {}).get("turn") or [])]

def row(rid):
    return next(m for m in thread() if m["id"] == rid)

def presence():
    return rest("GET", f"yui_agent_list?select=presence&id=eq.{agent}", tok)[1][0]["presence"]

def st():
    return json.loads(state.read_text())

def start():
    proc[0] = subprocess.Popen(CLI + ["--state", str(state), "run", "--interval", "1"],
                               stdout=open(bridgelog, "a"), stderr=subprocess.STDOUT)
    ups[0] += 1
    wait(lambda: bridgelog.read_text().count("online as") >= ups[0], 60, "bridge online in Yui")
    log(f"bridge up, pid {proc[0].pid}")

def maf_up():
    try:
        urllib.request.urlopen(URL, timeout=2)
    except urllib.error.HTTPError:
        return True  # 405 on GET: the endpoint is there
    except Exception:
        return False
    return True

try:
    # Agent Framework's AG-UI endpoint. agent-framework-ollama is a beta: allowed by name, so httpx stays on 0.x.
    maf = subprocess.Popen(["uv", "run", "--quiet", "--python", "3.12", "--with", "agent-framework-ag-ui>=1.4.0",
                            "--with", "agent-framework-ollama>=1.0.0b0", "--with", "uvicorn",
                            str(AGUI / "tests/sdk/maf_agui_agent.py"), str(mport)],
                           stdout=open(maflog, "w"), stderr=subprocess.STDOUT, start_new_session=True)
    wait(maf_up, 300, "Agent Framework AG-UI endpoint")
    ver = subprocess.run(["uv", "run", "--quiet", "--python", "3.12", "--with", "agent-framework-ag-ui>=1.4.0", "python", "-c",
                          "import importlib.metadata as m; print(m.version('agent-framework-ag-ui'), m.version('ag-ui-protocol'))"],
                         capture_output=True, text=True).stdout.strip()
    log(f"agent-framework-ag-ui, ag-ui-protocol: {ver} at {URL}")

    sql(f"insert into yui_users(id, apple_sub) values ('{T}','test.{T}')")
    tok = mint(T, ttl=3600)
    s, r = fn("yui-agents", {"action": "create", "name": "MAF AG-UI", "pair": True}, tok)
    agent = r["agent"]["id"]
    code = r["pairing"]["code"]

    print("== A. pair")
    bad = subprocess.run(CLI + ["--state", str(home / "bad.json"), "pair", code, "--url", f"http://127.0.0.1:{free_port()}/"],
                         capture_output=True, text=True, timeout=60)
    check("agui: a wrong URL fails before the code is spent", bad.returncode != 0 and not (home / "bad.json").exists(),
          bad.stderr.strip()[:160])
    p = subprocess.run(CLI + ["--state", str(state), "pair", code, "--url", URL, "--name", "maf_helper",
                              "--host-name", "INT-21 test"], capture_output=True, text=True, timeout=300)
    check("agui: pairs with the app's code after one hello run", p.returncode == 0 and "paired" in p.stdout,
          (p.stdout + p.stderr).strip()[:200])
    check("agui: state file is private and holds the connector token",
          oct(state.stat().st_mode & 0o777) == "0o600" and st().get("token", "").startswith("yui_ct_"))

    print("== B. a turn")
    start()
    check("agui: agent reads online", wait(lambda: presence() == "online", 20, "online"))
    hi = say("Hi! In one short sentence, what can you help with?")
    rep = wait(lambda: replies_to(hi), 300, "the answer")
    wait(lambda: row(hi)["handled_at"], 20, "hi handled")
    check("agui: the turn is answered once, meta.turn names it, delivered and handled",
          len(rep) == 1 and rep[0]["body"].strip() and rep[0]["meta"] == {"turn": [hi]}
          and row(hi)["delivered_at"] and row(hi)["handled_at"], rep and rep[0]["body"][:200])

    print("== C. a screen through yui_show")
    body, picks, ops, via_tool, tries = "", [], [], False, 0
    while not (picks and via_tool) and tries < SHOW_RETRIES:  # a 7B model sometimes writes the list out; ask again, like a person would
        tries += 1
        ask = say("Help me pick a drink for this afternoon: Tea or Coffee. Show me buttons to tap.")
        rep = wait(lambda: replies_to(ask), 300, "the screen")
        body = rep[0]["body"]
        ops = yl_ops(body)
        picks = [o for o in ops if o.get("op") == "add" and o.get("preset") in ("choose", "ask", "pick")]
        calls = st().get("calls", {}).get(agent) or []
        via_tool = any(c["function"]["name"] == "yui_show" for c in calls)
        if not (picks and via_tool):
            log(f"try {tries}: via yui_show={via_tool}, {len(picks)} choice op(s): {body[:140]!r}")
    run = next((t for t in reversed(st()["threads"][agent]) if t["role"] == "assistant" and t.get("toolCalls")), None)
    check(f"agui: the model called yui_show, the run ended there, the screen reached the phone (try {tries})",
          via_tool and run and run["toolCalls"][0]["function"]["name"] == "yui_show", body[:240])
    check("agui: the screen is a ```yui fence the YL parser reads, with choices, no errors",
          picks and picks[0]["props"].get("options") and not [o for o in ops if o.get("op") == "error"],
          json.dumps(picks[:1])[:200])

    print("== D. the tap as the tool's result")
    op = picks[0] if picks else {"id": "n1", "preset": "choose", "props": {"options": ["Tea", "Coffee"]}}
    choice = next((o for o in op["props"]["options"] if "tea" in o.lower()), op["props"]["options"][0])
    call_id = calls[0]["id"] if via_tool else None
    tap = say(f"[yui] {op['id']} {op['preset']} choice={choice}", "event",
              {"id": op["id"], "preset": op["preset"], "value": {"choice": choice}, "echo": choice})
    rep = wait(lambda: replies_to(tap), 300, "answer to the tap")
    th = st()["threads"][agent]
    result = next((t for t in th if t["role"] == "tool" and t.get("toolCallId") == call_id), None)
    check(f"agui: the tap ({choice}) went back as yui_show's result, not as the person's words",
          result and f"choice={choice}" in result["content"]
          and not any(t["role"] == "user" and f"choice={choice}" in t["content"] for t in th), json.dumps(result)[:200])
    check("agui: the tap is answered once and the screen's call is closed",
          len(rep) == 1 and rep[0]["body"].strip() and not st().get("calls", {}).get(agent), rep and rep[0]["body"][:240])

    print("== E. memory")
    back = say("Which drink did I just pick? One word.")
    rep = wait(lambda: replies_to(back), 300, "the recall")
    check(f"agui: the next turn recalls the tap ({choice}): the bridge keeps the AG-UI thread",
          len(rep) == 1 and choice.lower() in rep[0]["body"].lower(), rep and rep[0]["body"][:240])

    print("== F. kill -9 mid-turn")
    crash = say("Write a four line poem about tea.")
    wait(lambda: row(crash)["delivered_at"], 60, "turn started")
    time.sleep(1.5)
    proc[0].send_signal(signal.SIGKILL)
    proc[0].wait(10)
    log("bridge killed -9 while the agent worked")
    inflight = st().get("inflight", {}).get(agent)
    check("agui: the turn in flight is on disk with its run id", inflight and inflight.get("turn") == [crash]
          and inflight.get("messageId", "").startswith("yui-"), json.dumps(inflight)[:160])
    start()
    wait(lambda: replies_to(crash), 300, "answer after the restart")
    time.sleep(4)
    rep = replies_to(crash)
    check("agui: after the restart the same run goes again and the turn is answered, once",
          len(rep) == 1 and rep[0]["body"].strip() and "again after a restart" in bridgelog.read_text(),
          rep and rep[0]["body"][:160])

    print("== G. clean stop, totals")
    wait(lambda: all(m["handled_at"] for m in thread() if m["sender"] == "user"), 30, "all handled")
    proc[0].send_signal(signal.SIGTERM)
    proc[0].wait(20)
    check("agui: a clean stop reads offline", presence() == "offline", presence())
    users = [m for m in thread() if m["sender"] == "user"]
    named = [i for m in thread() if m["sender"] == "agent" for i in (m.get("meta") or {}).get("turn") or []]
    check("agui: every person's row handled and answered by exactly one reply",
          all(m["handled_at"] for m in users) and all(named.count(m["id"]) == 1 for m in users), f"{len(users)} rows")
    check("agui: no connector token in the bridge's log", "yui_ct_" not in bridgelog.read_text())
    (home / "thread.json").write_text(json.dumps(thread(), indent=1))
    (home / "agui_thread.json").write_text(json.dumps(st()["threads"].get(agent, []), indent=1))
finally:
    if proc[0] and proc[0].poll() is None:
        proc[0].kill()
    if maf and maf.poll() is None:
        os.killpg(maf.pid, signal.SIGKILL)  # uv and the server it started
    if tok:
        s, _ = fn("yui-delete", {}, tok)
        left = sql(f"select count(*)::int n from yui_messages where user_id = '{T}'")[0]["n"] \
            + sql(f"select count(*)::int n from yui_users where id = '{T}'")[0]["n"]
        check("agui: throwaway account deleted, nothing left", s == 200 and left == 0, f"{s} {left}")
    print(f"  bridge log: {bridgelog}, thread: {home / 'thread.json'}, AG-UI thread: {home / 'agui_thread.json'}")

print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)

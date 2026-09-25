#!/usr/bin/env python3
"""INT-13 end to end: a real Flue agent on Node, talking in live Yui.

The Flue app is adapters/flue/example: Flue 2.x on its Node target (vite
build, node dist/server.mjs), one agent on local Ollama qwen2.5:7b (no key),
whose own instructions never mention Yui. Its channels/yui.ts is what the
blueprint (adapters/flue/blueprint/channel--yui.md) writes: the Yui connector
dials out, each turn goes to the agent with init().dispatch() and the settled
reply goes back. On a fresh throwaway account (never a real one):

  A. pair with the app's code (yui-flue.ts pair); the state file is private.
  B. a turn: answered once, meta.turn names it, delivered and handled.
  C. a screen: the reply has a ```yui fence the YL parser reads, with
     choices, drawn only because the channel guide reached the instructions.
  D. a tap on it goes back as its [yui] line and is answered once.
  E. the next turn recalls the tap: one Flue conversation per Yui thread.
  F. kill -9 while the agent works: after a restart the same turn (same
     idempotency key) is answered, once.
  G. a clean stop reads offline; every row handled and answered exactly once;
     no connector token in the app's log; the account is deleted.

    python3 adapters/flue/tests/flue_e2e.py

Needs Node 22.18+, Ollama with qwen2.5:7b, and a Supabase access token like
supabase/tests.
"""
import json, os, signal, socket, subprocess, sys, tempfile, time, uuid
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
FLUE = REPO / "adapters/flue"
APP = FLUE / "example"
CLI = ["node", str(FLUE / "yui-flue.ts")]
YL = Path.home() / "dev/yuigui/site/lib/yl/yl.mjs"

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


print("==== Flue: a Flue agent on Node through the Yui channel (INT-13)")
if not (APP / "node_modules/@flue/runtime").exists():
    subprocess.run(["npm", "install", "--no-audit", "--no-fund"], cwd=APP, check=True)
b = subprocess.run(["npx", "vite", "build"], cwd=APP, capture_output=True, text=True)
check("flue: the example app builds for the Node target (vite build)", b.returncode == 0 and (APP / "dist/server.mjs").exists(),
      next((l.strip() for l in b.stdout.splitlines() if "built in" in l), b.stderr[-200:]))
flue_version = json.loads((APP / "node_modules/@flue/runtime/package.json").read_text())["version"]
log(f"@flue/runtime {flue_version}")

home = Path(tempfile.mkdtemp(prefix="yui-int13-flue-"))
state = home / "flue.json"
applog = home / "app.log"
with socket.socket() as so:
    so.bind(("127.0.0.1", 0))
    port = so.getsockname()[1]
T = str(uuid.uuid4())
tok = None
agent = None
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

def start():
    env = {**os.environ, "PORT": str(port), "YUI_FLUE_STATE": str(state)}
    env.pop("YUI_WEBHOOK_SECRET", None)
    proc[0] = subprocess.Popen(["node", "dist/server.mjs"], cwd=APP, env=env,
                               stdout=open(applog, "a"), stderr=subprocess.STDOUT)
    ups[0] += 1
    wait(lambda: applog.read_text().count("online as") >= ups[0], 60, "Flue app online in Yui")
    log(f"Flue app up on :{port}, pid {proc[0].pid}")

try:
    sql(f"insert into yui_users(id, apple_sub) values ('{T}','test.{T}')")
    tok = mint(T, ttl=3600)
    s, r = fn("yui-agents", {"action": "create", "name": "Flue", "pair": True}, tok)
    agent = r["agent"]["id"]

    print("== A. pair")
    p = subprocess.run(CLI + ["--state", str(state), "pair", r["pairing"]["code"], "--ref", "assistant",
                              "--host-name", "INT-13 test"], capture_output=True, text=True, timeout=60)
    st = json.loads(state.read_text()) if state.exists() else {}
    check("flue: pairs with the app's code", p.returncode == 0 and "paired" in p.stdout, (p.stdout + p.stderr).strip()[:200])
    check("flue: state file is private and holds the connector token",
          oct(state.stat().st_mode & 0o777) == "0o600" and st.get("token", "").startswith("yui_ct_"))

    print("== B. a turn")
    start()
    check("flue: agent reads online", wait(lambda: presence() == "online", 20, "online"))
    hi = say("Hi! In one short sentence, what can you help with?")
    rep = wait(lambda: replies_to(hi), 300, "Flue's answer")
    wait(lambda: row(hi)["handled_at"], 20, "hi handled")
    check("flue: the turn is answered once, meta.turn names it, delivered and handled",
          len(rep) == 1 and rep[0]["body"].strip() and rep[0]["meta"] == {"turn": [hi]}
          and row(hi)["delivered_at"] and row(hi)["handled_at"], rep and rep[0]["body"][:200])

    print("== C. a screen")
    body, picks, ops, tries = "", [], [], 0
    while not picks and tries < 3:  # a 7B model sometimes skips the fence; say it again, like a person would
        tries += 1
        ask = say("Help me pick a drink for this afternoon: Tea or Coffee. Give me the choices as buttons.")
        rep = wait(lambda: replies_to(ask), 300, "the screen")
        body = rep[0]["body"]
        ops = yl_ops(body)
        picks = [o for o in ops if o.get("op") == "add" and o.get("preset") in ("choose", "ask", "pick")]
        if not picks:
            log(f"no screen on try {tries}: {body[:120]!r}")
    check(f"flue: a Yui screen the YL parser reads, drawn only because the guide reached the agent's instructions (try {tries})",
          picks and picks[0]["props"].get("options") and not [o for o in ops if o.get("op") == "error"], body[:240])

    print("== D. a tap")
    op = picks[0]
    choice = next((o for o in op["props"]["options"] if "tea" in o.lower()), op["props"]["options"][0])
    tap = say(f"[yui] {op['id']} {op['preset']} choice={choice}", "event",
              {"id": op["id"], "preset": op["preset"], "value": {"choice": choice}, "echo": choice})
    rep = wait(lambda: replies_to(tap), 300, "answer to the tap")
    check(f"flue: the tap ({choice}) goes back as its [yui] line and is answered once",
          len(rep) == 1 and rep[0]["body"].strip(), rep and rep[0]["body"][:240])

    print("== E. memory")
    back = say("Which drink did I just pick? One word.")
    rep = wait(lambda: replies_to(back), 300, "the recall")
    check(f"flue: the next turn recalls the tap ({choice}): one Flue conversation per Yui thread",
          len(rep) == 1 and choice.lower() in rep[0]["body"].lower(), rep and rep[0]["body"][:240])

    print("== F. kill -9 mid-turn")
    crash = say("Write a four line poem about tea.")
    wait(lambda: row(crash)["delivered_at"], 60, "turn started")
    time.sleep(1.5)
    proc[0].send_signal(signal.SIGKILL)
    proc[0].wait(10)
    log("app killed -9 while the agent worked")
    inflight = json.loads(state.read_text()).get("inflight", {}).get(agent)
    check("flue: the turn in flight is on disk with its idempotency key", inflight and inflight.get("turn") == [crash]
          and len(inflight.get("key", "")) == 32, json.dumps(inflight)[:160])
    start()
    rep = wait(lambda: replies_to(crash), 300, "answer after the restart")
    time.sleep(4)
    rep = replies_to(crash)
    check("flue: after the restart the same turn is answered, once",
          len(rep) == 1 and rep[0]["body"].strip() and "sending 1 message(s) again" in applog.read_text(), rep and rep[0]["body"][:160])

    print("== G. clean stop, totals")
    wait(lambda: all(m["handled_at"] for m in thread() if m["sender"] == "user"), 30, "all handled")
    proc[0].send_signal(signal.SIGTERM)
    proc[0].wait(20)
    check("flue: a clean stop reads offline", presence() == "offline", presence())
    users = [m for m in thread() if m["sender"] == "user"]
    named = [i for m in thread() if m["sender"] == "agent" for i in (m.get("meta") or {}).get("turn") or []]
    check("flue: every person's row handled and answered by exactly one reply",
          all(m["handled_at"] for m in users) and all(named.count(m["id"]) == 1 for m in users), f"{len(users)} rows")
    check("flue: no connector token in the app's log", "yui_ct_" not in applog.read_text())
    (home / "thread.json").write_text(json.dumps(thread(), indent=1))
finally:
    if proc[0] and proc[0].poll() is None:
        proc[0].kill()
    if tok:
        s, _ = fn("yui-delete", {}, tok)
        left = sql(f"select count(*)::int n from yui_messages where user_id = '{T}'")[0]["n"] \
            + sql(f"select count(*)::int n from yui_users where id = '{T}'")[0]["n"]
        check("flue: throwaway account deleted, nothing left", s == 200 and left == 0, f"{s} {left}")
    print(f"  app log: {applog}, thread: {home / 'thread.json'}")

print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)

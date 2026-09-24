#!/usr/bin/env python3
"""INT-1 end to end: the Yui channel plugin inside a real OpenClaw gateway, against live PROOF.

On a fresh throwaway account (never a real one), with OpenClaw in its own
throwaway home (OPENCLAW_HOME / STATE_DIR / CONFIG_PATH, never ~/.openclaw):

  A. `openclaw plugins install -l`, then `openclaw yui pair <code>` with a code
     from the app's Add agent; the state file is private, the connector is
     kind openclaw.
  B. `openclaw gateway run`: the agent reads online. The person says hi: the
     OpenClaw agent gets the channel guide and the "Yui Lines, not A2UI" note
     in its system prompt and answers with a ```yui screen. One reply, with
     meta.turn; the row is delivered and handled.
  C. The person taps the screen: the event line reaches the agent, the answer lands.
  D. The gateway is killed -9 mid-turn: after a restart the turn is replayed
     and answered once.
  E. A turn answered but never acked: the restart acks it without a second
     agent turn.
  F. A clean stop reads offline at once; two messages sent while it is down go
     in as one turn, in order.
  G. `openclaw yui send` puts a handoff in the thread.

The agent's model is a local fake OpenAI-compatible server, so the test is
deterministic, costs nothing, and can see exactly what OpenClaw sent it.

    python3 adapters/openclaw/tests/openclaw_e2e.py

Needs `openclaw` on PATH and a Supabase access token like supabase/tests
(SUPABASE_ACCESS_TOKEN or the Supabase CLI login). The account is deleted at the end.
"""
import json, os, re, shutil, signal, socket, subprocess, sys, tempfile, threading, time, uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
PLUGIN = REPO / "adapters/openclaw"
OPENCLAW = shutil.which("openclaw") or sys.exit("openclaw is not on PATH")

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
def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


# -- the agent's model: a fake OpenAI-compatible server that records every call ----

def text_of(content):
    if isinstance(content, str):
        return content
    return "\n".join(p.get("text", "") for p in content or [] if isinstance(p, dict))


class Model:
    def __init__(self):
        self.calls = []          # {"system": str, "user": str} for every chat completion
        self.kill_once = set()   # markers whose first turn kills the gateway before it answers
        self.gateway = None
        self.lock = threading.Lock()
        model = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a): pass
            def do_GET(self):
                self.reply(200, {"object": "list", "data": [{"id": "fake-1", "object": "model"}]})
            def reply(self, code, obj):
                body = json.dumps(obj).encode()
                self.send_response(code); self.send_header("content-type", "application/json")
                self.send_header("content-length", str(len(body))); self.end_headers(); self.wfile.write(body)
            def do_POST(self):
                req = json.loads(self.rfile.read(int(self.headers["content-length"])))
                msgs = req.get("messages", [])
                system = "\n".join(text_of(m.get("content")) for m in msgs if m.get("role") in ("system", "developer"))
                users = [text_of(m.get("content")) for m in msgs if m.get("role") == "user"]
                user = users[-1] if users else ""
                with model.lock:
                    model.calls.append({"system": system, "user": user})
                    die = next((k for k in model.kill_once if k in user), None)
                    model.kill_once.discard(die)
                if die:  # the host dies mid-turn, before any answer
                    os.killpg(model.gateway.pid, signal.SIGKILL)
                    model.gateway.wait(10)
                    return self.reply(500, {"error": {"message": "gone"}})
                tap = re.search(r"\[yui\] n1 choose choice=(\w+)", user)
                if tap:
                    answer = f"{tap.group(1)} it is."
                elif "hi yui" in user:
                    answer = 'Hi! What sounds good?\n```yui\nchoose "Pick one" Coffee|Walk|Nap\n```'
                else:
                    said = [w for w in ("crash test", "first while down", "second while down") if w in user]
                    answer = "got: " + " / ".join(said or ["something"])
                if not req.get("stream"):
                    return self.reply(200, {"id": "c1", "object": "chat.completion", "created": int(time.time()),
                                            "model": "fake-1", "choices": [{"index": 0, "finish_reason": "stop",
                                            "message": {"role": "assistant", "content": answer}}],
                                            "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}})
                self.send_response(200); self.send_header("content-type", "text/event-stream"); self.end_headers()
                chunk = lambda delta, fin=None, **kw: ("data: " + json.dumps({"id": "c1", "object": "chat.completion.chunk",
                    "created": int(time.time()), "model": "fake-1",
                    "choices": [{"index": 0, "delta": delta, "finish_reason": fin}], **kw}) + "\n\n").encode()
                self.wfile.write(chunk({"role": "assistant", "content": answer}))
                self.wfile.write(chunk({}, "stop", usage={"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}))
                self.wfile.write(b"data: [DONE]\n\n"); self.wfile.flush()

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.url = f"http://127.0.0.1:{self.server.server_port}/v1"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def turns(self, marker):
        return [c for c in self.calls if marker in c["user"]]


# -- a throwaway OpenClaw -------------------------------------------------------------

home = Path(tempfile.mkdtemp(prefix="yui-int1-openclaw-"))
state_dir = home / ".openclaw"
state_dir.mkdir()
config = state_dir / "openclaw.json"
ENV = {**os.environ, "OPENCLAW_HOME": str(home), "OPENCLAW_STATE_DIR": str(state_dir),
       "OPENCLAW_CONFIG_PATH": str(config)}
PORT = free_port()
model = Model()
config.write_text(json.dumps({
    "gateway": {"mode": "local", "port": PORT, "bind": "loopback"},
    "models": {"providers": {"fake": {
        "baseUrl": model.url, "apiKey": "not-a-key", "api": "openai-completions",
        "models": [{"id": "fake-1", "name": "Fake", "reasoning": False, "input": ["text"],
                    "contextWindow": 200000, "maxTokens": 4096}]}}},
    "agents": {"defaults": {"model": {"primary": "fake/fake-1"}}},
}, indent=1))
signal.signal(signal.SIGTERM, lambda *a: sys.exit(143))  # a stopped test still deletes its account

def oc(*a, timeout=120):
    return subprocess.run([OPENCLAW, *a], capture_output=True, text=True, timeout=timeout, env=ENV, cwd=home)

real_config = Path.home() / ".openclaw/openclaw.json"
real_mtime = real_config.stat().st_mtime if real_config.exists() else None

print(f"== OpenClaw {oc('--version').stdout.strip()} in a throwaway home, gateway port {PORT}")
T = str(uuid.uuid4())
sql(f"insert into yui_users(id, apple_sub) values ('{T}','test.{T}')")
tok = mint(T, ttl=3600)
gw = [None]
ups = [0]
gw_log = home / "gateway.log"
state = state_dir / "yui/connector.json"

def start():
    out = open(gw_log, "a")
    gw[0] = subprocess.Popen([OPENCLAW, "gateway", "run", "--port", str(PORT), "--allow-unconfigured"],
                             stdout=out, stderr=subprocess.STDOUT, env=ENV, cwd=home, start_new_session=True)
    model.gateway = gw[0]
    ups[0] += 1
    wait(lambda: gw_log.read_text().count("[yui] online as") >= ups[0], 120, "gateway online")
    log(f"gateway up, pid {gw[0].pid}")

def stop():
    os.killpg(gw[0].pid, signal.SIGTERM)
    gw[0].wait(60)
    log(f"gateway stopped cleanly (exit {gw[0].returncode})")

def say(text, kind="text", meta=None):
    rid = str(uuid.uuid4())
    row = {"id": rid, "user_id": T, "agent_id": agent, "sender": "user", "body": text, "kind": kind}
    if meta:
        row["meta"] = meta
    s, r = rest("POST", "yui_messages", tok, row)
    assert s == 201, (s, r)
    log(f"app sent {text!r}")
    return rid

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

try:
    s, r = fn("yui-agents", {"action": "create", "name": "Claw", "pair": True}, tok)
    agent = r["agent"]["id"]

    print("== A. install and pair")
    p = oc("plugins", "install", "-l", str(PLUGIN))
    cfg = json.loads(config.read_text())  # the channel section is valid once the plugin is in
    cfg["channels"] = {"yui": {"enabled": True, "interval": 1}}
    config.write_text(json.dumps(cfg, indent=1))
    insp = oc("plugins", "inspect", "yui", "--runtime", "--json")
    info = json.loads(insp.stdout[insp.stdout.index("{"):]) if "{" in insp.stdout else {}
    check("plugin installs and loads as a channel",
          p.returncode == 0 and info.get("plugin", {}).get("status") == "loaded"
          and info["plugin"].get("channelIds") == ["yui"] and "yui" in info["plugin"].get("cliCommands", []),
          (p.stdout + p.stderr).strip()[-200:])
    p = oc("yui", "pair", r["pairing"]["code"], "--agent", "main", "--host-name", "INT-1 test")
    st = json.loads(state.read_text()) if state.exists() else {}
    check("pairs with the app's code", p.returncode == 0 and "paired" in p.stdout, (p.stdout + p.stderr).strip()[-200:])
    check("state file is private and holds the connector token",
          state.exists() and oct(state.stat().st_mode & 0o777) == "0o600" and st.get("token", "").startswith("yui_ct_"),
          oct(state.stat().st_mode & 0o777) if state.exists() else "missing")
    check("token is not in openclaw.json", "yui_ct_" not in config.read_text())
    kind = sql(f"select c.kind ck, a.kind ak, a.remote_ref from yui_connectors c join yui_agents a on a.connector_id = c.id"
               f" where c.user_id = '{T}'")
    check("the connector and agent are kind openclaw, ref main",
          kind and kind[0] == {"ck": "openclaw", "ak": "openclaw", "remote_ref": "main"}, f"{kind}")

    print("== B. hi gets a screen")
    start()
    check("agent reads online", wait(lambda: presence() == "online", 30, "online"))
    hi = say("hi yui")
    rep = wait(lambda: replies_to(hi), 120, "reply to hi")
    guide = fn("yui-connect", {"action": "guide"})[1]["guide"]
    call = model.turns("hi yui")[0]
    check("one reply with a yui screen, meta.turn = [hi]",
          len(rep) == 1 and "```yui\nchoose" in rep[0]["body"] and rep[0]["meta"] == {"turn": [hi]}, f"{rep}")
    check(f"the agent's system prompt carries the channel guide ({guide['version']})",
          "You are talking to someone in Yui" in call["system"]
          and guide["body"].strip().splitlines()[-1] in call["system"])
    check("and says plainly: on Yui use Yui Lines, not A2UI", "use Yui Lines, not A2UI" in call["system"])
    wait(lambda: row(hi)["handled_at"], 20, "hi handled")
    check("hi marked delivered and handled", row(hi)["delivered_at"] and row(hi)["handled_at"])

    print("== C. a tap on the screen")
    tap = say("[yui] n1 choose choice=Walk", "event",
              {"id": "n1", "preset": "choose", "value": {"choice": "Walk"}, "echo": "Walk"})
    rep = wait(lambda: replies_to(tap), 120, "reply to tap")
    check("the tap reaches the agent as its event line", model.turns("[yui] n1 choose choice=Walk"))
    check("the answer to the tap lands once", [m["body"] for m in rep] == ["Walk it is."], f"{rep}")

    print("== D. killed -9 mid-turn")
    model.kill_once.add("crash test")
    crash = say("crash test")
    wait(lambda: gw[0].poll() is not None, 120, "gateway killed")
    log("gateway killed -9 inside the agent's model call")
    check("mid-turn row is delivered, not handled, not answered",
          row(crash)["delivered_at"] and not row(crash)["handled_at"] and not replies_to(crash))
    start()
    rep = wait(lambda: replies_to(crash), 120, "reply after restart")
    wait(lambda: row(crash)["handled_at"], 20, "crash handled")
    check("replayed after restart, answered once", len(rep) == 1 and len(model.turns("crash test")) == 2,
          f"replies={len(rep)} model turns={len(model.turns('crash test'))}")

    print("== E. answered but never acked")
    stop()
    sql(f"update yui_messages set handled_at = null where id = '{hi}'")
    log("hi's handled_at cleared (a crash between the reply and the ack)")
    start()
    wait(lambda: row(hi)["handled_at"], 30, "hi re-acked")
    time.sleep(2)
    check("acked again without a second agent turn or reply",
          len(model.turns("hi yui")) == 1 and len(replies_to(hi)) == 1,
          f"turns={len(model.turns('hi yui'))} replies={len(replies_to(hi))}")

    print("== F. clean stop, messages while down")
    stop()
    check("a clean stop reads offline at once", presence() == "offline", presence())
    a, b = say("first while down"), say("second while down")
    time.sleep(1)
    check("nothing picked up while down", not row(a)["delivered_at"] and not row(b)["delivered_at"])
    start()
    rep = wait(lambda: replies_to(a), 120, "reply to backlog")
    both = [c for c in model.turns("first while down") if "second while down" in c["user"]]
    check("backlog goes in as one turn, in order",
          len(model.turns("first while down")) == 1 and both
          and both[0]["user"].index("first while down") < both[0]["user"].index("second while down"))
    check("one reply for the pair", len(rep) == 1 and rep[0]["meta"]["turn"] == [a, b], f"{rep}")

    print("== G. send a handoff")
    p = oc("yui", "send", "Your report is ready")
    out = p.stdout.strip().splitlines()
    mid = json.loads(out[-1]).get("message_id") if p.returncode == 0 and out else None
    check("send writes a handoff row", mid and any(m["id"] == mid and m["sender"] == "agent"
          and m["body"] == "Your report is ready" for m in thread()), (p.stdout + p.stderr).strip()[-200:])

    print("== totals")
    wait(lambda: all(m["handled_at"] for m in thread() if m["sender"] == "user"), 20, "all handled")
    users = [m for m in thread() if m["sender"] == "user"]
    named = [i for m in thread() if m["sender"] == "agent" for i in (m.get("meta") or {}).get("turn") or []]
    check("every person's row handled and answered by exactly one reply",
          all(m["handled_at"] for m in users) and all(named.count(m["id"]) == 1 for m in users), f"{len(users)} rows")
    stop()
    check("a clean stop reads offline", presence() == "offline", presence())
except Exception as e:
    check("ran to the end", False, repr(e))
finally:
    if gw[0] and gw[0].poll() is None:
        os.killpg(gw[0].pid, signal.SIGKILL)
    model.server.shutdown()
    s, _ = fn("yui-delete", {}, tok)
    left = sql(f"select count(*)::int n from yui_messages where user_id = '{T}'")[0]["n"] \
        + sql(f"select count(*)::int n from yui_users where id = '{T}'")[0]["n"]
    check("throwaway account deleted, nothing left", s == 200 and left == 0, f"{s} {left}")
    check("~/.openclaw untouched", real_mtime == (real_config.stat().st_mtime if real_config.exists() else None))
    print(f"  gateway log: {gw_log}")

print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)

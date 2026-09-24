#!/usr/bin/env python3
"""INT-2 end to end: the webhook bridges (Python and Node) against live PROOF.

For each client, on a fresh throwaway account (never a real one):

  A. pair with a code from the app's Add agent; the state file is private.
  B. the person says hi: the fake webhook gets the turn, with the channel guide
     and a valid signature, and answers with a ```yui screen. The reply lands
     once, carries meta.turn, and the row is marked delivered and handled.
  C. the person taps the screen: the event reaches the webhook with its JSON,
     the answer lands.
  D. the bridge is killed -9 mid-turn: after a restart the turn is replayed
     and answered once.
  E. a turn that was answered but never acked (a crash between the two): the
     restart acks it without calling the webhook again.
  F. a clean stop reads offline at once; two messages sent while it is down
     go in as one turn, in order.
  G. `send` puts a handoff in the thread.

Pass: every person's row is handled and named by exactly one reply, and the
webhook saw each row once (twice only for the turn killed mid-flight).

    python3 adapters/webhook/tests/webhook_e2e.py [--client python|node|both]

Needs a Supabase access token like supabase/tests (SUPABASE_ACCESS_TOKEN or the
Supabase CLI login). Each account is deleted at the end.
"""
import argparse, hashlib, hmac, json, os, signal, subprocess, sys, tempfile, threading, time, uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
WEBHOOK_DIR = REPO / "adapters/webhook"
CLIENTS = {
    "python": [sys.executable, str(WEBHOOK_DIR / "python/yui_webhook.py")],
    "node": ["node", str(WEBHOOK_DIR / "node/yui-webhook.mjs")],
}
SECRET = "test-secret-" + uuid.uuid4().hex[:8]

ap = argparse.ArgumentParser()
ap.add_argument("--client", choices=["python", "node", "both"], default="both")
args = ap.parse_args()

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


# -- the developer's agent: a fake webhook that records every turn ------------------

class Hook:
    def __init__(self):
        self.calls = []          # every turn payload, with its signature check
        self.kill_once = set()   # texts whose first turn kills the bridge before it answers
        self.bridge = None
        self.lock = threading.Lock()
        hook = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a): pass
            def do_POST(self):
                raw = self.rfile.read(int(self.headers["content-length"]))
                ts, sig = self.headers.get("x-yui-timestamp", ""), self.headers.get("x-yui-signature", "")
                good = sig == "sha256=" + hmac.new(SECRET.encode(), f"{ts}.".encode() + raw, hashlib.sha256).hexdigest()
                turn = json.loads(raw)
                with hook.lock:
                    hook.calls.append({**turn, "signed": good, "turn_header": self.headers.get("x-yui-turn")})
                    die = turn["text"] in hook.kill_once
                    hook.kill_once.discard(turn["text"])
                if die:  # the agent's host dies mid-turn, before any answer
                    hook.bridge.send_signal(signal.SIGKILL)
                    hook.bridge.wait(10)
                    self.send_response(500); self.end_headers()
                    return
                taps = [m["event"]["echo"] for m in turn["messages"] if (m["event"] or {}).get("echo")]
                if taps:
                    reply = f"{taps[-1]} it is."
                elif turn["text"] == "hi":
                    reply = 'Hi! What sounds good?\n```yui\nchoose "Pick one" Coffee|Walk|Nap\n```'
                else:
                    reply = "got: " + " / ".join(m["body"] for m in turn["messages"])
                body = json.dumps({"reply": reply}).encode()
                self.send_response(200); self.send_header("content-type", "application/json")
                self.send_header("content-length", str(len(body))); self.end_headers(); self.wfile.write(body)

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.url = f"http://127.0.0.1:{self.server.server_port}/yui"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def seen(self, row_id):
        return sum(1 for c in self.calls if row_id in c["turn"])


def run_client(name: str) -> None:
    cmd = CLIENTS[name]
    print(f"\n==== {name} client: {' '.join(Path(c).name for c in cmd)}")
    home = Path(tempfile.mkdtemp(prefix=f"yui-int2-{name}-"))
    state = home / "webhook.json"
    base = cmd + ["--state", str(state)]
    T = str(uuid.uuid4())
    sql(f"insert into yui_users(id, apple_sub) values ('{T}','test.{T}')")
    tok = mint(T, ttl=3600)
    hook = Hook()
    proc = [None]
    ups = [0]

    def start():
        out = open(home / "bridge.log", "a")
        proc[0] = subprocess.Popen(base + ["run", "--webhook", hook.url, "--secret", SECRET, "--interval", "1"],
                                   stdout=out, stderr=subprocess.STDOUT)
        hook.bridge = proc[0]
        ups[0] += 1
        wait(lambda: (home / "bridge.log").read_text().count("online as") >= ups[0], 30, "bridge online")
        log(f"bridge up, pid {proc[0].pid}")

    def stop():
        proc[0].send_signal(signal.SIGTERM)
        proc[0].wait(20)
        log(f"bridge stopped cleanly (exit {proc[0].returncode})")

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
        s, r = fn("yui-agents", {"action": "create", "name": "Hook", "pair": True}, tok)
        agent = r["agent"]["id"]
        print("== A. pair")
        p = subprocess.run(base + ["pair", r["pairing"]["code"], "--ref", f"int2-{name}", "--host-name", "INT-2 test"],
                           capture_output=True, text=True, timeout=60)
        st = json.loads(state.read_text()) if state.exists() else {}
        check(f"{name}: pairs with the app's code", p.returncode == 0 and "paired" in p.stdout,
              (p.stdout + p.stderr).strip()[:200])
        check(f"{name}: state file is private and holds the connector token",
              state.exists() and oct(state.stat().st_mode & 0o777) == "0o600"
              and st.get("token", "").startswith("yui_ct_"), oct(state.stat().st_mode & 0o777) if state.exists() else "missing")
        kind = sql(f"select kind from yui_connectors where user_id = '{T}'")
        check(f"{name}: the connector is kind http", kind and kind[0]["kind"] == "http", f"{kind}")

        print("== B. hi gets a screen")
        start()
        check(f"{name}: agent reads online", wait(lambda: presence() == "online", 20, "online"))
        hi = say("hi")
        rep = wait(lambda: replies_to(hi), 30, "reply to hi")
        guide = fn("yui-connect", {"action": "guide"})[1]["guide"]
        call = next(c for c in hook.calls if hi in c["turn"])
        check(f"{name}: one reply with a yui screen, meta.turn = [hi]",
              len(rep) == 1 and "```yui\nchoose" in rep[0]["body"] and rep[0]["meta"] == {"turn": [hi]}, f"{rep}")
        check(f"{name}: webhook got the channel guide ({guide['version']})",
              call["guide"]["version"] == guide["version"] and "You are talking to someone in Yui" in call["guide"]["body"])
        check(f"{name}: POST is signed and carries a turn key", call["signed"] and len(call["turn_header"] or "") == 32)
        check(f"{name}: payload names the agent and the text",
              call["agent"]["id"] == agent and call["agent"]["ref"] == f"int2-{name}" and call["text"] == "hi"
              and call["messages"][0]["event"] is None)
        wait(lambda: row(hi)["handled_at"], 15, "hi handled")
        check(f"{name}: hi marked delivered and handled", row(hi)["delivered_at"] and row(hi)["handled_at"])

        print("== C. a tap on the screen")
        tap = say("[yui] n1 choose choice=Walk", "event",
                  {"id": "n1", "preset": "choose", "value": {"choice": "Walk"}, "echo": "Walk"})
        rep = wait(lambda: replies_to(tap), 30, "reply to tap")
        call = next(c for c in hook.calls if tap in c["turn"])
        check(f"{name}: the tap reaches the webhook with its JSON",
              call["messages"][0]["event"] == {"id": "n1", "preset": "choose", "value": {"choice": "Walk"}, "echo": "Walk"})
        check(f"{name}: the answer to the tap lands once", [m["body"] for m in rep] == ["Walk it is."], f"{rep}")

        print("== D. killed -9 mid-turn")
        hook.kill_once.add("crash test")
        crash = say("crash test")
        wait(lambda: proc[0].poll() is not None, 30, "bridge killed")
        log("bridge killed -9 inside the webhook call")
        check(f"{name}: mid-turn row is delivered, not handled, not answered",
              row(crash)["delivered_at"] and not row(crash)["handled_at"] and not replies_to(crash))
        start()
        rep = wait(lambda: replies_to(crash), 30, "reply after restart")
        wait(lambda: row(crash)["handled_at"], 15, "crash handled")
        check(f"{name}: replayed after restart, answered once", len(rep) == 1 and hook.seen(crash) == 2,
              f"replies={len(rep)} webhook calls={hook.seen(crash)}")

        print("== E. answered but never acked")
        stop()
        sql(f"update yui_messages set handled_at = null where id = '{hi}'")
        log("hi's handled_at cleared (a crash between the reply and the ack)")
        start()
        wait(lambda: row(hi)["handled_at"], 20, "hi re-acked")
        time.sleep(2)
        check(f"{name}: acked again without a second webhook call or reply",
              hook.seen(hi) == 1 and len(replies_to(hi)) == 1, f"calls={hook.seen(hi)} replies={len(replies_to(hi))}")

        print("== F. clean stop, messages while down")
        stop()
        check(f"{name}: a clean stop reads offline at once", presence() == "offline", presence())
        a, b = say("first while down"), say("second while down")
        time.sleep(1)
        check(f"{name}: nothing picked up while down", not row(a)["delivered_at"] and not row(b)["delivered_at"])
        start()
        rep = wait(lambda: replies_to(a), 30, "reply to backlog")
        call = next(c for c in hook.calls if a in c["turn"])
        check(f"{name}: backlog goes in as one turn, in order",
              call["turn"] == [a, b] and call["text"] == "first while down\nsecond while down", f"{call['turn']}")
        check(f"{name}: one reply for the pair", len(rep) == 1 and rep[0]["meta"]["turn"] == [a, b])

        print("== G. send a handoff")
        p = subprocess.run(base + ["send", "Your report is ready"], capture_output=True, text=True, timeout=60)
        mid = json.loads(p.stdout or "{}").get("message_id") if p.returncode == 0 else None
        check(f"{name}: send writes a handoff row", mid and any(m["id"] == mid and m["sender"] == "agent"
              and m["body"] == "Your report is ready" for m in thread()), (p.stdout + p.stderr).strip()[:200])

        print("== totals")
        wait(lambda: all(m["handled_at"] for m in thread() if m["sender"] == "user"), 15, "all handled")
        users = [m for m in thread() if m["sender"] == "user"]
        named = [i for m in thread() if m["sender"] == "agent" for i in (m.get("meta") or {}).get("turn") or []]
        check(f"{name}: every person's row handled and answered by exactly one reply",
              all(m["handled_at"] for m in users) and all(named.count(m["id"]) == 1 for m in users),
              f"{len(users)} rows")
        check(f"{name}: webhook saw each row once (the killed turn twice)",
              all(hook.seen(m["id"]) == (2 if m["id"] == crash else 1) for m in users),
              f"{[hook.seen(m['id']) for m in users]}")
        stop()
    finally:
        if proc[0] and proc[0].poll() is None:
            proc[0].kill()
        hook.server.shutdown()
        s, _ = fn("yui-delete", {}, tok)
        left = sql(f"select count(*)::int n from yui_messages where user_id = '{T}'")[0]["n"] \
            + sql(f"select count(*)::int n from yui_users where id = '{T}'")[0]["n"]
        check(f"{name}: throwaway account deleted, nothing left", s == 200 and left == 0, f"{s} {left}")
        print(f"  bridge log: {home / 'bridge.log'}")


for c in (["python", "node"] if args.client == "both" else [args.client]):
    try:
        run_client(c)
    except Exception as e:  # one client failing still runs the other
        check(f"{c}: ran to the end", False, repr(e))

print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)

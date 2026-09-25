#!/usr/bin/env python3
"""INT-12 end to end: the model bridge against live PROOF.

Runs, each on a fresh throwaway account (never a real one):

  stream  the scripted server (tests/fake-model.ts), streaming, with a key:
    A. pair with the app's code, the base URL and the model; the state file is
       private and holds the key's variable name, never the key.
    B. hello: one reply, meta.turn, delivered and handled; the model got the
       person's instructions plus the channel guide as the system message.
    C. a ```yui screen comes through as is.
    D. a tap reaches the model as its [yui] line, after the screen it answers.
    E. Yui holds the thread: the model is sent the earlier turns, in order.
    F. a long answer: delivered, no reply while it streams (the working row),
       then the whole answer once.
    G. killed -9 mid-stream: after a restart the model is asked again and one
       answer lands.
    H. answered but never acked: the restart acks it, no second ask, no second reply.
    I. the server says no (400): the person reads why, once. A 503 is tried again.
    J. the server is down for a while: one note says so, then the answer lands.
    K. a clean stop reads offline; messages sent meanwhile go as one turn.
  plain   a server that refuses streams: the bridge learns it and asks plain.
  ollama  a real model on this Mac (Ollama, --model, default qwen2.5:7b): its
          answer draws a Yui screen that the YL parser reads, a tap goes back
          as the next turn and is answered, it remembers the tap, and a kill -9
          mid-answer still ends in one reply.
  phone   with --sim: the same Ollama model and YuiUITests/OpenAICompatTests on a
          simulator: the working row, the model's screen, a tap and its
          answer (light), a follow-up that needs the thread (dark). Shots in --out.

Pass: every person's row is handled and named by exactly one reply.

    python3 adapters/openai-compat/tests/openai_e2e.py [--run stream|plain|ollama|phone|all] [--model qwen2.5:7b] [--sim <udid>] [--out DIR]

Needs a Supabase access token like supabase/tests. Accounts are deleted.
"""
import argparse, hashlib, json, os, re, secrets, signal, subprocess, sys, tempfile, time, urllib.request, uuid
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
HERE = REPO / "adapters/openai-compat"
BRIDGE = ["node", str(HERE / "yui-openai.ts")]
YL = Path.home() / "dev/yuigui/site/lib/yl/yl.mjs"
KEY = "sk-int12-" + secrets.token_hex(8)

ap = argparse.ArgumentParser()
ap.add_argument("--run", choices=["stream", "plain", "ollama", "phone", "all"], default="all")
ap.add_argument("--model", default="qwen2.5:7b", help="the Ollama model for the ollama and phone runs")
ap.add_argument("--sim", help="simulator udid: also run YuiUITests/OpenAICompatTests (phone side)")
ap.add_argument("--out", default="/tmp/int12-proof")
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
        time.sleep(0.4)
    raise TimeoutError(what)


def start_fake(extra):
    p = subprocess.Popen(["node", str(HERE / "tests/fake-model.ts"), *extra], stdout=subprocess.PIPE, text=True)
    return p, p.stdout.readline().split()[1]

def model_log(url):
    with urllib.request.urlopen(f"{url.removesuffix('/v1')}/_log") as r:
        return json.loads(r.read())

def yl_ops(text):
    """The YL parser's ops for the first ```yui fence in a reply."""
    if "```yui\n" not in text:
        return []
    fence = text.split("```yui\n", 1)[1].split("```", 1)[0]
    js = f"import({json.dumps(str(YL))}).then(m => console.log(JSON.stringify(m.parse({json.dumps(fence)}))))"
    return json.loads(subprocess.check_output(["node", "-e", js], text=True))


class Run:
    """One throwaway account, one agent, one bridge state file."""

    def __init__(self, name, env=None):
        self.name = name
        self.home = Path(tempfile.mkdtemp(prefix=f"yui-int12-{name}-"))
        self.state = self.home / "openai.json"
        self.base = BRIDGE + ["--state", str(self.state)]
        self.env = {**os.environ, **(env or {})}
        self.T = str(uuid.uuid4())
        sql(f"insert into yui_users(id, apple_sub) values ('{self.T}','test.{self.T}')")
        self.tok = mint(self.T, ttl=3600)
        self.proc = None
        self.ups = 0
        self.agent = None

    def create_agent(self, name):
        s, r = fn("yui-agents", {"action": "create", "name": name, "pair": True}, self.tok)
        self.agent = r["agent"]["id"]
        return r["pairing"]["code"]

    def pair(self, code, *extra):
        return subprocess.run(self.base + ["pair", code, "--host-name", "INT-12 test", *extra],
                              capture_output=True, text=True, timeout=60, env=self.env)

    def start(self):
        out = open(self.home / "bridge.log", "a")
        self.proc = subprocess.Popen(self.base + ["run", "--interval", "1"], stdout=out, stderr=subprocess.STDOUT, env=self.env)
        self.ups += 1
        wait(lambda: self.bridge_log().count("online as") >= self.ups, 30, "bridge online")
        log(f"bridge up, pid {self.proc.pid}")

    def stop(self):
        self.proc.send_signal(signal.SIGTERM)
        self.proc.wait(20)
        log(f"bridge stopped cleanly (exit {self.proc.returncode})")

    def kill(self):
        self.proc.send_signal(signal.SIGKILL)
        self.proc.wait(10)

    def bridge_log(self):
        p = self.home / "bridge.log"
        return p.read_text() if p.exists() else ""

    def say(self, text, kind="text", meta=None):
        rid = str(uuid.uuid4())
        row = {"id": rid, "user_id": self.T, "agent_id": self.agent, "sender": "user", "body": text, "kind": kind}
        if meta:
            row["meta"] = meta
        s, r = rest("POST", "yui_messages", self.tok, row)
        assert s == 201, (s, r)
        log(f"app sent {text[:60]!r}")
        return rid

    def tap(self, ops, choice):
        op = next(o for o in ops if o.get("op") == "add" and o.get("preset") == "choose")
        return self.say(f"[yui] {op['id']} choose choice={choice}", "event",
                        {"id": op["id"], "preset": "choose", "value": {"choice": choice}, "echo": choice})

    def thread(self):
        s, r = rest("GET", "yui_messages?select=id,sender,body,kind,meta,delivered_at,handled_at"
                           f"&agent_id=eq.{self.agent}&order=created_at.asc,id.asc", self.tok)
        assert s == 200, (s, r)
        return r

    def replies_to(self, rid):
        return [m for m in self.thread() if m["sender"] == "agent" and rid in ((m.get("meta") or {}).get("turn") or [])]

    def row(self, rid):
        return next(m for m in self.thread() if m["id"] == rid)

    def presence(self):
        return rest("GET", f"yui_agent_list?select=presence&id=eq.{self.agent}", self.tok)[1][0]["presence"]

    def totals(self):
        th = self.thread()
        users = [m for m in th if m["sender"] == "user"]
        named = [i for m in th if m["sender"] == "agent" for i in (m.get("meta") or {}).get("turn") or []]
        check(f"{self.name}: every person's row handled and answered by exactly one reply",
              all(m["handled_at"] for m in users) and all(named.count(m["id"]) == 1 for m in users),
              f"{len(users)} rows, {[(m['body'][:14], named.count(m['id'])) for m in users if named.count(m['id']) != 1]}")

    def close(self):
        if self.proc and self.proc.poll() is None:
            self.proc.kill()
        s, _ = fn("yui-delete", {}, self.tok)
        left = sql(f"select count(*)::int n from yui_messages where user_id = '{self.T}'")[0]["n"] \
            + sql(f"select count(*)::int n from yui_users where id = '{self.T}'")[0]["n"]
        check(f"{self.name}: throwaway account deleted, nothing left", s == 200 and left == 0, f"{s} {left}")
        print(f"  bridge log: {self.home / 'bridge.log'}")


def run_stream():
    print("\n==== stream: the scripted server, streaming, with a key")
    fake, url = start_fake(["--key", KEY])
    r = Run("stream", {"YUI_TEST_MODEL_KEY": KEY, "YUI_OPENAI_WAIT_NOTE": "3"})
    calls = lambda text: sum(1 for c in model_log(url) if c["text"].split("\n")[-1] == text and c["model"] == "fake-1")
    try:
        print("== A. pair")
        code = r.create_agent("Echo")
        p = r.pair(code, "--url", url, "--model", "fake-1", "--key-env", "YUI_TEST_MODEL_KEY", "--ref", "echo",
                   "--system", "You are Echo.", "--context", "8192")
        st = json.loads(r.state.read_text()) if r.state.exists() else {}
        check("stream: pairs with the app's code, the URL and the model",
              p.returncode == 0 and "paired: Echo is fake-1" in p.stdout, (p.stdout + p.stderr).strip()[:300])
        check("stream: state file is private, holds the token, the model and the key's name, never the key",
              r.state.exists() and oct(r.state.stat().st_mode & 0o777) == "0o600" and st.get("token", "").startswith("yui_ct_")
              and st.get("remotes", {}).get("echo") == {"url": url, "model": "fake-1", "keyEnv": "YUI_TEST_MODEL_KEY",
                                                        "system": "You are Echo.", "context": 8192}
              and KEY not in r.state.read_text(), json.dumps(st.get("remotes")))
        bound = sql(f"select a.remote_ref, c.kind from yui_agents a join yui_connectors c on c.id = a.connector_id where a.id = '{r.agent}'")
        check("stream: the agent is bound as remote_ref echo on an http connector",
              bound and bound[0] == {"remote_ref": "echo", "kind": "http"}, f"{bound}")
        bad = subprocess.run(r.base + ["pair", "000000", "--url", url, "--model", "nope", "--key-env", "YUI_TEST_MODEL_KEY"],
                             capture_output=True, text=True, env=r.env)
        nokey = subprocess.run(r.base + ["pair", "000000", "--url", url, "--model", "fake-1"], capture_output=True, text=True, env=r.env)
        check("stream: pairing without the key says the key was turned down",
              nokey.returncode == 1 and "turned the key down (401" in nokey.stderr, nokey.stderr.strip()[:200])
        check("stream: pairing a model the server lacks fails before the code is spent",
              bad.returncode == 1 and "has no model \"nope\"" in bad.stderr and "fake-1" in bad.stderr, bad.stderr.strip()[:200])

        print("== B. hello")
        r.start()
        check("stream: agent reads online", wait(lambda: r.presence() == "online", 20, "online"))
        hi = r.say("hello")
        rep = wait(lambda: r.replies_to(hi), 30, "reply to hello")
        check("stream: one reply, meta.turn = [hello]", [m["body"] for m in rep] == ["You said: hello"] and rep[0]["meta"] == {"turn": [hi]}, f"{rep}")
        wait(lambda: r.row(hi)["handled_at"], 15, "hello handled")
        check("stream: hello marked delivered and handled", r.row(hi)["delivered_at"] and r.row(hi)["handled_at"])
        guide = fn("yui-connect", {"action": "guide"})[1]["guide"]
        call = next(c for c in model_log(url) if c["text"] == "hello")
        check(f"stream: system message = the person's words + the channel guide ({guide['version']})",
              call["messages"][0] == {"role": "system", "content": f"You are Echo.\n\n{guide['body'].strip()}"}
              and call["messages"][1:] == [{"role": "user", "content": "hello"}], json.dumps(call["messages"])[:300])
        check("stream: asked to stream, with the key as a bearer token", call["stream"] and call["auth"] == f"Bearer {KEY}")

        print("== C. a screen")
        sc = r.say("screen")
        rep = wait(lambda: r.replies_to(sc), 30, "reply to screen")
        check("stream: a ```yui screen comes through as is", len(rep) == 1 and rep[0]["body"] == 'Pick one:\n```yui\nchoose "Pick one" Tea|Coffee\n```', f"{rep}")

        print("== D. a tap")
        tap = r.say("[yui] n1 choose choice=Tea", "event", {"id": "n1", "preset": "choose", "value": {"choice": "Tea"}, "echo": "Tea"})
        rep = wait(lambda: r.replies_to(tap), 30, "reply to tap")
        check("stream: the tap is answered once", [m["body"] for m in rep] == ["Tea it is."], f"{rep}")
        call = next(c for c in model_log(url) if c["text"].startswith("[yui] n1"))
        check("stream: the tap reached the model as its line, right after the screen it answers",
              call["messages"][-1] == {"role": "user", "content": "[yui] n1 choose choice=Tea"}
              and call["messages"][-2]["role"] == "assistant" and "```yui" in call["messages"][-2]["content"])

        print("== E. Yui holds the thread")
        h = r.say("history")
        rep = wait(lambda: r.replies_to(h), 30, "reply to history")
        want = "user: hello\nassistant: You said: hello\nuser: screen\nassistant: Pick one:\nuser: [yui] n1 choose choice=Tea\nassistant: Tea it is."
        check("stream: the model is sent every earlier turn, in order, roles taking turns",
              [m["body"] for m in rep] == [want], f"{rep and rep[0]['body']!r}")

        print("== F. a long answer: working, then done")
        slow = r.say("slow 5")
        wait(lambda: r.row(slow)["delivered_at"], 15, "slow delivered")
        time.sleep(2.5)
        mid = r.row(slow)
        check("stream: while it streams: delivered, not handled, no reply (the working row)",
              mid["delivered_at"] and not mid["handled_at"] and not r.replies_to(slow))
        rep = wait(lambda: r.replies_to(slow), 40, "reply to slow")
        check("stream: the whole answer lands once",
              [m["body"] for m in rep] == ["Step 1, step 2, step 3, step 4, step 5\n\nDone after 5 steps."], f"{rep}")

        print("== G. killed -9 mid-stream")
        crash = r.say("slow 8")
        wait(lambda: (json.loads(r.state.read_text()).get("inflight") or {}).get(r.agent), 20, "turn on disk")
        wait(lambda: calls("slow 8") == 1, 20, "model asked")
        time.sleep(2.5)
        r.kill()
        log("bridge killed -9 while the model streams")
        check("stream: mid-answer row is delivered, not handled, not answered",
              r.row(crash)["delivered_at"] and not r.row(crash)["handled_at"] and not r.replies_to(crash))
        r.start()
        rep = wait(lambda: r.replies_to(crash), 60, "reply after restart")
        wait(lambda: r.row(crash)["handled_at"], 15, "crash handled")
        time.sleep(2)
        check("stream: after the restart the model is asked again and one whole answer lands",
              calls("slow 8") == 2 and len(r.replies_to(crash)) == 1
              and rep[0]["body"] == "Step 1, step 2, step 3, step 4, step 5, step 6, step 7, step 8\n\nDone after 8 steps.",
              f"asks={calls('slow 8')} replies={len(r.replies_to(crash))}")
        check("stream: the restart says it asked again", "asking again for 1 message(s)" in r.bridge_log())

        print("== H. answered but never acked")
        sql(f"update yui_messages set handled_at = null where id = '{hi}'")
        log("hello's handled_at cleared (a crash between the reply and the ack)")
        wait(lambda: r.row(hi)["handled_at"], 20, "hello re-acked")
        check("stream: acked again without a second ask or reply", calls("hello") == 1 and len(r.replies_to(hi)) == 1,
              f"asks={calls('hello')} replies={len(r.replies_to(hi))}")

        print("== I. the server says no, or not now")
        no = r.say("refuse")
        rep = wait(lambda: r.replies_to(no), 30, "reply to refuse")
        check("stream: a 400 is answered once with the server's reason",
              [m["body"] for m in rep] == ["Echo couldn't answer: 400: This model's maximum context length is 4096 tokens"], f"{rep}")
        fl = r.say("flaky")
        rep = wait(lambda: r.replies_to(fl), 30, "reply to flaky")
        check("stream: a 503 is tried again, then answered once", [m["body"] for m in rep] == ["Back again."] and calls("flaky") == 2,
              f"{rep} asks={calls('flaky')}")

        print("== J. the server is down for a while")
        dn = r.say("down 12")
        rep = wait(lambda: r.replies_to(dn), 90, "reply to down")
        notes = [m for m in r.thread() if (m.get("meta") or {}).get("bridge") == "status"]
        check("stream: one note says the model can't be reached, then the answer lands once",
              len(notes) == 1 and "can't reach its model" in notes[0]["body"] and [m["body"] for m in rep] == ["Up again."],
              f"notes={[n['body'][:60] for n in notes]} rep={[m['body'] for m in rep]}")
        h2 = r.say("history")
        rep = wait(lambda: r.replies_to(h2), 30, "reply to history 2")
        check("stream: the bridge's note is not part of what the model is sent", rep and "can't reach" not in rep[0]["body"], rep and rep[0]["body"][-120:])

        print("== K. clean stop, messages while down")
        wait(lambda: all(m["handled_at"] for m in r.thread() if m["sender"] == "user"), 20, "all handled")
        r.stop()
        check("stream: a clean stop reads offline at once", r.presence() == "offline", r.presence())
        a, b = r.say("first while down"), r.say("second while down")
        r.start()
        rep = wait(lambda: r.replies_to(a) and r.replies_to(b), 30, "reply to backlog")
        call = next(c for c in model_log(url) if c["text"].endswith("second while down"))
        check("stream: the backlog goes as one turn, in order, answered once",
              call["messages"][-1] == {"role": "user", "content": "first while down\nsecond while down"}
              and len(r.replies_to(a)) == 1 and r.replies_to(a) == r.replies_to(b), f"{call['messages'][-1]}")
        wait(lambda: all(m["handled_at"] for m in r.thread() if m["sender"] == "user"), 20, "all handled")
        r.stop()
        r.totals()
    finally:
        fake.kill()
        r.close()


def run_plain():
    print("\n==== plain: a server that refuses streams")
    fake, url = start_fake(["--refuse-stream"])
    r = Run("plain")
    try:
        code = r.create_agent("Plain")
        p = r.pair(code, "--url", f"{url}/chat/completions", "--model", "fake-2")
        check("plain: pairs, the endpoint URL is taken back to the base",
              p.returncode == 0 and json.loads(r.state.read_text())["remotes"]["fake-2"]["url"] == url, (p.stdout + p.stderr).strip()[:200])
        r.start()
        hi = r.say("hello")
        rep = wait(lambda: r.replies_to(hi), 30, "reply to hello")
        check("plain: answered once", [m["body"] for m in rep] == ["You said: hello"], f"{rep}")
        sl = r.say("slow 3")
        rep = wait(lambda: r.replies_to(sl), 30, "reply to slow")
        check("plain: a long answer lands whole", [m["body"] for m in rep] == ["Step 1, step 2, step 3\n\nDone after 3 steps."], f"{rep}")
        streams = [c["stream"] for c in model_log(url)]
        check("plain: asked to stream once, refused, then plain from then on (remembered on disk)",
              streams == [True, False, False] and json.loads(r.state.read_text())["remotes"]["fake-2"].get("stream") is False
              and "does not stream" in r.bridge_log(), f"{streams}")
        r.stop()
        r.totals()
    finally:
        fake.kill()
        r.close()


def run_ollama():
    print(f"\n==== ollama: {args.model} on this Mac")
    r = Run("ollama")
    try:
        code = r.create_agent("Qwen")
        p = r.pair(code, "--server", "ollama", "--model", args.model, "--ref", "qwen")
        check(f"ollama: pairs with {args.model}", p.returncode == 0 and f"is {args.model} at http://127.0.0.1:11434/v1" in p.stdout,
              (p.stdout + p.stderr).strip()[:200])
        r.start()
        ask = r.say("Show me a choose screen titled Drink with exactly two options: Tea and Coffee.")
        wait(lambda: r.row(ask)["delivered_at"], 20, "delivered")
        rep = wait(lambda: r.replies_to(ask), 300, "Ollama's answer")
        body = rep[0]["body"]
        ops = yl_ops(body)
        choose = [o for o in ops if o.get("op") == "add" and o.get("preset") == "choose"]
        check("ollama: the answer lands once and draws a Yui screen the YL parser reads",
              len(rep) == 1 and choose and {"Tea", "Coffee"} <= set(choose[0]["props"].get("options", []))
              and not [o for o in ops if o.get("op") == "error"], body[:200])
        tap = r.tap(ops, "Tea")
        rep = wait(lambda: r.replies_to(tap), 300, "answer to the tap")
        check("ollama: the tap goes back as the next turn and is answered once", len(rep) == 1 and rep[0]["body"].strip(), rep and rep[0]["body"][:200])
        q = r.say("Which drink did I just pick? Answer in one word.")
        rep = wait(lambda: r.replies_to(q), 300, "answer to the question")
        check("ollama: it remembers the tap (Yui sent the thread)", len(rep) == 1 and "tea" in rep[0]["body"].lower(), rep and rep[0]["body"][:200])

        crash = r.say("Write four short sentences about green tea.")
        wait(lambda: (json.loads(r.state.read_text()).get("inflight") or {}).get(r.agent), 30, "turn on disk")
        time.sleep(1)
        r.kill()
        log("bridge killed -9 while Ollama answers")
        check("ollama: killed mid-answer: delivered, not handled, not answered",
              r.row(crash)["delivered_at"] and not r.row(crash)["handled_at"] and not r.replies_to(crash))
        r.start()
        rep = wait(lambda: r.replies_to(crash), 300, "answer after restart")
        wait(lambda: r.row(crash)["handled_at"], 20, "handled")
        time.sleep(3)
        check("ollama: after the restart exactly one answer lands", len(r.replies_to(crash)) == 1, rep[0]["body"][:120])
        r.stop()
        r.totals()
        m = re.findall(r"answered \(streamed\)", r.bridge_log())
        check("ollama: Ollama's answers were streamed", len(m) >= 3, f"{len(m)} streamed")
    finally:
        r.close()


def run_phone():
    print(f"\n==== phone: {args.model} and the app on a simulator")
    r = Run("phone")
    out = Path(args.out)
    shots = out / "shots"
    shots.mkdir(parents=True, exist_ok=True)
    for f in shots.iterdir():
        f.unlink()
    try:
        code = r.create_agent("Qwen")
        p = r.pair(code, "--server", "ollama", "--model", args.model, "--ref", "qwen")
        check("phone: pairs", p.returncode == 0, (p.stdout + p.stderr).strip()[:200])
        rts = []
        for _ in range(2):  # one fresh session per launch: a replayed refresh token signs everyone out
            rt = secrets.token_urlsafe(32)
            sql(f"insert into yui_sessions(user_id, refresh_hash, expires_at) values "
                f"('{r.T}', '{hashlib.sha256(rt.encode()).hexdigest()}', now() + interval '1 day')")
            rts.append(rt)
        # Warm the model so the first answer on the phone is not a cold load.
        subprocess.run(BRIDGE + ["try", "hi", "--model", args.model], capture_output=True, timeout=300)
        r.start()
        env = {**os.environ, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer",
               "TEST_RUNNER_YUI_RTS": ",".join(rts), "TEST_RUNNER_YUI_USER": r.T, "TEST_RUNNER_YUI_SHOTS": str(shots)}
        subprocess.run(["xcodegen", "generate", "--quiet"], cwd=REPO, env=env, check=True)
        ui = subprocess.run(["xcodebuild", "test", "-project", "Yui.xcodeproj", "-scheme", "Yui",
                             "-destination", f"id={args.sim}", "-derivedDataPath", "/tmp/int12-dd",
                             "-only-testing:YuiUITests/OpenAICompatTests"],
                            cwd=REPO, env=env, stdout=open(out / "xcodebuild.log", "w"), stderr=subprocess.STDOUT)
        wait(lambda: all(m["handled_at"] for m in r.thread() if m["sender"] == "user"), 60, "all handled")
        r.stop()
        text = (out / "xcodebuild.log").read_text()
        check("phone: OpenAICompatTests ran and passed in the simulator",
              ui.returncode == 0 and "Executed 1 test, with 0 failures" in text, f"xcodebuild exit {ui.returncode}, log {out / 'xcodebuild.log'}")
        users = [m for m in r.thread() if m["sender"] == "user"]
        taps = [m for m in users if m["kind"] == "event"]
        check("phone: the phone's messages and the tap each got exactly one answer",
              len(users) >= 3 and taps and all(len(r.replies_to(m["id"])) == 1 for m in users),
              f"{[(m['body'][:30], len(r.replies_to(m['id']))) for m in users]}")
        (out / "thread.json").write_text(json.dumps(r.thread(), indent=1))
        print(f"  screenshots: {shots}")
    finally:
        r.close()


runs = {"stream": [run_stream], "plain": [run_plain], "ollama": [run_ollama], "phone": [run_phone],
        "all": [run_stream, run_plain, run_ollama]}[args.run]
if args.sim and run_phone not in runs:
    runs.append(run_phone)
if run_phone in runs and not args.sim:
    sys.exit("--run phone needs --sim <udid>")
for f in runs:
    try:
        f()
    except Exception as e:  # one run failing still runs the others
        check(f"{f.__name__}: ran to the end", False, repr(e))

print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)

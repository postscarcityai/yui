#!/usr/bin/env python3
"""INT-17 end to end: n8n talking to live Yui, three ways, on a throwaway account.

A real n8n (the npm package, run locally with its own empty user folder) loads
the three workflows in adapters/n8n/workflows and this package's Yui node:

  A. MCP (path D): n8n's AI Agent node with its MCP Client Tool node pointed at
     yui-mcp with a connection token (Bearer yui_ct_...), on a local Ollama
     model. The agent puts a choose screen on the phone with yui_show, waits
     with yui_answers, and reports the tap.
  B. The Yui node (this package): Ask and Wait, no LLM. The workflow's answer
     is the tap, as flat fields.
  C. Webhook (path E): the webhook bridge (adapters/webhook) POSTs each turn to
     an n8n Webhook trigger; the workflow answers "hi" with a screen and a tap
     with a line naming the choice. No LLM.

For each: the screen lands in the thread once, parses with yuigui's YL parser,
the person's tap (written the way the app writes it) reaches the workflow, and
what the workflow does with it lands where it should. The account is deleted
at the end; the token lives only in n8n's throwaway database and a temp file
that go with it.

    python3 adapters/n8n/tests/n8n_e2e.py [--run mcp|node|webhook|all] [--n8n PATH] [--log FILE]

Needs a Supabase access token like supabase/tests, n8n (`npm i n8n` somewhere,
pass its bin with --n8n or put it on PATH), and for A Ollama with qwen2.5:7b.
"""
import argparse, json, os, re, shutil, signal, socket, subprocess, sys, tempfile, threading, time, uuid
from pathlib import Path
from urllib import request as urlreq, error as urlerr

HERE = Path(__file__).resolve().parent
PKG = HERE.parent
REPO = PKG.parents[1]
WORKFLOWS = PKG / "workflows"
BRIDGE = [sys.executable, str(REPO / "adapters/webhook/python/yui_webhook.py")]
YL = Path.home() / "dev/yuigui/site/lib/yl/yl.mjs"

ap = argparse.ArgumentParser()
ap.add_argument("--run", choices=["mcp", "node", "webhook", "all"], default="all")
ap.add_argument("--n8n", default=shutil.which("n8n") or str(Path.home() / ".cache/n8n-int17/node_modules/.bin/n8n"))
ap.add_argument("--node", default=next((str(p) for p in [Path.home() / ".cache/node24/node_modules/node/bin/node"] if p.exists()), None),
                help="a Node 24+ binary for n8n (n8n 2.x refuses Node 22)")
ap.add_argument("--model", default="qwen2.5:7b")
ap.add_argument("--ollama", default="http://127.0.0.1:11434")
ap.add_argument("--log", help="also write the log here")
args = ap.parse_args()

exec(open(REPO / "supabase/tests/agents_test.py").read().split("results = []")[0])

LOG = open(args.log, "w") if args.log else None
SECRETS = []  # every token this run makes; scrubbed from anything printed
def out(s):
    for t in SECRETS:
        s = s.replace(t, "yui_ct_[redacted]")
    print(s, flush=True)
    if LOG:
        LOG.write(s + "\n"); LOG.flush()

results = []
def check(name, ok, detail=""):
    ok = bool(ok); results.append(ok)
    out(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  [{str(detail)[:400]}]" if detail else ""))
def log(msg): out(f"  .. {msg}")
def wait(cond, secs, what):
    end = time.time() + secs
    while time.time() < end:
        v = cond()
        if v:
            return v
        time.sleep(0.5)
    raise TimeoutError(what)

def yl_ops(text):
    """The YL parser's ops for every ```yui fence in a message."""
    ops = []
    for fence in text.split("```yui\n")[1:]:
        fence = fence.split("```", 1)[0]
        js = f"import({json.dumps(str(YL))}).then(m => console.log(JSON.stringify(m.parse({json.dumps(fence)}))))"
        ops += json.loads(subprocess.check_output(["node", "-e", js], text=True))
    return ops

def free_port():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p

def post_json(url, body, timeout):
    req = urlreq.Request(url, json.dumps(body).encode(), {"content-type": "application/json"})
    try:
        with urlreq.urlopen(req, timeout=timeout) as r:
            raw = r.read().decode()
            return r.status, (json.loads(raw) if raw.strip().startswith(("{", "[")) else raw)
    except urlerr.HTTPError as e:
        return e.code, e.read().decode()


# -- n8n ------------------------------------------------------------------------

class N8n:
    """One n8n process with an empty user folder, the Yui node loaded from dist/."""
    def __init__(self, home):
        self.home = home
        self.port = free_port()
        self.url = f"http://127.0.0.1:{self.port}"
        node_bin = str(Path(args.node).parent) if args.node else None
        self.env = {**os.environ,
                    **({"PATH": node_bin + os.pathsep + os.environ["PATH"]} if node_bin else {}),
                    "N8N_USER_FOLDER": str(home),
                    "N8N_PORT": str(self.port), "N8N_LISTEN_ADDRESS": "127.0.0.1",
                    "N8N_DIAGNOSTICS_ENABLED": "false", "N8N_VERSION_NOTIFICATIONS_ENABLED": "false",
                    "N8N_PERSONALIZATION_ENABLED": "false", "N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS": "true",
                    "N8N_SECURE_COOKIE": "false", "N8N_RUNNERS_ENABLED": "true",
                    "DB_SQLITE_POOL_SIZE": "2", "N8N_LOG_LEVEL": "info",
                    "EXECUTIONS_DATA_SAVE_ON_SUCCESS": "all"}
        self.proc = None

    def cli(self, *a, check=True):
        p = subprocess.run([args.n8n, *a], env=self.env, capture_output=True, text=True, timeout=300)
        if check and p.returncode:
            raise RuntimeError(f"n8n {a[0]} exit {p.returncode}: {(p.stdout + p.stderr)[-800:]}")
        return p

    def import_workflow(self, path, subs):
        wf = json.loads(Path(path).read_text())
        text = json.dumps(wf)
        for k, v in subs.items():
            text = text.replace(k, v)
        f = self.home / f"import-{uuid.uuid4().hex[:6]}.json"
        f.write_text(text)
        self.cli("import:workflow", f"--input={f}")
        f.unlink()
        return json.loads(text)["id"]

    def import_credentials(self, creds):
        f = self.home / "creds.json"
        f.write_text(json.dumps(creds)); f.chmod(0o600)
        try:
            self.cli("import:credentials", f"--input={f}")
        finally:
            f.unlink()

    def publish(self, wid):
        p = self.cli("publish:workflow", f"--id={wid}", check=False)
        if p.returncode:
            self.cli("update:workflow", f"--id={wid}", "--active=true")

    def install_package(self):
        """Installs this package the way a person does by hand: npm pack, then into ~/.n8n/nodes."""
        subprocess.run(["npm", "run", "build"], cwd=PKG, check=True, capture_output=True)
        tgz = subprocess.run(["npm", "pack", "--pack-destination", str(self.home)], cwd=PKG, check=True,
                             capture_output=True, text=True).stdout.strip().splitlines()[-1]
        nodes = self.home / ".n8n/nodes"
        nodes.mkdir(parents=True, exist_ok=True)
        (nodes / "package.json").write_text('{"name": "installed-nodes", "private": true}')
        subprocess.run(["npm", "install", "--no-audit", "--no-fund", "--omit=peer", "--legacy-peer-deps",
                        str(self.home / tgz)], cwd=nodes, check=True, capture_output=True, env=self.env)
        return sorted(p.name for p in (nodes / "node_modules/n8n-nodes-yui").rglob("*") if p.is_file())

    def start(self):
        self.log = open(self.home / "n8n.log", "w")
        self.proc = subprocess.Popen([args.n8n, "start"], env=self.env, stdout=self.log, stderr=subprocess.STDOUT,
                                     start_new_session=True)
        def up():
            try:
                with urlreq.urlopen(self.url + "/healthz/readiness", timeout=2) as r:
                    return r.status == 200
            except Exception:
                return False
        wait(up, 180, "n8n up")

    def last_errors(self):
        """Error messages from n8n's own record of its executions (for a failed check)."""
        import sqlite3
        try:
            db = sqlite3.connect(self.home / ".n8n/database.sqlite")
            rows = db.execute("select data from execution_data order by executionId desc limit 3").fetchall()
        except Exception as e:
            return [repr(e)]
        found = []
        for (data,) in rows:  # n8n stores it "flatted": one list, strings as their own entries
            try:
                strings = [x for x in json.loads(data) if isinstance(x, str)]
            except Exception:
                strings = [data]
            found += [x[:300] for x in strings if re.search(r"(?i)error|fail|refus|timed? ?out|not ", x) and len(x) > 8]
        return list(dict.fromkeys(found))[:8]

    def stop(self):
        if self.proc and self.proc.poll() is None:
            os.killpg(self.proc.pid, signal.SIGTERM)
            try:
                self.proc.wait(30)
            except subprocess.TimeoutExpired:
                os.killpg(self.proc.pid, signal.SIGKILL)


# -- the run ----------------------------------------------------------------------

def main():
    runs = ["mcp", "node", "webhook"] if args.run == "all" else [args.run]
    home = Path(tempfile.mkdtemp(prefix="yui-int17-"))
    (home / ".n8n").mkdir()
    n8n = N8n(home)
    T = str(uuid.uuid4())
    sql(f"insert into yui_users(id, apple_sub) values ('{T}','test.{T}')")
    tok = mint(T, ttl=3600)
    bridge = None
    out(f"== n8n {n8n.cli('--version').stdout.strip()} at {n8n.url}, user folder {home}")
    files = n8n.install_package()
    check("the npm pack of n8n-nodes-yui installs into ~/.n8n/nodes (dist only)",
          "Yui.node.js" in files and "YuiApi.credentials.js" in files and not any(f.endswith(".ts") for f in files), files)

    def thread(agent):
        s, r = rest("GET", "yui_messages?select=id,sender,body,kind,meta,delivered_at,handled_at,created_at"
                           f"&agent_id=eq.{agent}&order=created_at.asc,id.asc", tok)
        assert s == 200, (s, r)
        return r

    def tap(agent, fence_ops, choice):
        """Answer the screen the way the app does: an event row from the person."""
        ch = next(o for o in fence_ops if o.get("op") == "add" and o.get("preset") in ("choose", "ask"))
        opts = [o.get("label") if isinstance(o, dict) else o for o in ch.get("props", {}).get("options") or []]
        label = next((o for o in opts if str(o).lower() == choice.lower()), None)
        assert label, f"{choice} is not an option on the screen: {opts}"
        key = "choice" if ch["preset"] == "choose" else "answer"
        row = {"id": str(uuid.uuid4()), "user_id": T, "agent_id": agent, "sender": "user", "kind": "event",
               "body": f"[yui] {ch['id']} {ch['preset']} {key}={label}",
               "meta": {"id": ch["id"], "preset": ch["preset"], "value": {key: label}, "echo": label}}
        s, r = rest("POST", "yui_messages", tok, row)
        assert s == 201, (s, r)
        return row

    def watch_and_tap(agent, choice, secs, got):
        """Waits for the first agent screen, parses it, taps it. Runs beside the workflow call."""
        try:
            m = wait(lambda: next((m for m in thread(agent) if m["sender"] == "agent" and "```yui" in m["body"]), None),
                     secs, "a screen in the thread")
            got["screen"] = m
            got["ops"] = yl_ops(m["body"])
            got["errors"] = [o for o in got["ops"] if o.get("op") == "error"]
            got["tap"] = tap(agent, got["ops"], choice)
            got["tap_at"] = time.time()
        except Exception as e:
            got["error"] = repr(e)

    def pair_mcp(name, ref):
        s, r = fn("yui-agents", {"action": "create", "name": name, "pair": True}, tok)
        agent = r["agent"]["id"]
        s, r = fn("yui-connect", {"action": "pair", "code": r["pairing"]["code"], "remote_ref": ref,
                                  "kind": "mcp", "host_name": "n8n (INT-17 test)"})
        ct = r.get("connector_token", "")
        SECRETS.append(ct)
        return agent, ct

    try:
        agents = {}
        creds = []
        subs = {}
        if "mcp" in runs:
            agents["mcp"], ct = pair_mcp("n8n agent", "n8n-agent")
            check("A: paired an MCP connection for n8n (kind mcp, token yui_ct_)", ct.startswith("yui_ct_"))
            creds += [{"id": "yuiBearer000001", "name": "Yui token", "type": "httpBearerAuth", "data": {"token": ct}},
                      {"id": "ollamaLocal00001", "name": "Ollama", "type": "ollamaApi", "data": {"baseUrl": args.ollama}}]
        if "node" in runs:
            agents["node"], ct2 = pair_mcp("n8n flow", "n8n-flow")
            check("B: paired a second MCP connection for the Yui node", ct2.startswith("yui_ct_"))
            creds += [{"id": "yuiApi0000000001", "name": "Yui account", "type": "yuiApi",
                       "data": {"token": ct2, "endpoint": f"{BASE}/functions/v1/yui-mcp"}}]
        if creds:
            n8n.import_credentials(creds)
        wids = {}
        if "mcp" in runs:
            wids["mcp"] = n8n.import_workflow(WORKFLOWS / "yui-mcp-agent.json", {"qwen2.5:7b": args.model})
        if "node" in runs:
            wids["node"] = n8n.import_workflow(WORKFLOWS / "yui-node-ask.json", {})
        if "webhook" in runs:
            wids["webhook"] = n8n.import_workflow(WORKFLOWS / "yui-webhook-turn.json", {})
        for w in wids.values():
            n8n.publish(w)
        n8n.start()
        log(f"n8n up, {len(wids)} workflows published")
        loaded = (home / "n8n.log").read_text()
        check("n8n started, no load error for n8n-nodes-yui",
              not re.search(r"(?i)(error|failed).{0,120}n8n-nodes-yui|n8n-nodes-yui.{0,120}(error|failed)", loaded),
              "" if "n8n-nodes-yui" not in loaded else loaded[-400:])

        # A. MCP Client Tool + AI Agent on a local model
        if "mcp" in runs:
            out("== A. n8n AI Agent + MCP Client Tool -> yui-mcp (path D)")
            if args.model.startswith("qwen"):
                log("warming the model")
                post_json(f"{args.ollama}/api/generate", {"model": args.model, "prompt": "hi", "stream": False,
                                                          "options": {"num_ctx": 8192}}, 400)
            got = {}
            w = threading.Thread(target=watch_and_tap, args=(agents["mcp"], "Soup", 400, got)); w.start()
            t0 = time.time()
            s, r = post_json(f"{n8n.url}/webhook/yui-agent", {"ask": "Ask me on my phone what we are having for lunch: Salad, Soup or Tacos. Wait for my tap, then tell me what I picked."}, 600)
            took = time.time() - t0
            w.join(5)
            log(f"workflow answered in {took:.0f}s: {json.dumps(r)[:300]}")
            check("A: the agent's screen landed in the thread", got.get("screen"), got.get("error"))
            if got.get("screen"):
                m = got["screen"]
                check("A: it parses with the YL parser, a choose with the three options",
                      not got["errors"] and any(o.get("preset") == "choose" for o in got["ops"]), got["ops"])
                screens = [x for x in thread(agents["mcp"]) if x["sender"] == "agent" and "```yui" in x["body"]]
                check("A: one screen, not a retry storm", len(screens) == 1, len(screens))
            if s != 200:
                log(f"n8n recorded: {n8n.last_errors()}")
            text = json.dumps(r) if not isinstance(r, str) else r
            check("A: the tap reached the workflow: its answer names Soup", s == 200 and "soup" in text.lower(), (s, text[:300]))
            row = next((x for x in thread(agents["mcp"]) if got.get("tap") and x["id"] == got["tap"]["id"]), None)
            check("A: yui_answers took the tap (delivered and handled)", row and row["delivered_at"] and row["handled_at"], row)

        # B. the Yui node, Ask and Wait
        if "node" in runs:
            out("== B. the Yui node: Ask and Wait (no LLM)")
            got = {}
            w = threading.Thread(target=watch_and_tap, args=(agents["node"], "Tacos", 60, got)); w.start()
            s, r = post_json(f"{n8n.url}/webhook/yui-ask", {"question": "Lunch?"}, 120)
            w.join(5)
            log(f"workflow answered: {json.dumps(r)[:300]}")
            check("B: the node's screen landed and parses", got.get("screen") and not got.get("errors"), got.get("error") or got.get("errors"))
            if got.get("screen"):
                check("B: the screen is the one the node was given, chat text above it",
                      got["screen"]["body"].startswith("Quick one from n8n\n```yui\nchoose \"Lunch?\" Salad|Soup|Tacos"), got["screen"]["body"])
            item = r[0] if isinstance(r, list) and r else r
            check("B: the workflow's output is the tap, flat (choice, echo, line, screen_id)",
                  s == 200 and isinstance(item, dict) and item.get("choice") == "Tacos" and item.get("echo") == "Tacos"
                  and item.get("line") == got.get("tap", {}).get("body") and item.get("screen_id") == got["screen"]["id"], (s, r))
            row = next((x for x in thread(agents["node"]) if got.get("tap") and x["id"] == got["tap"]["id"]), None)
            check("B: the tap is marked delivered and handled", row and row["delivered_at"] and row["handled_at"], row)
            follow = [x for x in thread(agents["node"]) if x["sender"] == "agent" and "Tacos" in x["body"] and "```" not in x["body"]]
            check("B: the next node (Send Message) used the answer", len(follow) == 1, [x["body"] for x in follow])

        # C. the webhook bridge -> an n8n Webhook trigger
        if "webhook" in runs:
            out("== C. webhook bridge -> n8n Webhook trigger (path E, no LLM)")
            s, r = fn("yui-agents", {"action": "create", "name": "n8n hook", "pair": True}, tok)
            agents["webhook"] = agent = r["agent"]["id"]
            state = home / "webhook.json"
            p = subprocess.run(BRIDGE + ["--state", str(state), "pair", r["pairing"]["code"], "--ref", "n8n-hook",
                                         "--host-name", "n8n (INT-17 test)"], capture_output=True, text=True)
            try:
                SECRETS.append(json.loads(state.read_text())["connector_token"])
            except Exception:
                pass
            check("C: the bridge paired (kind http)", p.returncode == 0, (p.stdout + p.stderr)[-200:])
            blog = open(home / "bridge.log", "w")
            bridge = subprocess.Popen(BRIDGE + ["--state", str(state), "run", "--webhook", f"{n8n.url}/webhook/yui-turn",
                                                "--interval", "1"], stdout=blog, stderr=subprocess.STDOUT)
            wait(lambda: "online as" in (home / "bridge.log").read_text(), 30, "bridge online")
            hi = {"id": str(uuid.uuid4()), "user_id": T, "agent_id": agent, "sender": "user", "body": "hi", "kind": "text"}
            assert rest("POST", "yui_messages", tok, hi)[0] == 201
            m = wait(lambda: next((x for x in thread(agent) if x["sender"] == "agent"), None), 60, "the workflow's screen")
            ops = yl_ops(m["body"])
            check("C: 'hi' reached the workflow; its answer is a screen the YL parser reads",
                  "```yui" in m["body"] and ops and not [o for o in ops if o.get("op") == "error"]
                  and any(o.get("preset") == "choose" for o in ops), m["body"])
            check("C: the reply names its turn (meta.turn)", (m.get("meta") or {}).get("turn") == [hi["id"]], m.get("meta"))
            t = tap(agent, ops, "Soup")
            m2 = wait(lambda: next((x for x in thread(agent) if x["sender"] == "agent" and (x.get("meta") or {}).get("turn") == [t["id"]]), None),
                      60, "the answer to the tap")
            check("C: the tap reached the workflow as an event: the answer names Soup", "Soup" in m2["body"], m2["body"])
            try:  # the bridge writes the reply first, then marks the turn handled
                wait(lambda: all(x["handled_at"] for x in thread(agent) if x["sender"] == "user"), 15, "handled")
            except TimeoutError:
                pass
            rows = {x["id"]: x for x in thread(agent)}
            check("C: both of the person's rows are handled, each answered once",
                  all(rows[i]["handled_at"] for i in (hi["id"], t["id"]))
                  and sum(1 for x in rows.values() if x["sender"] == "agent") == 2,
                  [(x["sender"], bool(x["handled_at"])) for x in rows.values()])
            bridge.send_signal(signal.SIGTERM); bridge.wait(20); bridge = None
    finally:
        if bridge and bridge.poll() is None:
            bridge.send_signal(signal.SIGTERM)
            try: bridge.wait(20)
            except Exception: bridge.kill()
        n8n.stop()
        s, _ = fn("yui-delete", {}, tok)
        left = sql(f"select (select count(*) from yui_messages where user_id = '{T}') + "
                   f"(select count(*) from yui_users where id = '{T}') + "
                   f"(select count(*) from yui_connectors where user_id = '{T}') n")[0]["n"]
        check("throwaway account deleted, nothing left", s == 200 and left == 0, f"{s} {left}")
        # n8n's database held the tokens (encrypted); it goes with the folder
        shutil.rmtree(home, ignore_errors=True)
        check("n8n's user folder (its database and the tokens in it) removed", not home.exists())
        dumped = "\n".join(Path(x).read_text() for x in [args.log] if x and Path(x).exists())
        check("no token in this log", not any(t and t in dumped for t in SECRETS))

    out(f"\n{sum(results)}/{len(results)} passed")
    return all(results)


if __name__ == "__main__":
    sys.exit(0 if main() else 1)

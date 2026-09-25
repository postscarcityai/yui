#!/usr/bin/env python3
"""INT-18 end to end: the A2A bridge against live PROOF and a scripted A2A agent.

The agent is tests/echo-agent.ts (no model, fixed answers). Never point this
at an LLM host on this Mac. For each protocol run, on a fresh throwaway
account (never a real one):

  A. pair with the app's code and the agent's card URL; the state file is private.
  B. hello and screen: the answer lands once in the thread, with meta.turn;
     the row is delivered and handled; the agent got the channel guide as a
     context part on the task's first message, and contextId = the Yui agent.
  C. a long task: the row is delivered with no reply while the task works (the
     app's working row), then the whole answer lands once.
  D. the bridge is killed -9 mid-task: after a restart it picks the task back
     up (SubscribeToTask or GetTask) instead of sending the turn again, and the
     answer lands once.
  E. input-required: the question lands; the person's answer continues the
     same task, without a second guide.
  F. a tap on a screen reaches the agent as text and data.
  G. failed: the person reads why.
  H. a clean stop reads offline.
  ADK (--protocol adk, INT-9, not in `all`): a real Google ADK agent,
     tests/sdk/adk_agent.py, served over A2A by ADK's own to_a2a, its model
     local Ollama qwen2.5:7b through LiteLLM (no key). Pair, a turn, a screen
     the YL parser reads (drawn only because the guide reached the model: the
     agent's own instruction never mentions Yui), a tap on it, a clean stop.
     Needs uv and Ollama with qwen2.5:7b.
  LangGraph (--protocol langgraph, INT-14, not in `all`): a scripted LangGraph
     graph, tests/sdk/langgraph_agent.py (no model), served over A2A by
     LangGraph's own Agent Server (`langgraph dev`, /a2a/{assistant_id}). As
     ADK, plus: the guide and the tap reach the graph's state as data keys
     (yui_channel_guide, yui_events), the thread is the Yui agent, and the
     guide never shows up as a chat message. Needs uv.
  CrewAI (--protocol crewai, INT-15, not in `all`): a CrewAI agent,
     tests/sdk/crewai_agent.py, served over A2A 0.3 by CrewAI's own
     A2AServerConfig card and task executor on the A2A SDK's server, its model
     local Ollama qwen2.5:7b through LiteLLM (no key). As ADK: the screen is
     drawn only because the guide reached the agent's backstory. Needs uv and
     Ollama with qwen2.5:7b.
  Microsoft Agent Framework (--protocol maf, INT-16, not in `all`): an Agent
     Framework agent, tests/sdk/maf_agent.py, served over A2A 1.0 by its
     A2AExecutor on the A2A SDK's server, its model local Ollama qwen2.5:7b
     (no key). As ADK: the screen is drawn only because the guide reached the
     run's instructions. Plus: the agent recalls the tap on the next turn (one
     session per contextId). Needs uv and Ollama with qwen2.5:7b.
  I. with --sim: the phone side, on its own fresh account and thread (A2A
     1.0): YuiUITests/A2ATests on a simulator shows the working row, the long
     answer, a screen and a tap (light), a question and its answer (dark).
     Screenshots in --out.

Pass: every person's row is handled and named by exactly one reply, and the
agent got each turn exactly once.

    python3 adapters/a2a/tests/a2a_e2e.py [--protocol 1.0|0.3|poll|phone|adk|langgraph|crewai|maf|all] [--sim <udid>] [--out DIR]

`poll` is 1.0 with streaming off: the bridge sends, then follows by GetTask.
Needs a Supabase access token like supabase/tests. Accounts are deleted.
"""
import argparse, hashlib, json, os, secrets, signal, subprocess, sys, tempfile, time, urllib.request, uuid
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
A2A = REPO / "adapters/a2a"
BRIDGE = ["node", str(A2A / "yui-a2a.ts")]

ap = argparse.ArgumentParser()
ap.add_argument("--protocol", choices=["1.0", "0.3", "poll", "phone", "adk", "langgraph", "crewai", "maf", "all"], default="all")
ap.add_argument("--sim", help="simulator udid: also run YuiUITests/A2ATests (phone side)")
ap.add_argument("--out", default="/tmp/int18-proof")
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


def start_agent(extra):
    p = subprocess.Popen(["node", str(A2A / "tests/echo-agent.ts"), *extra], stdout=subprocess.PIPE, text=True)
    line = p.stdout.readline()
    url = line.split()[1]
    return p, url

def agent_log(url):
    with urllib.request.urlopen(f"{url}/_log") as r:
        return json.loads(r.read())


def run(protocol: str) -> None:
    version = "0.3" if protocol == "0.3" else "1.0"
    phone = protocol == "phone"
    print(f"\n==== A2A {protocol}")
    home = Path(tempfile.mkdtemp(prefix=f"yui-int18-{protocol}-"))
    state = home / "a2a.json"
    base = BRIDGE + ["--state", str(state)]
    agent_proc, url = start_agent(["--protocol", version] + (["--no-streaming"] if protocol == "poll" else []))
    log(f"scripted agent at {url}")
    T = str(uuid.uuid4())
    sql(f"insert into yui_users(id, apple_sub) values ('{T}','test.{T}')")
    tok = mint(T, ttl=3600)
    proc = [None]
    ups = [0]

    def start():
        out = open(home / "bridge.log", "a")
        proc[0] = subprocess.Popen(base + ["run", "--interval", "1"], stdout=out, stderr=subprocess.STDOUT)
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

    def sends(text):  # how many times the agent got a message with this text
        return sum(1 for c in agent_log(url) if c.get("text") == text)

    agent = None
    try:
        s, r = fn("yui-agents", {"action": "create", "name": "Echo", "pair": True}, tok)
        agent = r["agent"]["id"]
        print("== A. pair by agent card")
        p = subprocess.run(base + ["pair", r["pairing"]["code"], "--card", url, "--host-name", "INT-18 test"],
                           capture_output=True, text=True, timeout=60)
        st = json.loads(state.read_text()) if state.exists() else {}
        check(f"{protocol}: pairs with the app's code and the card URL",
              p.returncode == 0 and "paired" in p.stdout and f"A2A {version}" in p.stdout, (p.stdout + p.stderr).strip()[:300])
        check(f"{protocol}: state file is private, holds the token and the card",
              state.exists() and oct(state.stat().st_mode & 0o777) == "0o600"
              and st.get("token", "").startswith("yui_ct_") and st.get("remotes", {}).get("echo", {}).get("card", "").startswith(url),
              json.dumps(st.get("remotes")))
        ref = sql(f"select kind, remote_ref from yui_agents where id = '{agent}'")
        check(f"{protocol}: the agent is bound as remote_ref echo", ref and ref[0]["remote_ref"] == "echo", f"{ref}")

        if phone:
            phone_side(T, start, stop, thread, replies_to)
            return
        print("== B. hello, then a screen")
        start()
        check(f"{protocol}: agent reads online", wait(lambda: presence() == "online", 20, "online"))
        hi = say("hello")
        rep = wait(lambda: replies_to(hi), 30, "reply to hello")
        check(f"{protocol}: one reply, meta.turn = [hello]",
              [m["body"] for m in rep] == ["You said: hello"] and rep[0]["meta"] == {"turn": [hi]}, f"{rep}")
        wait(lambda: row(hi)["handled_at"], 15, "hello handled")
        check(f"{protocol}: hello marked delivered and handled", row(hi)["delivered_at"] and row(hi)["handled_at"])
        guide = fn("yui-connect", {"action": "guide"})[1]["guide"]
        call = next(c for c in agent_log(url) if c.get("text") == "hello")
        check(f"{protocol}: the guide rides as a context part ({guide['version']}), contextId = the Yui agent",
              call["context"] == [{"yui": "channel_guide", "version": guide["version"]}] and call["contextId"] == agent
              and call["version"] == ("1.0" if version == "1.0" else ""), f"{call}")
        sc = say("screen")
        rep = wait(lambda: replies_to(sc), 30, "reply to screen")
        check(f"{protocol}: a ```yui screen comes through as is", len(rep) == 1 and '```yui\nchoose "Pick one" Tea|Coffee\n```' in rep[0]["body"])

        print("== C. a long task: working, then done")
        slow = say("slow 5")
        wait(lambda: row(slow)["delivered_at"], 15, "slow delivered")
        time.sleep(2.5)
        mid = row(slow)
        check(f"{protocol}: while it works: delivered, not handled, no reply (the working row)",
              mid["delivered_at"] and not mid["handled_at"] and not replies_to(slow))
        rep = wait(lambda: replies_to(slow), 40, "reply to slow")
        check(f"{protocol}: the whole answer lands once",
              [m["body"] for m in rep] == ["Step 1, step 2, step 3, step 4, step 5\n\nDone after 5 steps."], f"{rep}")

        print("== D. killed -9 mid-task")
        crash = say("slow 8")
        wait(lambda: (json.loads(state.read_text()).get("inflight", {}).get(agent) or {}).get("taskId"), 20, "task id on disk")
        time.sleep(1.5)
        task_id = json.loads(state.read_text())["inflight"][agent]["taskId"]
        proc[0].send_signal(signal.SIGKILL)
        proc[0].wait(10)
        log(f"bridge killed -9 while task {task_id[:8]} works")
        check(f"{protocol}: mid-task row is delivered, not handled, not answered",
              row(crash)["delivered_at"] and not row(crash)["handled_at"] and not replies_to(crash))
        start()
        rep = wait(lambda: replies_to(crash), 60, "reply after restart")
        wait(lambda: row(crash)["handled_at"], 15, "crash handled")
        follow = [c for c in agent_log(url) if c.get("taskId") == task_id and c["method"] in
                  ("SubscribeToTask", "tasks/resubscribe", "GetTask", "tasks/get")]
        check(f"{protocol}: after the restart the task is picked back up, not sent again",
              sends("slow 8") == 1 and follow, f"sends={sends('slow 8')} follow={[c['method'] for c in follow]}")
        check(f"{protocol}: the answer lands once, whole",
              [m["body"] for m in rep] == ["Step 1, step 2, step 3, step 4, step 5, step 6, step 7, step 8\n\nDone after 8 steps."],
              f"{rep}")

        print("== E. input-required")
        ask = say("ask")
        rep = wait(lambda: replies_to(ask), 30, "question")
        check(f"{protocol}: the agent's question lands", [m["body"] for m in rep] == ["Which color?"], f"{rep}")
        wait(lambda: row(ask)["handled_at"], 15, "ask handled")
        blue = say("Blue")
        rep = wait(lambda: replies_to(blue), 30, "answer")
        calls = agent_log(url)
        c_ask = next(c for c in calls if c.get("text") == "ask")
        c_blue = next(c for c in calls if c.get("text") == "Blue")
        check(f"{protocol}: the answer continues the same task, no second guide",
              [m["body"] for m in rep] == ["Blue it is."] and c_blue["taskId"] and c_blue["context"] == [],
              f"{c_blue}")
        check(f"{protocol}: the first message of that task had the guide", c_ask["taskId"] is None and c_ask["context"])

        print("== F. a tap")
        tap = say("[yui] n1 choose choice=Tea", "event", {"id": "n1", "preset": "choose", "value": {"choice": "Tea"}, "echo": "Tea"})
        rep = wait(lambda: replies_to(tap), 30, "reply to tap")
        check(f"{protocol}: the tap reaches the agent and is answered once",
              [m["body"] for m in rep] == ["Tea it is."], f"{rep}")

        print("== G. failed")
        f = say("fail")
        rep = wait(lambda: replies_to(f), 30, "reply to fail")
        check(f"{protocol}: the person reads why it failed",
              [m["body"] for m in rep] == ["Echo couldn't finish that.\n\nThe printer is on fire."], f"{rep}")

        print("== H. clean stop, totals")
        wait(lambda: all(m["handled_at"] for m in thread() if m["sender"] == "user"), 20, "all handled")
        stop()
        check(f"{protocol}: a clean stop reads offline at once", presence() == "offline", presence())
        users = [m for m in thread() if m["sender"] == "user"]
        named = [i for m in thread() if m["sender"] == "agent" for i in (m.get("meta") or {}).get("turn") or []]
        check(f"{protocol}: every person's row handled and answered by exactly one reply",
              all(m["handled_at"] for m in users) and all(named.count(m["id"]) == 1 for m in users), f"{len(users)} rows")
        check(f"{protocol}: the agent got each turn exactly once",
              all(sends(m["body"]) == 1 for m in users), f"{[(m['body'][:12], sends(m['body'])) for m in users]}")
    finally:
        if proc[0] and proc[0].poll() is None:
            proc[0].kill()
        agent_proc.kill()
        s, _ = fn("yui-delete", {}, tok)
        left = sql(f"select count(*)::int n from yui_messages where user_id = '{T}'")[0]["n"] \
            + sql(f"select count(*)::int n from yui_users where id = '{T}'")[0]["n"]
        check(f"{protocol}: throwaway account deleted, nothing left", s == 200 and left == 0, f"{s} {left}")
        print(f"  bridge log: {home / 'bridge.log'}")


YL = Path.home() / "dev/yuigui/site/lib/yl/yl.mjs"

def yl_ops(text):
    """The YL parser's ops for every ```yui fence in a reply."""
    ops = []
    for fence in text.split("```yui\n")[1:]:
        fence = fence.split("```", 1)[0]
        js = f"import({json.dumps(str(YL))}).then(m => console.log(JSON.stringify(m.parse({json.dumps(fence)}))))"
        ops += json.loads(subprocess.check_output(["node", "-e", js], text=True))
    return ops


SDK = {  # --protocol adk / langgraph: a real framework's own A2A server
    "adk": {"name": "ADK", "card": "INT-9", "log": "adk.log", "boot": 240,
            "what": "a Google ADK agent over A2A (INT-9)",
            "served": "A2A 1.0, served by to_a2a", "reached": "the guide reached it through ADK"},
    "langgraph": {"name": "LangGraph", "card": "INT-14", "log": "langgraph.log", "boot": 240,
                  "what": "a LangGraph agent on LangGraph's Agent Server over A2A (INT-14)",
                  "served": "A2A 1.0, served by langgraph dev",
                  "reached": "drawn only because the guide reached the graph's state"},
    "crewai": {"name": "CrewAI", "card": "INT-15", "log": "crewai.log", "boot": 300, "version": "0.3",
               "what": "a CrewAI agent over A2A (INT-15)",
               "served": "A2A 0.3, served by CrewAI's A2AServerConfig and executor",
               "reached": "drawn only because the guide reached the agent's backstory"},
    "maf": {"name": "Agent Framework", "card": "INT-16", "log": "maf.log", "boot": 300,
            "what": "a Microsoft Agent Framework agent over A2A (INT-16)",
            "served": "A2A 1.0, served by Agent Framework's A2AExecutor",
            "reached": "drawn only because the guide reached the run's instructions"},
}


def start_sdk(kind, home, port):
    """Starts the framework's agent in its own process group; returns (process, base URL, [card URL], card getter)."""
    url = f"http://127.0.0.1:{port}"
    out = open(home / SDK[kind]["log"], "w")
    if kind == "adk":
        proc = subprocess.Popen(["uv", "run", "--quiet", "--with", "google-adk", "--with", "litellm",
                                 "--with", "a2a-sdk[http-server]", "--with", "uvicorn",
                                 str(A2A / "tests/sdk/adk_agent.py"), str(port)],
                                stdout=out, stderr=subprocess.STDOUT, start_new_session=True)
        card_url = [url]
    elif kind == "crewai":
        proc = subprocess.Popen(["uv", "run", "--quiet", "--python", "3.12", "--with", "crewai[a2a,litellm]", "--with", "uvicorn",
                                 str(A2A / "tests/sdk/crewai_agent.py"), str(port)],
                                stdout=out, stderr=subprocess.STDOUT, start_new_session=True)
        card_url = [url]
    elif kind == "maf":  # its A2A and Ollama packages are betas: allowed by name, so httpx stays on 0.x
        proc = subprocess.Popen(["uv", "run", "--quiet", "--python", "3.12", "--with", "agent-framework-a2a>=1.0.0b0",
                                 "--with", "agent-framework-ollama>=1.0.0b0", "--with", "a2a-sdk[http-server]", "--with", "uvicorn",
                                 str(A2A / "tests/sdk/maf_agent.py"), str(port)],
                                stdout=out, stderr=subprocess.STDOUT, start_new_session=True)
        card_url = [url]
    else:  # langgraph dev writes .langgraph_api/ where it runs, so it runs in a copy
        lg = home / "langgraph"
        lg.mkdir()
        for f in ("langgraph_agent.py", "langgraph.json"):
            (lg / f).write_text((A2A / "tests/sdk" / f).read_text())
        proc = subprocess.Popen(["uv", "run", "--quiet", "--with", "langgraph-cli[inmem]", "langgraph", "dev",
                                 "--config", "langgraph.json", "--port", str(port), "--no-browser", "--no-reload"],
                                cwd=lg, stdout=out, stderr=subprocess.STDOUT, start_new_session=True)
        card_url = [None]

    def card():
        try:
            if card_url[0] is None:  # the graph's assistant, then its card
                req = urllib.request.Request(f"{url}/assistants/search", json.dumps({"graph_id": "yui_helper"}).encode(),
                                             {"content-type": "application/json"})
                with urllib.request.urlopen(req, timeout=2) as r:
                    card_url[0] = f"{url}/.well-known/agent-card.json?assistant_id={json.loads(r.read())[0]['assistant_id']}"
            u = card_url[0] if "?" in card_url[0] else f"{card_url[0]}/.well-known/agent-card.json"
            with urllib.request.urlopen(u, timeout=2) as r:
                return json.loads(r.read())
        except Exception:
            return None
    return proc, url, card_url, card


def lg_state(url, thread_id):
    """The LangGraph thread's state (the Agent Server's own threads API)."""
    with urllib.request.urlopen(f"{url}/threads/{thread_id}/state", timeout=10) as r:
        return json.loads(r.read())["values"]


def run_sdk(kind):
    S = SDK[kind]
    print(f"\n==== {S['name']}: {S['what']}")
    home = Path(tempfile.mkdtemp(prefix=f"yui-{S['card'].lower()}-{kind}-"))
    state = home / "a2a.json"
    base = BRIDGE + ["--state", str(state)]
    import socket
    with socket.socket() as so:
        so.bind(("127.0.0.1", 0))
        port = so.getsockname()[1]
    agent_proc, url, card_url, card = start_sdk(kind, home, port)
    T = str(uuid.uuid4())
    proc = [None]
    agent = None
    tok = None
    k = kind

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

    try:
        c = wait(card, S["boot"], f"the {S['name']} agent's card (first run downloads it)")
        log(f"{S['name']} agent {c['name']} at {card_url[0]}")
        sql(f"insert into yui_users(id, apple_sub) values ('{T}','test.{T}')")
        tok = mint(T, ttl=3600)
        s, r = fn("yui-agents", {"action": "create", "name": S["name"], "pair": True}, tok)
        agent = r["agent"]["id"]

        print(f"== pair by the {S['name']} agent's card")
        p = subprocess.run(base + ["pair", r["pairing"]["code"], "--card", card_url[0], "--host-name", f"{S['card']} test"],
                           capture_output=True, text=True, timeout=60)
        st = json.loads(state.read_text()) if state.exists() else {}
        check(f"{k}: pairs with the app's code and {S['name']}'s card ({S['served']})",
              p.returncode == 0 and "paired" in p.stdout and f"A2A {S.get('version', '1.0')}" in p.stdout, (p.stdout + p.stderr).strip()[:300])
        check(f"{k}: state file is private, holds the token and the card",
              oct(state.stat().st_mode & 0o777) == "0o600" and st.get("token", "").startswith("yui_ct_")
              and any(v.get("card", "").startswith(url) for v in st.get("remotes", {}).values()), json.dumps(st.get("remotes")))

        print("== a turn")
        out = open(home / "bridge.log", "a")
        proc[0] = subprocess.Popen(base + ["run", "--interval", "1"], stdout=out, stderr=subprocess.STDOUT)
        wait(lambda: "online as" in (home / "bridge.log").read_text(), 30, "bridge online")
        check(f"{k}: agent reads online", wait(lambda: presence() == "online", 20, "online"))
        hi = say("Hi! In one short sentence, what can you help with?")
        rep = wait(lambda: replies_to(hi), 300, f"{S['name']}'s answer")
        wait(lambda: row(hi)["handled_at"], 20, "hi handled")
        check(f"{k}: the turn is answered once, meta.turn names it, delivered and handled",
              len(rep) == 1 and rep[0]["body"].strip() and rep[0]["meta"] == {"turn": [hi]}
              and row(hi)["delivered_at"] and row(hi)["handled_at"], rep and rep[0]["body"][:200])

        print("== a screen")
        ask = say("Help me pick a drink for this afternoon: Tea or Coffee. Give me the choices as buttons.")
        rep = wait(lambda: replies_to(ask), 300, "the screen")
        body = rep[0]["body"]
        ops = yl_ops(body)
        picks = [o for o in ops if o.get("op") == "add" and o.get("preset") in ("choose", "ask")]
        check(f"{k}: a Yui screen the YL parser reads ({S['reached']})",
              len(rep) == 1 and picks and picks[0]["props"].get("options") and not [o for o in ops if o.get("op") == "error"],
              body[:240])

        print("== a tap")
        op = picks[0]
        choice = next((o for o in op["props"]["options"] if "tea" in o.lower()), op["props"]["options"][0])
        tap = say(f"[yui] {op['id']} {op['preset']} choice={choice}", "event",
                  {"id": op["id"], "preset": op["preset"], "value": {"choice": choice}, "echo": choice})
        rep = wait(lambda: replies_to(tap), 300, "answer to the tap")
        check(f"{k}: the tap ({choice}) goes back as the next turn and is answered once",
              len(rep) == 1 and rep[0]["body"].strip(), rep and rep[0]["body"][:240])
        if kind == "langgraph":
            check(f"{k}: the graph read the tap from its data part (yui_events in the state), not only the text",
                  rep and rep[0]["body"].startswith(f"{choice} it is. (read from the tap's data)"), rep and rep[0]["body"])
            v = lg_state(url, agent)
            g = v.get("yui_channel_guide") or {}
            online = (home / "bridge.log").read_text()
            gv = online.split("guide ", 1)[1].split()[0] if "guide " in online else "?"
            check(f"{k}: the thread is the Yui agent (contextId = thread_id) and its state holds the guide",
                  g.get("version") and str(g.get("version")) == gv and "choose" in g.get("body", ""),
                  f"guide {g.get('version')} ({len(g.get('body', ''))} chars), bridge guide {gv}")
            humans = [m for m in v.get("messages", []) if m.get("type") == "human"]
            check(f"{k}: the graph saw only the person's words as messages (the guide never became chat)",
                  len(humans) == 3 and not any(g.get("body") and g["body"] in str(m.get("content")) for m in humans)
                  and v.get("yui_events") == [], f"{[str(m.get('content'))[:40] for m in humans]}")

        if kind == "maf":
            back = say("Which drink did I just pick? One word.")
            rep = wait(lambda: replies_to(back), 300, "the recall")
            check(f"{k}: the next turn recalls the tap ({choice}): one session per contextId keeps the thread",
                  len(rep) == 1 and choice.lower() in rep[0]["body"].lower(), rep and rep[0]["body"][:240])

        print("== clean stop, totals")
        wait(lambda: all(m["handled_at"] for m in thread() if m["sender"] == "user"), 20, "all handled")
        proc[0].send_signal(signal.SIGTERM)
        proc[0].wait(20)
        check(f"{k}: a clean stop reads offline", presence() == "offline", presence())
        users = [m for m in thread() if m["sender"] == "user"]
        named = [i for m in thread() if m["sender"] == "agent" for i in (m.get("meta") or {}).get("turn") or []]
        check(f"{k}: every person's row handled and answered by exactly one reply",
              all(m["handled_at"] for m in users) and all(named.count(m["id"]) == 1 for m in users), f"{len(users)} rows")
        (home / "thread.json").write_text(json.dumps(thread(), indent=1))
    finally:
        if proc[0] and proc[0].poll() is None:
            proc[0].kill()
        os.killpg(agent_proc.pid, signal.SIGKILL)  # uv and the server it started
        if tok:
            s, _ = fn("yui-delete", {}, tok)
            left = sql(f"select count(*)::int n from yui_messages where user_id = '{T}'")[0]["n"] \
                + sql(f"select count(*)::int n from yui_users where id = '{T}'")[0]["n"]
            check(f"{k}: throwaway account deleted, nothing left", s == 200 and left == 0, f"{s} {left}")
        print(f"  bridge log: {home / 'bridge.log'}, {S['name']} log: {home / S['log']}, thread: {home / 'thread.json'}")


def phone_side(T, start, stop, thread, replies_to):
    print("== I. the phone (simulator)")
    out = Path(args.out)
    shots = out / "shots"
    shots.mkdir(parents=True, exist_ok=True)
    for f in shots.iterdir():
        f.unlink()
    rts = []
    for _ in range(2):  # one fresh session per launch: a replayed refresh token signs everyone out
        rt = secrets.token_urlsafe(32)
        sql(f"insert into yui_sessions(user_id, refresh_hash, expires_at) values "
            f"('{T}', '{hashlib.sha256(rt.encode()).hexdigest()}', now() + interval '1 day')")
        rts.append(rt)
    start()
    env = {**os.environ, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer",
           "TEST_RUNNER_YUI_RTS": ",".join(rts), "TEST_RUNNER_YUI_USER": T, "TEST_RUNNER_YUI_SHOTS": str(shots)}
    subprocess.run(["xcodegen", "generate", "--quiet"], cwd=REPO, env=env, check=True)
    ui = subprocess.run(["xcodebuild", "test", "-project", "Yui.xcodeproj", "-scheme", "Yui",
                         "-destination", f"id={args.sim}", "-derivedDataPath", "/tmp/int18-dd",
                         "-only-testing:YuiUITests/A2ATests"],
                        cwd=REPO, env=env, stdout=open(out / "xcodebuild.log", "w"), stderr=subprocess.STDOUT)
    stop()
    log_text = (out / "xcodebuild.log").read_text()
    check("1.0: A2ATests ran and passed in the simulator",
          ui.returncode == 0 and "Executed 1 test, with 0 failures" in log_text,
          f"xcodebuild exit {ui.returncode}, log {out / 'xcodebuild.log'}")
    phone = [m for m in thread() if m["sender"] == "user"]
    check("1.0: the phone's messages (and the tap) each got exactly one answer",
          len(phone) == 5 and all(len(replies_to(m["id"])) == 1 for m in phone),
          f"{[(m['body'][:24], len(replies_to(m['id']))) for m in phone]}")
    print(f"  screenshots: {shots}")


runs = ["1.0", "0.3", "poll"] if args.protocol == "all" else [args.protocol]
if args.sim and "phone" not in runs:
    runs.append("phone")
if "phone" in runs and not args.sim:
    sys.exit("--protocol phone needs --sim <udid>")
for p in runs:
    try:
        run_sdk(p) if p in SDK else run(p)
    except Exception as e:  # one run failing still runs the others
        check(f"{p}: ran to the end", False, repr(e))

print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)

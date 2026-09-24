#!/usr/bin/env python3
"""YUI-49 end to end: a 👍 on the agent's message reaches the agent as a turn,
and the agent builds what it proposed. Live against PROOF, on a throwaway account.

The host is the real `yui` platform adapter under Hermes' real
BasePlatformAdapter, in its own process. Its agent:
  - answers any plain message with one scripted proposal (so the thing to
    react to is always the same);
  - answers a react event with a real model: the `claude` CLI with the channel
    guide exactly as the plugin injects it (platform_hint()), no tools. So the
    reaction section of the guide is what tells it what 👍 means.

Without --sim the script plays the app over REST: it says hi, reacts 👍 to the
proposal, checks the event row, the badge column and the agent's reply.
With --sim the phone does it: YuiUITests/ReactionTests long-presses the
bubble, taps 👍, waits for the reply, reopens in dark and finds the badge
still there. Screenshots in --out.

    python3 supabase/tests/reactions_e2e.py [--out /tmp/yui49-proof] [--sim <udid>]

Needs the Hermes venv at ~/.hermes/hermes-agent, the `claude` CLI, and a
Supabase access token like the other supabase/tests. The account is deleted
at the end.
"""
import argparse, asyncio, hashlib, json, os, secrets, signal, subprocess, sys, tempfile, time, uuid
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
HERMES = Path.home() / ".hermes/hermes-agent"
PROPOSAL = "Want me to set up Saturday? Goblet squats 5x5 with the 50s, then a 20 minute tabata, done by 10."
PERSONA = ("You are Yui, a friendly assistant in the Yui app. You are on the Yui channel with the person. "
           "Today is Thursday. They have a home gym: dumbbells to 50 lb, a bench, bands, a pull-up bar.")

ap = argparse.ArgumentParser()
ap.add_argument("--out", default="/tmp/yui49-proof")
ap.add_argument("--sim", help="simulator udid: the phone reacts (YuiUITests/ReactionTests)")
ap.add_argument("--model", default="claude-opus-5-5")
ap.add_argument("--host", help=argparse.SUPPRESS)
args = ap.parse_args()


# -- child: the agent's host ----------------------------------------------------

def run_host(home: Path) -> None:
    os.environ["HERMES_HOME"] = str(home)
    os.environ["YUI_CONNECTOR_FILE"] = str(home / "connector.json")
    sys.path[:0] = [str(HERMES), str(REPO / "hermes-plugin")]
    import logging
    logging.basicConfig(filename=home / "host.log", level=logging.INFO,
                        format=f"%(asctime)s [{os.getpid()}] %(name)s %(message)s")
    from gateway.config import PlatformConfig
    from gateway.platform_registry import PlatformEntry, platform_registry
    from yui.adapter import YuiAdapter, platform_hint
    platform_registry.register(PlatformEntry(name="yui", label="Yui", adapter_factory=lambda cfg: YuiAdapter(cfg),
                                             check_fn=lambda: True))
    log = home / "agent.jsonl"

    def note(**kw):
        with open(log, "a") as f:
            f.write(json.dumps({"t": time.time(), **kw}, ensure_ascii=False) + "\n")

    def model(text: str) -> str:
        p = subprocess.run(["claude", "-p", "--model", args.model, "--append-system-prompt",
                            f"{PERSONA}\n\n{platform_hint()}", "--tools", "", "--setting-sources", "",
                            "--strict-mcp-config", "--disable-slash-commands", "--no-session-persistence",
                            "--output-format", "json"],
                           input=text, capture_output=True, text=True, cwd="/tmp", timeout=300,
                           env={**os.environ, "USER": os.environ.get("USER", "urzas")})
        return json.loads(p.stdout)["result"]

    async def agent(event):
        text = event.text
        note(ev="turn", text=text)
        if "[yui] react " not in text:
            return PROPOSAL
        reply = await asyncio.to_thread(model, text)
        note(ev="reply", text=reply)
        return reply

    async def main():
        adapter = YuiAdapter(PlatformConfig(enabled=True, extra={"remote_ref": "reactions-e2e"}))
        adapter.set_message_handler(agent)
        while not await adapter.connect():
            await asyncio.sleep(2)
        note(ev="up")
        stop = asyncio.Event()
        asyncio.get_running_loop().add_signal_handler(signal.SIGTERM, stop.set)
        await stop.wait()
        await adapter.disconnect()

    asyncio.run(main())


if args.host:
    run_host(Path(args.host))
    sys.exit(0)


# -- parent: the app and the judge -----------------------------------------------

exec(open(REPO / "supabase/tests/agents_test.py").read().split("results = []")[0])
OUT = Path(args.out)
OUT.mkdir(parents=True, exist_ok=True)
HOME = Path(tempfile.mkdtemp(prefix="yui-reactions-e2e-"))
os.environ["YUI_CONNECTOR_FILE"] = str(HOME / "connector.json")
import importlib.util  # noqa: E402
_spec = importlib.util.spec_from_file_location("yui_connector", REPO / "hermes-plugin/yui/connector.py")
connector = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(connector)


def screen_presets(body: str) -> list:
    """Line heads inside ```yui fences (`timer@hiit 20/10x8` -> timer)."""
    out, inside = [], False
    for line in body.splitlines():
        t = line.strip()
        if t == "```yui":
            inside = True
        elif t == "```":
            inside = False
        elif inside and t:
            out.append(t.split()[0].lstrip("~>").split("@")[0])
    return out

results = []
def check(name, ok, detail=""):
    ok = bool(ok); results.append(ok); print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  [{detail}]" if detail else ""), flush=True)
def log(msg): print(f"  .. {msg}", flush=True)

T = str(uuid.uuid4())
sql(f"insert into yui_users(id, apple_sub) values ('{T}','test.{T}')")
tok = mint(T, ttl=3600)
host = None


def events():
    try:
        return [json.loads(l) for l in (HOME / "agent.jsonl").read_text().splitlines() if l.strip()]
    except FileNotFoundError:
        return []


def wait(cond, secs, what):
    end = time.time() + secs
    while time.time() < end:
        if cond():
            return True
        time.sleep(1)
    raise TimeoutError(what)


def thread():
    s, r = rest("GET", f"yui_messages?select=id,sender,kind,body,meta,reaction,created_at,handled_at"
                       f"&agent_id=eq.{agent}&order=created_at.asc,id.asc", tok)
    assert s == 200, (s, r)
    return r


def proposal():
    return next((m for m in thread() if m["sender"] == "agent" and m["body"] == PROPOSAL), None)


def react_rows():
    return [m for m in thread() if m["sender"] == "user" and m["kind"] == "event" and "react" in (m["meta"] or {})]


def answer_after_react():
    rows = thread()
    last = max((i for i, m in enumerate(rows) if m["kind"] == "event"), default=None)
    return next((m for m in rows[last + 1:] if m["sender"] == "agent"), None) if last is not None else None


def fresh_rt():
    rt = secrets.token_urlsafe(32)
    sql(f"insert into yui_sessions(user_id, refresh_hash, expires_at) values "
        f"('{T}', '{hashlib.sha256(rt.encode()).hexdigest()}', now() + interval '1 day')")
    return rt


def phone():
    shots = OUT / "shots"
    shots.mkdir(exist_ok=True)
    for f in shots.iterdir():
        f.unlink()
    env = {**os.environ, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer",
           "TEST_RUNNER_YUI_RTS": ",".join(fresh_rt() for _ in range(2)), "TEST_RUNNER_YUI_USER": T,
           "TEST_RUNNER_YUI_SHOTS": str(shots)}
    subprocess.run(["xcodegen", "generate", "--quiet"], cwd=REPO, env=env, check=True)
    ui = subprocess.Popen(["xcodebuild", "test", "-project", "Yui.xcodeproj", "-scheme", "Yui",
                           "-destination", f"id={args.sim}", "-derivedDataPath", "/tmp/yui49-dd",
                           "-only-testing:YuiUITests/ReactionTests"],
                          cwd=REPO, env=env, stdout=open(OUT / "xcodebuild.log", "w"), stderr=subprocess.STDOUT)
    while ui.poll() is None:
        if (shots / "need-reply").exists() and not (shots / "reply-ok").exists() and answer_after_react():
            (shots / "reply-ok").touch()
        time.sleep(1)
    text = (OUT / "xcodebuild.log").read_text()
    check("ReactionTests ran and passed in the simulator",
          ui.returncode == 0 and "Executed 1 test, with 0 failures" in text,
          f"xcodebuild exit {ui.returncode}, log {OUT / 'xcodebuild.log'}")


try:
    s, r = fn("yui-agents", {"action": "create", "name": "Yui", "pair": True}, tok)
    agent = r["agent"]["id"]
    s2, p = connector.pair(r["pairing"]["code"], "reactions-e2e", "Reactions test host")
    check("throwaway account, agent and host paired", (s, s2) == (200, 200), f"{s} {s2}")
    host = subprocess.Popen([str(HERMES / "venv/bin/python"), __file__, "--host", str(HOME), "--model", args.model],
                            stdout=open(HOME / "host.out", "a"), stderr=subprocess.STDOUT)
    wait(lambda: any(e["ev"] == "up" for e in events()), 60, "host up")
    log(f"host up, pid {host.pid}")

    if args.sim:
        print("== the phone asks, holds the answer, taps 👍 (simulator)")
        phone()
    else:
        print("== the app (REST) asks, then reacts 👍")
        s, r = rest("POST", "yui_messages", tok, {"user_id": T, "agent_id": agent, "sender": "user",
                                                  "body": "Saturday workout?", "kind": "text"})
        wait(lambda: proposal(), 90, "proposal")
        pid = proposal()["id"]
        # Exactly what the app sends (Reactions.swift, Reaction.body/meta).
        body = f'[yui] react msg={pid} emoji=👍 meaning="build it"\n> {PROPOSAL}'
        s, r = rest("POST", "yui_messages", tok, {"user_id": T, "agent_id": agent, "sender": "user", "kind": "event",
                                                  "body": body, "meta": {"react": {"msg": pid, "emoji": "👍"}}})
        check("the reaction is written", s == 201, f"{s} {r}")
        wait(lambda: answer_after_react(), 300, "agent's answer to the reaction")

    p = proposal()
    check("the proposal carries 👍 on the server", p and p["reaction"] == "👍", f"{p and p['reaction']}")
    rr = react_rows()
    check("one react event, with the quote", len(rr) == 1 and rr[0]["body"].startswith(f"[yui] react msg={p['id']} emoji=👍")
          and 'meaning="build it"' in rr[0]["body"] and "> Want me to set up Saturday?" in rr[0]["body"],
          f"{[x['body'] for x in rr]}")
    turns = [e["text"] for e in events() if e["ev"] == "turn" and "[yui] react" in e["text"]]
    check("the agent got the react event as its turn, quote included",
          len(turns) == 1 and "emoji=👍" in turns[0] and "> Want me to set up Saturday?" in turns[0], f"{turns}")
    a = answer_after_react()
    presets = screen_presets(a["body"]) if a else []
    check("the agent acted on 👍: it built the plan (a screen with a list, timer, card or plan)",
          a and any(x in presets for x in ("list", "timer", "card", "plan")), f"presets={presets}")
    confirm = a and any(w in a["body"].lower() for w in ("want me to", "should i", "shall i", "ready to"))
    check("and did not ask to confirm first", a and not confirm, (a or {}).get("body", "")[:200])
    check("the react row is handled", all(m["handled_at"] for m in react_rows()))
    (OUT / "agent-reply.txt").write_text((a or {}).get("body", ""))
    (OUT / "react-turn.txt").write_text(turns[0] if turns else "")
finally:
    if host and host.poll() is None:
        host.send_signal(signal.SIGTERM)
        try:
            host.wait(20)
        except Exception:
            host.kill()
    sql(f"delete from yui_users where id = '{T}'")
    left = sql(f"select (select count(*) from yui_messages where user_id='{T}') + "
               f"(select count(*) from yui_agents where user_id='{T}') as n")[0]["n"]
    check("test account deleted, zero rows left", left == 0, f"{left}")

print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)

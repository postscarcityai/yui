#!/usr/bin/env python3
"""YUI-44 end to end: @mention another agent, with two real hosts on this Mac.

A throwaway account gets three agents. Alpha and Bravo are each served by the
real `yui` platform adapter under Hermes' real BasePlatformAdapter, in their
own processes with their own connector (two gateways, two agents). Cleo is
paired, then stopped: offline. The agents are scripted so the checks are exact:
  - Alpha answers "Alpha here." (or "Asking @bravo about it." when asked to ask).
  - Bravo answers "Box squats instead of back squats, easier on the knee.
    @alpha over to you." The @alpha is the loop probe: it must start nothing.

Without --sim the script plays the app over REST. With --sim the phone does
the first part: YuiUITests/MentionTests types @, filters, picks Bravo, sends,
waits for Bravo's answer in Alpha's thread, mentions Cleo (offline line), then
reopens in dark and follows the link into Bravo's thread. Either way the script
then checks the rows, that Alpha was never asked, that Alpha's next turn reads
what Bravo said as context, that Alpha's own @bravo (in a turn the person
started) reaches Bravo, and that Bravo's @alpha never loops back.

    python3 supabase/tests/mention_e2e.py [--out /tmp/yui44-proof] [--sim <udid>]

Needs the Hermes venv at ~/.hermes/hermes-agent and a Supabase access token
like the other supabase/tests. The account is deleted at the end.
"""
import argparse, asyncio, hashlib, json, os, secrets, signal, subprocess, sys, tempfile, time, uuid
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
HERMES = Path.home() / ".hermes/hermes-agent"
BRAVO = "Box squats instead of back squats, easier on the knee. @alpha over to you."

ap = argparse.ArgumentParser()
ap.add_argument("--out", default="/tmp/yui44-proof")
ap.add_argument("--sim", help="simulator udid: the phone mentions (YuiUITests/MentionTests)")
ap.add_argument("--host", help=argparse.SUPPRESS)
ap.add_argument("--name", help=argparse.SUPPRESS)
args = ap.parse_args()


# -- child: one agent's host ------------------------------------------------------

def run_host(home: Path, name: str) -> None:
    os.environ["HERMES_HOME"] = str(home)
    os.environ["YUI_CONNECTOR_FILE"] = str(home / "connector.json")
    sys.path[:0] = [str(HERMES), str(REPO / "hermes-plugin")]
    import logging
    logging.basicConfig(filename=home / "host.log", level=logging.INFO,
                        format=f"%(asctime)s [{os.getpid()}] %(name)s %(message)s")
    from gateway.config import PlatformConfig
    from gateway.platform_registry import PlatformEntry, platform_registry
    from yui.adapter import YuiAdapter
    platform_registry.register(PlatformEntry(name="yui", label="Yui", adapter_factory=lambda cfg: YuiAdapter(cfg),
                                             check_fn=lambda: True))
    log = home / "agent.jsonl"

    def note(**kw):
        with open(log, "a") as f:
            f.write(json.dumps({"t": time.time(), **kw}, ensure_ascii=False) + "\n")

    async def agent(event):
        note(ev="turn", text=event.text)
        if name == "bravo":
            return BRAVO
        return "Asking @bravo about it." if "ask bravo" in event.text.lower() else "Alpha here."

    async def main():
        adapter = YuiAdapter(PlatformConfig(enabled=True, extra={"remote_ref": name}))
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
    run_host(Path(args.host), args.name)
    sys.exit(0)


# -- parent: the app and the judge -------------------------------------------------

exec(open(REPO / "supabase/tests/agents_test.py").read().split("results = []")[0])
OUT = Path(args.out)
OUT.mkdir(parents=True, exist_ok=True)

results = []
def check(name, ok, detail=""):
    ok = bool(ok); results.append(ok); print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  [{detail}]" if detail else ""), flush=True)
def log(msg): print(f"  .. {msg}", flush=True)

T = str(uuid.uuid4())
sql(f"insert into yui_users(id, apple_sub) values ('{T}','test.{T}')")
tok = mint(T, ttl=3600)
hosts, homes, ids, cts = {}, {}, {}, {}


def events(name):
    try:
        return [json.loads(l) for l in (homes[name] / "agent.jsonl").read_text().splitlines() if l.strip()]
    except FileNotFoundError:
        return []


def turns(name):
    return [e["text"] for e in events(name) if e["ev"] == "turn"]


def wait(cond, secs, what):
    end = time.time() + secs
    while time.time() < end:
        if cond():
            return True
        time.sleep(1)
    raise TimeoutError(what)


def thread(name):
    s, r = rest("GET", f"yui_messages?select=id,sender,kind,body,meta,created_at,delivered_at,handled_at"
                       f"&agent_id=eq.{ids[name]}&order=created_at.asc,id.asc", tok)
    assert s == 200, (s, r)
    return r


def mirrors(name="alpha", status=False):
    return [m for m in thread(name) if "mention_reply" in (m["meta"] or {})
            and bool(m["meta"]["mention_reply"].get("status")) == status]


def arrived(name="bravo", by=None):
    return [m for m in thread(name) if "mentioned" in (m["meta"] or {})
            and (by is None or m["meta"]["mentioned"]["by"] == by)]


def fresh_rt():
    rt = secrets.token_urlsafe(32)
    sql(f"insert into yui_sessions(user_id, refresh_hash, expires_at) values "
        f"('{T}', '{hashlib.sha256(rt.encode()).hexdigest()}', now() + interval '1 day')")
    return rt


def say(name, body, meta=None):
    row = {"id": str(uuid.uuid4()), "user_id": T, "agent_id": ids[name], "sender": "user", "body": body, "kind": "text"}
    if meta:
        row["meta"] = meta
    s, r = rest("POST", "yui_messages", tok, row)
    assert s == 201, (s, r)
    return row["id"]


def mention(name, words):
    """Exactly what the app sends (Mentions.swift, body/meta)."""
    return say("alpha", f"[yui] mention to={name}\n{words}",
               {"mention": {"to": ids[name], "handle": name, "name": name.title()}})


def phone():
    shots = OUT / "shots"
    shots.mkdir(exist_ok=True)
    for f in shots.iterdir():
        f.unlink()
    env = {**os.environ, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer",
           "TEST_RUNNER_YUI_RTS": ",".join(fresh_rt() for _ in range(2)), "TEST_RUNNER_YUI_USER": T,
           "TEST_RUNNER_YUI_SHOTS": str(shots)}
    subprocess.run(["xcodegen", "generate", "--quiet"], cwd=REPO, env=env, check=True)
    ui = subprocess.run(["xcodebuild", "test", "-project", "Yui.xcodeproj", "-scheme", "Yui",
                         "-destination", f"id={args.sim}", "-derivedDataPath", "/tmp/yui44-dd",
                         "-only-testing:YuiUITests/MentionTests"],
                        cwd=REPO, env=env, stdout=open(OUT / "xcodebuild.log", "w"), stderr=subprocess.STDOUT)
    text = (OUT / "xcodebuild.log").read_text()
    check("MentionTests ran and passed in the simulator",
          ui.returncode == 0 and "Executed 1 test, with 0 failures" in text,
          f"xcodebuild exit {ui.returncode}, log {OUT / 'xcodebuild.log'}")


try:
    for name in ("alpha", "bravo", "cleo"):
        s, r = fn("yui-agents", {"action": "create", "name": name.title(), "pair": True}, tok)
        ids[name] = r["agent"]["id"]
        s2, p = fn("yui-connect", {"action": "pair", "code": r["pairing"]["code"], "remote_ref": name,
                                   "host_name": f"Mention test host {name}", "kind": "hermes"})
        assert (s, s2) == (200, 200), (s, r, s2, p)
        cts[name] = p["connector_token"]
        homes[name] = Path(tempfile.mkdtemp(prefix=f"yui-mention-e2e-{name}-"))
        (homes[name] / "connector.json").write_text(json.dumps(
            {"token": p["connector_token"], "connector_id": p["connector"]["id"], "name": p["connector"]["name"]}))
    fn("yui-connect", {"action": "bye"}, cts["cleo"])
    check("throwaway account, three agents on three connectors", len(ids) == 3)
    for name in ("alpha", "bravo"):
        hosts[name] = subprocess.Popen([str(HERMES / "venv/bin/python"), __file__, "--host", str(homes[name]),
                                        "--name", name], stdout=open(homes[name] / "host.out", "a"),
                                       stderr=subprocess.STDOUT)
    wait(lambda: all(any(e["ev"] == "up" for e in events(n)) for n in ("alpha", "bravo")), 90, "hosts up")
    log(f"hosts up: alpha {hosts['alpha'].pid}, bravo {hosts['bravo'].pid}")
    say("alpha", "Plan a leg day for Saturday")
    wait(lambda: any(m["sender"] == "agent" for m in thread("alpha")), 60, "alpha's first answer")

    if args.sim:
        print("== the phone mentions Bravo, then Cleo (simulator)")
        phone()
    else:
        print("== the app (REST) mentions Bravo, then Cleo")
        mention("bravo", "@Bravo does this fit my knee?")
        wait(lambda: mirrors(), 60, "bravo's answer in alpha's thread")
        mention("cleo", "@Cleo you there?")
        wait(lambda: mirrors(status=True), 30, "cleo's status line")

    src = [m for m in thread("alpha") if "mention" in (m["meta"] or {}) and m["meta"]["mention"]["handle"] == "bravo"]
    check("one mention row in alpha's thread, handled on arrival",
          len(src) == 1 and src[0]["handled_at"] and src[0]["body"].startswith("[yui] mention to=bravo\n"), f"{src}")
    check("alpha was never asked", not any("does this fit my knee" in t for t in turns("alpha")), f"{turns('alpha')}")
    got = arrived(by="person")
    check("bravo got it as a turn, with alpha's thread quoted",
          len(got) == 1 and any("does this fit my knee?" in t and "> Person: Plan a leg day for Saturday" in t
                                and "> Alpha: Alpha here." in t for t in turns("bravo")), f"{turns('bravo')}")
    m = mirrors()
    check("bravo's answer is in alpha's thread, in bravo's name",
          len(m) == 1 and m[0]["body"] == BRAVO and m[0]["meta"]["mention_reply"]["name"] == "Bravo"
          and m[0]["meta"]["mention_reply"]["to"] == src[0]["id"], f"{m}")
    st = mirrors(status=True)
    check("cleo (offline) says so in one line", len(st) == 1 and st[0]["body"] == "Cleo is offline. It gets this when it's back.",
          f"{[x['body'] for x in st]}")
    time.sleep(5)
    check("bravo's @alpha started nothing (depth 1)", arrived("alpha") == [] and len(mirrors()) == 1)

    print("== alpha reads what happened as context on its next turn")
    n = len(turns("alpha"))
    say("alpha", "Thanks. What did Bravo say?")
    wait(lambda: len(turns("alpha")) > n, 60, "alpha's next turn")
    t = turns("alpha")[-1]
    check("alpha's next turn starts with the notes",
          "[yui] note: in this thread the person asked Bravo, not you: @Bravo does this fit my knee?" in t
          and f"[yui] note: Bravo answered here: {BRAVO}" in t and "Cleo is offline" not in t, t)

    print("== alpha asks bravo itself, in a turn the person started")
    nb = len(turns("bravo"))
    say("alpha", "Please ask bravo about Sunday too")
    wait(lambda: arrived(by="agent"), 60, "alpha's @bravo reaching bravo")
    a = arrived(by="agent")
    check("alpha's reply carried @bravo, and bravo got it", len(a) == 1 and a[0]["body"].rstrip().endswith("Asking @bravo about it.")
          and a[0]["meta"]["mentioned"]["from"] == ids["alpha"], f"{a}")
    wait(lambda: len(mirrors()) == 2, 60, "bravo's second answer back in alpha's thread")
    time.sleep(5)
    check("bravo answered once more, and it came back once", len(turns("bravo")) == nb + 1 and len(mirrors()) == 2,
          f"{len(turns('bravo'))} turns, {len(mirrors())} mirrors")
    check("no loop: nothing ever reached alpha as a mention", arrived("alpha") == [])
    (OUT / "bravo-turn.txt").write_text(next((x for x in turns("bravo") if "does this fit" in x), ""))
    (OUT / "alpha-context-turn.txt").write_text(t)
finally:
    for h in hosts.values():
        if h.poll() is None:
            h.send_signal(signal.SIGTERM)
            try:
                h.wait(20)
            except Exception:
                h.kill()
    sql(f"delete from yui_users where id = '{T}'")
    left = sql(f"select (select count(*) from yui_messages where user_id='{T}') + "
               f"(select count(*) from yui_agents where user_id='{T}') as n")[0]["n"]
    check("test account deleted, zero rows left", left == 0, f"{left}")

print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)

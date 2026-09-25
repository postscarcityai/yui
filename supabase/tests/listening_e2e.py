#!/usr/bin/env python3
"""YUI-64 end to end: an agent that is paired but not listening says so.

Live against PROOF, on a throwaway account. One computer (one connector
token), two agents, the way `hermes -p <profile> yui pair` leaves them:

  Alpha  its gateway runs: the real `yui` platform adapter under Hermes'
         BasePlatformAdapter, in its own process, with a scripted agent that
         echoes every line.
  Bravo  paired from the same computer, its gateway never started.

Checks: Alpha reads online and Bravo not_listening (the computer is up, so
per-computer presence would have said online); a message to Bravo waits,
undelivered; Bravo's gateway starts and the message that waited is answered
(plugin 834a2a0); Bravo reads online. With --sim the phone does the same in
YuiUITests/ListeningTests (light, then dark), screenshots in --out.

    python3 supabase/tests/listening_e2e.py [--out /tmp/yui64-proof] [--sim <udid>]

Needs the Hermes venv at ~/.hermes/hermes-agent and a Supabase access token
like the other supabase/tests. The account is deleted at the end.
"""
import argparse, asyncio, hashlib, json, os, secrets, signal, subprocess, sys, tempfile, time, uuid
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
HERMES = Path.home() / ".hermes/hermes-agent"

ap = argparse.ArgumentParser()
ap.add_argument("--out", default="/tmp/yui64-proof")
ap.add_argument("--sim", help="simulator udid: also run YuiUITests/ListeningTests (phone side)")
ap.add_argument("--host", help=argparse.SUPPRESS)  # child mode: run a gateway for one profile
ap.add_argument("--ref", help=argparse.SUPPRESS)
args = ap.parse_args()


# -- child: one profile's gateway -------------------------------------------------

def run_host(home: Path, ref: str) -> None:
    # Its own Hermes home (cursor, outbox), the computer's shared connector token.
    os.environ["HERMES_HOME"] = str(home / ref)
    os.environ["YUI_CONNECTOR_FILE"] = str(home / "connector.json")
    sys.path[:0] = [str(HERMES), str(REPO / "hermes-plugin")]
    import logging
    logging.basicConfig(filename=home / f"host-{ref}.log", level=logging.INFO,
                        format=f"%(asctime)s [{ref}] %(name)s %(message)s")
    from gateway.config import PlatformConfig
    from gateway.platform_registry import PlatformEntry, platform_registry
    from yui.adapter import YuiAdapter
    platform_registry.register(PlatformEntry(name="yui", label="Yui", adapter_factory=lambda cfg: YuiAdapter(cfg),
                                             check_fn=lambda: True))
    up = home / f"up-{ref}"

    async def agent(event):
        await asyncio.sleep(1)
        return "\n".join(f"echo: {l}" for l in event.text.split("\n") if l.strip())

    async def main():
        adapter = YuiAdapter(PlatformConfig(enabled=True, extra={"remote_ref": ref}))
        adapter.set_message_handler(agent)
        while not await adapter.connect():
            await asyncio.sleep(2)
        up.touch()
        stop = asyncio.Event()
        asyncio.get_running_loop().add_signal_handler(signal.SIGTERM, stop.set)
        await stop.wait()
        await adapter.disconnect()

    asyncio.run(main())


if args.host:
    run_host(Path(args.host), args.ref)
    sys.exit(0)


# -- parent: the app, the computer and the judge -----------------------------------

exec(open(REPO / "supabase/tests/agents_test.py").read().split("results = []")[0])
OUT = Path(args.out)
OUT.mkdir(parents=True, exist_ok=True)
HOME = Path(tempfile.mkdtemp(prefix="yui-listening-e2e-"))
os.environ["YUI_CONNECTOR_FILE"] = str(HOME / "connector.json")
import importlib.util  # noqa: E402
_spec = importlib.util.spec_from_file_location("yui_connector", REPO / "hermes-plugin/yui/connector.py")
connector = importlib.util.module_from_spec(_spec)  # stdlib only: the CLI side of `yui pair`
_spec.loader.exec_module(connector)

results = []
def check(name, ok, detail=""):
    ok = bool(ok); results.append(ok); print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  [{detail}]" if detail else ""), flush=True)
def log(msg): print(f"  .. {msg}", flush=True)

T = str(uuid.uuid4())
sql(f"insert into yui_users(id, apple_sub) values ('{T}','test.{T}')")
tok = mint(T, ttl=3600)
hosts = {}


def wait(cond, secs, what):
    end = time.time() + secs
    while time.time() < end:
        if cond():
            return True
        time.sleep(0.5)
    raise TimeoutError(what)


def start_host(ref):
    hosts[ref] = subprocess.Popen([str(HERMES / "venv/bin/python"), __file__, "--host", str(HOME), "--ref", ref],
                                  stdout=open(HOME / f"host-{ref}.out", "a"), stderr=subprocess.STDOUT)
    wait(lambda: (HOME / f"up-{ref}").exists(), 60, f"{ref} gateway up")
    log(f"{ref} gateway up, pid {hosts[ref].pid}")


def presence(aid):
    s, r = rest("GET", f"yui_agent_list?select=presence,status&id=eq.{aid}", tok)
    return r[0] if s == 200 and r else {"error": (s, r)}


def thread(aid):
    s, r = rest("GET", f"yui_messages?select=id,sender,body,delivered_at,handled_at"
                       f"&agent_id=eq.{aid}&order=created_at.asc,id.asc", tok)
    assert s == 200, (s, r)
    return r


def pair(name, ref):
    s, r = fn("yui-agents", {"action": "create", "name": name, "pair": True}, tok)
    aid = r["agent"]["id"]
    s2, p = connector.pair(r["pairing"]["code"], ref, "Test Mac")
    return aid, s2, p


def phone_side():
    print("== The phone (simulator)")
    shots = OUT / "shots"
    shots.mkdir(exist_ok=True)
    for f in shots.iterdir():
        f.unlink()
    rts = []
    for _ in range(2):  # one fresh session per launch
        rt = secrets.token_urlsafe(32)
        sql(f"insert into yui_sessions(user_id, refresh_hash, expires_at) values "
            f"('{T}', '{hashlib.sha256(rt.encode()).hexdigest()}', now() + interval '1 day')")
        rts.append(rt)
    env = {**os.environ, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer",
           "TEST_RUNNER_YUI_RTS": ",".join(rts), "TEST_RUNNER_YUI_USER": T, "TEST_RUNNER_YUI_SHOTS": str(shots)}
    subprocess.run(["xcodegen", "generate", "--quiet"], cwd=REPO, env=env, check=True)
    ui = subprocess.Popen(["xcodebuild", "test", "-project", "Yui.xcodeproj", "-scheme", "Yui",
                           "-destination", f"id={args.sim}", "-derivedDataPath", "/tmp/yui64-dd",
                           "-only-testing:YuiUITests/ListeningTests"],
                          cwd=REPO, env=env, stdout=open(OUT / "xcodebuild.log", "w"), stderr=subprocess.STDOUT)
    before = None
    while ui.poll() is None:
        if (shots / "need-wake").exists() and not (shots / "wake-ok").exists():
            before = [m for m in thread(bravo) if m["sender"] == "user"]
            start_host("bravo")
            (shots / "wake-ok").touch()
        time.sleep(1)
    log_text = (OUT / "xcodebuild.log").read_text()
    check("ListeningTests ran and passed in the simulator",
          ui.returncode == 0 and "Executed 1 test, with 0 failures" in log_text,
          f"xcodebuild exit {ui.returncode}, log {OUT / 'xcodebuild.log'}")
    check("the phone's message waited on the server, undelivered, until the gateway started",
          before is not None and [m["body"] for m in before] == ["hi Bravo, are you there?"]
          and all(m["delivered_at"] is None for m in before), f"{before}")
    wait(lambda: any(m["body"] == "echo: hi Bravo, are you there?" for m in thread(bravo)), 60, "bravo echo")
    check("then it was answered once", [m["body"] for m in thread(bravo) if m["sender"] == "agent"]
          == ["echo: hi Bravo, are you there?"], f"{thread(bravo)}")


try:
    alpha, s1, p1 = pair("Alpha", "alpha")
    check("Alpha paired from the CLI: not listening yet", s1 == 200 and p1["agent"]["presence"] == "not_listening",
          f"{s1} {p1.get('agent', {}).get('presence')}")
    start_host("alpha")
    check("Alpha's gateway runs: online", presence(alpha)["presence"] == "online", f"{presence(alpha)}")
    bravo, s2, p2 = pair("Bravo", "bravo")
    check("Bravo paired on the same computer, same connector token",
          s2 == 200 and p2["connector_token"] is None and p2["connector"]["id"] == p1["connector"]["id"], f"{s2}")
    time.sleep(50)  # Alpha's gateway heartbeats (45 s) in between: the computer is up
    pa, pb = presence(alpha), presence(bravo)
    check("Alpha online, Bravo not listening yet (its gateway never started)",
          pa["presence"] == "online" and pb["presence"] == "not_listening", f"{pa} {pb}")
    check("older apps still read the computer's status", pb["status"] == "connected", f"{pb}")
    (OUT / "presence.json").write_text(json.dumps({"alpha": pa, "bravo": pb}, indent=2))
    s, r = fn("yui-agents", {"action": "list"}, tok)
    got = {a["name"]: a["presence"] for a in r["agents"]}
    check("the app's agent list says the same", got == {"Alpha": "online", "Bravo": "not_listening"}, f"{got}")

    if args.sim:
        phone_side()
    else:
        s, r = rest("POST", "yui_messages", tok, {"id": str(uuid.uuid4()), "user_id": T, "agent_id": bravo,
                                                  "sender": "user", "body": "hi Bravo, are you there?", "kind": "text"})
        time.sleep(5)
        waiting = [m for m in thread(bravo) if m["sender"] == "user"]
        check("a message to Bravo waits, undelivered", s == 201 and all(m["delivered_at"] is None for m in waiting),
              f"{s} {waiting}")
        start_host("bravo")
        wait(lambda: any(m["body"] == "echo: hi Bravo, are you there?" for m in thread(bravo)), 60, "bravo echo")
        check("Bravo's gateway starts: the message that waited is answered", True)
    check("Bravo online once its gateway runs", presence(bravo)["presence"] == "online", f"{presence(bravo)}")

    hosts["bravo"].send_signal(signal.SIGTERM); hosts["bravo"].wait(30)
    pa, pb = presence(alpha), presence(bravo)
    check("Bravo's gateway stops cleanly: Bravo offline, Alpha stays online",
          pa["presence"] == "online" and pb["presence"] == "offline", f"{pa} {pb}")
    hosts["alpha"].send_signal(signal.SIGTERM); hosts["alpha"].wait(30)
    pa = presence(alpha)
    check("the last gateway stops: the computer reads offline", pa["presence"] == "offline"
          and pa["status"] == "offline", f"{pa}")
except Exception as e:
    check("scenario ran to the end", False, repr(e))
finally:
    for h in hosts.values():
        if h.poll() is None:
            h.kill()
    for f in HOME.glob("host-*.log"):
        (OUT / f.name).write_text(f.read_text())
    s, r = fn("yui-delete", {}, tok)
    left = sql(f"select (select count(*) from yui_messages where user_id='{T}') + "
               f"(select count(*) from yui_connectors where user_id='{T}') as n")[0]["n"]
    check("throwaway account deleted, zero rows left", s == 200 and left == 0, f"{s} {left}")
    import shutil
    shutil.rmtree(HOME, ignore_errors=True)

print(f"\n{sum(results)}/{len(results)} passed  (proof in {OUT})")
sys.exit(0 if all(results) else 1)

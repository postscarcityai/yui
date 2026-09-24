#!/usr/bin/env python3
"""YUI-28 end to end: no message is lost or doubled when the agent's host dies,
sleeps or loses its network. Live against PROOF, on a throwaway account.

The host is the real `yui` platform adapter under Hermes' real
BasePlatformAdapter (turn lifecycle, hooks, send), in its own process, with a
scripted agent that thinks for a few seconds and echoes every line it gets.
The script plays the app (yui_user token) and does this to the host:

  A. normal turn: m1 gets its echo.
  B. kill -9 while the agent is thinking about m2. m3 and m4 are sent while the
     host is dead; they wait on the server, not delivered. Restart: m2 is
     replayed (its turn never finished), then m3 and m4, in order.
  C. the host's network drops while the agent answers m5: the reply goes to the
     outbox file. kill -9 with the reply only on disk. Restart able to read but
     still unable to write: m5 is not replayed (the outbox shows it was
     answered). Network back: the reply goes out once.
  D. honest status: a clean stop says goodbye (offline at once); a host that
     went quiet without one reads asleep with its last-seen time; restart reads
     online. m6 then gets its echo.

Pass: every message's echo appears exactly once, in order, every row is marked
handled, and the agent finished each message exactly once.

  E. with --sim: the phone side, YuiUITests/OfflineTests on a simulator. The
     phone's network drops, two messages wait on the phone, the app is killed,
     relaunched, the network returns: each lands once, in order, and is
     answered. Then the host goes quiet: the app says asleep (light and dark),
     a message waits, the host wakes and answers it. Screenshots in --out.

    python3 supabase/tests/offline_e2e.py [--out /tmp/yui28-proof] [--sim <udid>]

Needs the Hermes venv at ~/.hermes/hermes-agent (the host imports the gateway)
and a Supabase access token like the other supabase/tests. The account is
deleted at the end.
"""
import argparse, asyncio, hashlib, json, os, secrets, signal, subprocess, sys, tempfile, time, uuid
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
HERMES = Path.home() / ".hermes/hermes-agent"
THINK = 4.0  # seconds the scripted agent takes per turn

ap = argparse.ArgumentParser()
ap.add_argument("--out", default="/tmp/yui28-proof")
ap.add_argument("--sim", help="simulator udid: also run YuiUITests/OfflineTests (phone side)")
ap.add_argument("--host", help=argparse.SUPPRESS)  # child mode: run the host in this dir
args = ap.parse_args()


# -- child: the agent's host ----------------------------------------------------

def run_host(home: Path) -> None:
    os.environ["HERMES_HOME"] = str(home)
    os.environ["YUI_CONNECTOR_FILE"] = str(home / "connector.json")
    sys.path[:0] = [str(HERMES), str(REPO / "hermes-plugin")]
    import logging
    logging.basicConfig(filename=home / "host.log", level=logging.INFO,
                        format=f"%(asctime)s [{os.getpid()}] %(name)s %(message)s")
    import httpx
    from gateway.config import PlatformConfig
    from gateway.platform_registry import PlatformEntry, platform_registry
    from yui.adapter import YuiAdapter
    # What the plugin loader does for a profile that has the plugin enabled.
    platform_registry.register(PlatformEntry(name="yui", label="Yui", adapter_factory=lambda cfg: YuiAdapter(cfg),
                                             check_fn=lambda: True))

    offline_flag = home / "offline"
    outbound_flag = home / "outbound-down"
    agent_log = home / "agent.jsonl"

    def note(**kw):
        with open(agent_log, "a") as f:
            f.write(json.dumps({"pid": os.getpid(), "t": time.time(), **kw}) + "\n")

    async def agent(event):
        lines = [l for l in event.text.split("\n") if l.strip()]
        note(ev="start", lines=lines)
        await asyncio.sleep(THINK)
        note(ev="done", lines=lines)
        return "\n".join(f"echo: {l}" for l in lines)

    async def offline_hook(request):
        # The Mac's network is down: every call to Yui fails before it leaves.
        # `outbound-down`: only reply inserts fail (reads still work).
        if offline_flag.exists() or (outbound_flag.exists() and request.method == "POST"
                                     and request.url.path.endswith("/rest/v1/yui_messages")):
            raise httpx.ConnectError("network down (test)", request=request)

    async def main():
        adapter = YuiAdapter(PlatformConfig(enabled=True, extra={"remote_ref": "offline-e2e"}))
        adapter.set_message_handler(agent)
        while not await adapter.connect():
            await asyncio.sleep(2)
        adapter._client.event_hooks["request"].append(offline_hook)
        note(ev="up")
        stop = asyncio.Event()
        loop = asyncio.get_running_loop()
        loop.add_signal_handler(signal.SIGTERM, stop.set)
        await stop.wait()
        await adapter.disconnect()  # the clean stop: says goodbye
        note(ev="stopped")

    asyncio.run(main())


if args.host:
    run_host(Path(args.host))
    sys.exit(0)


# -- parent: the app, the clock and the judge ------------------------------------

exec(open(REPO / "supabase/tests/agents_test.py").read().split("results = []")[0])
OUT = Path(args.out)
OUT.mkdir(parents=True, exist_ok=True)
HOME = Path(tempfile.mkdtemp(prefix="yui-offline-e2e-"))
os.environ["YUI_CONNECTOR_FILE"] = str(HOME / "connector.json")
import importlib.util  # noqa: E402
_spec = importlib.util.spec_from_file_location("yui_connector", REPO / "hermes-plugin/yui/connector.py")
connector = importlib.util.module_from_spec(_spec)  # stdlib only: no Hermes needed in this process
_spec.loader.exec_module(connector)

results = []
def check(name, ok, detail=""):
    ok = bool(ok); results.append(ok); print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  [{detail}]" if detail else ""), flush=True)
def log(msg): print(f"  .. {msg}", flush=True)

T = str(uuid.uuid4())
sql(f"insert into yui_users(id, apple_sub) values ('{T}','test.{T}')")
tok = mint(T, ttl=3600)
host = None


def start_host():
    global host
    host = subprocess.Popen([str(HERMES / "venv/bin/python"), __file__, "--host", str(HOME)],
                            stdout=open(HOME / "host.out", "a"), stderr=subprocess.STDOUT)
    wait(lambda: sum(1 for e in agent_events() if e["ev"] == "up") > ups[0], 60, "host up")
    ups[0] += 1
    log(f"host up, pid {host.pid}")
ups = [0]


def kill_host(sig=signal.SIGKILL):
    host.send_signal(sig)
    host.wait(30)
    log(f"host pid {host.pid} {'killed -9' if sig == signal.SIGKILL else 'stopped cleanly'}")


def agent_events():
    try:
        return [json.loads(l) for l in (HOME / "agent.jsonl").read_text().splitlines() if l.strip()]
    except FileNotFoundError:
        return []


def wait(cond, secs, what):
    end = time.time() + secs
    while time.time() < end:
        if cond():
            return True
        time.sleep(0.5)
    raise TimeoutError(what)


def say(text):
    s, r = rest("POST", "yui_messages", tok, {"id": str(uuid.uuid4()), "user_id": T, "agent_id": agent,
                                              "sender": "user", "body": text, "kind": "text"})
    assert s == 201, (s, r)
    log(f"app sent {text!r}")


def thread():
    s, r = rest("GET", f"yui_messages?select=id,sender,body,meta,created_at,delivered_at,handled_at"
                       f"&agent_id=eq.{agent}&order=created_at.asc,id.asc", tok)
    assert s == 200, (s, r)
    return r


def echoes():
    return [l for m in thread() if m["sender"] == "agent" for l in m["body"].split("\n")]


def presence():
    s, r = rest("GET", f"yui_agent_list?select=presence,status,last_seen_at&id=eq.{agent}", tok)
    return r[0]


def phone_side():
    print("== E. the phone: network drop, killed app, asleep agent (simulator)")
    shots = OUT / "shots"
    shots.mkdir(exist_ok=True)
    for f in shots.iterdir():
        f.unlink()
    rts = []
    for _ in range(4):  # one fresh session per launch: a replayed refresh token signs everyone out
        rt = secrets.token_urlsafe(32)
        sql(f"insert into yui_sessions(user_id, refresh_hash, expires_at) values "
            f"('{T}', '{hashlib.sha256(rt.encode()).hexdigest()}', now() + interval '1 day')")
        rts.append(rt)
    flag = OUT / "phone-offline"
    env = {**os.environ, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer",
           "TEST_RUNNER_YUI_RTS": ",".join(rts), "TEST_RUNNER_YUI_USER": T,
           "TEST_RUNNER_YUI_OFFLINE": str(flag), "TEST_RUNNER_YUI_SHOTS": str(shots)}
    subprocess.run(["xcodegen", "generate", "--quiet"], cwd=REPO, env=env, check=True)
    ui = subprocess.Popen(["xcodebuild", "test", "-project", "Yui.xcodeproj", "-scheme", "Yui",
                           "-destination", f"id={args.sim}", "-derivedDataPath", "/tmp/yui28-dd",
                           "-only-testing:YuiUITests/OfflineTests"],
                          cwd=REPO, env=env, stdout=open(OUT / "xcodebuild.log", "w"), stderr=subprocess.STDOUT)
    served = set()
    phone_rows_before = None
    offline_seen = leaked = False
    while ui.poll() is None:
        if flag.exists():  # the phone is "offline": nothing of it may reach the server
            offline_seen = True
            leaked |= any(m["body"].startswith("p1") or m["body"].startswith("p2") for m in thread())
        if (shots / "need-asleep").exists() and "asleep" not in served:
            served.add("asleep")
            phone_rows_before = [m["body"] for m in thread() if m["sender"] == "user"]
            kill_host()
            # A sleeping Mac just goes quiet; age its heartbeat instead of waiting 2 minutes.
            sql(f"update yui_connectors set last_seen_at = now() - interval '5 minutes' where user_id = '{T}'")
            (shots / "asleep-ok").touch()
        if (shots / "need-wake").exists() and "wake" not in served:
            served.add("wake")
            start_host()
            (shots / "wake-ok").touch()
        time.sleep(1)
    log_text = (OUT / "xcodebuild.log").read_text()
    check("OfflineTests ran and passed in the simulator",
          ui.returncode == 0 and "Executed 1 test, with 0 failures" in log_text,
          f"xcodebuild exit {ui.returncode}, log {OUT / 'xcodebuild.log'}")
    phone = [m for m in thread() if m["sender"] == "user" and m["body"].startswith("p")]
    bodies = [m["body"] for m in phone]
    check("the phone's messages landed once each, in order",
          bodies == ["p1 sent with no network", "p2 sent with no network", "p3 while you sleep", "p4 still asleep"],
          f"{bodies}")
    check("sent while the phone was offline: not on the server until it came back",
          offline_seen and not leaked and phone_rows_before is not None
          and "p1 sent with no network" in phone_rows_before, f"offline_seen={offline_seen} leaked={leaked}")
    time.sleep(THINK + 2)
    got = [l for l in echoes() if l.startswith("echo: p")]
    check("the agent answered each once, in order", got == [f"echo: {b}" for b in bodies], f"{got}")
    check("the phone's rows are all handled", all(m["handled_at"] for m in thread() if m["sender"] == "user"))


try:
    s, r = fn("yui-agents", {"action": "create", "name": "Echo", "pair": True}, tok)
    agent = r["agent"]["id"]
    s2, p = connector.pair(r["pairing"]["code"], "offline-e2e", "Offline test host")
    check("throwaway account, agent and host paired", (s, s2) == (200, 200), f"{s} {s2}")

    start_host()
    check("host online after connect", presence()["presence"] == "online", f"{presence()}")

    print("== A. a normal turn")
    say("m1")
    wait(lambda: "echo: m1" in echoes(), 60, "echo m1")
    check("m1 answered", echoes() == ["echo: m1"], f"{echoes()}")

    print("== B. kill -9 mid-turn, messages sent while the host is dead")
    say("m2")
    wait(lambda: any(e["ev"] == "start" and "m2" in e["lines"] for e in agent_events()), 60, "m2 start")
    kill_host()
    row2 = next(m for m in thread() if m["body"] == "m2")
    check("m2 was delivered to the agent, not handled (its turn died)",
          row2["delivered_at"] is not None and row2["handled_at"] is None, f"{row2}")
    say("m3"); say("m4")
    time.sleep(3)
    waiting = [m for m in thread() if m["body"] in ("m3", "m4")]
    check("m3 and m4 wait on the server while the host is dead",
          all(m["delivered_at"] is None for m in waiting) and "echo: m3" not in echoes(), f"{waiting}")
    start_host()
    wait(lambda: "echo: m4" in echoes(), 90, "echo m4")
    time.sleep(THINK + 2)
    check("after restart: m2 replayed, then m3 and m4, once each, in order",
          echoes() == ["echo: m1", "echo: m2", "echo: m3", "echo: m4"], f"{echoes()}")

    print("== C. the network drops while the agent answers; kill -9 with the reply only on disk")
    say("m5")
    wait(lambda: any(e["ev"] == "start" and "m5" in e["lines"] for e in agent_events()), 60, "m5 start")
    (HOME / "offline").touch()
    log("host network down")
    wait(lambda: any(e["ev"] == "done" and "m5" in e["lines"] for e in agent_events()), 60, "m5 done")
    wait(lambda: (HOME / "yui/outbox.jsonl").exists() and "m5" in (HOME / "yui/outbox.jsonl").read_text(), 30,
         "m5 reply queued")
    queued = [json.loads(l) for l in (HOME / "yui/outbox.jsonl").read_text().splitlines()]
    check("the reply to m5 waits in the outbox, not in the thread",
          len(queued) == 1 and queued[0]["row"]["body"] == "echo: m5" and "echo: m5" not in echoes(),
          f"{[q['row']['body'] for q in queued]}")
    check("the queued reply names the row it answers (meta.turn)",
          queued[0]["row"].get("meta", {}).get("turn") == [next(m["id"] for m in thread() if m["body"] == "m5")])
    kill_host()
    (HOME / "outbound-down").touch()
    (HOME / "offline").unlink()
    log("host restarts able to read the thread but not to write replies")
    start_host()
    time.sleep(8)
    starts_m5 = sum(1 for e in agent_events() if e["ev"] == "start" and "m5" in e["lines"])
    check("restarted host does not run m5 again (its answer is in the outbox)", starts_m5 == 1, f"starts={starts_m5}")
    (HOME / "outbound-down").unlink()
    log("host network back")
    wait(lambda: "echo: m5" in echoes(), 120, "echo m5 delivered")
    time.sleep(5)
    check("network back: the queued reply goes out once",
          echoes().count("echo: m5") == 1 and not (HOME / "yui/outbox.jsonl").read_text().strip(), f"{echoes()}")

    print("== D. honest status")
    kill_host(signal.SIGTERM)
    pr = presence()
    check("a clean stop says goodbye: offline at once", pr["presence"] == "offline" and pr["status"] == "offline", f"{pr}")
    start_host()
    check("restart: online again", presence()["presence"] == "online", f"{presence()}")
    kill_host()
    # A sleeping Mac just goes quiet. Age its last heartbeat past the 2-minute window
    # instead of waiting for it.
    sql(f"update yui_connectors set last_seen_at = now() - interval '5 minutes' where user_id = '{T}'")
    pr = presence()
    check("a host that went quiet without a goodbye reads asleep, with its last-seen time",
          pr["presence"] == "asleep" and pr["status"] == "offline" and pr["last_seen_at"], f"{pr}")
    (OUT / "presence.json").write_text(json.dumps(pr, indent=2))
    say("m6")
    time.sleep(3)
    check("a message to a sleeping agent waits", "echo: m6" not in echoes())
    start_host()
    wait(lambda: "echo: m6" in echoes(), 60, "echo m6")
    time.sleep(THINK + 2)

    print("== Verdict")
    rows = thread()
    user_rows = [m for m in rows if m["sender"] == "user"]
    want = [f"echo: m{i}" for i in range(1, 7)]
    check("every message's echo exactly once, in order", echoes() == want, f"{echoes()}")
    check("every message is marked delivered and handled",
          all(m["delivered_at"] and m["handled_at"] for m in user_rows),
          f"{[(m['body'], bool(m['delivered_at']), bool(m['handled_at'])) for m in user_rows]}")
    done = [l for e in agent_events() if e["ev"] == "done" for l in e["lines"]]
    check("the agent finished each message exactly once, in order", done == [f"m{i}" for i in range(1, 7)], f"{done}")
    starts = [l for e in agent_events() if e["ev"] == "start" for l in e["lines"]]
    check("only the turn killed mid-thought was started twice", starts.count("m2") == 2
          and all(starts.count(f"m{i}") == 1 for i in (1, 3, 4, 5, 6)), f"{starts}")
    if args.sim:
        phone_side()
        rows = thread()
    (OUT / "thread.json").write_text(json.dumps([{k: m[k] for k in ("sender", "body", "delivered_at", "handled_at")}
                                                 for m in rows], indent=2))
    (OUT / "agent.jsonl").write_text((HOME / "agent.jsonl").read_text())
    kill_host(signal.SIGTERM)
except Exception as e:
    check("scenario ran to the end", False, repr(e))
finally:
    if host and host.poll() is None:
        host.kill()
    if (HOME / "host.log").exists():
        (OUT / "host.log").write_text((HOME / "host.log").read_text())
    s, r = fn("yui-delete", {}, tok)
    left = sql(f"select (select count(*) from yui_messages where user_id='{T}') + "
               f"(select count(*) from yui_connectors where user_id='{T}') as n")[0]["n"]
    check("throwaway account deleted, zero rows left", s == 200 and left == 0, f"{s} {left}")
    import shutil
    shutil.rmtree(HOME, ignore_errors=True)

print(f"\n{sum(results)}/{len(results)} passed  (proof in {OUT})")
sys.exit(0 if all(results) else 1)

#!/usr/bin/env python3
"""YUI-116 step 5 end to end: a take recorded on the phone reaches the agent
as links. Live against yuigui, on a throwaway account.

The host is the real `yui` platform adapter under Hermes' real
BasePlatformAdapter, in its own process. Its scripted agent answers the first
message with a loop (`loop@beat 120 ... +play`) and a take event with a line
naming what it got and a `card` that links back to the take.

The phone (YuiUITests/TakeLiveTests) signs in, gets the loop, records about
4 s of it and sends. The take goes up to the yui-media bucket like a camera
photo and the event carries signed links. This script checks the agent's turn:
the links arrive whole (the plugin's photo localizer leaves them alone), open
with no key like any link, and hold an AAC file at 48 kHz (afinfo) and a MIDI
file with the loop's hits. The files and screenshots land in --out.

    ~/.hermes/hermes-agent/venv/bin/python supabase/tests/take_e2e.py --sim <udid> [--out DIR]

Needs the Hermes venv at ~/.hermes/hermes-agent and a Supabase access token
like the other supabase/tests. The account is deleted at the end.
"""
import argparse, asyncio, hashlib, json, os, re, secrets, signal, subprocess, sys, tempfile, time, urllib.request, uuid
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
HERMES = Path.home() / ".hermes/hermes-agent"
BEAT = ('Here is a beat. Record a take over it.\n```yui\n'
        'loop@beat 120 "Take one" p=x...x...|..x...x.|xxxxxxxx +play\n```')

ap = argparse.ArgumentParser()
ap.add_argument("--out", default="/tmp/yui116-take-e2e")
ap.add_argument("--sim", required=True, help="simulator udid: the phone records (YuiUITests/TakeLiveTests)")
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
    from yui.adapter import YuiAdapter
    platform_registry.register(PlatformEntry(name="yui", label="Yui", adapter_factory=lambda cfg: YuiAdapter(cfg),
                                             check_fn=lambda: True))
    log = home / "agent.jsonl"

    def note(**kw):
        with open(log, "a") as f:
            f.write(json.dumps({"t": time.time(), **kw}, ensure_ascii=False) + "\n")

    async def agent(event):
        text = event.text
        note(ev="turn", text=text, media=list(event.media_urls or []), types=list(event.media_types or []))
        m = re.search(r"audio=\"?([^\"\s]+)", text)
        if not m:
            return BEAT
        secs = re.search(r"seconds=([\d.]+)", text)
        return (f"Got your take, {secs.group(1) if secs else '?'} s. Here it is back.\n```yui\n"
                f'card "Your take" body="AAC and MIDI, links good for 7 days" url={m.group(1)}\n```')

    async def main():
        adapter = YuiAdapter(PlatformConfig(enabled=True, extra={"remote_ref": "take-e2e"}))
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
HOME = Path(tempfile.mkdtemp(prefix="yui-take-e2e-"))
os.environ["YUI_CONNECTOR_FILE"] = str(HOME / "connector.json")
import importlib.util  # noqa: E402
_spec = importlib.util.spec_from_file_location("yui_connector", REPO / "hermes-plugin/yui/connector.py")
connector = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(connector)

results = []
def check(name, ok, detail=""):
    ok = bool(ok); results.append(ok); print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  [{detail}]" if detail else ""), flush=True)
def log(msg): print(f"  .. {msg}", flush=True)

T = str(uuid.uuid4())
sql(f"insert into yui_users(id, apple_sub) values ('{T}','test.{T}')")
# The simulator registers no push token, so no phone has told the host its
# build; say it here (this branch's commit count), or the host draws the loop in words.
BUILD = int(subprocess.run(["git", "rev-list", "--count", "HEAD"], cwd=REPO, capture_output=True, text=True).stdout)
sql(f"insert into yui_devices(user_id, name, app_build, app_build_at) values ('{T}', 'take-e2e sim', {BUILD}, now())")
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


def take_turn():
    return next((e for e in events() if e["ev"] == "turn" and "audio=" in e["text"]), None)


def fresh_rt():
    rt = secrets.token_urlsafe(32)
    sql(f"insert into yui_sessions(user_id, refresh_hash, expires_at) values "
        f"('{T}', '{hashlib.sha256(rt.encode()).hexdigest()}', now() + interval '1 day')")
    return rt


def get(url):
    with urllib.request.urlopen(url, timeout=60) as r:
        return r.read()


try:
    s, r = fn("yui-agents", {"action": "create", "name": "Yui", "pair": True}, tok)
    agent = r["agent"]["id"]
    s2, p = connector.pair(r["pairing"]["code"], "take-e2e", "Take test host")
    check("throwaway account, agent and host paired", (s, s2) == (200, 200), f"{s} {s2}")
    host = subprocess.Popen([str(HERMES / "venv/bin/python"), __file__, "--host", str(HOME), "--sim", args.sim],
                            stdout=open(HOME / "host.out", "a"), stderr=subprocess.STDOUT)
    wait(lambda: any(e["ev"] == "up" for e in events()), 60, "host up")
    log(f"host up, pid {host.pid}")

    shots = OUT / "shots"
    shots.mkdir(exist_ok=True)
    for f in shots.iterdir():
        f.unlink()
    env = {**os.environ, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer",
           "TEST_RUNNER_YUI_RTS": fresh_rt(), "TEST_RUNNER_YUI_USER": T, "TEST_RUNNER_YUI_SHOTS": str(shots)}
    dd = os.environ.get("YUI_DD", "/tmp/yui116-take-dd")
    verb = "test-without-building" if os.environ.get("YUI_DD") else "test"
    ui = subprocess.Popen(["xcodebuild", verb, "-project", "Yui.xcodeproj", "-scheme", "Yui",
                           "-destination", f"id={args.sim}", "-derivedDataPath", dd,
                           "-only-testing:YuiUITests/TakeLiveTests", f"CURRENT_PROJECT_VERSION={BUILD}"],
                          cwd=REPO, env=env, stdout=open(OUT / "xcodebuild.log", "w"), stderr=subprocess.STDOUT)
    asked = False
    seen = None
    while ui.poll() is None:
        rows = sql(f"select to_char(created_at,'HH24:MI:SS') c, to_char(revoked_at,'HH24:MI:SS') r from yui_sessions where user_id='{T}' order by created_at")
        if os.environ.get("YUI_DEBUG") and rows != seen:
            log(f"sessions {rows}")
            seen = rows
        if (shots / "need-beat").exists() and not asked:
            s, _ = rest("POST", "yui_messages", tok, {"user_id": T, "agent_id": agent, "sender": "user",
                                                      "body": "Make me a beat to record over", "kind": "text"})
            log(f"asked for the beat ({s})")
            asked = True
            (shots / "beat-ok").touch()
        if (shots / "need-got").exists() and not (shots / "got-ok").exists() and take_turn():
            (shots / "got-ok").touch()
        time.sleep(1)
    text = (OUT / "xcodebuild.log").read_text()
    check("TakeLiveTests ran and passed in the simulator",
          ui.returncode == 0 and "Executed 1 test, with 0 failures" in text,
          f"xcodebuild exit {ui.returncode}, log {OUT / 'xcodebuild.log'}")

    print("== What the agent got")
    t = take_turn()
    check("the agent got the take as a turn", t, "")
    t = t or {"text": "", "media": []}
    (OUT / "take-turn.txt").write_text(t["text"])
    audio = (re.search(r"audio=\"?([^\"\s]+)", t["text"]) or [None, ""])[1]
    midi = (re.search(r"midi=\"?([^\"\s]+)", t["text"]) or [None, ""])[1]
    sign = f"{BASE}/storage/v1/object/sign/yui-media/{T}/{agent}/user/"
    check("audio is a whole signed link into the person's own media", audio.startswith(sign) and ".m4a?token=" in audio, audio[:140])
    check("midi is a whole signed link too", midi.startswith(sign) and ".mid?token=" in midi, midi[:140])
    check("the plugin fetched nothing (a take is links, not a photo)", not t.get("media"), t.get("media"))
    secs = float((re.search(r"seconds=([\d.]+)", t["text"]) or [None, "0"])[1])
    check("the take says how long it is (about 4 s)", 3 <= secs <= 9, secs)

    m4a = get(audio) if audio else b""
    (OUT / "take.m4a").write_bytes(m4a)
    info = subprocess.run(["afinfo", str(OUT / "take.m4a")], capture_output=True, text=True).stdout
    (OUT / "take.afinfo.txt").write_text(info)
    check("the audio link opens with no key and holds an MPEG-4 audio file", m4a[4:8] == b"ftyp", f"{len(m4a)} bytes")
    check("AAC, 48000 Hz, 2 channels (afinfo)", "aac" in info.lower() and "48000 Hz" in info and "2 ch" in info,
          " | ".join(l.strip() for l in info.splitlines() if "Data format" in l or "duration" in l))
    dur = float((re.search(r"estimated duration: ([\d.]+)", info) or [None, "0"])[1])
    check("its length matches the event", abs(dur - secs) < 0.5, f"{dur} s vs {secs} s")

    mid = get(midi) if midi else b""
    (OUT / "take.mid").write_bytes(mid)
    ons = sum(1 for i in range(len(mid) - 2) if mid[i] == 0x99 and mid[i + 2] > 0)  # drum note-ons, channel 10
    check("the MIDI link holds a Standard MIDI File with the loop's drum hits",
          mid[:4] == b"MThd" and ons >= 8, f"{len(mid)} bytes, {ons} drum note-ons (running status off)")

    rows = rest("GET", f"yui_messages?select=sender,kind,body,meta&agent_id=eq.{agent}&order=created_at.asc,id.asc", tok)[1]
    ev = next((m for m in rows if m["kind"] == "event" and "audio" in ((m["meta"] or {}).get("value") or {})), None)
    val = ((ev or {}).get("meta") or {}).get("value") or {}
    check("the event row carries the spec's shape (id, preset, audio, midi, seconds, bpm)",
          ev and ev["meta"].get("preset") == "loop" and ev["meta"].get("id") == "beat" and val.get("audio") == audio
          and val.get("midi") == midi and val.get("seconds") == secs and val.get("bpm") == 120,
          json.dumps((ev or {}).get("meta"))[:200])
    reply = next((m for m in rows if m["sender"] == "agent" and "Got your take" in m["body"]), None)
    check("the agent answered with the take as a link (card url=)", reply and audio in reply["body"], (reply or {}).get("body", "")[:120])
finally:
    if host and host.poll() is None:
        host.send_signal(signal.SIGTERM)
        try:
            host.wait(20)
        except Exception:
            host.kill()
    fn("yui-delete", {}, tok)  # the account and its media, like the app's Delete account
    sql(f"delete from yui_users where id = '{T}'")
    left = sql(f"select (select count(*) from yui_messages where user_id='{T}') + "
               f"(select count(*) from yui_agents where user_id='{T}') + "
               f"(select count(*) from storage.objects where bucket_id='yui-media' and name like '{T}/%') as n")[0]["n"]
    check("test account and its media deleted, zero rows left", left == 0, f"{left}")

print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)

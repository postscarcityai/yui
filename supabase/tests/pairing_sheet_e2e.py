#!/usr/bin/env python3
"""YUI-192 end to end: the Add agent sheet leaves "Waiting for its gateway".

Live against yuigui, on a throwaway account. The phone (simulator) makes an
agent and shows its pairing code (YuiUITests/PairingSheetTests). This script is
the computer: it pairs the code (`hermes yui pair`), then starts the real `yui`
platform adapter (`hermes gateway restart`). The sheet must flip to connected
within seconds, with nobody touching the phone.

    python3 supabase/tests/pairing_sheet_e2e.py --sim <udid> [--out /tmp/yui192] [--appearance light|dark]

Needs the Hermes venv at ~/.hermes/hermes-agent and a Supabase access token
like the other supabase/tests. The account is deleted at the end.
"""
import argparse, asyncio, hashlib, json, os, secrets, signal, subprocess, sys, tempfile, time, uuid
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
HERMES = Path.home() / ".hermes/hermes-agent"

ap = argparse.ArgumentParser()
ap.add_argument("--out", default="/tmp/yui192")
ap.add_argument("--sim")
ap.add_argument("--appearance", default="light")
ap.add_argument("--host", help=argparse.SUPPRESS)
ap.add_argument("--ref", help=argparse.SUPPRESS)
args = ap.parse_args()


def run_host(home: Path, ref: str) -> None:
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
        return "echo"

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

if not args.sim:
    ap.error("--sim is required")
exec(open(REPO / "supabase/tests/agents_test.py").read().split("results = []")[0])
OUT = Path(args.out)
OUT.mkdir(parents=True, exist_ok=True)
HOME = Path(tempfile.mkdtemp(prefix="yui-pairing-sheet-e2e-"))
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
tok = mint(T, ttl=3600)
host = None


def presence(aid):
    s, r = rest("GET", f"yui_agent_list?select=presence,status&id=eq.{aid}", tok)
    return r[0] if s == 200 and r else {"error": (s, r)}


try:
    shots = OUT / "shots"
    shots.mkdir(exist_ok=True)
    for f in shots.iterdir():
        f.unlink()
    rt = secrets.token_urlsafe(32)
    sql(f"insert into yui_sessions(user_id, refresh_hash, expires_at) values "
        f"('{T}', '{hashlib.sha256(rt.encode()).hexdigest()}', now() + interval '1 day')")
    env = {**os.environ, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer",
           "TEST_RUNNER_YUI_RTS": rt, "TEST_RUNNER_YUI_USER": T, "TEST_RUNNER_YUI_SHOTS": str(shots),
           "TEST_RUNNER_YUI_APPEARANCE": args.appearance}
    subprocess.run(["xcodegen", "generate", "--quiet"], cwd=REPO, env=env, check=True)
    ui = subprocess.Popen(["xcodebuild", "test", "-project", "Yui.xcodeproj", "-scheme", "Yui",
                           "-destination", f"id={args.sim}", "-derivedDataPath", "/tmp/yui192-dd",
                           "-only-testing:YuiUITests/PairingSheetTests"],
                          cwd=REPO, env=env, stdout=open(OUT / "xcodebuild.log", "w"), stderr=subprocess.STDOUT)
    agent_id = None
    woke = None
    while ui.poll() is None:
        if (shots / "need-pair").exists() and not (shots / "pair-ok").exists():
            code = (shots / "code").read_text().strip()
            s, p = connector.pair(code, "gamma", "Test Mac")
            check("the computer paired the code (hermes yui pair)", s == 200 and p["agent"]["presence"] == "not_listening",
                  f"{s} {p.get('agent', {}).get('presence')}")
            agent_id = p["agent"]["id"]
            (shots / "pair-ok").touch()
        if (shots / "need-wake").exists() and not (shots / "wake-ok").exists():
            time.sleep(15)  # the person reads the screen, then restarts the gateway
            host = subprocess.Popen([str(HERMES / "venv/bin/python"), __file__, "--host", str(HOME), "--ref", "gamma"],
                                    stdout=open(HOME / "host-gamma.out", "a"), stderr=subprocess.STDOUT)
            while not (HOME / "up-gamma").exists():
                time.sleep(0.5)
            woke = time.time()
            (shots / "wake-ok").touch()
        time.sleep(1)
    log_text = (OUT / "xcodebuild.log").read_text()
    check("PairingSheetTests ran and passed in the simulator",
          ui.returncode == 0 and "Executed 1 test, with 0 failures" in log_text,
          f"xcodebuild exit {ui.returncode}, log {OUT / 'xcodebuild.log'}")
    check("the server says online once the gateway runs", agent_id and presence(agent_id)["presence"] == "online",
          f"{agent_id and presence(agent_id)}")
    if (shots / "seconds").exists():
        log(f"the sheet flipped {float((shots / 'seconds').read_text()):.1f} s after the gateway was up")
except Exception as e:
    check("scenario ran to the end", False, repr(e))
finally:
    if host and host.poll() is None:
        host.send_signal(signal.SIGTERM)
        try: host.wait(30)
        except Exception: host.kill()
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

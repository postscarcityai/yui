#!/usr/bin/env python3
"""YUI-70 end to end on the simulator: the drawer's Controls over the live relay,
served by the plugin's own code (hermes-plugin/yui/controls.py) on a throwaway
profile. (YuiUITests/ControlsLiveTests, light then dark.)

A throwaway owner pairs a throwaway host and reports its controls through
yui-connect. This script is the host: a fresh profile home in a temp folder
(SOUL.md, memory with a token-shaped line, a skill, a schedule, keys in .env),
and a loop that answers each control row the way the gateway does
(adapter._control: mark delivered, controls.Host.handle, one kind=control
answer, handled). The simulator signs in as the owner and runs the round
trips; afterwards the host's files are checked, and yui_messages is searched
for anything key-shaped. Everything is removed at the end.

    ~/.hermes/hermes-agent/venv/bin/python supabase/tests/controls_e2e.py --sim <udid> [--out DIR]

(The hermes-agent venv: the host side imports cron and hermes_cli like the gateway.)
"""
import argparse, hashlib, json, os, re, secrets, shutil, subprocess, sys, tempfile, threading, time, uuid
from datetime import datetime, timezone
from pathlib import Path

HOME = Path(tempfile.mkdtemp(prefix="yui70-host-"))
os.environ["HERMES_HOME"] = str(HOME)  # before any hermes import: cron binds its paths at import
exec(open(__file__.replace("controls_e2e.py", "agents_test.py")).read().split("results = []")[0])

results = []
def check(name, ok, detail=""):
    ok = bool(ok); results.append(ok); print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  [{detail}]" if detail else ""), flush=True)

ap = argparse.ArgumentParser()
ap.add_argument("--sim", required=True)
ap.add_argument("--out", default="/tmp/yui70-e2e")
args = ap.parse_args()
OUT = Path(args.out); OUT.mkdir(parents=True, exist_ok=True)
shots = OUT / "shots"; shots.mkdir(exist_ok=True)
for f in shots.iterdir():
    f.unlink()
REPO = Path(__file__).resolve().parents[2]
AGENT_SRC = Path(os.environ.get("HERMES_AGENT") or Path.home() / ".hermes/hermes-agent")
sys.path.insert(0, str(AGENT_SRC))
sys.path.insert(0, str(REPO / "hermes-plugin"))
from cron import jobs as cron  # noqa: E402
from hermes_cli import config as hconfig  # noqa: E402
import importlib.util  # noqa: E402
spec = importlib.util.spec_from_file_location("yui_controls", REPO / "hermes-plugin/yui/controls.py")
controls = importlib.util.module_from_spec(spec); spec.loader.exec_module(controls)

RUN = uuid.uuid4().hex[:8]
PROFILE = f"scout-{RUN}"
KEY = "sk-ant-api03-" + secrets.token_urlsafe(40).replace("-", "x").replace("_", "y")  # token-shaped, never a real key
BOT = f"{secrets.randbelow(10**9):09d}:" + secrets.token_urlsafe(26)
SOUL = "# Scout\n\nYou are Scout, a trail-running coach who lives in Yui.\n\n## Voice\n\n- Warm, quick, a little playful.\n- Short sentences.\n"
O = str(uuid.uuid4())

# The host's profile: what a real Hermes profile holds.
(HOME / "SOUL.md").write_text(SOUL)
(HOME / "memories").mkdir()
(HOME / "memories/MEMORY.md").write_text(
    "Long runs are on Sunday mornings, 8:00 start.\n§\nKnee felt tight after the 18 km on Sep 14.\n§\n"
    f"Strava sync token: {KEY}")
(HOME / "memories/USER.md").write_text("Chris likes short answers and buttons over paragraphs.")
(HOME / "skills/fitness/trail-planner").mkdir(parents=True)
(HOME / "skills/fitness/trail-planner/SKILL.md").write_text(
    "---\nname: trail-planner\ndescription: Plan a week of runs from the calendar.\n---\n\n# Trail planner\n\n1. Read the week.\n")
(HOME / ".env").write_text(f"ANTHROPIC_API_KEY={KEY}\nTELEGRAM_BOT_TOKEN={BOT}\n")
(HOME / "config.yaml").write_text("model:\n  default: claude-opus-5-5\n  provider: custom\n  base_url: http://127.0.0.1:8765/v1\n"
                                  f"  api_key: {KEY}\ntoolsets:\n- hermes-cli\nplatforms:\n  yui:\n    enabled: true\n")
job = cron.create_job(prompt="Send the day's run and the weather as one card.", schedule="0 8 * * 1-5", name="morning brief")["id"]
host = controls.Host(HOME, cron=cron, config=hconfig)

served, stop = [], threading.Event()

def serve(ct: str, agent: str) -> None:
    """The gateway's _control loop, against the live relay."""
    token, exp = None, 0.0
    while not stop.is_set():
        try:
            if time.time() > exp - 60:
                s, r = fn("yui-connect", {"action": "session", "serving": [PROFILE]}, ct)
                token, exp = r["access_token"], datetime.fromisoformat(r["expires_at"].replace("Z", "+00:00")).timestamp()
                fn("yui-connect", {"action": "heartbeat", "serving": [PROFILE]}, ct)
            s, rows_ = rest("GET", f"yui_messages?agent_id=eq.{agent}&sender=eq.user&kind=eq.control&handled_at=is.null"
                                  f"&select=id,user_id,meta&order=created_at.asc", token)
            for row in (rows_ if s == 200 else []):
                now = datetime.now(timezone.utc).isoformat()
                rest("PATCH", f"yui_messages?id=eq.{row['id']}", token, {"delivered_at": now}, "return=minimal")
                ans, change = host.handle(row["meta"], owner=row["user_id"] == O, who=row["user_id"], agent=agent)
                reply = {"id": str(uuid.uuid4()), "user_id": row["user_id"], "agent_id": agent, "sender": "agent",
                         "kind": "control", "body": controls.body_of(row["meta"], ans), "meta": {**ans, "for": row["id"]}}
                s2, r2 = rest("POST", "yui_messages", token, reply, "return=minimal")
                rest("PATCH", f"yui_messages?id=eq.{row['id']}", token, {"handled_at": now}, "return=minimal")
                served.append((row["meta"].get("op"), row["meta"].get("section"), ans.get("ok"), ans.get("error"), s2, change))
            if int(time.time()) % 30 == 0:
                fn("yui-connect", {"action": "heartbeat", "serving": [PROFILE]}, ct)
        except Exception as e:
            print(f"host loop: {e}", flush=True)
        stop.wait(0.3)

try:
    sql(f"insert into yui_users(id, apple_sub, email) values ('{O}','test.{O}','yui-controls-e2e-{RUN}@example.com')")
    tokO = mint(O)
    s, r = fn("yui-agents", {"action": "create", "name": "Scout", "pair": True}, tokO)
    agent = r["agent"]["id"]
    s, r = fn("yui-connect", {"action": "pair", "code": r["pairing"]["code"], "remote_ref": PROFILE, "host_name": "Test Mac"})
    ct = r["connector_token"]
    check("a throwaway owner pairs a throwaway host", s == 200 and ct, s)
    s, r = fn("yui-connect", {"action": "controls", "remote_ref": PROFILE, "controls": controls.report()}, ct)
    check("the host reports its controls (as the gateway does at start)", s == 200 and r.get("agents") == 1, r)
    t = threading.Thread(target=serve, args=(ct, agent), daemon=True); t.start()

    rts = []
    for _ in range(2):  # one fresh session per launch
        rt = secrets.token_urlsafe(32)
        sql(f"insert into yui_sessions(user_id, refresh_hash, expires_at) values "
            f"('{O}', '{hashlib.sha256(rt.encode()).hexdigest()}', now() + interval '1 day')")
        rts.append(rt)
    env = {**os.environ, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer",
           "TEST_RUNNER_YUI_RTS": ",".join(rts), "TEST_RUNNER_YUI_USER": O, "TEST_RUNNER_YUI_SHOTS": str(shots)}
    ui = subprocess.Popen(["xcodebuild", "test", "-project", "Yui.xcodeproj", "-scheme", "Yui",
                           "-destination", f"id={args.sim}", "-derivedDataPath", "/tmp/yui70-dd",
                           "-only-testing:YuiUITests/ControlsLiveTests"],
                          cwd=REPO, env=env, stdout=open(OUT / "xcodebuild.log", "w"), stderr=subprocess.STDOUT)
    while ui.poll() is None:
        for need in shots.glob("need-*"):
            what = need.name[5:]
            if what == "soul":
                (shots / "host-soul.md").write_text((HOME / "SOUL.md").read_text())
            (shots / f"{what}-ok").touch()
            need.unlink()
        time.sleep(0.5)
    stop.set()
    log_text = (OUT / "xcodebuild.log").read_text()
    check("ControlsLiveTests ran and passed in the simulator",
          ui.returncode == 0 and re.search(r"Executed [1-9]\d* tests?, with 0 failures", log_text),
          f"xcodebuild exit {ui.returncode}, log {OUT / 'xcodebuild.log'}")

    print("\n== On the host")
    soul = (HOME / "SOUL.md").read_text()
    check("the SOUL.md edit is on the host", "Always end with one question." in soul, soul[-80:])
    mem = (HOME / "memories/MEMORY.md").read_text()
    check("the forgotten memory is gone from the host, the rest stays",
          "Knee felt tight" not in mem and "Long runs" in mem and KEY in mem, mem[:80])
    check("the key-shaped line was never overwritten", KEY in mem)
    cfg = hconfig.load_config()
    check("the skill is on again (switched off, then on)", "trail-planner" not in ((cfg.get("skills") or {}).get("disabled") or []))
    j = cron.get_job(job)
    check("the schedule is scheduled again, due now (run now)", j["state"] == "scheduled"
          and (datetime.fromisoformat(j["next_run_at"]) - datetime.now(datetime.fromisoformat(j["next_run_at"]).tzinfo)).total_seconds() < 600, j["next_run_at"])
    log = [json.loads(x) for x in (HOME / "yui/controls.log").read_text().splitlines()]
    ops = [(x["op"], x["section"]) for x in log]
    check("the host logged each change", ops.count(("act", "skills")) == 2 and ops.count(("act", "schedules")) == 3
          and ("put", "soul") in ops and ("delete", "memory") in ops, ops)
    check("the host kept the old copies in its trash", len(list((HOME / "yui/controls-trash").iterdir())) >= 3)
    (OUT / "host-controls.log").write_text((HOME / "yui/controls.log").read_text())
    (OUT / "host-served.json").write_text(json.dumps(served, indent=1))
    check("every request was answered", served and all(x[4] == 201 for x in served), [x for x in served if x[4] != 201][:3])

    print("\n== No secrets on the relay")
    rows_ = sql(f"select id, sender, kind, body, meta::text as meta from yui_messages where agent_id = '{agent}'")
    blob = json.dumps(rows_)
    keyish = controls.KEYISH.findall(blob)
    check(f"{len(rows_)} rows for the agent; nothing key-shaped in any body or meta",
          len(rows_) > 10 and not keyish and KEY not in blob and BOT.split(":")[1] not in blob, keyish[:3])
    q = (f"select count(*)::int n from yui_messages where agent_id = '{agent}' and "
         f"(body ~* 'sk-ant|api03|{BOT.split(':')[0]}' or meta::text ~* 'sk-ant|api03|{BOT.split(':')[0]}' "
         f"or meta::text like '%{KEY[:24]}%')")
    n = sql(q)[0]["n"]
    (OUT / "secrets-query.txt").write_text(f"{q}\n-> {n}\n")
    check("the secrets query finds nothing", n == 0, q)
    hidden = [r for r in rows_ if "[hidden on your Mac]" in r["meta"]]
    check("the token-shaped memory went out as [hidden on your Mac]", hidden, len(hidden))
finally:
    stop.set()
    sql(f"delete from yui_users where id = '{O}'; delete from yui_pair_attempts where created_at > now() - interval '1 hour'")
    shutil.rmtree(HOME, ignore_errors=True)

print(f"\nshots: {shots}\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)

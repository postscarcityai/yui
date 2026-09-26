#!/usr/bin/env python3
"""YUI-69 end to end on the simulator: Talk about this over the live relay, with
the plugin's own code as the host (hermes-plugin/yui/talk.py + controls.py) on a
throwaway profile. (YuiUITests/TalkLiveTests.)

A throwaway owner pairs a throwaway host. This script is the host and a
scripted agent (never an LLM): it answers control rows as the gateway does,
expands each attach line the way adapter._dispatch does (talk.expand), and
answers each turn with a proposal through talk.propose, written into the
thread with the connector token. Taps on the proposals are taken as
adapter._talk_tap takes them (talk.take / talk.again), no turn. The simulator
runs the round trips: SOUL.md gets a new line, a memory is forgotten, a
schedule moves to 7:30, one proposal is kept as is, and one hits a terminal
edit mid-proposal (conflict, Ask again, applied). Last, a memory entry with a
token-shaped line is attached and a change asked for: the turn shows the
placeholder, the proposal is refused, and yui_messages is searched for
anything key-shaped. Everything is removed at the end.

    ~/.hermes/hermes-agent/venv/bin/python supabase/tests/talk_e2e.py --sim <udid> [--out DIR]
"""
import argparse, hashlib, json, os, re, secrets, shutil, subprocess, sys, tempfile, threading, time, uuid
from datetime import datetime, timezone
from pathlib import Path

HOME = Path(tempfile.mkdtemp(prefix="yui69-host-"))
os.environ["HERMES_HOME"] = str(HOME)  # before any hermes import: cron binds its paths at import
exec(open(__file__.replace("talk_e2e.py", "agents_test.py")).read().split("results = []")[0])

results = []
def check(name, ok, detail=""):
    ok = bool(ok); results.append(ok); print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  [{detail}]" if detail else ""), flush=True)

ap = argparse.ArgumentParser()
ap.add_argument("--sim", required=True)
ap.add_argument("--out", default="/tmp/yui69-e2e")
args = ap.parse_args()
OUT = Path(args.out); OUT.mkdir(parents=True, exist_ok=True)
shots = OUT / "shots"; shots.mkdir(exist_ok=True)
for f in shots.iterdir():
    f.unlink()
REPO = Path(__file__).resolve().parents[2]
AGENT_SRC = Path(os.environ.get("HERMES_AGENT") or Path.home() / ".hermes/hermes-agent")
sys.path.insert(0, str(AGENT_SRC))
sys.path.insert(0, str(REPO / "hermes-plugin" / "yui"))
from cron import jobs as cron  # noqa: E402
from hermes_cli import config as hconfig  # noqa: E402
import controls, talk  # noqa: E402  (the plugin's own modules, as the gateway runs them)

RUN = uuid.uuid4().hex[:8]
PROFILE = f"scout-{RUN}"
KEY = "sk-ant-api03-" + secrets.token_urlsafe(40).replace("-", "x").replace("_", "y")  # token-shaped, never a real key
SOUL = "# Scout\n\nYou are Scout, a trail-running coach who lives in Yui.\n\n## Voice\n\n- Warm, quick, a little playful.\n- Short sentences.\n"
O = str(uuid.uuid4())

(HOME / "SOUL.md").write_text(SOUL)
(HOME / "memories").mkdir()
(HOME / "memories/MEMORY.md").write_text(
    "Long runs are on Sunday mornings, 8:00 start.\n§\nKnee felt tight after the 18 km on Sep 14.\n§\n"
    f"Strava sync token: {KEY}")
(HOME / "memories/USER.md").write_text("Chris likes short answers and buttons over paragraphs.")
(HOME / ".env").write_text(f"ANTHROPIC_API_KEY={KEY}\n")
(HOME / "config.yaml").write_text("model:\n  default: claude-opus-5-5\n  provider: custom\n  base_url: http://127.0.0.1:8765/v1\n"
                                  f"  api_key: {KEY}\ntoolsets:\n- hermes-cli\nplatforms:\n  yui:\n    enabled: true\n")
job = cron.create_job(prompt="Send the day's run and the weather as one card.", schedule="0 8 * * 1-5", name="morning brief")["id"]
host = controls.Host(HOME, cron=cron, config=hconfig)
t = talk.Talk(host)

served, turns, proposals, stop = [], [], [], threading.Event()
state = {"token": None}


def write(agent: str, body: str, meta=None) -> str:
    row = {"id": str(uuid.uuid4()), "user_id": O, "agent_id": agent, "sender": "agent", "kind": "text", "body": body}
    if meta:
        row["meta"] = meta
    s, _ = rest("POST", "yui_messages", state["token"], row, "return=minimal")
    if s >= 300:
        print(f"write refused {s}", flush=True)
    return row["id"]


def scripted_agent(agent: str, text: str, expanded: str) -> None:
    """What a model would do with the turn, fixed: one proposal per item, by its words."""
    a = talk.read_attach(text)
    send = lambda ag, user, body: write(ag, body)
    if not a:
        write(agent, "Tap Talk about this on something in Controls first.")
        return
    words, s, i = a["words"].lower(), a["section"], a["id"]
    rev = re.search(r"rev=(\S+)", expanded).group(1)
    if "readonly=yes" in expanded:
        # A naive agent tries anyway, with what it was shown: the host must refuse.
        shown = expanded.split("(current) ---\n", 1)[1].split("\n--- end ---", 1)[0]
        out = t.propose(s, i, rev, value={"text": shown.replace("Strava", "New Strava")}, why="Rotated.", send=send)
        proposals.append(("secret", out))
        write(agent, "That one holds a key, so it can only be changed on your Mac.")
        return
    if s == "soul":
        cur = expanded.split("(current) ---\n", 1)[1].split("\n--- end ---", 1)[0] if "(current) ---" in expanded \
            else host.handle({"v": 1, "op": "get", "section": "soul", "id": i}, owner=True)[0]["item"]["text"]
        if "shorter" in words:
            new, why = cur.replace("- Short sentences.", "- Very short sentences."), "Even shorter sentences."
        elif "again" in words or "question" in words:
            new, why = cur.rstrip("\n") + "\n- End with one question.\n", "Every answer ends with one question."
        else:
            new, why = cur.rstrip("\n") + "\n- Calm and brief while you work.\n", "Calm and brief while you work, same warmth after."
        out = t.propose(s, i, rev, value={"text": new}, why=why, send=send)
    elif s == "memory":
        out = t.propose(s, i, rev, delete=True, why="Out of date, so I'll forget it.", send=send)
    elif s == "schedules":
        out = t.propose(s, i, rev, value={"schedule": "30 7 * * 1-5"}, why="Weekdays at 7:30.", send=send)
    else:
        out = {"ok": False, "message": "read only"}
        write(agent, "I can talk about that one, not change it.")
    proposals.append((s, out))
    if not out.get("ok"):
        write(agent, f"I couldn't propose that: {out.get('message')}")


def serve(ct: str, agent: str) -> None:
    """The gateway: control rows, turns (with the attach expansion) and proposal taps, over the live relay."""
    exp = 0.0
    while not stop.is_set():
        try:
            if time.time() > exp - 60:
                s, r = fn("yui-connect", {"action": "session", "serving": [PROFILE]}, ct)
                state["token"], exp = r["access_token"], datetime.fromisoformat(r["expires_at"].replace("Z", "+00:00")).timestamp()
                fn("yui-connect", {"action": "heartbeat", "serving": [PROFILE]}, ct)
            token = state["token"]
            s, rows_ = rest("GET", f"yui_messages?agent_id=eq.{agent}&sender=eq.user&handled_at=is.null"
                                  f"&select=id,user_id,kind,body,meta&order=created_at.asc", token)
            for row in (rows_ if s == 200 else []):
                now = datetime.now(timezone.utc).isoformat()
                rest("PATCH", f"yui_messages?id=eq.{row['id']}", token, {"delivered_at": now}, "return=minimal")
                owner = row["user_id"] == O
                if row["kind"] == "control":
                    ans, _ = host.handle(row["meta"], owner=owner, who=row["user_id"], agent=agent)
                    reply = {"id": str(uuid.uuid4()), "user_id": row["user_id"], "agent_id": agent, "sender": "agent",
                             "kind": "control", "body": controls.body_of(row["meta"], ans), "meta": {**ans, "for": row["id"]}}
                    rest("POST", "yui_messages", token, reply, "return=minimal")
                    served.append(("control", row["meta"].get("op"), row["meta"].get("section"), ans.get("ok")))
                elif row["kind"] == "event" and talk.Talk.tap_of(row):
                    tap = talk.Talk.tap_of(row)
                    if tap["kind"] == "again":
                        body = t.again(tap["pid"])
                        served.append(("again", tap["pid"], bool(body)))
                        if body:
                            t.turn(agent=agent, user=O, key=agent, owner=True, owner_user=O)
                            expanded = t.expand(body, key=agent, owner=True, profile=PROFILE)
                            turns.append(expanded)
                            scripted_agent(agent, body, expanded)
                    else:
                        out = t.take(tap, who=row["user_id"], agent=agent)
                        served.append(("tap", tap["pid"], tap["choice"], bool(out.get("applied"))))
                        if out.get("reply"):
                            write(agent, out["reply"], {"turn": [row["id"]], "board": True,
                                                        **({"talk": {"applied": out["applied"]}} if out.get("applied") else {})})
                elif row["kind"] == "text":
                    t.turn(agent=agent, user=row["user_id"], key=agent, owner=owner, owner_user=O)
                    expanded = t.expand(row["body"], key=agent, owner=owner, profile=PROFILE)
                    turns.append(expanded)
                    scripted_agent(agent, row["body"], expanded)
                rest("PATCH", f"yui_messages?id=eq.{row['id']}", token, {"handled_at": now}, "return=minimal")
            if int(time.time()) % 30 == 0:
                fn("yui-connect", {"action": "heartbeat", "serving": [PROFILE]}, ct)
        except Exception as e:
            print(f"host loop: {e!r}", flush=True)
        stop.wait(0.3)


try:
    sql(f"insert into yui_users(id, apple_sub, email) values ('{O}','test.{O}','yui-talk-e2e-{RUN}@example.com')")
    tokO = mint(O)
    s, r = fn("yui-agents", {"action": "create", "name": "Scout", "pair": True}, tokO)
    agent = r["agent"]["id"]
    s, r = fn("yui-connect", {"action": "pair", "code": r["pairing"]["code"], "remote_ref": PROFILE, "host_name": "Test Mac"})
    ct = r["connector_token"]
    check("a throwaway owner pairs a throwaway host", s == 200 and ct, s)
    s, r = fn("yui-connect", {"action": "controls", "remote_ref": PROFILE, "controls": controls.report()}, ct)
    check("the host reports its controls", s == 200 and r.get("agents") == 1, r)
    th = threading.Thread(target=serve, args=(ct, agent), daemon=True); th.start()

    rts = []
    for _ in range(2):
        rt = secrets.token_urlsafe(32)
        sql(f"insert into yui_sessions(user_id, refresh_hash, expires_at) values "
            f"('{O}', '{hashlib.sha256(rt.encode()).hexdigest()}', now() + interval '1 day')")
        rts.append(rt)
    env = {**os.environ, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer",
           "TEST_RUNNER_YUI_RTS": ",".join(rts), "TEST_RUNNER_YUI_USER": O, "TEST_RUNNER_YUI_SHOTS": str(shots)}
    ui = subprocess.Popen(["xcodebuild", "test", "-project", "Yui.xcodeproj", "-scheme", "Yui",
                           "-destination", f"id={args.sim}", "-derivedDataPath", os.environ.get("YUI_DD", "/tmp/yui69-dd"),
                           "-only-testing:YuiUITests/TalkLiveTests"],
                          cwd=REPO, env=env, stdout=open(OUT / "xcodebuild.log", "w"), stderr=subprocess.STDOUT)
    while ui.poll() is None:
        for need in shots.glob("need-*"):
            what = need.name[5:]
            if what == "edit":  # a terminal edit, mid-proposal
                p = HOME / "SOUL.md"
                p.write_text(p.read_text().rstrip("\n") + "\n- Edited in a terminal.\n")
            if what.startswith("host-"):
                (shots / f"{what}.md").write_text((HOME / "SOUL.md").read_text())
            (shots / f"{what}-ok").touch()
            need.unlink()
        time.sleep(0.5)
    stop.set()
    log_text = (OUT / "xcodebuild.log").read_text()
    check("TalkLiveTests ran and passed in the simulator",
          ui.returncode == 0 and re.search(r"Executed [1-9]\d* tests?, with 0 failures", log_text),
          f"xcodebuild exit {ui.returncode}, log {OUT / 'xcodebuild.log'}")

    print("\n== On the host")
    soul = (HOME / "SOUL.md").read_text()
    (OUT / "host-SOUL.md").write_text(soul)
    check("SOUL.md got the new line from the talk", "- Calm and brief while you work." in soul, soul[-160:])
    check("the kept proposal wrote nothing", "Very short sentences" not in soul and "- Short sentences." in soul)
    check("the terminal edit survived the conflict", "- Edited in a terminal." in soul)
    check("Ask again proposed against the new file and landed", "- End with one question." in soul
          and soul.index("Edited in a terminal") < soul.index("End with one question"))
    mem = (HOME / "memories/MEMORY.md").read_text()
    check("the talked-out memory is forgotten, the rest stays", "Knee felt tight" not in mem and "Long runs" in mem, mem[:80])
    check("the key-shaped line was never overwritten", KEY in mem)
    j = cron.get_job(job)
    check("the schedule moved to 7:30 on weekdays", j["schedule_display"] == "30 7 * * 1-5", j["schedule_display"])
    logp = HOME / "yui/controls.log"
    log = [json.loads(x) for x in logp.read_text().splitlines()] if logp.exists() else []
    talked = [(x["op"], x["section"], x.get("proposal")) for x in log if x.get("via") == "talk"]
    check("every applied proposal logged with via talk and its id", len(talked) == 4
          and all(p for _, _, p in talked), talked)
    trash = HOME / "yui/controls-trash"
    check("the host kept the old copies in its trash", trash.exists() and len(list(trash.iterdir())) >= 4)
    (OUT / "host-controls.log").write_text(logp.read_text() if logp.exists() else "")
    (OUT / "host-served.json").write_text(json.dumps({"served": served, "proposals": proposals}, indent=1, default=str))
    taps = [x for x in served if x[0] == "tap"]
    check("one Keep it as is, and a conflict (Apply with no write) before Ask again",
          any(x[2] == "Keep it as is" for x in taps) and any(x[2] == "Apply" and not x[3] for x in taps)
          and any(x[0] == "again" and x[2] for x in served), taps)

    print("\n== No secrets")
    secret_turns = [x for x in turns if "readonly=yes" in x]
    (OUT / "turns.txt").write_text("\n\n=====\n\n".join(turns))
    check("the agent's turn for the token-shaped memory shows the placeholder, never the key",
          secret_turns and all(controls.HIDDEN in x and KEY not in x for x in secret_turns), len(secret_turns))
    sp = [o for s_, o in proposals if s_ == "secret"]
    check("its proposal was refused", sp and not any(o.get("ok") for o in sp), sp)
    rows_ = sql(f"select id, sender, kind, body, meta::text as meta from yui_messages where agent_id = '{agent}'")
    blob = json.dumps(rows_)
    keyish = controls.KEYISH.findall(blob)
    q = (f"select count(*)::int n from yui_messages where agent_id = '{agent}' and "
         f"(body ~* 'sk-ant|api03' or meta::text ~* 'sk-ant|api03' or body like '%{KEY[:24]}%')")
    n = sql(q)[0]["n"]
    (OUT / "secrets-query.txt").write_text(f"{q}\n-> {n}\n({len(rows_)} rows for the agent)\n")
    check(f"{len(rows_)} rows for the agent; nothing key-shaped in yui_messages", len(rows_) > 10 and not keyish and n == 0,
          keyish[:3])
    attach_rows = [r for r in rows_ if r["sender"] == "user" and r["body"].startswith("[yui] attach ")]
    check("the phone sent attach lines, never the item text", attach_rows
          and all(len(r["body"].split("\n", 1)[0]) < 140 and "trail-running coach" not in r["body"] for r in attach_rows),
          len(attach_rows))
finally:
    stop.set()
    sql(f"delete from yui_users where id = '{O}'; delete from yui_pair_attempts where created_at > now() - interval '1 hour'")
    shutil.rmtree(HOME, ignore_errors=True)

print(f"\nshots: {shots}\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)

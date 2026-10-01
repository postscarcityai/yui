#!/usr/bin/env python3
"""YUI-94 end to end: a group thread with two real hosts on this Mac.

A throwaway account gets three agents. Alpha and Bravo are each served by the
real `yui` platform adapter under Hermes' real BasePlatformAdapter, in their
own processes with their own connector. Cleo is paired, then stopped: offline.
The agents are scripted, and answer from the LAST line of what they are asked
(the words, under the group header and the quote), so the checks are exact:
  - Alpha: "Asking @bravo about it." when asked to ask bravo, else "Alpha here."
  - Bravo: "Box squats instead of back squats, easier on the knee. @alpha over
    to you." and, when the ask says slow, after eight seconds.

The group is Alpha (lead), Bravo and Cleo, max hops 1. The checks:
  1. the person talks to the group, no @: the lead (Alpha) answers, Bravo never
     asked; @Bravo: only Bravo answers;
  2. Alpha hands off to Bravo (a handoff row), Bravo's @alpha goes past the hop
     budget: a guard row, held, Alpha not asked;
  3. Let it: Alpha is asked, answers, and the chain ends;
  4. @Cleo: the offline line, in Cleo's name;
  5. Stop while Bravo works a slow ask: one Stopped line, and Bravo's @alpha
     hands nothing on.

Without --sim the script plays the app over REST (the same calls GroupClient
makes). With --sim the phone does it: YuiUITests/GroupTests makes the group in
the New group sheet and drives the thread, light then dark, and the script
judges the rows afterwards.

    python3 supabase/tests/group_e2e.py [--out /tmp/yui94-proof] [--sim <udid>]

Needs the Hermes venv at ~/.hermes/hermes-agent and a Supabase access token
like the other supabase/tests. The account is deleted at the end.
"""
import argparse, asyncio, hashlib, json, os, secrets, signal, subprocess, sys, tempfile, time, uuid
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
HERMES = Path.home() / ".hermes/hermes-agent"
BRAVO = "Box squats instead of back squats, easier on the knee. @alpha over to you."

ap = argparse.ArgumentParser()
ap.add_argument("--out", default="/tmp/yui94-proof")
ap.add_argument("--sim", help="simulator udid: the phone drives the group (YuiUITests/GroupTests)")
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
        last = event.text.strip().splitlines()[-1].lower()
        if name == "bravo":
            if "slow" in last:
                await asyncio.sleep(8)
            return BRAVO
        if "ask bravo" in last:
            return "Asking @bravo to go slow." if "slow" in last else "Asking @bravo about it."
        return "Alpha here."

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
# A phone this new: the newest app_build on the account is above group_min_build.
sql(f"insert into yui_devices(user_id, name, apns_token, app_build) values ('{T}', 'group e2e phone', '{hashlib.sha256(T.encode()).hexdigest()}', 999999)")
tok = mint(T, ttl=3600)
hosts, homes, ids, cts = {}, {}, {}, {}
GID = None


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


def group_rows():
    s, r = rest("GET", f"yui_messages?select=id,agent_id,sender,kind,body,meta,created_at,delivered_at,handled_at"
                       f"&thread_id=eq.{GID}&order=created_at.asc,id.asc", tok)
    assert s == 200, (s, r)
    return r


def g(row):
    return (row.get("meta") or {}).get("group") or {}


def guards(state=None):
    return [m for m in group_rows() if isinstance(g(m).get("guard"), dict) and (state is None or g(m)["guard"]["state"] == state)]


def handoffs(to=None):
    return [m for m in group_rows() if m["sender"] == "user" and "from" in g(m) and (to is None or m["agent_id"] == ids[to])]


def asked(name, words):
    """A turn whose own words (the last line, under the header and quote) are `words`: not mere context."""
    return any(t.strip().splitlines()[-1] == words for t in turns(name))


def agent_says(name):
    return [m for m in group_rows() if m["sender"] == "agent" and m["agent_id"] == ids[name]
            and not ({"guard", "status"} & set(g(m)))]


def statuses():
    return [m for m in group_rows() if m["sender"] == "agent" and "status" in g(m)]


def fresh_rt():
    rt = secrets.token_urlsafe(32)
    sql(f"insert into yui_sessions(user_id, refresh_hash, expires_at) values "
        f"('{T}', '{hashlib.sha256(rt.encode()).hexdigest()}', now() + interval '1 day')")
    return rt


def post(body, agent, meta=None, thread=True):
    row = {"id": str(uuid.uuid4()), "user_id": T, "agent_id": ids[agent], "sender": "user", "body": body, "kind": "text"}
    if thread:
        row["thread_id"] = GID
    if meta is not None:
        row["meta"] = meta
    s, r = rest("POST", "yui_messages", tok, row, prefer="return=minimal")
    assert s in (200, 201, 204), (s, r)
    return row["id"]


def say(words, to=None):
    """What GroupClient.say sends: the words, the addressed ids in meta.group.to, any member as agent."""
    to = [ids[n] for n in (to or [])]
    return post(words, (to or [None])[0] and next(n for n in ids if ids[n] == to[0]) or "alpha", {"group": {"to": to}})


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
                         "-destination", f"id={args.sim}", "-derivedDataPath", "/tmp/yui94-dd",
                         "-only-testing:YuiUITests/GroupTests"],
                        cwd=REPO, env=env, stdout=open(OUT / "xcodebuild.log", "w"), stderr=subprocess.STDOUT)
    text = (OUT / "xcodebuild.log").read_text()
    check("GroupTests ran and passed in the simulator",
          ui.returncode == 0 and "Executed 1 test, with 0 failures" in text,
          f"xcodebuild exit {ui.returncode}, log {OUT / 'xcodebuild.log'}")


try:
    for name in ("alpha", "bravo", "cleo"):
        s, r = fn("yui-agents", {"action": "create", "name": name.title(), "pair": True}, tok)
        ids[name] = r["agent"]["id"]
        s2, p = fn("yui-connect", {"action": "pair", "code": r["pairing"]["code"], "remote_ref": name,
                                   "host_name": f"Group test host {name}", "kind": "hermes"})
        assert (s, s2) == (200, 200), (s, r, s2, p)
        cts[name] = p["connector_token"]
        homes[name] = Path(tempfile.mkdtemp(prefix=f"yui-group-e2e-{name}-"))
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

    if args.sim:
        print("== the phone makes the group and drives it (simulator)")
        phone()
        s, r = rest("GET", "yui_threads?select=id,title,lead,max_hops,archived_at&order=created_at.asc", tok)
        GID = r[0]["id"] if r else None
        check("the New group sheet made one group, Race week, Alpha leads",
              len(r) == 1 and r[0]["title"] == "Race week" and r[0]["lead"] == ids["alpha"], f"{r}")
    else:
        print("== the app (REST) makes the group")
        GID = str(uuid.uuid4())
        s, r = rest("POST", "yui_threads", tok, {"id": GID, "user_id": T, "title": "Race week", "lead": ids["alpha"],
                                                  "max_hops": 1}, prefer="return=minimal")
        assert s in (200, 201, 204), (s, r)
        s, r = rest("POST", "yui_thread_members", tok, [{"thread_id": GID, "agent_id": ids[n], "user_id": T}
                                                         for n in ("bravo", "cleo")], prefer="return=minimal")
        assert s in (200, 201, 204), (s, r)
        say("How did I sleep?")
        wait(lambda: agent_says("alpha"), 60, "the lead's answer")
        say("@Bravo does this fit my knee?", to=["bravo"])
        wait(lambda: agent_says("bravo"), 60, "bravo's answer")
        say("@Alpha please ask bravo about Sunday", to=["alpha"])
        wait(lambda: guards("held"), 90, "the guard row")
        gr = guards("held")[0]
        post(f"[yui] group continue guard={gr['id']}", "alpha", {"group": {"control": "continue", "guard": gr["id"]}})
        wait(lambda: guards("continued"), 30, "the guard read continued")
        wait(lambda: len(agent_says("alpha")) >= 3, 60, "alpha answering the handoff")
        say("@Cleo are you there?", to=["cleo"])
        wait(lambda: statuses(), 30, "cleo's status line")
        say("@Alpha please ask bravo slow", to=["alpha"])
        wait(lambda: handoffs("bravo") and len(handoffs("bravo")) >= 2, 60, "the slow handoff reaching bravo")
        time.sleep(1)
        post("[yui] group stop", "alpha", {"group": {"control": "stop"}})

    if GID is None:
        raise SystemExit("no group to judge")
    time.sleep(12)  # the slow turn finishes, and whatever it hands on would land
    rows = group_rows()
    people = [m for m in rows if m["sender"] == "user" and "words" in g(m)]
    check("the person's rows keep the words apart from the quote", all(g(m)["words"] and "[yui]" not in g(m)["words"] for m in people),
          f"{[g(m).get('words') for m in people]}")

    first = next((m for m in people if g(m)["words"].startswith("How did I sleep")), None)
    check("no @: the lead was asked, and only the lead", first is not None and first["agent_id"] == ids["alpha"]
          and asked("alpha", "How did I sleep?") and not asked("bravo", "How did I sleep?"), f"{turns('bravo')}")
    knee = [m for m in people if "does this fit my knee" in g(m)["words"]]
    check("@Bravo: Bravo was asked, Alpha never was",
          len(knee) == 1 and knee[0]["agent_id"] == ids["bravo"]
          and asked("bravo", "@Bravo does this fit my knee?")
          and not asked("alpha", "@Bravo does this fit my knee?"), f"{turns('alpha')}")
    check("Bravo's answer is in the group, in Bravo's name", any(m["body"] == BRAVO for m in agent_says("bravo")))

    ho = handoffs("bravo")
    check("Alpha's @bravo is a handoff row to Bravo, with the ask and the asker", ho
          and g(ho[0])["from"] == ids["alpha"] and g(ho[0])["from_name"] == "Alpha" and g(ho[0]).get("msg"), f"{ho[:1]}")
    gs = guards()
    check("Bravo's @alpha went past max hops: a guard row, in Bravo's thread, to Alpha",
          gs and gs[0]["agent_id"] == ids["bravo"] and g(gs[0])["guard"]["to"] == ids["alpha"]
          and g(gs[0])["guard"]["reason"] == "hops", f"{gs[:1]}")
    check("Let it: the guard reads continued, and Alpha was asked then",
          guards("continued") and handoffs("alpha") and any("over to you" in t.splitlines()[-1] for t in turns("alpha")),
          f"{[g(m)['guard']['state'] for m in guards()]}")
    held = [m for m in guards("held")]
    check("the chain ended: nothing is left held", not held, f"{held}")

    st = statuses()
    check("Cleo (offline) says so in one line, in Cleo's name",
          any(m["body"] == "Cleo is offline. It gets this when it's back." and g(m)["about"] == ids["cleo"] for m in st),
          f"{[m['body'] for m in st]}")

    stopped = [m for m in st if g(m).get("status") == "stopped"]
    check("Stop: one Stopped line in the group", len(stopped) == 1 and stopped[0]["body"].startswith("Stopped."),
          f"{[m['body'] for m in stopped]}")
    after = [m for m in rows if m["created_at"] > stopped[0]["created_at"]] if stopped else []
    check("Bravo's @alpha after Stop handed nothing on (no handoff, no guard)",
          not [m for m in after if (m["sender"] == "user" and "from" in g(m)) or isinstance(g(m).get("guard"), dict)],
          f"{[(m['sender'], m['body'][:40]) for m in after]}")
    check("the slow ask still got its answer from Bravo", len(agent_says("bravo")) >= 3, f"{len(agent_says('bravo'))}")
    (OUT / "alpha-turns.txt").write_text("\n----\n".join(turns("alpha")))
    (OUT / "bravo-turns.txt").write_text("\n----\n".join(turns("bravo")))
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
               f"(select count(*) from yui_agents where user_id='{T}') + (select count(*) from yui_threads where user_id='{T}') as n")[0]["n"]
    check("test account deleted, zero rows left", left == 0, f"{left}")

print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)

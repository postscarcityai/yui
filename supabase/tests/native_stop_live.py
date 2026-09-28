#!/usr/bin/env python3
"""YUI-190, live on yuigui: Stop a hosted agent's turn, and the app through kills, relaunches and switches.

Makes a throwaway account. First on the wire: a long ask to Basil, then the person's stop
control once the runtime has picked it up; the turn ends with nothing written (no answer row,
the ask handled, one stop answer). Then in the app (--sim): YuiUITests/StopLiveTests asks Yui
for a week of meals, taps the stop square, and this script checks the database meanwhile. Then
five kills and relaunches, each on a different agent of the crew, with a shot each and the app
still running; the last one reopens Yui, where Stopped is still in the record. The account is
deleted at the end.

    python3 supabase/tests/native_stop_live.py --out /tmp/yui190-live --sim <udid> --dd <derived data>
"""
import argparse, hashlib, os, secrets, subprocess, sys, time, uuid
from pathlib import Path
exec(open(Path(__file__).resolve().parent.joinpath("agents_test.py")).read().split("results = []")[0])

ap = argparse.ArgumentParser()
ap.add_argument("--out", default="/tmp/yui190-live")
ap.add_argument("--sim")
ap.add_argument("--dd", help="derived data holding a build-for-testing of this tree")
ap.add_argument("--appearance", default="light", choices=["light", "dark"])
args = ap.parse_args()
OUT = Path(args.out); OUT.mkdir(parents=True, exist_ok=True)
DEV = {**os.environ, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"}

results = []
def check(name, ok, detail=""):
    results.append(ok); print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  [{detail}]" if detail else ""), flush=True)
def simctl(*a): return subprocess.run(["xcrun", "simctl", *a], env=DEV, capture_output=True, text=True)
def one(q): return sql(q)[0]
def answers(agent_id, mid, after=None):
    # after: a stop row's id. Only an answer written after the stop is a late one; one written before it was
    # finished before the person tapped, and stays.
    late = f" and created_at > (select created_at from yui_messages where id='{after}')" if after else ""
    return sql(f"select body from yui_messages where agent_id='{agent_id}' and sender='agent' and kind='text' "
               f"and coalesce(meta->'turn','[]'::jsonb) ? '{mid}'" + late)
def wait_until(fn, seconds, step=1.0):
    end = time.time() + seconds
    while time.time() < end:
        v = fn()
        if v: return v
        time.sleep(step)
    return None
def stop_row(agent_id):
    sid = str(uuid.uuid4())
    rest("POST", "yui_messages", mint(T, ttl=900), {"id": sid, "user_id": T, "agent_id": agent_id, "sender": "user", "body": "stop",
                                                    "kind": "control", "meta": {"op": "stop"}}, prefer="return=minimal")
    return sid

T = str(uuid.uuid4())
sql(f"insert into yui_users(id, apple_sub, timezone) values ('{T}','test.{T}','America/New_York')")
try:
    s, _ = fn("yui-agents", {"action": "list"}, mint(T))
    agents = {a["name"]: a["id"] for a in sql(f"select id, name from yui_agents where user_id='{T}' and kind='hosted' order by sort, created_at")}
    check("a new account gets the crew", s == 200 and {"Yui", "Basil"} <= set(agents), f"{sorted(agents)}")

    # 1. On the wire: Basil mid-turn, then Stop.
    basil = agents["Basil"]
    mid = str(uuid.uuid4())
    rest("POST", "yui_messages", mint(T, ttl=900), {"id": mid, "user_id": T, "agent_id": basil, "sender": "user", "kind": "text",
         "body": "Write me a detailed seven day meal plan with recipes for every meal and a full grocery list."}, prefer="return=minimal")
    picked = wait_until(lambda: one(f"select delivered_at is not null as d from yui_messages where id='{mid}'")["d"], 60)
    check("the runtime picks the ask up", bool(picked))
    time.sleep(0.5)
    sid = stop_row(basil)
    ans = wait_until(lambda: sql(f"select meta from yui_messages where agent_id='{basil}' and sender='agent' and kind='control' "
                                 f"and meta->>'for'='{sid}'"), 30)
    check("the stop is answered as a control, never a turn", bool(ans) and ans[0]["meta"].get("op") == "stop", f"{ans}")
    handled = wait_until(lambda: one(f"select handled_at is not null as h from yui_messages where id='{mid}'")["h"], 30)
    check("the ask is handled", bool(handled))
    early = answers(basil, mid)
    check("the ask was still being answered when the stop landed", not early, f"{[r['body'][:80] for r in early]}")
    time.sleep(45)
    late = answers(basil, mid, sid)
    check("no answer lands for the stopped ask (45 s)", not late, f"{[r['body'][:80] for r in late]}")
    other = sql(f"select body from yui_messages where agent_id='{basil}' and sender='agent' and kind='text' and created_at > "
                f"(select created_at from yui_messages where id='{mid}') and coalesce(meta->>'bridge','') <> ''")
    check("and no 'can't reach its model' either", not other, f"{[r['body'][:80] for r in other]}")

    # A new ask after the stop is answered as usual.
    m2 = str(uuid.uuid4())
    rest("POST", "yui_messages", mint(T, ttl=900), {"id": m2, "user_id": T, "agent_id": basil, "sender": "user", "kind": "text",
         "body": "Thanks. What's one quick high protein breakfast?"}, prefer="return=minimal")
    got = wait_until(lambda: answers(basil, m2), 120, 3)
    check("the next ask gets its answer", bool(got), (got or [{}])[0].get("body", "")[:80].replace("\n", " | "))

    if args.sim:
        # 2. In the app: ask Yui, tap the stop square.
        yui = agents["Yui"]
        rt = secrets.token_urlsafe(32)
        sql(f"insert into yui_sessions(user_id, refresh_hash, expires_at) values ('{T}','{hashlib.sha256(rt.encode()).hexdigest()}', now() + interval '1 day')")
        simctl("ui", args.sim, "appearance", args.appearance)
        simctl("terminate", args.sim, "com.yuigui.app")
        for f in ("picked", "stopped", "checked"): (OUT / f).unlink(missing_ok=True)
        env = {**DEV, "TEST_RUNNER_YUI_RT": rt, "TEST_RUNNER_YUI_USER": T, "TEST_RUNNER_YUI_AGENT": yui,
               "TEST_RUNNER_YUI_SHOTS": str(OUT), "TEST_RUNNER_YUI_APPEARANCE": args.appearance}
        log = open(OUT / "xcodebuild.log", "w")
        ui = subprocess.Popen(["xcodebuild", "test-without-building", "-scheme", "Yui", "-destination", f"platform=iOS Simulator,id={args.sim}",
                               "-derivedDataPath", args.dd, "-only-testing:YuiUITests/StopLiveTests"],
                              cwd=Path(__file__).resolve().parents[2], env=env, stdout=log, stderr=subprocess.STDOUT)
        ask = wait_until(lambda: sql(f"select id from yui_messages where agent_id='{yui}' and sender='user' and kind='text' "
                                     f"and body like 'Plan every meal%' and delivered_at is not null"), 180, 1)
        check("the app's ask reaches hosted Yui", bool(ask))
        (OUT / "picked").write_text("")
        wait_until(lambda: (OUT / "stopped").exists(), 60)
        aid = ask[0]["id"] if ask else ""
        st = wait_until(lambda: sql(f"select id, handled_at from yui_messages where agent_id='{yui}' and sender='user' and kind='control' "
                                    f"and meta->>'op'='stop'"), 30)
        check("the stop square sent one stop row", bool(st) and len(st) == 1, f"{st}")
        wait_until(lambda: one(f"select handled_at is not null as h from yui_messages where id='{aid}'")["h"], 30)
        time.sleep(45)
        late = answers(yui, aid, st[0]["id"] if st else None)
        check("no answer lands for the app's stopped ask", not late, f"{[r['body'][:80] for r in late]}")
        (OUT / "checked").write_text("")
        ui.wait(timeout=300)
        check("StopLiveTests passed in the app", ui.returncode == 0, f"exit {ui.returncode}, {OUT / 'xcodebuild.log'}")

        # 3. Kill, relaunch, switch: five agents, then Yui again with Stopped still there.
        crew = [n for n in agents if n != "Yui"][:5]
        simctl("boot", args.sim)  # xcodebuild can leave the sim shut down after the UI test
        simctl("bootstatus", args.sim, "-b")
        for i, name in enumerate(crew + ["Yui"], 1):
            simctl("terminate", args.sim, "com.yuigui.app")
            r = simctl("launch", args.sim, "com.yuigui.app", "-selectedAgent", agents[name], "-yuiStageFirst", "YES", "-appearance", args.appearance)
            time.sleep(10)
            shot = OUT / f"switch-{i:02d}-{name.lower()}.png"
            simctl("io", args.sim, "screenshot", str(shot))
            alive = "com.yuigui.app" in simctl("spawn", args.sim, "launchctl", "list").stdout
            check(f"relaunch {i} on {name}: running", r.returncode == 0 and alive and shot.exists(), shot.name)
        crashes = [p.name for p in Path.home().joinpath("Library/Logs/DiagnosticReports").glob("Yui*")
                   if p.stat().st_mtime > time.time() - 900]
        check("no crash reports", not crashes, f"{crashes}")
finally:
    if args.sim: simctl("terminate", args.sim, "com.yuigui.app")
    sql(f"delete from yui_users where id = '{T}'")
    left = sql("select " + " + ".join(f"(select count(*) from {t} where user_id = '{T}')" for t in
               ["yui_agents", "yui_messages", "yui_sessions", "yui_native_jobs"]) + " as n")
    check("throwaway account deleted, zero rows left", left[0]["n"] == 0, f"{left}")

print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)

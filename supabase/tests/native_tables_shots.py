#!/usr/bin/env python3
"""YUI-170: each agent's own tables, in the app, on a throwaway account.

Makes a new account (the crew arrives with its starter tables), asks the live native
runtime the table asks (add milk to my groceries, delete the coffee row, log today's bench,
what did I eat this week, make me a table for my reading list), waits for each answer,
then relaunches the installed Yui on each thread and screenshots the chat. Checks each
answer hit the agent's tables. The account is deleted at the end.

    python3 supabase/tests/native_tables_shots.py --sim <udid> --out /tmp/yui170-shots [--appearance dark]
"""
import argparse, hashlib, json, os, secrets, subprocess, sys, time, uuid
from pathlib import Path
exec(open(Path(__file__).resolve().parent.joinpath("agents_test.py")).read().split("results = []")[0])

ap = argparse.ArgumentParser()
ap.add_argument("--sim", required=True)
ap.add_argument("--out", default="/tmp/yui170-shots")
ap.add_argument("--appearance", default="light", choices=["light", "dark"])
args = ap.parse_args()
OUT = Path(args.out); OUT.mkdir(parents=True, exist_ok=True)
DEV = {**os.environ, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"}

results = []
def check(name, ok, detail=""):
    results.append(ok); print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  [{detail}]" if detail else ""), flush=True)
def simctl(*a): return subprocess.run(["xcrun", "simctl", *a], env=DEV, capture_output=True, text=True)

T = str(uuid.uuid4())
sql(f"insert into yui_users(id, apple_sub, timezone) values ('{T}','test.{T}','America/New_York')")
answers = {}
def ask(agent_id, body, kind="text", wait=240):
    mid = str(uuid.uuid4())
    s, _ = rest("POST", "yui_messages", mint(T, ttl=900), {"id": mid, "user_id": T, "agent_id": agent_id, "sender": "user", "body": body, "kind": kind},
                prefer="return=minimal")
    end = time.time() + wait
    while time.time() < end:
        time.sleep(4)
        if sql(f"select handled_at is not null as h from yui_messages where id='{mid}'")[0]["h"]: break
    rows = sql(f"select body from yui_messages where agent_id='{agent_id}' and sender='agent' and coalesce(meta->'turn','[]'::jsonb) ? '{mid}' order by created_at")
    return "\n".join(r["body"] for r in rows)
def rows_of(agent_id, table):
    return sql(f"select key, vals from yui_native_table_rows where agent_id='{agent_id}' and tname='{table}' order by pos")

try:
    s, _ = fn("yui-agents", {"action": "list"}, mint(T))
    agents = {a["name"]: a["id"] for a in sql(f"select id, name from yui_agents where user_id='{T}' and kind='hosted'")}
    check("a new account gets the crew", s == 200 and {"Yui", "Arnold", "Basil"} <= set(agents), f"{sorted(agents)}")
    yui, arnold, basil = agents["Yui"], agents["Arnold"], agents["Basil"]
    # Three meals this week, so "what did I eat" has something to read.
    sql(f"insert into yui_native_table_rows (agent_id, user_id, tname, key, vals) values "
        f"('{basil}','{T}','meals','e1', jsonb_build_object('Day', (now() at time zone 'America/New_York')::date - 2, 'Meal','Breakfast','Food','Oatmeal with berries','Cal',300,'Protein',10,'Carbs',54,'Fat',5)),"
        f"('{basil}','{T}','meals','e2', jsonb_build_object('Day', (now() at time zone 'America/New_York')::date - 1, 'Meal','Lunch','Food','Chicken bowl','Cal',640,'Protein',52,'Carbs',60,'Fat',18)),"
        f"('{basil}','{T}','meals','e3', jsonb_build_object('Day', (now() at time zone 'America/New_York')::date - 1, 'Meal','Dinner','Food','Salmon and rice','Cal',720,'Protein',40,'Carbs',70,'Fat',26))")
    answers["yui-milk"] = a = ask(yui, "Add milk to my groceries.")
    check("add milk: a milk row in Yui's groceries", any("milk" in (r["vals"].get("Item") or "").lower() for r in rows_of(yui, "groceries")), a[:120])
    answers["yui-coffee"] = a = ask(yui, "Delete the coffee row from my groceries table.")
    held = sql(f"select meta->'native'->'held'->>'id' as id from yui_messages where agent_id='{yui}' and sender='agent' and meta->'native' ? 'held' order by created_at desc limit 1")
    check("delete coffee: a Delete or Keep button, nothing deleted yet", bool(held) and any(r["key"] == "coffee" for r in rows_of(yui, "groceries")), a[-160:])
    answers["yui-reading"] = a = ask(yui, "Make me a table for my reading list. Start with Dune and Project Hail Mary.")
    check("reading list: a new table of Yui's own", bool(sql(f"select 1 from yui_native_tables where agent_id='{yui}' and name ~* 'read|book'")), a[:120])
    answers["arnold-bench"] = a = ask(arnold, "Log today's bench: 3 sets of 8 at 135.")
    check("log today's bench: a session row", any("bench" in (r["vals"].get("Exercise") or "").lower() for r in rows_of(arnold, "sessions")), a[:120])
    answers["basil-week"] = a = ask(basil, "What did I eat this week?")
    check("what did I eat: answered from the meals table", any(w in a.lower() for w in ["oat", "chicken", "salmon", "1,660", "1660"]), a[:120])
    (OUT / "answers.json").write_text(json.dumps(answers, indent=2))

    rt = secrets.token_urlsafe(32)
    sql(f"insert into yui_sessions(user_id, refresh_hash, expires_at) values ('{T}','{hashlib.sha256(rt.encode()).hexdigest()}', now() + interval '1 day')")
    simctl("ui", args.sim, "appearance", args.appearance)
    simctl("terminate", args.sim, "com.yuigui.app")
    r = simctl("launch", args.sim, "com.yuigui.app", "-yuiRefreshToken", rt, "-yuiUserID", T, "-appearance", args.appearance)
    check("the app launches signed in", r.returncode == 0, r.stderr.strip()[:120])
    time.sleep(14)
    for name, aid in [("yui", yui), ("arnold", arnold), ("basil", basil)]:
        simctl("terminate", args.sim, "com.yuigui.app")
        simctl("launch", args.sim, "com.yuigui.app", "-selectedAgent", aid, "-yuiStageFirst", "NO", "-appearance", args.appearance)
        time.sleep(10)
        shot = OUT / f"{name}-tables-{args.appearance}.png"
        r = simctl("io", args.sim, "screenshot", str(shot))
        check(f"{name}'s thread, shot", r.returncode == 0 and shot.exists() and shot.stat().st_size > 50_000, shot.name)
finally:
    simctl("terminate", args.sim, "com.yuigui.app")
    sql(f"delete from yui_users where id = '{T}'")
    left = sql("select " + " + ".join(f"(select count(*) from {t} where user_id = '{T}')" for t in
               ["yui_agents", "yui_messages", "yui_sessions", "yui_connectors", "yui_devices", "yui_native_tables", "yui_native_table_rows"]) + " as n")
    check("throwaway account deleted, zero rows left", left[0]["n"] == 0, f"{left}")

print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)

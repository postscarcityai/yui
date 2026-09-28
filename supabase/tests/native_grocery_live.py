#!/usr/bin/env python3
"""YUI-188, live on yuigui: Basil's grocery list just works for a Basil made before it existed.

Chris's Basil was made with YUI-170's starter set (foods and meals only), so "put the goods on
my grocery list" came back as "(I couldn't do all of that: a table change didn't fit (put: no
table "groceries"); ...)" three times over, in stage-sized type.

Makes a throwaway account, turns its Basil back into that old Basil (foods and meals, nothing
else), shows the old reply in the app (before), then talks to the live runtime: a sample day,
then "Yeah, exactly. Put the goods on my grocery list." Checks the groceries table arrived with
its starter rows, the goods landed on it, the reply carries no slip and patches his Groceries
page, a row taken off never comes back, and Yui makes a table of her own from a put. With --sim,
screenshots before and after (chat and stage). The account is deleted at the end.

    python3 supabase/tests/native_grocery_live.py --out /tmp/yui188-live [--sim <udid>]
"""
import argparse, hashlib, json, os, re, secrets, subprocess, sys, time, uuid
from pathlib import Path
exec(open(Path(__file__).resolve().parent.joinpath("agents_test.py")).read().split("results = []")[0])

ap = argparse.ArgumentParser()
ap.add_argument("--out", default="/tmp/yui188-live")
ap.add_argument("--sim")
ap.add_argument("--appearance", default="light", choices=["light", "dark"])
args = ap.parse_args()
OUT = Path(args.out); OUT.mkdir(parents=True, exist_ok=True)
DEV = {**os.environ, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"}

results = []
def check(name, ok, detail=""):
    results.append(ok); print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  [{detail}]" if detail else ""), flush=True)
def simctl(*a): return subprocess.run(["xcrun", "simctl", *a], env=DEV, capture_output=True, text=True)

# What Chris's Basil answered on Sep 27 at 23:55 (yui_messages, his account), word for word.
OLD = ('```yui\ncard "Grocery list" body="No table called groceries yet."\n```\n\nAll set. Tap items as you grab them. '
       'Want me to save this as a reusable weekly grocery list?\n\n(I couldn\'t do all of that: a table change didn\'t fit '
       '(put: no table "groceries"); a table change didn\'t fit (put: no table "groceries"); a table change didn\'t fit '
       '(put: no table "groceries").)')

T = str(uuid.uuid4())
sql(f"insert into yui_users(id, apple_sub, timezone) values ('{T}','test.{T}','America/New_York')")
log = {}
def ask(agent_id, body, wait=240):
    mid = str(uuid.uuid4())
    rest("POST", "yui_messages", mint(T, ttl=900), {"id": mid, "user_id": T, "agent_id": agent_id, "sender": "user", "body": body, "kind": "text"},
         prefer="return=minimal")
    end = time.time() + wait
    while time.time() < end:
        time.sleep(4)
        if sql(f"select handled_at is not null as h from yui_messages where id='{mid}'")[0]["h"]: break
    rows = sql(f"select body from yui_messages where agent_id='{agent_id}' and sender='agent' and coalesce(meta->'turn','[]'::jsonb) ? '{mid}' order by created_at")
    return "\n".join(r["body"] for r in rows)
def lit(v): return "'" + str(v).replace("'", "''") + "'"
def rows_of(agent_id, table):
    return sql(f"select key, vals from yui_native_table_rows where agent_id='{agent_id}' and tname='{table}' order by pos")
def tables_of(agent_id):
    return [r["name"] for r in sql(f"select name from yui_native_tables where agent_id='{agent_id}' order by created_at, name")]
def shots(agent_id, tag):
    if not args.sim: return
    for stage in ("NO", "YES"):
        simctl("terminate", args.sim, "com.yuigui.app")
        simctl("launch", args.sim, "com.yuigui.app", "-selectedAgent", agent_id, "-yuiStageFirst", stage, "-appearance", args.appearance)
        time.sleep(12)
        shot = OUT / f"basil-{tag}-{'stage' if stage == 'YES' else 'chat'}-{args.appearance}.png"
        r = simctl("io", args.sim, "screenshot", str(shot))
        check(f"{tag}: {'stage' if stage == 'YES' else 'chat'} shot", r.returncode == 0 and shot.exists() and shot.stat().st_size > 50_000, shot.name)

try:
    s, _ = fn("yui-agents", {"action": "list"}, mint(T))
    agents = {a["name"]: a["id"] for a in sql(f"select id, name from yui_agents where user_id='{T}' and kind='hosted'")}
    check("a new account gets the crew", s == 200 and {"Yui", "Basil"} <= set(agents), f"{sorted(agents)}")
    yui, basil = agents["Yui"], agents["Basil"]
    # Back to the Basil Chris has: YUI-170's starter set, seeded, no list of what he was given.
    sql(f"delete from yui_native_tables where agent_id='{basil}' and name not in ('foods','meals')")
    sql(f"update yui_native_profiles set profile = profile - 'seededTables' - 'mealScreens' where agent_id='{basil}'")
    check("the old Basil: foods and meals only", tables_of(basil) == ["foods", "meals"], f"{tables_of(basil)}")

    if args.sim:
        rt = secrets.token_urlsafe(32)
        sql(f"insert into yui_sessions(user_id, refresh_hash, expires_at) values ('{T}','{hashlib.sha256(rt.encode()).hexdigest()}', now() + interval '1 day')")
        simctl("ui", args.sim, "appearance", args.appearance)
        simctl("terminate", args.sim, "com.yuigui.app")
        r = simctl("launch", args.sim, "com.yuigui.app", "-yuiRefreshToken", rt, "-yuiUserID", T, "-appearance", args.appearance)
        check("the app launches signed in", r.returncode == 0, r.stderr.strip()[:120])
        time.sleep(14)
        # Before: his ask and the reply he got, as rows in the thread.
        # Handled as it goes in, so the runtime never answers it.
        sql(f"insert into yui_messages(user_id, agent_id, sender, kind, body, handled_at, delivered_at) values "
            f"('{T}','{basil}','user','text','Yeah, exactly. Put the goods on my grocery list.', now(), now())")
        time.sleep(1)
        before = str(uuid.uuid4())
        sql(f"insert into yui_messages(id, user_id, agent_id, sender, kind, body) values ('{before}','{T}','{basil}','agent','text',{lit(OLD)})")
        shots(basil, "before")
        sql(f"delete from yui_messages where agent_id='{basil}'")

    log["sample-day"] = a = ask(basil, "I like mostly fish, but also chicken, ground beef, white rice, potatoes, and light vegetables. Give me a sample day.")
    check("a sample day comes back", bool(a.strip()), a[:100].replace("\n", " | "))
    log["grocery"] = a = ask(basil, "Yeah, exactly. Put the goods on my grocery list.")
    names = tables_of(basil)
    check("his grocery list arrived (a starter table he never had)", "groceries" in names, f"{names}")
    g = rows_of(basil, "groceries")
    starters = {"greek-yogurt", "egg", "spinach", "chicken-thigh", "rice", "berry"}
    check("with its starter rows, once", starters <= {r["key"] for r in g}, f"{[r['key'] for r in g]}")
    goods = [r["vals"].get("Item") for r in g if r["key"] not in starters]
    check("the goods landed on Groceries", len(goods) >= 2 and any(re.search(r"fish|salmon|cod|tilapia|tuna|potato|beef|chicken|rice|veg|broccoli|green", str(x), re.I) for x in goods), f"{goods}")
    check("no slip: no ops, no parentheses, no 'couldn't'", not re.search(r"I couldn't do all|didn't fit|no table|put:|Couldn't save", a), a[-200:].replace("\n", " | "))
    check("his Groceries page redraws", bool(re.search(r"^~aisle-|^~groc-left", a, re.M)), "")
    check("never the whole reply in words: the list is on a screen", "```yui" in a, "")
    shots(basil, "after")

    # A row they take off never comes back; the table is never seeded twice.
    sql(f"delete from yui_native_table_rows where agent_id='{basil}' and tname='groceries' and key='egg'")
    log["thanks"] = ask(basil, "Thanks!")
    check("a row taken off stays off", "egg" not in {r["key"] for r in rows_of(basil, "groceries")}, "")
    prof = sql(f"select profile->'seededTables' as s from yui_native_profiles where agent_id='{basil}'")[0]["s"] or []
    check("seededTables names his groceries", "groceries" in prof, f"{prof}")

    # An agent makes its own table.
    before_names = set(tables_of(yui))
    log["wine"] = a = ask(yui, "Keep a log of the wines I try. Tonight: a 2019 Rioja, 4 stars.")
    made = [n for n in tables_of(yui) if n not in before_names]
    check("Yui makes a table of her own", bool(made) and any(rows_of(yui, n) for n in made), f"{made}: {a[:100]}")
    check("and says nothing about a slip", not re.search(r"I couldn't do all|didn't fit|Couldn't save", a), "")
    (OUT / "answers.json").write_text(json.dumps(log, indent=2))
finally:
    if args.sim: simctl("terminate", args.sim, "com.yuigui.app")
    sql(f"delete from yui_users where id = '{T}'")
    left = sql("select " + " + ".join(f"(select count(*) from {t} where user_id = '{T}')" for t in
               ["yui_agents", "yui_messages", "yui_sessions", "yui_native_tables", "yui_native_table_rows"]) + " as n")
    check("throwaway account deleted, zero rows left", left[0]["n"] == 0, f"{left}")

print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)

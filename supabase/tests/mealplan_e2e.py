#!/usr/bin/env python3
"""Basil's tools (YUI-183), live on yuigui: plan my meals, a swap, the grocery list, Today and a meal fixed.

A throwaway account (never anyone's real one): the first list provisions the crew, and Basil's home
carries Today (calories and macros against his goal, what's up next, today's meals to fix), This
week's meals and Groceries by aisle, with his recipes and goal in his tables. Then, through
yui_messages the way the app writes them, with the real yui-native answering from the database trigger:

  1. "Plan my meals" -> one full-screen plan: what it aims for first, the questions last. No model.
  2. The plan's Send -> a week in `meal_plan` kept to the no-gos, the answers in `plan_prefs`, the grocery
     list filled by aisle, one reply: a deck of days (each meal a swap button) and the pages drawn.
  3. A meal tapped on This week -> swapped, kept to the no-gos, the list follows, the pages patched.
  4. "add oat milk and 2 avocados to my groceries" -> in their aisles; a tick says nothing and sets Got.
  5. "I ate it" on Today -> the planned meal in `meals`, Today patched; a meal tapped -> its fix plan;
     the Send halves it.
  6. None of it took a free turn or a model call.

The account is deleted at the end. Does NOT touch native_enabled.

    python3 supabase/tests/mealplan_e2e.py [--out DIR]
"""
import argparse, json, re, time, uuid
from pathlib import Path
exec(open(Path(__file__).resolve().parent.joinpath("agents_test.py")).read().split("results = []")[0])

ap = argparse.ArgumentParser()
ap.add_argument("--out", default="")
args = ap.parse_args()

results, log = [], {}
def check(name, ok, detail=""):
    results.append(bool(ok)); print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  [{str(detail)[:300]}]" if detail else ""), flush=True)

_sql = sql
def sql(q, tries=4):
    """The management API times out now and then; a poll should not end the run."""
    for i in range(tries):
        try: return _sql(q)
        except (OSError, RuntimeError) as e:
            if i == tries - 1: raise
            print(f"sql retry: {e}", flush=True); time.sleep(3)

def agent_rows(agent_id, since):
    return sql(f"select id, body, meta, created_at from yui_messages where agent_id='{agent_id}' and sender='agent' "
               f"and created_at > '{since}' order by created_at")
def rows_of(agent_id, table):
    return {r["key"]: r["vals"] for r in sql(f"select key, vals from yui_native_table_rows where agent_id='{agent_id}' and tname='{table}' order by pos")}
def send(agent_id, body, kind="text", meta=None):
    mid = str(uuid.uuid4())
    s, _ = rest("POST", "yui_messages", mint(T, ttl=900), {"id": mid, "user_id": T, "agent_id": agent_id, "sender": "user", "body": body,
                                                           "kind": kind, **({"meta": meta} if meta else {})}, prefer="return=minimal")
    return mid, s
def tap(agent_id, id, preset, value, line=None):
    return send(agent_id, line or f"[yui] {id} {preset}", "event", {"id": id, "preset": preset, "value": value})
def wait_reply(agent_id, since, turn, wait=90):
    end = time.time() + wait
    while time.time() < end:
        got = [r for r in agent_rows(agent_id, since) if turn in ((r["meta"] or {}).get("turn") or [])]
        if got: return got[-1]
        time.sleep(1)
    return None
def wait_handled(mid, wait=60):
    end = time.time() + wait
    while time.time() < end:
        r = sql(f"select handled_at from yui_messages where id='{mid}'")
        if r and r[0]["handled_at"]: return True
        time.sleep(1)
    return False
def now(): return sql("select now() as t")[0]["t"]
def fence(body):
    m = re.search(r"```yui\n([\s\S]*?)\n```", body or "")
    return m.group(1) if m else ""
def native(r):
    n = (r["meta"] or {}).get("native") if r else None
    return n if isinstance(n, dict) else {}
def no_model(r): return r is not None and "model" not in native(r)

NOGO = ["dairy", "nuts"]
T = str(uuid.uuid4())
sql(f"insert into yui_users(id, apple_sub, timezone) values ('{T}','test.{T}','America/New_York')")
try:
    s, r = fn("yui-agents", {"action": "list"}, mint(T))
    agents = {a["name"]: a["id"] for a in sql(f"select id, name from yui_agents where user_id='{T}' and kind='hosted'")}
    check("a new account gets the crew", s == 200 and "Basil" in agents, f"{sorted(agents)}")
    basil = agents["Basil"]
    home = sql(f"select body from yui_messages where agent_id='{basil}' and meta->>'native'='home'")
    hb = home[0]["body"] if home else ""
    log["home"] = hb
    check("his home: four shortcuts, Today with what's next and a meal picker, This week's meals, Groceries by aisle",
          hb.count("menu shortcut") == 4 and "choose@eaten" in hb and "card@next-meal" in hb and "card@week-plan" in hb
          and "list@aisle-produce" in hb and "save groceries" in hb, hb[:200])
    tabs = {t["name"]: t["n"] for t in sql(f"select t.name, (select count(*) from yui_native_table_rows r where r.agent_id=t.agent_id and r.tname=t.name) as n "
                                          f"from yui_native_tables t where t.agent_id='{basil}'")}
    check("his recipes, goal, plan and grocery tables ship with him", tabs.get("recipes") == 38 and tabs.get("goal") == 1
          and tabs.get("meal_plan") == 0 and tabs.get("groceries") == 6, tabs)
    turns = lambda: sql(f"select coalesce(sum(turns), 0) as n from yui_native_usage where user_id='{T}'")[0]["n"]
    turns0 = turns()

    # 1. Plan my meals
    since = now(); t0 = time.time()
    mid, s = send(basil, "Plan my meals")
    rep = wait_reply(basil, since, mid)
    secs = round(time.time() - t0, 1)
    body = rep["body"] if rep else ""
    log["plan"] = {"s": secs, "body": body}
    f = fence(body)
    steps = re.findall(r"^(page|choose|pick)(?:@(\S+))?", f, re.M)
    check("Plan my meals opens one full-screen flow, no model call", f.startswith("plan@mealplan ") and no_model(rep), f"{secs}s")
    check("what it aims for first, the questions last, one Send", steps and steps[0][0] == "page"
          and [x[1] for x in steps[1:]] == ["days", "meals", "likes", "avoid", "budget", "cook"] and 'submit="Plan my week"' in f, steps)
    check("the flow lands in under 10 seconds", secs < 10, f"{secs}s")

    # 2. The Send
    answers = {"days": "5 days", "meals": "3 meals", "likes": ["Chicken", "Mexican"], "avoid": ["Dairy", "Nuts"], "budget": "In between", "cook": "30 minutes"}
    since = now(); t0 = time.time()
    mid, s = tap(basil, "mealplan", "plan", {"plan": answers}, '[yui] mealplan plan plan.days="5 days" plan.meals="3 meals"')
    rep = wait_reply(basil, since, mid)
    body = rep["body"] if rep else ""
    log["planned"] = {"s": round(time.time() - t0, 1), "body": body}
    check("the Send is answered with no model call", no_model(rep) and body.startswith("Your 5 days are planned."), body[:80])
    plan = rows_of(basil, "meal_plan")
    recipes = rows_of(basil, "recipes")
    log["meal_plan"] = plan
    days = sorted({v["Day"] for v in plan.values()})
    check("a week in meal_plan: 5 days, 3 meals each", len(plan) == 15 and len(days) == 5, f"{len(plan)} rows, {days}")
    bad = [v["Name"] for v in plan.values() if any(t in recipes.get(v["Recipe"], {}).get("Tags", "") for t in NOGO)]
    check("never a no-go (dairy, nuts)", not bad, bad)
    prefs = rows_of(basil, "plan_prefs").get("last", {})
    check("the answers are kept for next time", prefs.get("Avoid") == "Dairy, Nuts" and prefs.get("Days") == 5, prefs)
    groc = rows_of(basil, "groceries")
    mine = [v for v in groc.values() if v.get("From") == "plan"]
    check("the grocery list fills in by aisle from the plan", len(mine) >= 8 and all(v.get("Aisle") for v in mine) and not any(
        re.search(r"cheddar|almond|peanut|yogurt|feta|mozzarella|parmesan", v["Item"], re.I) for v in mine), f"{len(mine)} items")
    f = fence(body)
    check("one reply: a deck of days, each meal a swap button", f.startswith('deck@week-deck "This week\'s meals"') and f.count("choose@swap-") == 5, f[:200])
    check("the pages: This week and Groceries drawn, Today patched", ">3 clear" in f and ">4 clear" in f and "~kcal " in f and ">2 clear" not in f, f[-300:])
    prof = sql(f"select profile->>'mealScreens' as s from yui_native_profiles where agent_id='{basil}'")[0]["s"]
    check("the runtime remembers the pages it drew", bool(prof) and prof.startswith("v1;"), prof)

    # 3. A swap from This week
    day = days[1]; ymd = day.replace("-", "")
    was = plan[f"{day}-dinner"]
    since = now()
    mid, s = tap(basil, f"wk-{ymd}", "choose", {"choice": was["Name"]}, f'[yui] wk-{ymd} choose choice="{was["Name"]}"')
    rep = wait_reply(basil, since, mid)
    body = rep["body"] if rep else ""
    log["swap"] = body
    now_ = rows_of(basil, "meal_plan")[f"{day}-dinner"]
    tags = recipes.get(now_["Recipe"], {}).get("Tags", "")
    check("a tap swaps the meal, no model call", no_model(rep) and now_["Recipe"] != was["Recipe"] and body.startswith("Dinner is "), f"{was['Name']} -> {now_['Name']}")
    check("the swap keeps to the no-gos", not any(t in tags for t in NOGO), tags)
    f = fence(body)
    check("the deck's day and the week's card are patched, nothing drawn again", f"~swap-{ymd} " in f and f"~wk-{ymd} " in f and "clear" not in f, f[:200])

    # 4. The grocery list: words, then a tick
    since = now()
    mid, s = send(basil, "add oat milk and 2 avocados to my groceries")
    rep = wait_reply(basil, since, mid)
    groc = rows_of(basil, "groceries")
    log["added"] = rep and rep["body"]
    check("words add to the list in their aisles, no model call", no_model(rep) and groc.get("oat-milk", {}).get("Aisle") == "Dairy and eggs"
          and groc.get("avocado", {}).get("Aisle") == "Produce" and groc["avocado"].get("Qty") == "2", {k: groc.get(k) for k in ("oat-milk", "avocado")})
    label = "Avocados, 2" if groc["avocado"]["Item"] == "Avocados" else f'{groc["avocado"]["Item"]}, 2'
    before = len(agent_rows(basil, "2000-01-01"))
    mid, s = tap(basil, "aisle-produce", "list", {"item": label, "checked": True}, f'[yui] aisle-produce list item="{label}" checked')
    handled = wait_handled(mid)
    time.sleep(2)
    check("a tick sets Got and says nothing", handled and rows_of(basil, "groceries")["avocado"].get("Got") is True
          and len(agent_rows(basil, "2000-01-01")) == before, rows_of(basil, "groceries")["avocado"])

    # 5. Today: I ate it, then fix that meal
    since = now()
    mid, s = tap(basil, "next-meal", "card", {"cta": "I ate it"}, '[yui] next-meal card cta="I ate it"')
    rep = wait_reply(basil, since, mid)
    body = rep["body"] if rep else ""
    log["ate"] = body
    meals = rows_of(basil, "meals")
    ate = [v for k, v in meals.items() if k.startswith("plan-")]
    check("I ate it logs the planned meal, no model call", no_model(rep) and body.startswith("Logged ") and len(ate) == 1, body[:80])
    f = fence(body)
    check("Today is patched: calories, macros, the meal to fix", "~kcal " in f and "~macros " in f and "~eaten " in f and "clear" not in f, f[:300])
    slot = ate[0]["Meal"] if ate else "Dinner"
    cal = ate[0]["Cal"] if ate else 0
    since = now()
    choice = f"{slot}, {cal:,} kcal"
    mid, s = tap(basil, "eaten", "choose", {"choice": choice}, f'[yui] eaten choose choice="{choice}"')
    rep = wait_reply(basil, since, mid)
    body = rep["body"] if rep else ""
    fid = f"mfix-{days[0].replace('-', '')}-{slot.lower()}"
    check("a meal tapped on Today opens its fix, no model call", no_model(rep) and f"plan@{fid} " in body, body[:120])
    since = now()
    mid, s = tap(basil, fid, "plan", {"plan": {"portion": 50, "keep": "Keep it"}}, f"[yui] {fid} plan plan.portion=50")
    rep = wait_reply(basil, since, mid)
    body = rep["body"] if rep else ""
    log["fixed"] = body
    halved = [v for k, v in rows_of(basil, "meals").items() if k.startswith("plan-")]
    check("the fix's Send halves it", no_model(rep) and halved and halved[0]["Cal"] == round(cal / 2) and "50%" in body, body[:80])

    # 6. No free turn and no model: every answer came from the runtime.
    ans = agent_rows(basil, "2000-01-01")
    modeled = [r["body"][:40] for r in ans if native(r).get("model")]
    check("no answer in this run called a model", not modeled, modeled)
    turns1 = turns()
    check("no free turn was spent", turns1 == turns0, f"{turns0} -> {turns1}")
finally:
    if args.out:
        Path(args.out).mkdir(parents=True, exist_ok=True)
        Path(args.out, "mealplan_e2e.json").write_text(json.dumps(log, indent=2, default=str))
    sql(f"delete from yui_users where id = '{T}'")
    left = sql("select " + " + ".join(f"(select count(*) from {t} where user_id = '{T}')" for t in
               ["yui_agents", "yui_messages", "yui_connectors", "yui_native_profiles", "yui_sessions",
                "yui_native_tables", "yui_native_table_rows"]) + " as n")[0]["n"]
    check("throwaway account deleted, zero rows left", left == 0, f"left={left}")

print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)

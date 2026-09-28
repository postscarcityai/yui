#!/usr/bin/env python3
"""Arnold's tools (YUI-182), live on yuigui: the runner, the log, a day changed, the pages kept current.

A throwaway account (never anyone's real one): the first list provisions the crew, and Arnold's
home carries This week (with a day picker), Today and Progress. Then, through yui_messages the way
the app writes them, with the real yui-native answering from the database trigger:

  1. "Start today's workout" -> one full-screen plan, a step per move, how it felt last. No model.
  2. The plan's Send (an event row with meta {id, preset, value}) -> a row per move in `workouts`,
     today ticked on `this_week`, one reply that draws the pages (the first time).
  3. "Log today's workout" -> the short log plan; its Send with the person's own words logs each move
     on yesterday, and the reply only patches.
  4. Thursday tapped on This week -> its plan; the Send makes it Legs.
  5. None of it took a free turn or a model call.

The account is deleted at the end. Does NOT touch native_enabled.

    python3 supabase/tests/workouts_e2e.py [--out DIR]
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
def wait_reply(agent_id, since, turn, wait=90):
    end = time.time() + wait
    while time.time() < end:
        got = [r for r in agent_rows(agent_id, since) if turn in ((r["meta"] or {}).get("turn") or [])]
        if got: return got[-1]
        time.sleep(1)
    return None
def now(): return sql("select now() as t")[0]["t"]
def fence(body):
    m = re.search(r"```yui\n([\s\S]*?)\n```", body or "")
    return m.group(1) if m else ""
def no_model(r): return r is not None and "model" not in ((r["meta"] or {}).get("native") or {})

T = str(uuid.uuid4())
sql(f"insert into yui_users(id, apple_sub, timezone) values ('{T}','test.{T}','America/New_York')")
try:
    s, r = fn("yui-agents", {"action": "list"}, mint(T))
    agents = {a["name"]: a["id"] for a in sql(f"select id, name from yui_agents where user_id='{T}' and kind='hosted'")}
    check("a new account gets the crew", s == 200 and "Arnold" in agents, f"{sorted(agents)}")
    arnold = agents["Arnold"]
    home = sql(f"select body from yui_messages where agent_id='{arnold}' and meta->>'native'='home'")
    hb = home[0]["body"] if home else ""
    check("his home: four shortcuts, This week with a day picker, Today, Progress",
          hb.count("menu shortcut") == 4 and "choose@edit-day" in hb and ">4\n" in hb and "stat@streak" in hb and "save progress" in hb, hb[:200])
    check("the log ships with him, empty", sql(f"select count(*) as n from yui_native_tables where agent_id='{arnold}' and name='workouts'")[0]["n"] == 1)
    turns = lambda: sql(f"select coalesce(sum(turns), 0) as n from yui_native_usage where user_id='{T}'")[0]["n"]
    turns0 = turns()

    # 1. Start
    since = now(); t0 = time.time()
    mid, s = send(arnold, "Start today's workout")
    rep = wait_reply(arnold, since, mid)
    secs = round(time.time() - t0, 1)
    body = rep["body"] if rep else ""
    log["start"] = {"s": secs, "body": body}
    plan = re.search(r"^plan@(wk-(\d{8})-(\w{3})) ", fence(body), re.M)
    rest_day = "ask@anyway-" in body
    if rest_day:
        # Today is a rest day on the starter week: take the offer, the runner follows.
        ask_id = re.search(r"ask@(anyway-\w{3})", body).group(1)
        since = now()
        mid, s = send(arnold, f'[yui] {ask_id} ask answer="Yes, let\'s go"', "event", {"id": ask_id, "preset": "ask", "value": {"answer": "Yes, let's go"}})
        rep = wait_reply(arnold, since, mid); body = rep["body"] if rep else ""
        plan = re.search(r"^plan@(wk-(\d{8})-(\w{3})) ", fence(body), re.M)
    check("Start answers with the runner, no model call", bool(plan) and no_model(rep), f"{secs}s rest_day={rest_day}")
    check("the runner lands in under 10 seconds", secs < 10, f"{secs}s")
    steps = re.findall(r"^(pick|slide|choose)@(\S+)", fence(body), re.M)
    check("a step per move, how it felt last, one Send", steps and steps[-1] == ("choose", "feel") and 'submit="Finish workout"' in body
          and any(k == "pick" for k, _ in steps), steps)
    pid, ymd = plan.group(1), plan.group(2)
    day = f"{ymd[:4]}-{ymd[4:6]}-{ymd[6:]}"

    # 2. Finish: every set ticked on the first move, a heavier weight, the rest untouched.
    answers = {"e1-sets": ["Set 1", "Set 2", "Set 3"], "feel": "Just right"}
    if ("slide", "e1-lb") in steps: answers["e1-lb"] = 35
    line = f'[yui] {pid} plan plan.e1-sets="Set 1"|"Set 2"|"Set 3" plan.feel="Just right"'
    since = now(); t0 = time.time()
    mid, s = send(arnold, line, "event", {"id": pid, "preset": "plan", "value": {"plan": answers}})
    rep = wait_reply(arnold, since, mid)
    body = rep["body"] if rep else ""
    log["finish"] = {"s": round(time.time() - t0, 1), "body": body}
    check("Finish is answered with no model call", no_model(rep) and body.startswith("Logged "), body[:80])
    w = rows_of(arnold, "workouts")
    log["workouts_after_finish"] = w
    mine = {k: v for k, v in w.items() if k.startswith(day)}
    check("a row per move in the log, on the session's day", len(mine) >= 2 and all(v.get("Source") == "runner" for v in mine.values()), f"{list(mine)}")
    first = next(iter(mine.values()), {})
    check("the first move: three sets, the weight they set", first.get("Sets") == 3 and (("e1-lb" not in answers) or first.get("Weight") == 35), first)
    wk = rows_of(arnold, "this_week")
    from datetime import date
    dk = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"][date.fromisoformat(day).weekday()]
    check("the day is ticked on the split", wk.get(dk, {}).get("Done") is True, wk.get(dk))
    f = fence(body)
    check("the pages are drawn once: This week, Today, Progress", ">2 clear" in f and ">4 clear" in f and "stat@streak \"1 week\"" in f and "✓ " in f, f[:300])
    prof = sql(f"select profile->>'workoutScreens' as s from yui_native_profiles where agent_id='{arnold}'")[0]["s"]
    check("the runtime remembers what Progress holds", bool(prof), prof)

    # 3. Log today's workout: their own words, yesterday.
    since = now()
    mid, s = send(arnold, "Log today's workout")
    rep = wait_reply(arnold, since, mid)
    body = rep["body"] if rep else ""
    log["log"] = body
    check("Log opens the short log plan, no model call", "plan@wlog" in body and no_model(rep), body[:120])
    since = now()
    words = "Squat 5x5 @135, bench 3x5 at 115"
    mid, s = send(arnold, f'[yui] wlog plan plan.when=Yesterday plan.what="{words}" plan.minutes=50 plan.feel=Hard', "event",
                  {"id": "wlog", "preset": "plan", "value": {"plan": {"when": "Yesterday", "what": words, "minutes": 50, "feel": "Hard"}}})
    rep = wait_reply(arnold, since, mid)
    body = rep["body"] if rep else ""
    log["logged"] = body
    w = rows_of(arnold, "workouts")
    y = [v for k, v in w.items() if k.endswith("-squat") and v.get("Source") == "logged"]
    check("their words are logged move by move on yesterday", bool(y) and y[0].get("Weight") == 135 and y[0].get("Sets") == 5 and y[0]["Day"] < day, y)
    check("the reply only patches: nothing moves the person", no_model(rep) and "clear" not in fence(body) and "~best 135lb" in fence(body), fence(body)[:300])

    # 4. Thursday tapped on This week.
    since = now()
    mid, s = send(arnold, "[yui] edit-day choose choice=Thu", "event", {"id": "edit-day", "preset": "choose", "value": {"choice": "Thu"}})
    rep = wait_reply(arnold, since, mid)
    check("a day tapped opens its plan", rep is not None and "plan@day-thu" in rep["body"] and no_model(rep), rep and rep["body"][:120])
    since = now()
    mid, s = send(arnold, "[yui] day-thu plan plan.focus=Legs plan.minutes=45", "event", {"id": "day-thu", "preset": "plan", "value": {"plan": {"focus": "Legs", "minutes": 45}}})
    rep = wait_reply(arnold, since, mid)
    thu = rows_of(arnold, "this_week").get("thu", {})
    log["thursday"] = {"reply": rep and rep["body"], "row": thu}
    check("Thursday is Legs now, with its moves", thu.get("Focus") == "Legs" and "Squat" in str(thu.get("Workout")) and thu.get("Minutes") == 45, thu)
    check("This week is patched with it", rep is not None and '"Thu Legs"' in rep["body"] and "~days" in rep["body"], rep and fence(rep["body"])[:200])

    # 5. No free turn and no model: every answer came from the runtime.
    ans = agent_rows(arnold, "2000-01-01")
    modeled = [r["body"][:40] for r in ans if ((r["meta"] or {}).get("native") or {}).get("model")]
    check("no answer in this run called a model", not modeled, modeled)
    turns1 = turns()
    check("no free turn was spent", turns1 == turns0, f"{turns0} -> {turns1}")
finally:
    if args.out:
        Path(args.out).mkdir(parents=True, exist_ok=True)
        Path(args.out, "workouts_e2e.json").write_text(json.dumps(log, indent=2, default=str))
    sql(f"delete from yui_users where id = '{T}'")
    left = sql("select " + " + ".join(f"(select count(*) from {t} where user_id = '{T}')" for t in
               ["yui_agents", "yui_messages", "yui_connectors", "yui_native_profiles", "yui_sessions",
                "yui_native_tables", "yui_native_table_rows"]) + " as n")[0]["n"]
    check("throwaway account deleted, zero rows left", left == 0, f"left={left}")

print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)

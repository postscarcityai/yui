#!/usr/bin/env python3
"""Penny's tools (YUI-185), live on yuigui: plan my week by voice, the today list, reminders, move a task,
the evening review.

A throwaway account (never anyone's real one): the first list provisions the crew, and Penny's home
carries Today (the next task big with Done, the list with ticks, the evening review) and This week (a
timeline by day), with her tasks, reminders, reviews and week tables. Then, through yui_messages the way
the app writes them, with the real yui-native answering from the database trigger:

  1. "Plan my week" -> one full-screen plan: how it works first, the brain dump by mic, the questions last.
  2. The plan's Send (a brain dump in words) -> tasks with the day and time said, the rest sorted into days
     under the pace, a full day kept clear, reminders for the timed ones (in the table and in
     meta.native.reminders), This week drawn as a timeline with Edit order, Today patched.
  3. "What's next today?" -> answered from the table; a tick on the list says nothing and patches;
     Done on the next task.
  4. "Add a to-do: call mom tomorrow at 5" -> a task and a reminder.
  5. Edit order saved on This week -> the task takes that place's day, its reminder follows.
  6. Move a task -> a short plan, then the task on the day picked.
  7. Evening review -> a plan with each open task; the Send moves one to tomorrow, drops one, keeps the day.
  8. None of it took a free turn or a model call.

The account is deleted at the end. Does NOT touch native_enabled.

    python3 supabase/tests/planner_e2e.py [--out DIR]
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
def now(): return sql("select now() as t")[0]["t"]
def fence(body):
    m = re.search(r"```yui\n([\s\S]*?)\n```", body or "")
    return m.group(1) if m else ""
def words(body): return re.sub(r"```yui[\s\S]*$", "", body or "").strip()
def native(r):
    n = (r["meta"] or {}).get("native") if r else None
    return n if isinstance(n, dict) else {}
def no_model(r): return r is not None and "model" not in native(r)

T = str(uuid.uuid4())
sql(f"insert into yui_users(id, apple_sub, timezone) values ('{T}','test.{T}','America/New_York')")
try:
    s, r = fn("yui-agents", {"action": "list"}, mint(T))
    agents = {a["name"]: a["id"] for a in sql(f"select id, name from yui_agents where user_id='{T}' and kind='hosted'")}
    check("a new account gets the crew", s == 200 and "Penny" in agents, f"{sorted(agents)}")
    penny = agents["Penny"]
    home = sql(f"select body from yui_messages where agent_id='{penny}' and meta->>'native'='home'")
    hb = home[0]["body"] if home else ""
    log["home"] = hb
    check("her home: four shortcuts, Today with the next task and the list, This week as a timeline",
          hb.count("menu shortcut") == 4 and "card@next-task" in hb and "list@today" in hb and "card@wrap" in hb
          and "timeline@week" in hb and "save this week" in hb, hb[:200])
    tabs = {t["name"]: t["n"] for t in sql(f"select t.name, (select count(*) from yui_native_table_rows r where r.agent_id=t.agent_id and r.tname=t.name) as n "
                                          f"from yui_native_tables t where t.agent_id='{penny}'")}
    check("her tasks, reminders, reviews and week tables ship with her", tabs.get("tasks") == 1 and tabs.get("reminders") == 0
          and tabs.get("reviews") == 0 and tabs.get("week_prefs") == 0 and tabs.get("bills") == 5, tabs)
    turns = lambda: sql(f"select coalesce(sum(turns), 0) as n from yui_native_usage where user_id='{T}'")[0]["n"]
    turns0 = turns()
    day0 = sql("select (now() at time zone 'America/New_York')::date::text as d")[0]["d"]
    day = lambda n: sql(f"select ('{day0}'::date + {n})::text as d")[0]["d"]
    dow = lambda d: sql(f"select trim(to_char('{d}'::date, 'Day')) as w")[0]["w"]

    # 1. Plan my week
    since = now(); t0 = time.time()
    mid, s = send(penny, "Plan my week")
    rep = wait_reply(penny, since, mid)
    secs = round(time.time() - t0, 1)
    body = rep["body"] if rep else ""
    log["plan"] = {"s": secs, "body": body}
    f = fence(body)
    steps = re.findall(r"^(page|mic|choose|pick)(?:@(\S+))?", f, re.M)
    check("Plan my week opens one full-screen flow, no model call", f.startswith("plan@weekplan ") and "+inline" not in f and no_model(rep), f"{secs}s")
    check("how it works first, the brain dump by mic, the questions last, one Send", steps and steps[0][0] == "page" and steps[1] == ("mic", "dump")
          and [x[1] for x in steps[2:]] == ["busy", "pace", "remind"] and 'submit="Plan my week"' in f, steps)
    check("the flow lands in under 10 seconds", secs < 10, f"{secs}s")

    # 2. The Send: a brain dump, a full day, 2 or 3 a day
    full = dow(day(2))
    dump = ("I need to call the dentist tomorrow at 9. Groceries, and then pick up the dry cleaning. Book a haircut, "
            "pay the water bill, it's urgent. Renew the car registration. Email the landlord about the sink")
    answers = {"dump": dump, "busy": [full], "pace": "2 or 3", "remind": "10 minutes before"}
    since = now(); t0 = time.time()
    mid, s = tap(penny, "weekplan", "plan", {"plan": answers}, f'[yui] weekplan plan plan.pace="2 or 3" plan.busy="{full}"')
    rep = wait_reply(penny, since, mid)
    body = rep["body"] if rep else ""
    log["planned"] = {"s": round(time.time() - t0, 1), "body": body, "meta": rep and rep["meta"]}
    check("the Send is answered with no model call", no_model(rep) and body.startswith("Your week is planned: 7 things"), body[:120])
    tasks = rows_of(penny, "tasks")
    log["tasks"] = tasks
    dent = tasks.get("call-the-dentist", {})
    check("the day and time they said are kept", dent.get("Due") == day(1) and dent.get("Time") == "09:00", dent)
    check("urgent is high", tasks.get("pay-the-water-bill", {}).get("Priority") == "High", tasks.get("pay-the-water-bill"))
    opened = [v for k, v in tasks.items() if v.get("Status") == "Open"]
    per = {}
    for v in opened: per[v["Due"]] = per.get(v["Due"], 0) + 1
    check("sorted into days, never more than 3 a day, the full day kept clear", len(opened) == 7 and max(per.values()) <= 3 and day(2) not in per, per)
    check("her starter to-do is done once they plan", tasks.get("t1", {}).get("Done") is True, tasks.get("t1"))
    rem = rows_of(penny, "reminders")
    check("the timed one gets a reminder 10 minutes before", rem.get("call-the-dentist", {}).get("At") == f"{day(1)}T08:50", rem)
    check("the reply carries the reminders for the app to schedule", [x["key"] for x in native(rep).get("reminders", [])] == ["call-the-dentist"], native(rep).get("reminders"))
    f = fence(body)
    check("This week drawn as a timeline with Edit order, Today patched", ">3 clear" in f and "timeline@week " in f and "+reorder" in f
          and f.count("next@wk-") == 7 and "~next-task " in f and ">2 clear" not in f, f[:300])
    prof = sql(f"select profile->>'plannerScreens' as s from yui_native_profiles where agent_id='{penny}'")[0]["s"]
    check("the runtime remembers the pages it drew", bool(prof) and prof.startswith("v1;R,"), prof)
    prefs = rows_of(penny, "week_prefs").get("last", {})
    check("the answers are kept for next time", prefs.get("Busy") == full and prefs.get("Pace") == "2 or 3", prefs)

    # 3. The today list
    since = now()
    mid, s = send(penny, "What's next today?")
    rep = wait_reply(penny, since, mid)
    body = rep["body"] if rep else ""
    log["next"] = body
    today = sorted([v for v in rows_of(penny, "tasks").values() if v.get("Due") == day0 and v.get("Status") == "Open"], key=lambda v: v.get("Order", 99))
    check("What's next is answered from the table, no model call", no_model(rep) and today and words(body).startswith(f"Next: {today[0]['Task']}"), words(body))
    check("and patches Today only", "~next-task " in fence(body) and ">" not in fence(body).replace("->", ""), fence(body)[:200])
    first = today[0]["Task"]
    since = now()
    mid, s = tap(penny, "today", "list", {"item": first, "checked": True}, f'[yui] today list item="{first}" checked')
    rep = wait_reply(penny, since, mid)
    body = rep["body"] if rep else ""
    log["tick"] = body
    done = [v for v in rows_of(penny, "tasks").values() if v.get("Task") == first]
    check("a tick sets Done and says nothing: patches only", no_model(rep) and words(body) == "" and done and done[0].get("Done") is True
          and "clear" not in fence(body) and "kind=done" in fence(body), fence(body)[:200])
    since = now()
    mid, s = tap(penny, "next-task", "card", {"cta": "Done"}, '[yui] next-task card cta=Done')
    rep = wait_reply(penny, since, mid)
    log["donenext"] = rep and rep["body"]
    check("Done on the next task", no_model(rep) and words(rep["body"] if rep else "").startswith("Done: "), rep and rep["body"][:80])

    # 4. Add a to-do with a time
    since = now()
    mid, s = send(penny, "Add a to-do: call mom tomorrow at 5")
    rep = wait_reply(penny, since, mid)
    body = rep["body"] if rep else ""
    log["added"] = {"body": body, "meta": rep and rep["meta"]}
    check("a to-do with a time: added, and a reminder", no_model(rep) and words(body) == "Added call mom for tomorrow at 5:00 pm. I'll remind you."
          and rows_of(penny, "reminders").get("call-mom", {}).get("At") == f"{day(1)}T16:50", words(body))

    # 5. Edit order: the last task dragged to the top takes today's first place
    wk = re.findall(r"^next@wk-(\S+) .*key=(\S+)", fence(log["planned"]["body"]), re.M)
    queue = [k for _, k in wk]
    tasks = rows_of(penny, "tasks")
    queue = [k for k in queue if tasks.get(k, {}).get("Status") == "Open"] + ["call-mom"]
    last = max(queue, key=lambda k: (tasks.get(k, {}).get("Due") or rows_of(penny, "tasks")[k]["Due"]))
    order = [last] + [k for k in queue if k != last]
    since = now()
    mid, s = tap(penny, "week", "timeline", {"order": order}, "[yui] week timeline order=" + "|".join(order))
    rep = wait_reply(penny, since, mid)
    body = rep["body"] if rep else ""
    log["order"] = body
    moved = rows_of(penny, "tasks")[last]
    check("Edit order saved: the task takes that place's day, no model call", no_model(rep) and moved.get("Due") == day0 and words(body).startswith("Moved "), moved)

    # 6. Move a task
    since = now()
    mid, s = tap(penny, "week-move", "card", {"cta": "Move a task"}, '[yui] week-move card cta="Move a task"')
    rep = wait_reply(penny, since, mid)
    f = fence(rep["body"] if rep else "")
    opts = re.search(r'^choose@task "Which one\?" (.*)$', f, re.M)
    pick = next((o for o in re.findall(r'"([^"]+)"', opts.group(1) if opts else "") if o.startswith("Book a haircut")), None)
    check("Move a task opens a short plan: which one, then which day", f.startswith("plan@move ") and "choose@day " in f and pick, f[:200])
    target = dow(day(5))
    since = now()
    mid, s = tap(penny, "move", "plan", {"plan": {"task": pick, "day": target}}, f'[yui] move plan plan.day="{target}"')
    rep = wait_reply(penny, since, mid)
    body = rep["body"] if rep else ""
    log["moved"] = body
    check("the Send moves it, and This week is drawn in day order", no_model(rep) and rows_of(penny, "tasks")["book-a-haircut"]["Due"] == day(5)
          and words(body) == f"Book a haircut is on {target} now." and ">3 clear" in fence(body), words(body))

    # 7. Evening review
    since = now()
    mid, s = send(penny, "Evening review")
    rep = wait_reply(penny, since, mid)
    f = fence(rep["body"] if rep else "")
    log["review"] = f
    open_ids = re.findall(r"^choose@(r-\S+) ", f, re.M)
    check("the evening review: what got done first, each open task, how it went last, one Send", f.startswith("plan@review ")
          and re.search(r'^page "\d+ done today"', f, re.M) and len(open_ids) >= 2 and f.rstrip().splitlines()[-1].startswith("choose@feel "), f[:300])
    a, b = open_ids[0], open_ids[1]
    since = now()
    mid, s = tap(penny, "review", "plan", {"plan": {a: "Tomorrow", b: "Drop", "feel": "Okay"}}, f"[yui] review plan plan.feel=Okay")
    rep = wait_reply(penny, since, mid)
    body = rep["body"] if rep else ""
    log["reviewed"] = body
    tasks = rows_of(penny, "tasks")
    check("the Send: one to tomorrow, one dropped (kept in the table), no model call", no_model(rep) and tasks[a[2:]]["Due"] == day(1)
          and tasks[b[2:]]["Status"] == "Dropped" and words(body).startswith("Day wrapped: 1 to tomorrow and 1 dropped."), words(body))
    rv = rows_of(penny, "reviews").get(day0, {})
    check("the day is kept in reviews", rv.get("Moved") == 1 and rv.get("Dropped") == 1 and rv.get("Felt") == "Okay" and rv.get("Done", 0) >= 2, rv)

    # 8. No free turn and no model: every answer came from the runtime.
    ans = agent_rows(penny, "2000-01-01")
    modeled = [r["body"][:40] for r in ans if native(r).get("model")]
    check("no answer in this run called a model", not modeled, modeled)
    turns1 = turns()
    check("no free turn was spent", turns1 == turns0, f"{turns0} -> {turns1}")
finally:
    if args.out:
        Path(args.out).mkdir(parents=True, exist_ok=True)
        Path(args.out, "planner_e2e.json").write_text(json.dumps(log, indent=2, default=str))
    sql(f"delete from yui_users where id = '{T}'")
    left = sql("select " + " + ".join(f"(select count(*) from {t} where user_id = '{T}')" for t in
               ["yui_agents", "yui_messages", "yui_connectors", "yui_native_profiles", "yui_sessions",
                "yui_native_tables", "yui_native_table_rows"]) + " as n")[0]["n"]
    check("throwaway account deleted, zero rows left", left == 0, f"left={left}")

print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)

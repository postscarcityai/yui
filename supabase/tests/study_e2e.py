#!/usr/bin/env python3
"""Quill's tools (YUI-186), live on yuigui: cards with spaced review, what's due, learn a topic, the lesson's quiz,
walk me through a problem one step a page, his pages kept current.

A throwaway account (never anyone's real one): the first list provisions the crew, and Quill's home carries
What you're studying, Next review (the due count and Start) and Progress, with his decks, review, sessions,
problems and steps tables. Then, through yui_messages the way the app writes them, with the real yui-native
answering from the database trigger:

  1. "Review my cards" -> one full-screen plan: how it works first, then each due card's front and answer
     with Again, Hard, Good or Easy.
  2. The review's Send -> every card's Box and Due moved by its rating, the session kept, the pages patched.
  3. "What should I review next?" -> answered in one line from the table, the review under it.
  4. "Teach me photosynthesis" -> the learn plan, the topic already known, the questions last.
  5. A lesson kept (seeded as the runtime keeps one): a quiz answer is quiet, the deck's done keeps the score.
  6. "Walk me through a problem" -> a plan asking for it; a problem kept (seeded as the runtime keeps one):
     each step answered shows the next, the last one solves it.
  7. None of it took a free turn or a model call (the lesson and the steps are the only model calls, and the
     unit tests cover those with a scripted model).

The account is deleted at the end. Does NOT touch native_enabled.

    python3 supabase/tests/study_e2e.py [--out DIR]
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

def put_row(agent_id, table, key, vals):
    v = json.dumps(vals).replace("'", "''")
    sql(f"insert into yui_native_table_rows(agent_id, user_id, tname, key, vals) values ('{agent_id}','{T}','{table}','{key}','{v}'::jsonb)")
def handled(mid, wait=30):
    end = time.time() + wait
    while time.time() < end:
        r = sql(f"select handled_at is not null as h from yui_messages where id='{mid}'")
        if r and r[0]["h"]: return True
        time.sleep(1)
    return False

T = str(uuid.uuid4())
sql(f"insert into yui_users(id, apple_sub, timezone) values ('{T}','test.{T}','America/New_York')")
try:
    s, r = fn("yui-agents", {"action": "list"}, mint(T))
    agents = {a["name"]: a["id"] for a in sql(f"select id, name from yui_agents where user_id='{T}' and kind='hosted'")}
    check("a new account gets the crew", s == 200 and "Quill" in agents, f"{sorted(agents)}")
    quill = agents["Quill"]
    home = sql(f"select body from yui_messages where agent_id='{quill}' and meta->>'native'='home'")
    hb = home[0]["body"] if home else ""
    log["home"] = hb
    check("his home: four shortcuts, What you're studying, Next review with Start, Progress",
          hb.count("menu shortcut") == 4 and "card@studying" in hb and "stat@due 8" in hb and "card@review-start" in hb
          and "chart@studied" in hb and "save progress" in hb, hb[:200])
    tabs = {t["name"]: t["n"] for t in sql(f"select t.name, (select count(*) from yui_native_table_rows r where r.agent_id=t.agent_id and r.tname=t.name) as n "
                                          f"from yui_native_tables t where t.agent_id='{quill}'")}
    check("his decks, review, sessions, problems and steps tables ship with him", tabs.get("decks") == 1 and tabs.get("review") == 8
          and tabs.get("sessions") == 0 and tabs.get("problems") == 0 and tabs.get("steps") == 0, tabs)
    turns = lambda: sql(f"select coalesce(sum(turns), 0) as n from yui_native_usage where user_id='{T}'")[0]["n"]
    turns0 = turns()
    day0 = sql("select (now() at time zone 'America/New_York')::date::text as d")[0]["d"]
    day = lambda n: sql(f"select ('{day0}'::date + {n})::text as d")[0]["d"]

    # 1. Review my cards
    since = now(); t0 = time.time()
    mid, s = send(quill, "Review my cards")
    rep = wait_reply(quill, since, mid)
    secs = round(time.time() - t0, 1)
    body = rep["body"] if rep else ""
    log["review"] = {"s": secs, "body": body}
    f = fence(body)
    steps = re.findall(r"^(page|choose)(?:@(\S+))?", f, re.M)
    check("Review my cards opens one full-screen plan, no model call", f.startswith("plan@review ") and "+inline" not in f and no_model(rep), f"{secs}s")
    check("how it works first, then each card with its answer and Again, Hard, Good or Easy", steps and steps[0][0] == "page"
          and [x[1] for x in steps[1:]] == [f"c-c{i}" for i in range(1, 9)] and 'title="Capital of Japan?"' in f and '"Again"|"Hard"|"Good"|"Easy"' in f, steps[:3])
    check("the flow lands in under 10 seconds", secs < 10, f"{secs}s")

    # 2. The Send
    plan = {"c-c1": "Again", "c-c2": "Hard", "c-c3": "Good", "c-c4": "Easy", "c-c5": "Good", "c-c6": "Good", "c-c7": "Good", "c-c8": "Good"}
    since = now()
    mid, s = tap(quill, "review", "plan", {"plan": plan}, "[yui] review plan plan.c-c1=Again plan.c-c4=Easy")
    rep = wait_reply(quill, since, mid)
    body = rep["body"] if rep else ""
    log["reviewed"] = body
    check("the Send is answered with no model call", no_model(rep) and words(body) == "Saved: 8 cards reviewed, 1 to see again today. 1 still due.", words(body))
    cards = rows_of(quill, "review")
    log["cards"] = cards
    got = [(k, cards[k].get("Box"), cards[k].get("Due")) for k in ("c1", "c2", "c3", "c4")]
    check("each rating moves its card: again today, hard and good tomorrow, easy in three days",
          got == [("c1", 1, day0), ("c2", 2, day(1)), ("c3", 2, day(1)), ("c4", 3, day(3))], got)
    ses = list(rows_of(quill, "sessions").values())
    check("the review is kept in sessions", len(ses) == 1 and ses[0].get("Kind") == "Review" and ses[0].get("Cards") == 8 and ses[0].get("Right") == 7, ses)
    f = fence(body)
    check("his pages patched in place: due count, streak, the week's chart", "~due 1 " in f and "~streak 1 " in f and "~studied bar " in f
          and "clear" not in f, f[:300])
    prof = sql(f"select profile->>'studyScreens' as s from yui_native_profiles where agent_id='{quill}'")[0]["s"]
    check("the runtime remembers the pages it drew", prof == "v1", prof)

    # 3. What's due
    since = now()
    mid, s = send(quill, "What should I review next?")
    rep = wait_reply(quill, since, mid)
    body = rep["body"] if rep else ""
    log["next"] = body
    check("what's due: one line from the table, the review under it", no_model(rep) and words(body).startswith("1 card due today, from World capitals.")
          and fence(body).count("choose@c-") == 1, words(body))

    # 4. Learn a topic
    since = now()
    mid, s = send(quill, "Teach me photosynthesis")
    rep = wait_reply(quill, since, mid)
    body = rep["body"] if rep else ""
    log["learn"] = body
    f = fence(body)
    qs = re.findall(r"^(page|form|choose)(?:@(\S+))?", f, re.M)
    check("the learn plan: what happens first, the topic already known, time and what you know last", no_model(rep) and f.startswith("plan@learn ")
          and [x for x in qs] == [("page", ""), ("choose", "time"), ("choose", "know")] and native(rep).get("topic") == "photosynthesis", qs)

    # 5. A lesson kept, as the runtime keeps one after the model writes it; its quiz
    put_row(quill, "decks", "photosynthesis", {"Deck": "Photosynthesis", "Subject": "Biology", "Cards": 2, "Last": day0})
    put_row(quill, "review", "photosynthesis-1", {"Front": "Which gas do plants take in?", "Back": "Carbon dioxide", "Deck": "Photosynthesis", "Box": 1, "Due": day(1), "Reps": 0})
    put_row(quill, "review", "photosynthesis-2", {"Front": "Where does photosynthesis happen?", "Back": "Chloroplasts", "Deck": "Photosynthesis", "Box": 1, "Due": day(1), "Reps": 0})
    n0 = len(agent_rows(quill, "2000-01-01"))
    mid, s = tap(quill, "quiz-photosynthesis-1", "choose", {"choice": "Carbon dioxide", "correct": True}, "[yui] quiz-photosynthesis-1 choose choice=\"Carbon dioxide\" correct")
    ok = handled(mid)
    time.sleep(2)
    check("a quiz answer is taken quietly: handled, nothing said", ok and len(agent_rows(quill, "2000-01-01")) == n0, f"handled={ok}")
    since = now()
    mid, s = tap(quill, "lesson-photosynthesis", "deck", {"done": True, "pages": 7, "score": 2, "of": 3}, "[yui] lesson-photosynthesis deck done pages=7 score=2 of=3")
    rep = wait_reply(quill, since, mid)
    body = rep["body"] if rep else ""
    log["quizdone"] = body
    check("the deck's done keeps the score and patches Progress", no_model(rep) and words(body).startswith("2 of 3. Nice.")
          and '~last-quiz "2/3"' in fence(body) and rows_of(quill, "decks")["photosynthesis"].get("Score") == "2 of 3", words(body))

    # 6. Walk me through a problem
    since = now()
    mid, s = send(quill, "Walk me through a problem")
    rep = wait_reply(quill, since, mid)
    f = fence(rep["body"] if rep else "")
    log["problem"] = f
    qs = re.findall(r"^(page|form|choose)(?:@(\S+))?", f, re.M)
    check("the problem plan: how it goes first, the problem and the step size last", no_model(rep) and f.startswith("plan@problem ")
          and qs == [("page", ""), ("form", "question"), ("choose", "size")], qs)
    pk = "solve-2x-3-11"
    put_row(quill, "problems", pk, {"Problem": "Solve 2x + 3 = 11", "Subject": "Algebra", "Steps": 2, "At": 1, "Right": 0, "Done": False, "Day": day0, "Result": "x = 4"})
    put_row(quill, "steps", f"{pk}-1", {"Problem": pk, "N": 1, "Title": "Take away 3", "Body": "Take 3 from both sides.", "Tex": "2x + 3 - 3 = 11 - 3",
                                         "Ask": "What is 11 - 3?", "Options": "7|8|14", "Answer": "8", "Why": "11 take away 3 is 8."})
    put_row(quill, "steps", f"{pk}-2", {"Problem": pk, "N": 2, "Title": "Divide by 2", "Body": "Now 2x = 8. Divide both sides by 2.", "Tex": "x = 8 / 2",
                                         "Ask": "So x is?", "Options": "4|6|16", "Answer": "4", "Why": "8 split in two is 4."})
    since = now()
    mid, s = tap(quill, f"step-{pk}-1", "choose", {"choice": "7", "correct": False}, f"[yui] step-{pk}-1 choose choice=7")
    rep = wait_reply(quill, since, mid)
    body = rep["body"] if rep else ""
    log["step1"] = body
    f = fence(body)
    check("a wrong step: the right answer and why, then the next step on its own page", no_model(rep) and words(body) == "Not quite: it's 8. 11 take away 3 is 8."
          and f.startswith('page "Step 2 of 2: Divide by 2"') and f"choose@step-{pk}-2 " in f and f"step-{pk}-1" not in f, words(body))
    since = now()
    mid, s = tap(quill, f"step-{pk}-2", "choose", {"choice": "4", "correct": True}, f"[yui] step-{pk}-2 choose choice=4")
    rep = wait_reply(quill, since, mid)
    body = rep["body"] if rep else ""
    log["solved"] = body
    pr = rows_of(quill, "problems")[pk]
    st = rows_of(quill, "steps")
    check("the last step solves it: the result, the score, the problem kept done", no_model(rep) and words(body) == "Right. Solved: x = 4. You got 1 of 2 steps."
          and pr.get("Done") is True and st[f"{pk}-1"].get("Given") == "7" and st[f"{pk}-2"].get("Right") is True, words(body))

    # 7. No free turn and no model
    ans = agent_rows(quill, "2000-01-01")
    modeled = [r["body"][:40] for r in ans if native(r).get("model")]
    check("no answer in this run called a model", not modeled, modeled)
    turns1 = turns()
    check("no free turn was spent", turns1 == turns0, f"{turns0} -> {turns1}")
finally:
    if args.out:
        Path(args.out).mkdir(parents=True, exist_ok=True)
        Path(args.out, "study_e2e.json").write_text(json.dumps(log, indent=2, default=str))
    sql(f"delete from yui_users where id = '{T}'")
    left = sql("select " + " + ".join(f"(select count(*) from {t} where user_id = '{T}')" for t in
               ["yui_agents", "yui_messages", "yui_connectors", "yui_native_profiles", "yui_sessions",
                "yui_native_tables", "yui_native_table_rows"]) + " as n")[0]["n"]
    check("throwaway account deleted, zero rows left", left == 0, f"left={left}")

print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)

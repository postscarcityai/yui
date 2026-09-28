#!/usr/bin/env python3
"""Gouda's tools (YUI-184), live on yuigui: learn a song and play along, the practice log, saved sessions.

A throwaway account (never anyone's real one): the first list provisions the crew, and Gouda's home
carries Looper, Chords, Keys and Practice, with his songs (and their chords), practice, sessions and
studio tables. Then, through yui_messages the way the app writes them, with the real yui-native
answering from the database trigger:

  1. "Learn a song" -> one full-screen plan: what happens first, the questions last. No model.
  2. The plan's Send -> the lesson in `studio`, the song marked Learning, one reply: Chords drawn with
     the chords, the click at the chosen speed, a speed and a bar picker; Keys and Practice patched.
  3. Half speed, then bar 5 -> patches only (the click slows, the chord buttons loop that bar).
  4. "Log practice" -> a short plan; its Send writes `practice`, Practice patched (streak, this week).
     The click stopped after 3 minutes logs itself.
  5. The Looper's Send -> a save plan; its Send keeps the beat in `sessions`, the Looper patched;
     "Open a beat" brings a starter back.
  6. None of it took a free turn or a model call.

The account is deleted at the end. Does NOT touch native_enabled.

    python3 supabase/tests/music_e2e.py [--out DIR]
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
def native(r):
    n = (r["meta"] or {}).get("native") if r else None
    return n if isinstance(n, dict) else {}
def no_model(r): return r is not None and "model" not in native(r)
def ask(agent_id, fn_, *a):
    since = now(); t0 = time.time()
    mid, s = fn_(agent_id, *a)
    rep = wait_reply(agent_id, since, mid)
    return rep, (rep["body"] if rep else ""), round(time.time() - t0, 1)

T = str(uuid.uuid4())
sql(f"insert into yui_users(id, apple_sub, timezone) values ('{T}','test.{T}','America/New_York')")
try:
    s, r = fn("yui-agents", {"action": "list"}, mint(T))
    agents = {a["name"]: a["id"] for a in sql(f"select id, name from yui_agents where user_id='{T}' and kind='hosted'")}
    check("a new account gets the crew", s == 200 and "Gouda" in agents, f"{sorted(agents)}")
    gouda = agents["Gouda"]
    home = sql(f"select body from yui_messages where agent_id='{gouda}' and meta->>'native'='home'")
    hb = home[0]["body"] if home else ""
    log["home"] = hb
    check("his home: four shortcuts, Looper, Chords, Keys and Practice",
          hb.count("menu shortcut") == 4 and 'say="Learn a song"' in hb and "loop@looper" in hb and "choose@sessions" in hb
          and "chords@chords" in hb and "metronome@click" in hb and "keys@keys" in hb and "chart@practice-chart" in hb
          and "save practice" in hb, hb[:200])
    tabs = {t["name"]: t["n"] for t in sql(f"select t.name, (select count(*) from yui_native_table_rows r where r.agent_id=t.agent_id and r.tname=t.name) as n "
                                          f"from yui_native_tables t where t.agent_id='{gouda}'")}
    songs = rows_of(gouda, "songs")
    check("his songs (with their chords), practice, sessions and studio ship with him", tabs.get("songs") == 4 and tabs.get("practice") == 0
          and tabs.get("sessions") == 0 and "studio" in tabs and songs.get("stand-by-me", {}).get("Chords") == "A|A|F#m|F#m|D|E|A|A", tabs)
    turns = lambda: sql(f"select coalesce(sum(turns), 0) as n from yui_native_usage where user_id='{T}'")[0]["n"]
    turns0 = turns()

    # 1. Learn a song
    rep, body, secs = ask(gouda, send, "Learn a song")
    log["learn"] = {"s": secs, "body": body}
    f = fence(body)
    steps = re.findall(r"^(page|choose|pick|form)(?:@(\S+))?", f, re.M)
    check("Learn a song opens one full-screen flow, no model call", f.startswith("plan@learn ") and no_model(rep), f"{secs}s")
    check("what happens first, the questions last, one Send", steps and steps[0][0] == "page"
          and [x[1] for x in steps[1:]] == ["song", "own", "key", "speed"] and "submit=\"Let's play\"" in f, steps)
    check("the flow lands in under 10 seconds", secs < 10, f"{secs}s")

    # 2. The Send
    rep, body, secs = ask(gouda, tap, "learn", "plan", {"plan": {"song": "Stand By Me", "key": "As written", "speed": "75%"}},
                          '[yui] learn plan plan.song="Stand By Me" plan.speed="75%"')
    log["learned"] = {"s": secs, "body": body}
    f = fence(body)
    check("the Send is answered with no model call", no_model(rep) and body.startswith("Stand By Me is on your Chords page"), body[:90])
    studio = rows_of(gouda, "studio").get("now", {})
    check("the lesson is kept in studio", studio.get("Song") == "Stand By Me" and studio.get("Speed") == 75 and studio.get("Tonic") == "A", studio)
    check("the song is marked Learning", rows_of(gouda, "songs")["stand-by-me"].get("Status") == "Learning")
    check("Chords drawn: the chords, the click at 75%, a speed and a bar picker", ">3 clear" in f and 'chords@chords "A"|"F#m"|"D"|"E"' in f
          and "metronome@click 89 " in f and "choose@speed " in f and 'choose@bar "Loop a bar" "Whole song"|"Bar 1: A"' in f, f[:300])
    check("Keys and Practice patched, nothing else moves", '~keys A major "Keys, in A"' in f and "~next-up " in f
          and ">2 clear" not in f and ">4 clear" not in f and ">5 clear" not in f, f[-300:])
    prof = sql(f"select profile->>'musicScreens' as s from yui_native_profiles where agent_id='{gouda}'")[0]["s"]
    check("the runtime remembers the page it drew", prof == "v1;stand-by-me", prof)

    # 3. Slow it down, loop the hard bar
    rep, body, _ = ask(gouda, tap, "speed", "choose", {"choice": "Half"}, '[yui] speed choose choice=Half')
    f = fence(body)
    check("Half: the click slows with a patch, no model call", no_model(rep) and '~click 59 "Stand By Me"' in f and "clear" not in f, f[:200])
    rep, body, _ = ask(gouda, tap, "bar", "choose", {"choice": "Bar 5: D"}, '[yui] bar choose choice="Bar 5: D"')
    f = fence(body)
    log["bar"] = body
    check("Bar 5: the chord buttons loop that bar, a patch", no_model(rep) and '~chords "D"|"E" "Stand By Me, bar 5"' in f and "clear" not in f
          and "Next: bar 5 of Stand By Me" in f, f[:250])

    # 4. The practice log
    rep, body, _ = ask(gouda, send, "Log practice")
    f = fence(body)
    check("Log practice opens a short flow, no model call", no_model(rep) and f.startswith("plan@practiced ") and "choose@minutes" in f
          and 'pick@what "What did you play?" "Stand By Me"' in f, f[:200])
    rep, body, _ = ask(gouda, tap, "practiced", "plan", {"plan": {"minutes": "20 min", "what": ["Stand By Me"], "feel": "Getting there"}},
                       '[yui] practiced plan plan.minutes="20 min"')
    f = fence(body)
    log["practiced"] = body
    check("its Send logs it and patches Practice", no_model(rep) and body.startswith("Logged 20 minutes: Stand By Me.")
          and '~streak "1 day"' in f and '~week-min "20 min"' in f and "~practice-chart " in f and "clear" not in f, f[:300])
    rep, body, _ = ask(gouda, tap, "click", "metronome", {"bpm": 59, "beats": 4, "sub": 1, "seconds": 184},
                       "[yui] click metronome bpm=59 beats=4 sub=1 seconds=184")
    check("the click stopped after 3 minutes logs itself", no_model(rep) and body.startswith("Logged 3 minutes: Stand By Me.")
          and '~week-min "23 min"' in fence(body), body[:80])
    prac = rows_of(gouda, "practice")
    check("practice holds both", sorted(v["Minutes"] for v in prac.values()) == [3, 20], prac)

    # 5. Sessions
    beat = {"bpm": 88, "swing": 20, "steps": 8, "rows": ["kick", "snare", "clap", "hat"], "p": ["x..xx...", "..x...x.", "", "xxxxxxxx"]}
    rep, body, _ = ask(gouda, tap, "looper", "loop", beat, "[yui] looper loop bpm=88 swing=20")
    f = fence(body)
    check("the Looper's Send opens a save flow, no model call", no_model(rep) and f.startswith("plan@keep ") and "form@name" in f
          and "88 bpm, swing 20" in f, f[:200])
    rep, body, _ = ask(gouda, tap, "keep", "plan", {"plan": {"name": {"name": "Night drive"}, "then": "Keep it on my Looper"}},
                       '[yui] keep plan plan.then="Keep it on my Looper"')
    f = fence(body)
    log["saved"] = body
    sess = rows_of(gouda, "sessions")
    check("its Send keeps it by name and puts it on the Looper", no_model(rep) and sess.get("s-night-drive", {}).get("Pattern") == "x..xx...|..x...x.||xxxxxxxx"
          and "draft" not in sess and '~looper 88 "Night drive"' in f and '~sessions "Open a beat" "Night drive"' in f, f[:250])
    rep, body, _ = ask(gouda, tap, "sessions", "choose", {"choice": "Boom bap"}, '[yui] sessions choose choice="Boom bap"')
    check("Open a beat brings one back on the Looper", no_model(rep) and '~looper 90 "Boom bap"' in fence(body), body[:80])

    # 6. No free turn and no model: every answer came from the runtime.
    ans = agent_rows(gouda, "2000-01-01")
    modeled = [r["body"][:40] for r in ans if native(r).get("model")]
    check("no answer in this run called a model", not modeled, modeled)
    turns1 = turns()
    check("no free turn was spent", turns1 == turns0, f"{turns0} -> {turns1}")
finally:
    if args.out:
        Path(args.out).mkdir(parents=True, exist_ok=True)
        Path(args.out, "music_e2e.json").write_text(json.dumps(log, indent=2, default=str))
    sql(f"delete from yui_users where id = '{T}'")
    left = sql("select " + " + ".join(f"(select count(*) from {t} where user_id = '{T}')" for t in
               ["yui_agents", "yui_messages", "yui_connectors", "yui_native_profiles", "yui_sessions",
                "yui_native_tables", "yui_native_table_rows"]) + " as n")[0]["n"]
    check("throwaway account deleted, zero rows left", left == 0, f"left={left}")

print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)

#!/usr/bin/env python3
"""Every agent has its own quiet visual (YUI-180), live on yuigui.

A throwaway account (never anyone's real one): the first list provisions the crew, and every
crew agent in the list carries its `visual` pick (look, hears, strength, pace, the line it
would be), none of them full or quick. A crew agent made before defaults (its saved profile
has no `visual`) gets its starter's, a custom agent with no pick gets the soft orb, and a
pick the person's copy carries wins. Nothing is written into a thread. The account is deleted
at the end. Does NOT touch native_enabled.

    python3 supabase/tests/visual_defaults_e2e.py
"""
import json, uuid
exec(open(__file__.replace("visual_defaults_e2e.py", "agents_test.py")).read().split("results = []")[0])

results = []
def check(name, ok, detail=""):
    results.append(ok); print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  [{detail}]" if detail else ""), flush=True)

PICKS = {"Yui": ("orb", "voice", "dim"), "Arnold": ("orb", "music", "dim"), "Basil": ("orb", "voice", "dim"),
         "Gouda": ("orb", "music", "dim"), "Penny": ("orb", "off", "faint"), "Quill": ("orb", "voice", "faint")}
T = str(uuid.uuid4())
sql(f"insert into yui_users(id, apple_sub) values ('{T}','test.{T}')")
tok = lambda: mint(T)
def listing():
    return fn("yui-agents", {"action": "list"}, tok())
def by_name(r): return {a["name"]: a for a in r["agents"]}

try:
    s, r = listing()
    got = {n: (a.get("visual") or {}) for n, a in by_name(r).items()} if s == 200 else {}
    check("every crew agent in the list carries its pick",
          {n: (v.get("look"), v.get("hears"), v.get("strength")) for n, v in got.items()} == PICKS, f"{s} {got if s == 200 else r}")
    check("none is full or quick", all(v.get("strength") in ("dim", "faint") and v.get("pace") in ("slow", "even") for v in got.values()))
    check("each says the line it would be", got.get("Gouda", {}).get("line") == "visual orb react=music"
          and got.get("Penny", {}).get("line") == "visual orb react=off", f"{got.get('Gouda', {}).get('line')!r}")
    ids = {n: a["id"] for n, a in by_name(r).items()}

    # A crew agent made before defaults: its saved profile has no visual.
    sql(f"update yui_native_profiles set profile = profile - 'visual' where agent_id = '{ids['Quill']}'")
    # The person's own copy says something else: that wins.
    own = {"look": "waves", "hears": "mic", "strength": "faint", "pace": "slow", "tone": "sky"}
    sql(f"update yui_native_profiles set profile = jsonb_set(profile, '{{visual}}', '{json.dumps(own)}'::jsonb) where agent_id = '{ids['Basil']}'")
    # A custom agent Yui made, with no pick.
    sql(f"update yui_native_profiles set profile = (profile - 'visual') || '{{\"base\": \"custom\"}}'::jsonb where agent_id = '{ids['Arnold']}'")
    s, r = listing()
    got = {n: (a.get("visual") or {}) for n, a in by_name(r).items()} if s == 200 else {}
    check("made before defaults: its starter's pick", (got.get("Quill", {}).get("look"), got.get("Quill", {}).get("strength")) == ("orb", "faint"), f"{got.get('Quill')}")
    check("the person's copy wins", got.get("Basil", {}).get("line") == "visual waves tone=sky react=mic", f"{got.get('Basil')}")
    check("no pick at all: the soft orb", got.get("Arnold", {}) == {"look": "orb", "hears": "voice", "strength": "faint", "pace": "slow", "tone": "accent", "line": "visual orb"}, f"{got.get('Arnold')}")
    lines = sql(f"select count(*) as n from yui_messages where user_id = '{T}' and body ~ '(^|\\n)visual '")[0]["n"]
    check("no visual line is written into any thread", lines == 0, f"n={lines}")
finally:
    sql(f"delete from yui_users where id = '{T}'")
    left = sql("select " + " + ".join(f"(select count(*) from {t} where user_id = '{T}')" for t in
               ["yui_agents", "yui_messages", "yui_connectors", "yui_native_profiles", "yui_sessions",
                "yui_native_tables", "yui_native_table_rows"]) + " as n")[0]["n"]
    check("throwaway account deleted, zero rows left", left == 0, f"left={left}")

print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)

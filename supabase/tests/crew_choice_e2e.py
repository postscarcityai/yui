#!/usr/bin/env python3
"""The crew is the person's choice, live on yuigui (Chris, 2026-09-27: "either have all these
agents or can put any number of them to be in my list").

A throwaway account (never anyone's real one): the first list provisions Yui and the whole
crew, Yui answers a real turn, removing a crew member takes only that one out, Add agent
offers it again, `crew_add` puts it back without touching anyone else, a second `crew_add`
changes nothing, a paired agent stays where it was, and `crew_add_all` fills in everyone
missing. The account is deleted at the end. Does NOT touch native_enabled.

    python3 supabase/tests/crew_choice_e2e.py
"""
import time, uuid
exec(open(__file__.replace("crew_choice_e2e.py", "agents_test.py")).read().split("results = []")[0])

results = []
def check(name, ok, detail=""):
    results.append(ok); print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  [{detail}]" if detail else ""), flush=True)

CREW = ["Yui", "Arnold", "Basil", "Gouda", "Penny", "Quill"]
T = str(uuid.uuid4())
sql(f"insert into yui_users(id, apple_sub) values ('{T}','test.{T}')")
tok = lambda: mint(T)
def listing():
    s, r = fn("yui-agents", {"action": "list"}, tok())
    return s, r
def names(r): return [a["name"] for a in r["agents"]]
def ids(r): return {a["name"]: a["id"] for a in r["agents"]}

try:
    s, r = listing()
    check("first list provisions Yui and the whole crew, Yui first", s == 200 and names(r) == CREW, f"{s} {names(r) if s == 200 else r}")
    crew = {c["base"]: c for c in (r.get("crew") or [])}
    check("the list offers the crew, each one marked as in the list",
          sorted(crew) == sorted(n.lower() for n in CREW) and all(c["agent_id"] for c in crew.values()), f"{list(crew)}")
    # YUI-165: every starter says what it does, in Add agent and on its own row (About, the picker).
    check("every starter in the offer has a tagline, an about and three things to ask",
          all(c.get("tagline") and c.get("about") and len(c.get("can") or []) == 3 for c in crew.values()),
          f"basil: {crew.get('basil', {}).get('tagline')!r}")
    check("every crew agent in the list says what it does",
          all(a.get("tagline") and a.get("about") and len(a.get("can") or []) == 3 for a in r["agents"]),
          f"{[(a['name'], a.get('tagline')) for a in r['agents']]}")
    hello = sql(f"select body from yui_messages where user_id='{T}' and agent_id='{ids(r)['Gouda']}' "
                f"and meta->>'native' = 'first'")
    check("Gouda's hello is a normal answer with its beat on the backbone",
          bool(hello) and "p=x...x...|..x...x." in hello[0]["body"], (hello[0]["body"] if hello else "")[:90])
    before = ids(r)

    # A real turn: the person says hi, hosted Yui answers through the live runtime.
    yui = before["Yui"]
    s, m = rest("POST", "yui_messages", tok(), {"user_id": T, "agent_id": yui, "sender": "user",
                "body": "Hi Yui! In one short line, who is on my crew?", "kind": "text"}, prefer="return=representation")
    check("the person's message is stored", s in (200, 201), f"{s}")
    since = m[0]["created_at"] if s in (200, 201) else "now()"
    answer = None
    end = time.time() + 120
    while time.time() < end and not answer:
        a = sql(f"select body from yui_messages where user_id='{T}' and agent_id='{yui}' and sender='agent' "
                f"and created_at > '{since}' order by created_at limit 1")
        if a: answer = a[0]["body"]
        else: time.sleep(3)
    check("hosted Yui answers a real turn", bool(answer), (answer or "")[:140].replace("\n", " | "))

    # A paired agent of their own, so we can see nothing else moves.
    s, c = fn("yui-agents", {"action": "create", "name": "Nova", "color": "mint", "pair": True}, tok())
    check("a paired agent of their own is added", s == 200, f"{s} {c if s != 200 else ''}")

    # Remove Arnold: only Arnold goes.
    s, d = fn("yui-agents", {"action": "delete", "id": before["Arnold"]}, tok())
    s2, r = listing()
    check("removing Arnold takes only Arnold out", s == 200 and names(r) == [n for n in CREW if n != "Arnold"] + ["Nova"],
          f"{s} {names(r)}")
    crew = {c["base"]: c for c in (r.get("crew") or [])}
    check("Add agent offers Arnold again (not in the list)", crew.get("arnold", {}).get("agent_id") is None, f"{crew.get('arnold')}")

    # Put Arnold back: he lands with the crew, above Nova; nobody else changes.
    s, a = fn("yui-agents", {"action": "crew_add", "base": "arnold"}, tok())
    check("crew_add puts Arnold back", s == 200 and a.get("added") is True and a["agent"]["name"] == "Arnold", f"{s} added={a.get('added')}")
    s2, r = listing()
    after = ids(r)
    check("Arnold is back with the crew, above the paired agent", names(r) == [n for n in CREW if n != "Arnold"] + ["Arnold", "Nova"],
          f"{names(r)}")
    check("nobody else was replaced (same ids)", all(after[n] == before[n] for n in CREW if n != "Arnold"))
    s, a2 = fn("yui-agents", {"action": "crew_add", "base": "arnold"}, tok())
    check("a second tap changes nothing", s == 200 and a2.get("added") is False and a2["agent"]["id"] == after["Arnold"], f"{s} added={a2.get('added')}")
    s, bad = fn("yui-agents", {"action": "crew_add", "base": "urza"}, tok())
    check("only the crew can be added this way", s == 400, f"{s} {bad}")

    # Keep just Yui, then everyone at once.
    for n in ["Basil", "Gouda", "Penny", "Quill", "Arnold"]:
        fn("yui-agents", {"action": "delete", "id": after[n]}, tok())
    s2, r = listing()
    check("any number: just Yui and Nova left", names(r) == ["Yui", "Nova"], f"{names(r)}")
    s, al = fn("yui-agents", {"action": "crew_add_all"}, tok())
    s2, r = listing()
    check("crew_add_all brings everyone back, Nova untouched",
          s == 200 and sorted(names(r)[:6]) == sorted(CREW) and names(r)[-1] == "Nova" and ids(r)["Yui"] == before["Yui"],
          f"{s} {al if s != 200 else ''} {names(r)}")
    s, al2 = fn("yui-agents", {"action": "crew_add_all"}, tok())
    s2, r = listing()
    check("crew_add_all again adds nobody", s == 200 and al2.get("added") == [] and len(r["agents"]) == 7, f"{s} {al2}")
finally:
    sql(f"delete from yui_users where id = '{T}'")
    left = sql("select " + " + ".join(f"(select count(*) from {t} where user_id = '{T}')" for t in
               ["yui_agents", "yui_messages", "yui_connectors", "yui_native_profiles", "yui_sessions"]) + " as n")[0]["n"]
    check("throwaway account deleted, zero rows left", left == 0, f"left={left}")

print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)

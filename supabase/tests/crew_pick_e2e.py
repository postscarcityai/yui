#!/usr/bin/env python3
"""YUI-216, pick your crew, live on yuigui.

Throwaway accounts (never anyone's real one). An app that lists with crew_pick gets Yui alone and
crew_pending; crew_choose adds the picked starters after Yui in the crew's order, saves the choice
on the account, writes Yui's hello naming only who joined, and a repeat call adds nothing. A list
without crew_pick still provisions everyone (older apps), an account that signed up before the
picker never sees it, and a bad base is refused. Accounts are deleted at the end.

    python3 supabase/tests/crew_pick_e2e.py
"""
import sys, uuid
exec(open(__file__.replace("crew_pick_e2e.py", "agents_test.py")).read().split("results = []")[0])

results = []
def check(name, ok, detail=""):
    results.append(ok); print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  [{detail}]" if detail else ""), flush=True)

A, B, C = (str(uuid.uuid4()) for _ in range(3))
for u in (A, B, C):
    sql(f"insert into yui_users(id, apple_sub) values ('{u}','test.{u}')")
def call(u, body):
    return fn("yui-agents", body, mint(u))
def names(r): return [a["name"] for a in r["agents"]]

try:
    # A new app: Yui alone, picker pending.
    s, r = call(A, {"action": "list", "crew_pick": True})
    check("crew_pick list gives Yui alone and a pending pick", s == 200 and names(r) == ["Yui"] and r.get("crew_pending") is True,
          f"{s} {names(r) if s == 200 else r} pending={r.get('crew_pending') if s == 200 else ''}")
    check("the offer still lists every starter with what it does",
          s == 200 and len(r["crew"]) == 6 and all(c.get("tagline") and c.get("about") for c in r["crew"]), "")
    yui_id = r["agents"][0]["id"] if s == 200 else ""
    hello0 = sql(f"select count(*) as n from yui_messages where user_id='{A}' and agent_id='{yui_id}' and meta->>'native'='first'")[0]["n"]
    check("Yui has not said hello before the pick", hello0 == 0, f"{hello0}")
    s, r = call(A, {"action": "list", "crew_pick": True})
    check("a second list keeps the pick pending, Yui alone", s == 200 and names(r) == ["Yui"] and r["crew_pending"] is True, f"{names(r)}")

    s, bad = call(A, {"action": "crew_choose", "bases": ["nobody"]})
    check("a bad base is refused", s == 400 and bad.get("error") == "invalid_base", f"{s} {bad}")

    # The pick: Penny and Basil (out of order on purpose), Yui always.
    s, ch = call(A, {"action": "crew_choose", "bases": ["penny", "basil"]})
    check("crew_choose adds the picked, in the crew's order", s == 200 and ch.get("added") == ["basil", "penny"], f"{s} {ch}")
    s, r = call(A, {"action": "list", "crew_pick": True})
    check("the list is Yui, Basil, Penny and the pick is done", s == 200 and names(r) == ["Yui", "Basil", "Penny"] and r["crew_pending"] is False,
          f"{names(r)} pending={r.get('crew_pending')}")
    row = sql(f"select picked_at is not null as done, bases, own from yui_crew_choice where user_id='{A}'")
    check("the choice is saved on the account", bool(row) and row[0]["done"] and sorted(row[0]["bases"]) == ["basil", "penny", "yui"] and not row[0]["own"], f"{row}")
    hello = sql(f"select body from yui_messages where user_id='{A}' and agent_id='{yui_id}' and meta->>'native'='first'")
    body = hello[0]["body"] if hello else ""
    check("Yui's hello names only Basil and Penny",
          len(hello) == 1 and "Basil feeds you and Penny keeps your lists" in body and "Arnold" not in body and "Quill" not in body, body[:120].replace("\n", " | "))
    s, again = call(A, {"action": "crew_choose", "bases": ["penny", "basil"]})
    check("choosing again adds nobody and says hello once more never",
          s == 200 and again.get("added") == [] and sql(f"select count(*) as n from yui_messages where user_id='{A}' and agent_id='{yui_id}' and meta->>'native'='first'")[0]["n"] == 1, f"{again}")
    # A later listing (a phone with the picker gone) never re-opens it.
    s, r = call(A, {"action": "list"})
    check("an older app's list on the same account changes nothing", s == 200 and names(r) == ["Yui", "Basil", "Penny"] and r["crew_pending"] is False, f"{names(r)}")

    # Bring my own: nobody but Yui, own recorded.
    s, r = call(B, {"action": "list", "crew_pick": True})
    s, ch = call(B, {"action": "crew_choose", "bases": [], "own": True})
    row = sql(f"select own, bases from yui_crew_choice where user_id='{B}'")
    s2, r = call(B, {"action": "list", "crew_pick": True})
    check("bring your own: Yui alone, own saved, no picker again",
          s == 200 and names(r) == ["Yui"] and r["crew_pending"] is False and row[0]["own"] is True and row[0]["bases"] == ["yui"], f"{names(r)} {row}")
    yb = r["agents"][0]["id"]
    hb = sql(f"select body from yui_messages where user_id='{B}' and agent_id='{yb}' and meta->>'native'='first'")
    check("with no one else Yui says it is just the two of you", bool(hb) and "just us for now" in hb[0]["body"], (hb[0]["body"] if hb else "")[:80])

    # An older app: everyone, no picker.
    s, r = call(C, {"action": "list"})
    check("a list without crew_pick still provisions the whole crew",
          s == 200 and names(r) == ["Yui", "Arnold", "Basil", "Gouda", "Penny", "Quill"] and r["crew_pending"] is False, f"{names(r)}")
    check("and leaves no choice row", sql(f"select count(*) as n from yui_crew_choice where user_id='{C}'")[0]["n"] == 0, "")
finally:
    for u in (A, B, C):
        sql(f"delete from yui_users where id = '{u}'")
    left = sql("select (select count(*) from yui_crew_choice where user_id in ('%s','%s','%s')) + (select count(*) from yui_agents where user_id in ('%s','%s','%s')) as n" % (A, B, C, A, B, C))[0]["n"]
    check("throwaway accounts deleted, zero rows left", left == 0, f"left={left}")

print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)

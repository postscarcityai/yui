#!/usr/bin/env python3
"""YUI-228, live on yuigui: a new person answers Arnold's first-plan intake and the week comes back, no second wizard.

Makes a throwaway account, opens Arnold, sends the intake's Send as the app does (a plan event on `first`),
and times the answer. Checks the reply is the built week (This week rewritten, Today filled) with no
further questions ("Two things left", "Finish your split", a second plan). The account is deleted at the end.

    python3 supabase/tests/native_first_plan_live.py --out /tmp/yui228-live [--agent arnold]
"""
import argparse, json, sys, time, uuid
from pathlib import Path
exec(open(__file__.replace("native_first_plan_live.py", "agents_test.py")).read().split("results = []")[0])

ap = argparse.ArgumentParser()
ap.add_argument("--out", default="/tmp/yui228-live")
ap.add_argument("--wait", type=int, default=90)
args = ap.parse_args()
OUT = Path(args.out); OUT.mkdir(parents=True, exist_ok=True)

results = []
def check(name, ok, detail=""):
    results.append(ok); print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  [{detail}]" if detail else ""), flush=True)

PLAN = {"goal": "Lift heavy", "days": "3", "time": "45 min", "gear": ["Dumbbells"], "level": "Some experience"}
T = str(uuid.uuid4())
sql(f"insert into yui_users(id, apple_sub) values ('{T}','test.{T}')")
try:
    s, _ = fn("yui-agents", {"action": "list"}, mint(T))
    arn = sql(f"select id from yui_agents where user_id='{T}' and name='Arnold'")
    check("a new account gets Arnold", s == 200 and bool(arn), f"{s}")
    arn = arn[0]["id"]
    time.sleep(8)  # his hello lands
    body = "[yui] first plan plan.goal=\"Lift heavy\" plan.days=3 plan.time=\"45 min\" plan.gear=Dumbbells plan.level=\"Some experience\""
    meta = {"id": "first", "preset": "plan", "value": {"plan": PLAN}}
    s, r = rest("POST", "yui_messages", mint(T), {"user_id": T, "agent_id": arn, "sender": "user", "body": body, "kind": "event", "meta": meta},
                prefer="return=representation")
    check("the intake's Send reaches Arnold", s in (200, 201), f"{s}")
    since, t0 = r[0]["created_at"], time.time()
    got = []
    while time.time() < t0 + args.wait and not got:
        time.sleep(2)
        got = sql(f"select body from yui_messages where user_id='{T}' and agent_id='{arn}' and sender='agent' and created_at > '{since}' order by created_at")
    secs = round(time.time() - t0, 1)
    time.sleep(6)
    got = sql(f"select body from yui_messages where user_id='{T}' and agent_id='{arn}' and sender='agent' and created_at > '{since}' order by created_at")
    text = "\n".join(g["body"] for g in got)
    (OUT / "answer.txt").write_text(text)
    (OUT / "seconds.txt").write_text(str(secs))
    check("Arnold answers within 60 s", bool(got) and secs <= 60, f"{secs}s, {len(got)} messages")
    check("the reply is the built week", "Your week is built: 3 days" in text and "list@days" in text and "card@today" in text, text[:140].replace("\n", " | "))
    check("no second wizard", not any(w in text for w in ["Two things left", "Finish your split", "plan@", 'plan "']), "")
finally:
    sql(f"delete from yui_users where id = '{T}'")
    left = sql("select " + " + ".join(f"(select count(*) from {t} where user_id = '{T}')" for t in
               ["yui_agents", "yui_messages", "yui_sessions"]) + " as n")
    check("throwaway account deleted, zero rows left", left[0]["n"] == 0, f"{left}")

print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)

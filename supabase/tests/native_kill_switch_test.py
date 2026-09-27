#!/usr/bin/env python3
"""YUI-134: the native_enabled kill switch, live on yuigui.

Off: a new account gets no Yui and no crew, and a message to an existing hosted Yui
wakes nothing. On again: the same message gets an answer. The switch is always put
back to what it was, and both throwaway accounts are deleted.

    python3 supabase/tests/native_kill_switch_test.py
"""
import sys, time, uuid
exec(open(__file__.replace("native_kill_switch_test.py", "agents_test.py")).read().split("results = []")[0])

results = []
def check(name, ok, detail=""):
    results.append(ok); print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  [{detail}]" if detail else ""), flush=True)

def switch(v): sql(f"update yui_limits set value = {v} where name = 'native_enabled'")
def answers(uid, agent, since):
    return sql(f"select body from yui_messages where user_id='{uid}' and agent_id='{agent}' and sender='agent' "
               f"and created_at > '{since}'")
def say(uid, agent, body):
    s, r = rest("POST", "yui_messages", mint(uid), {"user_id": uid, "agent_id": agent, "sender": "user",
                "body": body, "kind": "text"}, prefer="return=representation")
    return s, (r[0]["created_at"] if s in (200, 201) else r)
def wait_answer(uid, agent, since, secs):
    end = time.time() + secs
    while time.time() < end:
        a = answers(uid, agent, since)
        if a: return a
        time.sleep(3)
    return []

was = sql("select value from yui_limits where name='native_enabled'")[0]["value"]
A, B = str(uuid.uuid4()), str(uuid.uuid4())
for u in (A, B): sql(f"insert into yui_users(id, apple_sub) values ('{u}','test.{u}')")
try:
    switch(1)
    s, _ = fn("yui-agents", {"action": "list"}, mint(A))
    yui = sql(f"select id from yui_agents where user_id='{A}' and name='Yui'")
    check("on: a new account gets hosted Yui", s == 200 and bool(yui), f"{s}")
    yui = yui[0]["id"]

    switch(0)
    s, _ = fn("yui-agents", {"action": "list"}, mint(B))
    n = sql(f"select count(*) as n from yui_agents where user_id='{B}'")[0]["n"]
    check("off: a new account gets no Yui and no crew", s == 200 and n == 0, f"{s} agents={n}")
    s, t = say(A, yui, "Hi Yui, are you there?")
    check("off: the message is stored", s in (200, 201), f"{s}")
    got = wait_answer(A, yui, t, 30)
    check("off: nothing wakes, no answer in 30 s", not got, f"{got[:1]}")

    switch(1)
    s, t = say(A, yui, "Hi Yui, one more time?")
    got = wait_answer(A, yui, t, 90)
    check("on again: Yui answers", bool(got), (got[0]["body"][:100] if got else ""))
finally:
    switch(was)
    for u in (A, B): sql(f"delete from yui_users where id = '{u}'")
    left = sql("select " + " + ".join(f"(select count(*) from {t} where user_id in ('{A}','{B}'))" for t in
               ["yui_agents", "yui_messages", "yui_connectors", "yui_sessions"]) + " as n")[0]["n"]
    now = sql("select value from yui_limits where name='native_enabled'")[0]["value"]
    check("switch restored, accounts deleted", str(now) == str(was) and left == 0, f"native_enabled={now} left={left}")

print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)

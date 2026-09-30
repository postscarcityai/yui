#!/usr/bin/env python3
"""YUI-40 step 4 widget relay tests against yuigui (live).

yui-widgets: a phone registers its pinned saved screens and gets a widget token; with it
the widget reads an agent's patch rows and sends button events (only for a pinned agent,
only "via": "widget" events, only "[yui] " bodies); nobody else's agent, no other token.
The database trigger asks yui-push for a widget push when an agent row patches a pinned
id; yui-push refuses a call without the shared secret and sends an apns-push-type
"widgets" request to Apple (a made-up token comes back BadDeviceToken, which is how we
see Apple read the topic and push type). Test accounts are deleted at the end. Run it on
its own (management API 429s). Needs a Supabase access token, like accounts_test.py.
"""
import sys, time, uuid, secrets
exec(open(__file__.replace("widgets_test.py", "agents_test.py")).read().split("results = []")[0])

results = []
def check(name, ok, detail=""):
    results.append(bool(ok)); print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  [{detail}]" if detail else ""))

def widget(body, token=None):
    h = {"apikey": PUBLISHABLE}
    if token: h["authorization"] = f"Bearer {token}"
    return http("POST", f"{BASE}/functions/v1/yui-widgets", h, body)

A, B = str(uuid.uuid4()), str(uuid.uuid4())
sql(f"insert into yui_users(id, apple_sub) values ('{A}','test.{A}'),('{B}','test.{B}')")
tokA, tokB = mint(A), mint(B)
try:
    a_agent = fn("yui-agents", {"action": "create", "name": "Coach"}, tokA)[1]["agent"]["id"]
    a_other = fn("yui-agents", {"action": "create", "name": "Penny"}, tokA)[1]["agent"]["id"]
    b_agent = fn("yui-agents", {"action": "create", "name": "Bravo"}, tokB)[1]["agent"]["id"]
    push = secrets.token_hex(32)

    print("== Register")
    pins = [{"agent_id": a_agent, "screen": "today", "ids": [{"id": "today", "preset": "list"}, {"id": "focus", "preset": "timer"}]},
            {"agent_id": a_agent, "screen": "weight", "ids": [{"id": "weight", "preset": "stat"}]},
            {"agent_id": b_agent, "screen": "theirs", "ids": [{"id": "x", "preset": "stat"}]}]
    s, r = widget({"action": "register", "pins": pins, "push_token": push, "environment": "production", "build": 500}, None)
    check("register needs a session", s == 401, str(s))
    s, r = widget({"action": "register", "pins": pins, "push_token": push, "environment": "production", "build": 500}, tokA)
    wt = r.get("widget_token", "") if isinstance(r, dict) else ""
    check("register answers a widget token and pins two screens (B's agent is ignored)", s == 200 and wt.startswith("yui_wt_") and r["pinned"] == 2, str(r))
    rows = sql(f"select screen, token_hash, push_token from yui_widgets where user_id='{A}' order by screen")
    check("two rows, the token is stored only as a hash", [x["screen"] for x in rows] == ["today", "weight"]
          and all(x["token_hash"] != wt and len(x["token_hash"]) == 64 for x in rows))
    s, r = widget({"action": "register", "pins": pins[:2], "widget_token": wt, "push_token": push}, tokA)
    check("registering again with the token keeps it", s == 200 and r["widget_token"] == wt, str(r))
    s, r = widget({"action": "register", "pins": pins[:2], "widget_token": wt, "push_token": push}, tokB)
    check("another account never gets that token", s == 200 and r["widget_token"] != wt and r["pinned"] == 0, str(r))
    s, r = widget({"action": "register", "pins": [], "widget_token": r["widget_token"]}, tokB)

    print("== Event")
    eid = str(uuid.uuid4())
    ev = {"action": "event", "agent_id": a_agent, "id": eid, "body": '[yui] today list checked item="Walk 30 min" saved=today via=widget',
          "meta": {"id": "today", "preset": "list", "value": {"item": "Walk 30 min", "checked": True, "saved": "today", "via": "widget"}}}
    check("event without a token is refused", widget(ev)[0] == 401)
    check("event with a session token is refused (widget tokens only)", widget(ev, tokA)[0] == 401)
    check("event with an unknown widget token is refused", widget(ev, "yui_wt_nope")[0] == 404)
    s, r = widget(ev, wt)
    row = sql(f"select sender, kind, body, meta from yui_messages where id='{eid}'")
    check("event lands as the person's event row", s == 200 and row and row[0]["sender"] == "user" and row[0]["kind"] == "event"
          and row[0]["meta"]["value"]["via"] == "widget", str(r))
    check("a resend is fine and writes nothing twice", widget(ev, wt)[0] == 200
          and sql(f"select count(*)::int n from yui_messages where id='{eid}'")[0]["n"] == 1)
    check("an agent that is not pinned is refused", widget({**ev, "agent_id": a_other, "id": str(uuid.uuid4())}, wt)[0] == 404)
    check("another account's agent is refused", widget({**ev, "agent_id": b_agent, "id": str(uuid.uuid4())}, wt)[0] == 404)
    check("a body that is not an event line is refused", widget({**ev, "id": str(uuid.uuid4()), "body": "hello"}, wt)[0] == 400)
    check("a meta without via=widget is refused", widget({**ev, "id": str(uuid.uuid4()), "meta": {"value": {}}}, wt)[0] == 400)
    check("a bad id is refused", widget({**ev, "id": "nope"}, wt)[0] == 400)

    print("== Read")
    sql(f"""insert into yui_messages(user_id, agent_id, sender, kind, body) values
      ('{A}','{a_agent}','agent','text', E'```yui\\n~weight 178.4 delta=-2.8\\n```'),
      ('{A}','{a_agent}','agent','text', 'Nice work today.')""")
    s, r = widget({"action": "read", "agent_id": a_agent}, wt)
    bodies = [x["body"] for x in r["rows"]] if isinstance(r, dict) else []
    check("read returns the patch row and leaves the chatter out", s == 200 and len(bodies) == 1 and "~weight" in bodies[0], str(r))
    check("read after the newest row is empty", widget({"action": "read", "agent_id": a_agent, "since": r["rows"][-1]["created_at"]}, wt)[1]["rows"] == [])
    check("read of an agent that is not pinned is refused", widget({"action": "read", "agent_id": a_other}, wt)[0] == 404)

    print("== Push")
    secret = sql("select decrypted_secret s from vault.decrypted_secrets where name='yui_widgets_secret'")[0]["s"]
    wid = sql(f"select id from yui_widgets where user_id='{A}' and screen='weight'")[0]["id"]
    # The patch row above already made the database push once, and Apple's BadDeviceToken cleared the token.
    check("the database push from that patch reached Apple and was answered", sql(f"select last_error from yui_widgets where id='{wid}'")[0]["last_error"] == "BadDeviceToken")
    sql(f"update yui_widgets set push_token='{push}', last_error=null where user_id='{A}'")
    def push_call(hdr):
        return http("POST", f"{BASE}/functions/v1/yui-push", {"apikey": PUBLISHABLE, **hdr}, {"action": "widgets", "ids": [wid]})
    check("widgets push without the secret is refused", push_call({})[0] == 401)
    check("widgets push with a wrong secret is refused", push_call({"x-yui-widgets": "nope"})[0] == 401)
    s, r = push_call({"x-yui-widgets": secret})
    res = (r.get("results") or [{}])[0] if isinstance(r, dict) else {}
    # Apple sees a real widgets request: a token that was never issued is BadDeviceToken, never a topic or push-type error.
    check("yui-push sends a widgets push to Apple (made-up token: BadDeviceToken)", s == 200 and res.get("reason") in ("BadDeviceToken", "Unregistered", "DeviceTokenNotForTopic"), str(r))
    left = sql(f"select push_token, last_error from yui_widgets where id='{wid}'")[0]
    check("a token Apple rejects is forgotten until the app registers again", left["push_token"] is None and left["last_error"], str(left))
    sql(f"update yui_widgets set push_token='{push}', last_push_at=null, pending_at=null where user_id='{A}'")
    sql(f"insert into yui_messages(user_id, agent_id, sender, kind, body) values ('{A}','{a_agent}','agent','text', E'```yui\\n~weight 177.9\\n```')")
    time.sleep(6)
    row = sql(f"select last_push_at, push_token, last_error from yui_widgets where user_id='{A}' and screen='weight'")[0]
    check("an agent patch on a pinned id triggers the push through the database", row["last_push_at"] is not None, str(row))
    time.sleep(2)
    row = sql(f"select push_token, last_error from yui_widgets where user_id='{A}' and screen='weight'")[0]
    check("...and Apple's answer to it lands on the row", row["push_token"] is None and bool(row["last_error"]) or row["push_token"] is not None, str(row))

    print("== Unpin")
    s, r = widget({"action": "register", "pins": pins[:1], "widget_token": wt}, tokA)
    check("registering fewer screens forgets the rest", s == 200 and sql(f"select count(*)::int n from yui_widgets where user_id='{A}'")[0]["n"] == 1)
    s, r = widget({"action": "register", "pins": [], "widget_token": wt}, tokA)
    check("registering none forgets all, and the token stops working", sql(f"select count(*)::int n from yui_widgets where user_id='{A}'")[0]["n"] == 0
          and widget({"action": "read", "agent_id": a_agent}, wt)[0] == 404)
finally:
    for u, t in ((A, tokA), (B, tokB)):
        s, r = fn("yui-delete", {}, t)
        if s != 200:
            sql(f"delete from yui_users where id='{u}'")
    left = sql(f"select count(*)::int n from yui_widgets where user_id in ('{A}','{B}')")[0]["n"]
    check("cleanup: test accounts deleted, no widget rows left", left == 0, f"left={left}")

print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)

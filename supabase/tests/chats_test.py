#!/usr/bin/env python3
"""YUI-169 chats tests against yuigui (live).

Two throwaway accounts. Checks through the real PostgREST paths that the app
(yui_user) and a host (yui_connector) see chats the way spec/CHATS.md says:
a first chat for every agent, a second chat, the chat a reply lands in, the
title, rename, the last chat that stays, delete taking its messages, and that
one person never reads or writes another's chat. Every test account is deleted
at the end. Needs a Supabase access token, like accounts_test.py.

The same rules run on a local Postgres with seeded data in chats_local.sh.
"""
import sys, uuid
exec(open(__file__.replace("chats_test.py", "agents_test.py")).read().split("results = []")[0])

results = []
def check(name, ok, detail=""):
    results.append(ok); print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  [{detail}]" if detail else ""))
def code(r): return r.get("message") or r.get("code") or r.get("error") if isinstance(r, dict) else r
def host(body, token=None): return fn("yui-connect", body, token)
def msg(user, agent, chat=None, sender="user", body="hi", meta=None):
    row = {"id": str(uuid.uuid4()), "user_id": user, "agent_id": agent, "sender": sender, "body": body, "kind": "text"}
    if chat: row["chat_id"] = chat
    if meta: row["meta"] = meta
    return row

A, B = str(uuid.uuid4()), str(uuid.uuid4())
sql(f"insert into yui_users(id, apple_sub) values ('{A}','test.{A}'),('{B}','test.{B}')")
tokA, tokB = mint(A), mint(B)
min_build = sql("select value from yui_limits where name = 'chats_min_build'")[0]["value"]
try:
    print("== Setup: A pairs Basil on a host, B has one agent")
    s, r = fn("yui-agents", {"action": "create", "name": "Basil", "pair": True}, tokA)
    a_agent = r["agent"]["id"]
    s, p = host({"action": "pair", "code": r["pairing"]["code"], "remote_ref": "basil", "host_name": "Test host"})
    a_ct = p["connector_token"]
    ctA = host({"action": "session"}, a_ct)[1]["access_token"]
    s, r = fn("yui-agents", {"action": "create", "name": "Bee"}, tokB)
    b_agent = r["agent"]["id"]

    print("== The first chat")
    s, r = rest("GET", "yui_chats?select=id,agent_id,is_first,title,titled_by", tokA)
    check("a new agent has exactly one chat, the first, with no title",
          s == 200 and len(r) == 1 and r[0]["agent_id"] == a_agent and r[0]["is_first"] and r[0]["title"] is None, f"{s} {r}")
    first = r[0]["id"]
    s, r = rest("GET", "yui_chats?select=id", tokB)
    check("B sees only its own chat", s == 200 and len(r) == 1 and r[0]["id"] != first, f"{s} {r}")
    s, r = rest("GET", "yui_chats?select=id", None)
    check("no token, no chats", s in (401, 403), f"{s}")
    s, r = rest("GET", "yui_chats?select=id", ctA)
    check("a host has no grant on yui_chats", s in (401, 403) or r == [], f"{s} {code(r)}")

    print("== A message with no chat_id (an old app) lands in the newest chat and is stamped")
    old = msg(A, a_agent, body="hello from an old app")
    s, r = rest("POST", "yui_messages", tokA, old, prefer="return=representation")
    check("the row lands in the first chat", s == 201 and r[0]["chat_id"] == first, f"{s} {code(r)}")
    check("the host is told the chat: id, first, new",
          r[0]["meta"].get("chat") == {"id": first, "first": True, "new": True}, f"{r[0]['meta']}")

    print("== A second chat")
    c2 = str(uuid.uuid4())
    s, r = rest("POST", "yui_chats", tokA, {"id": c2, "user_id": A, "agent_id": a_agent})
    if min_build >= 10000:
        check("a second chat needs a build at or above chats_min_build (update_needed)",
              s in (401, 403) and "update_needed" in str(r), f"{s} {code(r)}")
        sql(f"insert into yui_devices(user_id, name, app_build) values ('{A}', 'test phone', 99999)")
        s, r = rest("POST", "yui_chats", tokA, {"id": c2, "user_id": A, "agent_id": a_agent})
    check("a second chat is made", s == 201, f"{s} {code(r)}")
    s, r = rest("POST", "yui_chats", tokA, {"id": str(uuid.uuid4()), "user_id": A, "agent_id": b_agent})
    check("A cannot make a chat for B's agent", s in (401, 403, 409), f"{s} {code(r)}")
    s, r = rest("POST", "yui_chats", tokA, {"id": str(uuid.uuid4()), "user_id": A, "agent_id": a_agent, "title": "mine"})
    check("the app cannot set a title on insert", s in (401, 403), f"{s} {code(r)}")
    ask = msg(A, a_agent, chat=c2, body="What should I eat before a 10k run this weekend")
    s, r = rest("POST", "yui_messages", tokA, ask, prefer="return=representation")
    check("the first row in it is new and not first",
          s == 201 and r[0]["meta"]["chat"] == {"id": c2, "first": False, "new": True}, f"{s} {code(r)}")
    s, r = rest("GET", f"yui_chats?select=title,titled_by&id=eq.{c2}", tokA)
    check("it is titled from the first ask, at a word", r == [{"title": "What should I eat before a 10k", "titled_by": "auto"}], f"{r}")
    s, r = rest("POST", "yui_messages", tokA, msg(A, a_agent, chat=str(uuid.uuid4())))
    check("a row naming a chat that does not exist is refused", s in (400, 403, 409, 422) and "chat_not_found" in str(r), f"{s} {code(r)}")
    s, r = rest("POST", "yui_messages", tokB, msg(B, b_agent, chat=c2))
    check("B cannot write into A's chat", s in (400, 403, 409, 422), f"{s} {code(r)}")

    print("== Replies land in the chat of the row they answer")
    s, r = rest("POST", "yui_messages", ctA, msg(A, a_agent, sender="agent", body="Oats and a banana.", meta={"turn": [ask["id"]]}),
                prefer="return=representation")
    check("the host answers the second chat's row: it lands in the second chat", s == 201 and r[0]["chat_id"] == c2, f"{s} {code(r)}")
    s, r = rest("POST", "yui_messages", ctA, msg(A, a_agent, sender="agent", body="Answering the old row.", meta={"turn": [old["id"]]}),
                prefer="return=representation")
    check("the host answers the old row: it lands in the first chat even though the second is newer",
          s == 201 and r[0]["chat_id"] == first, f"{s} {code(r)}")
    s, r = rest("POST", "yui_messages", ctA, {**msg(A, a_agent, sender="agent", body="x"), "chat_id": first})
    check("a host cannot set chat_id itself", s in (401, 403), f"{s} {code(r)}")
    s, r = rest("POST", "yui_messages", ctA, msg(A, a_agent, sender="agent", body="A note for the first chat.", meta={"chat": first}),
                prefer="return=representation")
    check("a host can name a chat for a row with no turn", s == 201 and r[0]["chat_id"] == first, f"{s} {code(r)}")

    print("== The list")
    s, r = rest("GET", f"yui_chat_list?select=id,title,last_sender,last_body,unread&agent_id=eq.{a_agent}&order=last_at.desc", tokA)
    check("both chats are listed with the last line said", s == 200 and len(r) == 2 and {x["id"] for x in r} == {first, c2}
          and all(x["last_body"] for x in r), f"{s} {r}")
    check("an agent line newer than seen_at is unread", all(x["unread"] for x in r), f"{r}")
    s, r = rest("PATCH", f"yui_chats?id=eq.{c2}", tokA, {"seen_at": "2999-01-01T00:00:00+00:00"}, prefer="return=representation")
    check("the app can mark a chat seen", s == 200 and len(r) == 1, f"{s} {code(r)}")
    s, r = rest("PATCH", f"yui_chats?id=eq.{c2}", tokA, {"is_first": True})
    check("the app cannot set is_first", s in (401, 403), f"{s} {code(r)}")
    s, r = rest("PATCH", f"yui_chats?id=eq.{c2}", tokB, {"title": "hijack"}, prefer="return=representation")
    check("B cannot rename A's chat", s in (401, 403) or r == [], f"{s} {r}")

    print("== Rename and delete")
    s, r = rest("PATCH", f"yui_chats?id=eq.{c2}", tokA, {"title": "Tuesday's groceries"}, prefer="return=representation")
    check("rename sets titled_by person", s == 200 and r[0]["title"] == "Tuesday's groceries" and r[0]["titled_by"] == "person", f"{s} {r}")
    s, r = rest("PATCH", f"yui_chats?id=eq.{c2}", tokA, {"title": "x" * 61})
    check("a title over 60 characters is refused", s in (400, 409, 422), f"{s} {code(r)}")
    s, r = rest("DELETE", f"yui_chats?id=eq.{c2}", tokB, prefer="return=representation")
    check("B cannot delete A's chat", s in (401, 403) or r == [], f"{s} {r}")
    s, r = rest("DELETE", f"yui_chats?id=eq.{c2}", tokA, prefer="return=representation")
    check("A deletes the second chat", s in (200, 204), f"{s} {code(r)}")
    s, r = rest("GET", f"yui_messages?select=id&chat_id=eq.{c2}", tokA)
    check("its messages went with it", s == 200 and r == [], f"{s} {r}")
    s, r = rest("GET", f"yui_messages?select=id&chat_id=eq.{first}", tokA)
    check("the first chat's messages stayed", s == 200 and len(r) >= 3, f"{s} {len(r) if isinstance(r, list) else r}")
    s, r = rest("DELETE", f"yui_chats?id=eq.{first}", tokA)
    check("the last chat cannot be deleted (last_chat)", s in (400, 403, 409) and "last_chat" in str(r), f"{s} {code(r)}")

    print("== Deleting the agent takes its chats")
    fn("yui-agents", {"action": "delete", "id": a_agent}, tokA)
    left = sql(f"select count(*) as n from yui_chats where user_id = '{A}'")[0]["n"]
    check("no chat is left for the deleted agent", left == 0, f"{left}")
finally:
    sql(f"delete from yui_users where id in ('{A}','{B}')")
    left = sql("select " + " + ".join(f"(select count(*) from {t} where user_id in ('{A}','{B}'))" for t in
               ["yui_agents", "yui_messages", "yui_connectors", "yui_pairings", "yui_chats", "yui_devices"]) + " as n")
    check("test accounts deleted, zero rows left", left[0]["n"] == 0, f"{left}")

print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)

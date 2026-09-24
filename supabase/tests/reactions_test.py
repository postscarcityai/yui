#!/usr/bin/env python3
"""YUI-49 reaction tests against PROOF (live).

A reaction is one event row from the app; a trigger copies its emoji onto the
reacted agent message. Only the person's own agent messages, only the six
emoji, newest wins, null takes it back, and the host reads the reaction but
cannot set it. Every test account is deleted at the end. Needs a Supabase
access token, like accounts_test.py. Spec: yuigui/spec/REACTIONS.md.
"""
import sys, uuid
exec(open(__file__.replace("reactions_test.py", "agents_test.py")).read().split("results = []")[0])

results = []
def check(name, ok, detail=""):
    results.append(ok); print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  [{detail}]" if detail else ""))

def code(r): return r.get("code") or r.get("error") if isinstance(r, dict) else r
def host(body, token=None): return fn("yui-connect", body, token)
def react(user, agent, target, emoji, token, changed=False):
    line = f"[yui] react msg={target} emoji={emoji or 'none'}" + (" changed=true" if changed else "")
    return rest("POST", "yui_messages", token, {
        "user_id": user, "agent_id": agent, "sender": "user", "kind": "event", "body": line,
        "meta": {"react": {"msg": target, "emoji": emoji}}})
def reaction(mid):
    return sql(f"select reaction from yui_messages where id = '{mid}'")[0]["reaction"]

A, B = str(uuid.uuid4()), str(uuid.uuid4())
sql(f"insert into yui_users(id, apple_sub) values ('{A}','test.{A}'),('{B}','test.{B}')")
tokA, tokB = mint(A), mint(B)
try:
    print("== Setup: A and B each pair an agent; the agents write one reply each")
    def paired(tok, ref):
        s, r = fn("yui-agents", {"action": "create", "name": ref.title(), "pair": True}, tok)
        s2, p = host({"action": "pair", "code": r["pairing"]["code"], "remote_ref": ref, "host_name": "Test host"})
        assert s2 == 200, p
        return r["agent"]["id"], host({"action": "session"}, p["connector_token"])[1]["access_token"]
    a_agent, ctA = paired(tokA, "alpha")
    b_agent, ctB = paired(tokB, "bravo")
    def reply(ct, user, agent, body):
        mid = str(uuid.uuid4())
        s, r = rest("POST", "yui_messages", ct, {"id": mid, "user_id": user, "agent_id": agent,
                                                 "sender": "agent", "body": body, "kind": "text"})
        assert s == 201, (s, r)
        return mid
    a_reply = reply(ctA, A, a_agent, "Want me to set up the Tuesday plan?")
    b_reply = reply(ctB, B, b_agent, "Shall I book it?")
    s, r = rest("POST", "yui_messages", tokA, {"user_id": A, "agent_id": a_agent, "sender": "user", "body": "hi"},
                prefer="return=representation")
    a_own = r[0]["id"]

    print("== React")
    s, r = react(A, a_agent, a_reply, "👍", tokA)
    check("app reacts 👍 to its agent's message", s == 201, f"{s} {code(r)}")
    check("the reply now carries 👍", reaction(a_reply) == "👍", reaction(a_reply))
    s, r = rest("GET", f"yui_messages?id=eq.{a_reply}&select=reaction", tokA)
    check("app reads the reaction back", s == 200 and r == [{"reaction": "👍"}], f"{s} {r}")
    s, r = rest("GET", f"yui_messages?select=body,meta&kind=eq.event&sender=eq.user", ctA)
    check("host reads the react event as a turn", s == 200 and len(r) == 1 and r[0]["body"].startswith("[yui] react msg=")
          and r[0]["meta"]["react"]["emoji"] == "👍", f"{s} {r}")
    s, r = rest("GET", f"yui_messages?id=eq.{a_reply}&select=reaction", ctA)
    check("host reads the reaction on its message", s == 200 and r == [{"reaction": "👍"}], f"{s} {r}")

    s, r = react(A, a_agent, a_reply, "🔥", tokA, changed=True)
    check("changing it: newest wins", s == 201 and reaction(a_reply) == "🔥", f"{s} {reaction(a_reply)}")
    s, r = react(A, a_agent, a_reply, None, tokA)
    check("emoji null takes it back", s == 201 and reaction(a_reply) is None, f"{s} {reaction(a_reply)}")
    for e in ["👎", "🤔", "❤️", "⏳"]:
        s, r = react(A, a_agent, a_reply, e, tokA, changed=True)
        check(f"{e} is accepted", s == 201 and reaction(a_reply) == e, f"{s} {code(r)} {reaction(a_reply)}")

    print("== Refused")
    s, r = react(A, a_agent, a_reply, "💩", tokA)
    check("an emoji outside the six is refused", s == 400 and reaction(a_reply) == "⏳", f"{s} {code(r)}")
    s, r = react(A, a_agent, "not-an-id", "👍", tokA)
    check("a react without a message id is refused", s == 400, f"{s} {code(r)}")
    s, r = react(A, a_agent, a_own, "👍", tokA)
    check("the person's own message cannot be reacted to", s == 400 and reaction(a_own) is None, f"{s} {code(r)}")
    s, r = react(A, a_agent, b_reply, "👎", tokA)
    check("another user's message cannot be reacted to", s == 400 and reaction(b_reply) is None, f"{s} {code(r)}")
    s, r = react(B, b_agent, a_reply, "👎", tokB)
    check("B's reaction cannot reach A's message", s == 400 and reaction(a_reply) == "⏳", f"{s} {code(r)}")
    s, r = rest("PATCH", f"yui_messages?id=eq.{a_reply}", tokA, {"reaction": "👍"})
    check("app cannot set the column directly", s in (401, 403) and reaction(a_reply) == "⏳", f"{s} {code(r)}")
    s, r = rest("PATCH", f"yui_messages?id=eq.{a_reply}", ctA, {"reaction": "👍"})
    check("host cannot set the column directly", s in (401, 403) and reaction(a_reply) == "⏳", f"{s} {code(r)}")
    s, r = rest("POST", "yui_messages", ctA, {"user_id": A, "agent_id": a_agent, "sender": "agent", "kind": "text",
                                              "body": "self-like", "reaction": "❤️"})
    check("host cannot write a reply that arrives pre-reacted", s in (401, 403), f"{s} {code(r)}")
    s, r = rest("GET", f"yui_messages?id=eq.{a_reply}&select=reaction", tokB)
    check("B cannot read A's reaction", s == 200 and r == [], f"{s} {r}")

    print("== Out-of-order resend: an older reaction landing late does not win")
    sql(f"insert into yui_messages(user_id, agent_id, sender, kind, body, meta, created_at) values "
        f"('{A}','{a_agent}','user','event','[yui] react msg={a_reply} emoji=👎',"
        f"'{{\"react\":{{\"msg\":\"{a_reply}\",\"emoji\":\"👎\"}}}}', now() - interval '1 hour')")
    check("the newer ⏳ stays", reaction(a_reply) == "⏳", reaction(a_reply))
finally:
    sql(f"delete from yui_users where id in ('{A}','{B}')")
    left = sql("select " + " + ".join(f"(select count(*) from {t} where user_id in ('{A}','{B}'))" for t in
               ["yui_agents", "yui_messages", "yui_connectors", "yui_pairings"]) + " as n")
    check("test accounts deleted, zero rows left", left[0]["n"] == 0, f"{left}")

print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)

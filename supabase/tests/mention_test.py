#!/usr/bin/env python3
"""YUI-44 @mention tests against PROOF (live).

The person, in agent A's thread, mentions agent B with one row. A is not
asked (the row lands handled), B gets a copy with A's recent lines quoted,
B's answer comes back into A's thread in B's name, and an agent that can't
answer yet says so in one line. Agents may @ each other only inside a turn
the person started, depth 1. Every test account is deleted at the end.
Needs a Supabase access token, like accounts_test.py.
"""
import sys, uuid
exec(open(__file__.replace("mention_test.py", "agents_test.py")).read().split("results = []")[0])

results = []
def check(name, ok, detail=""):
    results.append(ok); print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  [{detail}]" if detail else ""))

def code(r): return r.get("code") or r.get("error") or r.get("message") if isinstance(r, dict) else r
def host(body, token=None): return fn("yui-connect", body, token)

def post(token, user, agent, body, sender="user", meta=None, rid=None):
    row = {"id": rid or str(uuid.uuid4()), "user_id": user, "agent_id": agent, "sender": sender,
           "body": body, "kind": "text"}
    if meta is not None: row["meta"] = meta
    s, r = rest("POST", "yui_messages", token, row, prefer="return=minimal")
    return s, r, row["id"]

def thread(agent, token=None):
    s, r = rest("GET", f"yui_messages?agent_id=eq.{agent}&order=created_at.asc,id.asc"
                "&select=id,sender,body,meta,delivered_at,handled_at", token or tokA)
    return r if s == 200 else []

def mention(to, words, handle="bravo", name="Bravo", into=None):
    return post(tokA, A, into or a_agent, f"[yui] mention to={handle}\n{words}",
                meta={"mention": {"to": to, "handle": handle, "name": name}})

A, B = str(uuid.uuid4()), str(uuid.uuid4())
sql(f"insert into yui_users(id, apple_sub) values ('{A}','test.{A}'),('{B}','test.{B}')")
tokA, tokB = mint(A), mint(B)
try:
    print("== Setup: A has alpha and bravo on two hosts and an unpaired one; B has charlie")
    def paired(tok, ref):
        s, r = fn("yui-agents", {"action": "create", "name": ref.title(), "pair": True}, tok)
        s2, p = host({"action": "pair", "code": r["pairing"]["code"], "remote_ref": ref, "host_name": "Test host"})
        assert s2 == 200, p
        return r["agent"]["id"], p["connector_token"], p["connector"]["id"]
    a_agent, a_ct, a_cid = paired(tokA, "alpha")
    b_agent, b_ct, b_cid = paired(tokA, "bravo")
    c_agent, _, _ = paired(tokB, "charlie")
    s, r = fn("yui-agents", {"action": "create", "name": "Loose"}, tokA)
    loose = r["agent"]["id"]
    ctA = host({"action": "session"}, a_ct)[1]["access_token"]
    ctB = host({"action": "session"}, b_ct)[1]["access_token"]

    print("== The person mentions bravo in alpha's thread")
    post(tokA, A, a_agent, "Plan a leg day for Saturday")
    s, r, a_reply = post(ctA, A, a_agent, "Here it is\n```yui\nask a1 \"Squats first?\" Yes|No\n```", sender="agent")
    check("alpha answers normally", s == 201, f"{s} {code(r)}")
    s, r, src = mention(b_agent, "@Bravo does this fit my knee?")
    check("app writes the mention row", s == 201, f"{s} {code(r)}")
    row = next(x for x in thread(a_agent) if x["id"] == src)
    check("the mention lands handled in alpha's thread (alpha was not asked)",
          bool(row["delivered_at"] and row["handled_at"]))
    s, r = rest("GET", f"yui_messages?agent_id=eq.{a_agent}&sender=eq.user&handled_at=is.null&select=id", ctA)
    check("alpha's host never gets the mention as a turn", s == 200 and src not in [x["id"] for x in r], f"{s} {r}")
    copy = [x for x in thread(b_agent) if (x["meta"] or {}).get("mentioned")]
    check("bravo's thread gets one copy", len(copy) == 1, f"{len(copy)}")
    copy = copy[0]
    m = copy["meta"]["mentioned"]
    check("copy names where it came from", m["from"] == a_agent and m["msg"] == src and m["by"] == "person"
          and m["from_name"] == "Alpha" and m["depth"] == 1, f"{m}")
    body = copy["body"]
    check("copy header line", body.startswith(f"[yui] mention from=alpha by=person msg={src}\n"), body[:80])
    check("copy quotes alpha's recent lines, screens as [screen]",
          "> Person: Plan a leg day for Saturday" in body and "> Alpha: Here it is [screen]" in body, body)
    check("copy ends with the person's words", body.rstrip().endswith("@Bravo does this fit my knee?"), body[-60:])
    check("the quoted context leaves out the mention's own header", "to=bravo" not in body)
    s, r = rest("GET", f"yui_messages?agent_id=eq.{b_agent}&sender=eq.user&handled_at=is.null&select=id", ctB)
    check("bravo's host sees it as a turn", s == 200 and [x["id"] for x in r] == [copy["id"]], f"{s} {r}")
    s, r = rest("GET", f"yui_messages?id=eq.{src}&select=id", ctB)
    check("bravo's host still cannot read alpha's thread", s == 200 and r == [], f"{s} {r}")
    status = [x for x in thread(a_agent) if (x["meta"] or {}).get("mention_reply", {}).get("status")]
    check("an online, unmuted agent gets no status line", status == [], f"{status}")

    print("== Bravo answers; the answer comes back in bravo's name")
    s, r, b_reply = post(ctB, A, b_agent, "Swap squats for box squats.\n```yui\nask b1 \"Want the swap?\" Yes|No\n```",
                         sender="agent", meta={"turn": [copy["id"]]})
    check("bravo's host writes its reply", s == 201, f"{s} {code(r)}")
    mirror = [x for x in thread(a_agent) if (x["meta"] or {}).get("mention_reply", {}).get("msg") == b_reply]
    check("one mirror in alpha's thread", len(mirror) == 1, f"{len(mirror)}")
    mr = mirror[0]
    check("mirror is an agent row with bravo's words", mr["sender"] == "agent" and mr["body"].startswith("Swap squats"))
    info = mr["meta"]["mention_reply"]
    check("mirror names bravo and the mention", info["agent"] == b_agent and info["name"] == "Bravo"
          and info["handle"] == "bravo" and info["to"] == src and "turn" not in mr["meta"], f"{mr['meta']}")
    s, r = rest("GET", f"yui_messages?id=eq.{mr['id']}&select=id", ctA)
    check("alpha's host can read the mirror (context)", s == 200 and len(r) == 1, f"{s} {r}")
    s, r, _ = post(ctB, A, b_agent, "Anything else?", sender="agent")
    n = len([x for x in thread(a_agent) if (x["meta"] or {}).get("mention_reply")])
    check("a bravo row that answers nothing mention-y stays in bravo's thread", n == 1, f"{n}")

    print("== Refusals")
    s, r, _ = mention(c_agent, "@Charlie hi", handle="charlie", name="Charlie")
    check("cannot mention another user's agent", s == 400 and "mention_agent_not_found" in str(r), f"{s} {code(r)}")
    check("...and nothing reached charlie", thread(c_agent, tokB) == [])
    s, r, _ = mention(a_agent, "@Alpha hi", handle="alpha", name="Alpha")
    check("cannot mention the agent you're in", s == 400, f"{s} {code(r)}")
    s, r, _ = post(tokA, A, a_agent, "[yui] mention to=x\nhi", meta={"mention": {"to": "not-a-uuid"}})
    check("a mention needs an agent id", s == 400 and "mention_needs_agent" in str(r), f"{s} {code(r)}")
    s, r, dup = mention(b_agent, "once")
    before = len(thread(b_agent))
    s, r = rest("POST", "yui_messages", tokA, {"id": dup, "user_id": A, "agent_id": a_agent, "sender": "user",
                "body": "[yui] mention to=bravo\nonce", "kind": "text", "meta": {"mention": {"to": b_agent}}})
    check("a resend of a mention is 409 and makes no second copy", s == 409 and len(thread(b_agent)) == before,
          f"{s} {len(thread(b_agent))} vs {before}")
    s, r, sid = mention(b_agent, "status lines stay out of the quote")
    q = next(x for x in thread(b_agent) if (x["meta"] or {}).get("mentioned", {}).get("msg") == sid)
    check("quoted context never includes the app's status lines", "It gets this" not in q["body"], q["body"])

    print("== Can't answer yet: one line in the agent's look")
    def status_for(src_id):
        return [x for x in thread(a_agent) if (x["meta"] or {}).get("mention_reply", {}).get("to") == src_id
                and x["meta"]["mention_reply"].get("status")]
    s, r, sid = mention(loose, "@Loose you there?", handle="loose", name="Loose")
    st = status_for(sid)
    check("unpaired agent: 'isn't connected yet'", s == 201 and len(st) == 1 and st[0]["body"] ==
          "Loose isn't connected yet. It gets this once it is." and st[0]["meta"]["mention_reply"]["status"] == "pending",
          f"{s} {st}")
    order = [x["id"] for x in thread(a_agent)]
    check("the status line sorts right under the mention", order.index(st[0]["id"]) == order.index(sid) + 1)
    rest("PATCH", f"yui_agents?id=eq.{b_agent}", tokA, {"push_muted": True})
    s, r, sid = mention(b_agent, "muted check")
    st = status_for(sid)
    check("muted agent: still delivered, says so", len(st) == 1 and "is muted" in st[0]["body"]
          and st[0]["meta"]["mention_reply"]["status"] == "muted", f"{st}")
    rest("PATCH", f"yui_agents?id=eq.{b_agent}", tokA, {"push_muted": False})
    sql(f"update yui_connectors set last_seen_at = now() - interval '5 minutes' where id = '{b_cid}'")
    s, r, sid = mention(b_agent, "asleep check")
    st = status_for(sid)
    check("asleep agent: 'gets this when its computer wakes'", len(st) == 1 and st[0]["body"] ==
          "Bravo is asleep. It gets this when its computer wakes.", f"{st}")
    host({"action": "bye"}, b_ct)
    s, r, sid = mention(b_agent, "offline check")
    st = status_for(sid)
    check("stopped agent: offline", len(st) == 1 and "is offline" in st[0]["body"], f"{st}")
    check("every one of those still reached bravo",
          sum(1 for x in thread(b_agent) if x["body"].rstrip().endswith(("muted check", "asleep check", "offline check"))) == 3)
    ctB = host({"action": "session"}, b_ct)[1]["access_token"]  # back online

    print("== Agents @ each other only inside a turn the person started")
    s, r, ask = post(tokA, A, a_agent, "Ask bravo about my knee")
    s, r, a_says = post(ctA, A, a_agent, "Asking @bravo now.", sender="agent",
                        meta={"turn": [ask], "mentions": ["bravo"]})
    check("alpha's reply with @bravo lands", s == 201, f"{s} {code(r)}")
    got = [x for x in thread(b_agent) if (x["meta"] or {}).get("mentioned", {}).get("msg") == a_says]
    check("bravo gets it, by=agent", len(got) == 1 and got[0]["meta"]["mentioned"]["by"] == "agent"
          and got[0]["body"].startswith(f"[yui] mention from=alpha by=agent msg={a_says}")
          and got[0]["body"].rstrip().endswith("Asking @bravo now."), f"{got}")
    before_a = len(thread(a_agent))
    s, r, b_back = post(ctB, A, b_agent, "Sure. @alpha tell them to rest.", sender="agent",
                        meta={"turn": [got[0]["id"]], "mentions": ["alpha"]})
    after = thread(a_agent)
    check("bravo's answer comes back to alpha's thread", any((x["meta"] or {}).get("mention_reply", {}).get("msg") == b_back
          for x in after))
    check("...but its @alpha starts nothing (depth 1)",
          len(after) == before_a + 1 and not any((x["meta"] or {}).get("mentioned") for x in after), f"{len(after)} vs {before_a}")
    s, r, _ = post(ctA, A, a_agent, "Out of the blue, @bravo", sender="agent", meta={"mentions": ["bravo"]})
    s, r, _ = post(ctA, A, a_agent, "Still out of the blue, @bravo", sender="agent",
                   meta={"turn": [str(uuid.uuid4())], "mentions": ["bravo"]})
    s, r, _ = post(ctA, A, a_agent, "Answering a mirror, @bravo", sender="agent",
                   meta={"turn": [b_back], "mentions": ["bravo"]})
    blue = [x for x in thread(b_agent) if "blue" in x["body"] or "Answering a mirror" in x["body"]]
    check("an agent's @ outside a person's turn does nothing", blue == [], f"{len(blue)}")
    s, r, ask2 = post(tokA, A, a_agent, "Ask charlie")
    s, r, _ = post(ctA, A, a_agent, "@charlie @alpha @nobody", sender="agent",
                   meta={"turn": [ask2], "mentions": ["charlie", "alpha", "nobody"]})
    check("an agent can't reach another user's agent, itself, or a name nobody has",
          thread(c_agent, tokB) == [] and not any("@nobody" in x["body"] for x in thread(b_agent))
          and not any((x["meta"] or {}).get("mentioned") for x in thread(a_agent)))
finally:
    sql(f"delete from yui_users where id in ('{A}','{B}')")
    left = sql("select " + " + ".join(f"(select count(*) from {t} where user_id in ('{A}','{B}'))" for t in
               ["yui_agents", "yui_messages", "yui_connectors", "yui_pairings"]) + " as n")
    check("test accounts deleted, zero rows left", left[0]["n"] == 0, f"{left}")

print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)

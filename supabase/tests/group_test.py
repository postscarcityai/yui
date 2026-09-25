#!/usr/bin/env python3
"""YUI-93 group thread tests against PROOF (live). Spec: yuigui/spec/GROUPS.md.

Three of the person's agents in one group. Who answers (the lead, or the ones
named), copies for the second and third, replies stamped into the group,
handoffs on a hop budget and a turn cap, the guard row with Let it and Stop,
status lines, the min build, and the walls: another user's thread, a
non-member, a host setting thread_id or meta.group, a host reading the group
tables or another agent's rows. Every test account is deleted at the end.
Needs a Supabase access token, like accounts_test.py.
"""
import sys, uuid
exec(open(__file__.replace("group_test.py", "agents_test.py")).read().split("results = []")[0])

results = []
def check(name, ok, detail=""):
    results.append(ok); print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  [{detail}]" if detail else ""))

def code(r): return r.get("code") or r.get("error") or r.get("message") if isinstance(r, dict) else r
def host(body, token=None): return fn("yui-connect", body, token)
def g(row): return (row.get("meta") or {}).get("group") or {}
def gd(row): return g(row)["guard"] if isinstance(g(row).get("guard"), dict) else {}

def post(token, user, agent, body, sender="user", meta=None, thread=None, rid=None):
    row = {"id": rid or str(uuid.uuid4()), "user_id": user, "agent_id": agent, "sender": sender,
           "body": body, "kind": "text"}
    if meta is not None: row["meta"] = meta
    if thread: row["thread_id"] = thread
    s, r = rest("POST", "yui_messages", token, row, prefer="return=minimal")
    return s, r, row["id"]

def say(words, to=None, token=None, rid=None):
    meta = {"group": {"to": to}} if to is not None else None
    return post(token or tokA, A, a_agent, words, meta=meta, thread=gid, rid=rid)

def group(token=None):
    s, r = rest("GET", f"yui_messages?thread_id=eq.{gid}&order=created_at.asc,id.asc"
                "&select=id,agent_id,sender,body,meta,delivered_at,handled_at,created_at", token or tokA)
    return r if s == 200 else []

def turns_for(ct, agent):
    s, r = rest("GET", f"yui_messages?agent_id=eq.{agent}&sender=eq.user&handled_at=is.null"
                "&order=created_at.asc&select=id,body,meta,thread_id", ct)
    return r if s == 200 else []

def ack(ids):
    if ids: sql("update yui_messages set delivered_at = now(), handled_at = now() where id in ("
                + ",".join(f"'{i}'" for i in ids) + ")")

def answer(ct, agent, turn_ids, words, mentions=None):
    meta = {"turn": turn_ids}
    if mentions is not None: meta["mentions"] = mentions
    s, r, rid = post(ct, A, agent, words, sender="agent", meta=meta)
    ack(turn_ids)
    return s, r, rid

A, B = str(uuid.uuid4()), str(uuid.uuid4())
sql(f"insert into yui_users(id, apple_sub) values ('{A}','test.{A}'),('{B}','test.{B}')")
tokA, tokB = mint(A), mint(B)
MIN = int(sql("select value from yui_limits where name = 'group_min_build'")[0]["value"])
try:
    print("== Setup: A has coach, sage, quill on hosts and an unpaired one; B has other")
    def paired(tok, ref):
        s, r = fn("yui-agents", {"action": "create", "name": ref.title(), "pair": True}, tok)
        s2, p = host({"action": "pair", "code": r["pairing"]["code"], "remote_ref": ref, "host_name": "Test host"})
        assert s2 == 200, p
        return r["agent"]["id"], p["connector_token"], p["connector"]["id"]
    a_agent, a_ct, a_cid = paired(tokA, "coach")
    b_agent, b_ct, b_cid = paired(tokA, "sage")
    c_agent, c_ct, c_cid = paired(tokA, "quill")
    o_agent, _, _ = paired(tokB, "other")
    s, r = fn("yui-agents", {"action": "create", "name": "Loose"}, tokA)
    loose = r["agent"]["id"]
    ctA = host({"action": "session"}, a_ct)[1]["access_token"]
    ctB = host({"action": "session"}, b_ct)[1]["access_token"]
    ctC = host({"action": "session"}, c_ct)[1]["access_token"]

    print("== Making a group")
    gid = str(uuid.uuid4())
    newg = {"id": gid, "user_id": A, "title": "Race week", "lead": a_agent}
    s, r = rest("POST", "yui_threads", tokA, newg, prefer="return=minimal")
    check("a phone below the group build gets update_needed", s == 403 and "update_needed" in str(r), f"{s} {code(r)}")
    sql(f"insert into yui_devices(user_id, name, app_build) values ('{A}', 'test phone', {MIN})")
    s, r = rest("POST", "yui_threads", tokA, newg, prefer="return=minimal")
    check("at the group build it makes one", s == 201, f"{s} {code(r)}")
    s, r = rest("GET", f"yui_thread_members?thread_id=eq.{gid}&select=agent_id", tokA)
    check("the lead is seated as a member", s == 200 and [x["agent_id"] for x in r] == [a_agent], f"{r}")
    s, r = rest("POST", "yui_thread_members", tokA, {"thread_id": gid, "agent_id": b_agent, "user_id": A}, prefer="return=minimal")
    s2, r2 = rest("POST", "yui_thread_members", tokA, {"thread_id": gid, "agent_id": c_agent, "user_id": A}, prefer="return=minimal")
    check("the person adds two more", s == 201 and s2 == 201, f"{s} {code(r)} {s2}")
    s, r = rest("POST", "yui_thread_members", tokA, {"thread_id": gid, "agent_id": o_agent, "user_id": A},
                prefer="return=minimal")
    check("another user's agent can't join", s >= 400, f"{s} {code(r)}")
    s, r = rest("GET", f"yui_threads?id=eq.{gid}&select=id", tokB)
    check("another user can't see the group", s == 200 and r == [], f"{s} {r}")
    s, r = rest("POST", "yui_threads", tokB, {"user_id": A, "title": "Sneaky", "lead": a_agent}, prefer="return=minimal")
    check("another user can't make a group for A", s >= 400, f"{s} {code(r)}")
    s, r = rest("PATCH", f"yui_threads?id=eq.{gid}", tokA, {"stopped_at": "2020-01-01T00:00:00Z"})
    check("the app can't set stopped_at by hand (Stop is a row)", s >= 400, f"{s} {code(r)}")
    s, r = rest("PATCH", f"yui_thread_members?thread_id=eq.{gid}&agent_id=eq.{a_agent}", tokA, {"left_at": "now()"})
    check("the lead can't leave", s >= 400 and "group_lead_cannot_leave" in str(r), f"{s} {code(r)}")
    s, r = rest("PATCH", f"yui_threads?id=eq.{gid}", tokA, {"lead": loose})
    check("the lead must be a member", s >= 400 and "group_lead_not_member" in str(r), f"{s} {code(r)}")
    s, r = rest("DELETE", f"yui_threads?id=eq.{gid}", tokA)
    left = sql(f"select count(*) as n from yui_threads where id = '{gid}'")[0]["n"]
    check("no hard delete from the app", left == 1, f"{s} {left}")

    print("== Who answers")
    s, r, m1 = say("how did I sleep?")
    check("a message with no @ lands", s == 201, f"{s} {code(r)}")
    row = next(x for x in group() if x["id"] == m1)
    check("...addressed to the lead", row["agent_id"] == a_agent and g(row)["to"] == [a_agent]
          and g(row)["hop"] == 0 and g(row)["root"] == m1, f"{row['agent_id']} {g(row)}")
    check("...its words kept for the app", g(row)["words"] == "how did I sleep?")
    check("...the header names the group",
          row["body"].startswith(f'[yui] group "Race week" thread={gid} with=coach,sage,quill lead=coach hop=0 from=person msg={m1}\n')
          and row["body"].endswith("how did I sleep?"), row["body"][:140])
    t = turns_for(ctA, a_agent)
    check("the lead's host gets it as a turn", [x["id"] for x in t] == [m1], f"{t}")
    check("nobody else is asked", turns_for(ctB, b_agent) == [] and turns_for(ctC, c_agent) == [])
    s, r, r1 = answer(ctA, a_agent, [m1], "Seven hours, solid.")
    row = next((x for x in group() if x["id"] == r1), None)
    check("the lead's reply is stamped into the group", row is not None and g(row) == {"thread": gid, "root": m1, "hop": 0},
          f"{row and row['meta']}")

    s, r, m2 = say("@Sage @Quill plan Saturday", to=[b_agent, c_agent])
    rows = group()
    main = next(x for x in rows if x["id"] == m2)
    copies = [x for x in rows if g(x).get("copy_of") == m2]
    check("named agents answer: first one gets the row", main["agent_id"] == b_agent and g(main)["to"] == [b_agent, c_agent])
    check("the second gets one copy", len(copies) == 1 and copies[0]["agent_id"] == c_agent, f"{copies}")
    check("the copy quotes the group", "> Person: how did I sleep?" in copies[0]["body"]
          and "> Coach: Seven hours, solid." in copies[0]["body"] and copies[0]["body"].endswith("@Sage @Quill plan Saturday"),
          copies[0]["body"])
    check("the lead is not asked", turns_for(ctA, a_agent) == [])
    s, r, _ = say("hi", to=[o_agent])
    check("naming a non-member is refused", s == 400 and "group_agent_not_member" in str(r), f"{s} {code(r)}")
    s, r, _ = say("hi", to=[loose])
    check("naming the user's own agent that isn't in the group is refused", s == 400, f"{s} {code(r)}")
    s, r, _ = post(tokA, A, a_agent, "[yui] mention to=sage\nhi", thread=gid, meta={"mention": {"to": b_agent}})
    check("a group row can't also be a mention", s == 400 and "group_uses_to" in str(r), f"{s} {code(r)}")
    s, r, _ = post(tokB, B, o_agent, "in A's group", thread=gid)
    check("another user can't write into the group", s >= 400, f"{s} {code(r)}")
    # both answer; sage hands off to coach
    ack([m2, copies[0]["id"]])

    print("== Handoffs on the hop budget")
    s, r, sb = post(ctB, A, b_agent, "Rest Friday. @coach can you move the long run?", sender="agent",
                    meta={"turn": [m2], "mentions": ["coach"]})
    check("sage's reply with @coach lands", s == 201, f"{s} {code(r)}")
    ask = [x for x in group() if g(x).get("msg") == sb and x["sender"] == "user"]
    check("coach gets one handoff ask at hop 1", len(ask) == 1 and ask[0]["agent_id"] == a_agent
          and g(ask[0])["hop"] == 1 and g(ask[0])["from"] == b_agent and g(ask[0])["from_name"] == "Sage"
          and g(ask[0])["root"] == m2, f"{ask and ask[0]['meta']}")
    check("the ask reads like the spec", ask[0]["body"].startswith(f'[yui] group "Race week" thread={gid}')
          and "hop=1 from=sage" in ask[0]["body"].split("\n")[0]
          and ask[0]["body"].rstrip().endswith("Rest Friday. @coach can you move the long run?"), ask[0]["body"])
    s, r = rest("GET", f"yui_messages?agent_id=eq.{a_agent}&meta->mentioned=not.is.null&select=id", tokA)
    check("no depth-1 mention copy is made in a group", s == 200 and r == [], f"{r}")
    check("coach's host sees it as a turn", [x["id"] for x in turns_for(ctA, a_agent)] == [ask[0]["id"]])
    s, r, ca = answer(ctA, a_agent, [ask[0]["id"]], "Moved to Sunday. @quill cards?", mentions=["quill"])
    ask2 = [x for x in group() if g(x).get("msg") == ca and x["sender"] == "user"]
    check("coach's answer (hop 1) hands off to quill at hop 2", len(ask2) == 1 and g(ask2[0])["hop"] == 2
          and ask2[0]["agent_id"] == c_agent, f"{ask2}")
    s, r, qa = answer(ctC, c_agent, [ask2[0]["id"]], "Cards done. @sage check?", mentions=["sage"])
    ask3 = [x for x in group() if g(x).get("msg") == qa and x["sender"] == "user"]
    check("hop 3 still goes (max 3)", len(ask3) == 1 and g(ask3[0])["hop"] == 3, f"{ask3}")
    s, r, sb2 = answer(ctB, b_agent, [ask3[0]["id"]], "Looks good. @quill flash cards too?", mentions=["quill"])
    rows = group()
    guard = [x for x in rows if gd(x).get("msg") == sb2]
    check("hop 4 is held: one guard row, no ask", len(guard) == 1
          and not any(g(x).get("msg") == sb2 and x["sender"] == "user" for x in rows), f"{guard}")
    gr = guard[0]
    check("the guard is in the asker's look and says why", gr["agent_id"] == b_agent and gr["sender"] == "agent"
          and gr["body"] == 'Sage wants to ask Quill: "Looks good. @quill flash cards too?"\nThat\'s 3 handoffs since you last said something.'
          and g(gr)["guard"]["state"] == "held" and g(gr)["guard"]["reason"] == "hops", f"{gr['body']} {g(gr)}")
    check("quill is not asked", turns_for(ctC, c_agent) == [])

    print("== Let it")
    s, r, cont = post(tokA, A, a_agent, f"[yui] group continue guard={gr['id']}", thread=gid,
        meta={"group": {"control": "continue", "guard": gr["id"]}})
    check("Let it lands", s == 201, f"{s} {code(r)}")
    rows = group()
    crow = next(x for x in rows if x["id"] == cont)
    check("...handled on the way in, sits in the lead's thread", crow["handled_at"] and crow["agent_id"] == a_agent)
    held = [x for x in rows if x["sender"] == "user" and g(x).get("msg") == sb2]
    check("the held ask goes to quill on a fresh budget", len(held) == 1 and held[0]["agent_id"] == c_agent
          and g(held[0])["root"] == cont and g(held[0])["hop"] == 1, f"{held}")
    gr2 = next(x for x in rows if x["id"] == gr["id"])
    check("the guard now reads continued", g(gr2)["guard"]["state"] == "continued" and g(gr2)["guard"]["by"] == cont)
    s, r, _ = post(tokA, A, a_agent, f"[yui] group continue guard={gr['id']}", thread=gid,
                   meta={"group": {"control": "continue", "guard": gr["id"]}})
    check("a guard lets through once", s == 400 and "group_guard_gone" in str(r), f"{s} {code(r)}")
    ack([held[0]["id"]])

    print("== The turn cap")
    rest("PATCH", f"yui_threads?id=eq.{gid}", tokA, {"max_turns": 2, "max_hops": 5})
    s, r, m3 = say("@Sage @Quill one more", to=[b_agent, c_agent])
    cp = next(x for x in group() if g(x).get("copy_of") == m3)
    ack([m3, cp["id"]])
    s, r, s3 = post(ctB, A, b_agent, "@coach your turn", sender="agent", meta={"turn": [m3], "mentions": ["coach"]})
    rows = group()
    guard = [x for x in rows if gd(x).get("msg") == s3]
    check("two addressees used both turns: the third is held", len(guard) == 1
          and g(guard[0])["guard"]["reason"] == "turns"
          and guard[0]["body"].endswith("That's 2 turns since you last said something."), f"{guard}")
    rest("PATCH", f"yui_threads?id=eq.{gid}", tokA, {"max_turns": 8, "max_hops": 3})
    s, r = rest("PATCH", f"yui_threads?id=eq.{gid}", tokA, {"max_hops": 9})
    check("max hops stays 1 to 5", s >= 400, f"{s}")

    print("== Stop")
    s, r, m4 = say("@Sage go", to=[b_agent])
    ack([m4])
    s, r, s4 = post(ctB, A, b_agent, "@quill and @coach, over to you", sender="agent",
                    meta={"turn": [m4], "mentions": ["quill", "coach"]})
    pend = [x for x in group() if x["sender"] == "user" and g(x).get("msg") == s4]
    check("two handoffs waiting", len(pend) == 2, f"{len(pend)}")
    sql(f"update yui_messages set delivered_at = now() where id = '{pend[1]['id']}'")  # coach picked its up
    s, r, stop = post(tokA, A, a_agent, "[yui] group stop", thread=gid, meta={"group": {"control": "stop"}})
    check("Stop lands", s == 201, f"{s} {code(r)}")
    rows = group()
    q = next(x for x in rows if x["id"] == pend[0]["id"])
    c = next(x for x in rows if x["id"] == pend[1]["id"])
    check("the ask nobody picked up is cancelled", q["handled_at"] and g(q).get("cancelled") is True)
    check("the one already picked up runs on", not c["handled_at"] and not g(c).get("cancelled"))
    line = [x for x in rows if g(x).get("status") == "stopped"]
    check("one line says so", len(line) == 1 and line[0]["body"] == "Stopped. Quill won't pick up Sage's ask."
          and line[0]["agent_id"] == a_agent, f"{line and line[0]['body']}")
    s, r, late = answer(ctA, a_agent, [c["id"]], "Done. @quill one more?", mentions=["quill"])
    rows = group()
    check("a turn running at Stop finishes, its @s go nowhere",
          not any(g(x).get("msg") == late for x in rows if x["sender"] == "user")
          and not any(gd(x).get("msg") == late for x in rows), "")
    s, r, m5 = say("@Sage fresh start", to=[b_agent])
    ack([m5])
    s, r, s5 = post(ctB, A, b_agent, "@quill after the stop", sender="agent", meta={"turn": [m5], "mentions": ["quill"]})
    check("a new message after Stop starts a fresh chain",
          any(g(x).get("msg") == s5 and x["sender"] == "user" for x in group()))
    ack([x["id"] for x in turns_for(ctC, c_agent)])

    print("== Status lines")
    rest("PATCH", f"yui_agents?id=eq.{c_agent}", tokA, {"push_muted": True})
    s, r, m6 = say("@Quill muted?", to=[c_agent])
    st = [x for x in group() if g(x).get("status") == "muted" and g(x).get("root") == m6]
    check("a muted addressee: one line in its look", len(st) == 1 and st[0]["agent_id"] == c_agent
          and "is muted" in st[0]["body"], f"{st}")
    rest("PATCH", f"yui_agents?id=eq.{c_agent}", tokA, {"push_muted": False})
    host({"action": "bye"}, c_ct)
    s, r, m7 = say("@Quill offline?", to=[c_agent])
    st = [x for x in group() if g(x).get("root") == m7 and g(x).get("status")]
    check("an offline addressee: says so, still gets it", len(st) == 1 and "is offline" in st[0]["body"], f"{st}")
    ctC = host({"action": "session"}, c_ct)[1]["access_token"]
    order = [x["id"] for x in group()]
    check("the status line sorts right under the message", order.index(st[0]["id"]) == order.index(m7) + 1)
    ack([m6, m7])

    print("== Hosts: walls")
    s, r = rest("GET", "yui_threads?select=id", ctA)
    check("a host can't read yui_threads", s >= 400 or r == [], f"{s} {r}")
    s, r = rest("GET", "yui_thread_members?select=agent_id", ctA)
    check("a host can't read yui_thread_members", s >= 400 or r == [], f"{s} {r}")
    s, r = rest("GET", f"yui_messages?id=eq.{sb}&select=id", ctA)
    check("a host can't read another member's rows", s == 200 and r == [], f"{s} {r}")
    s, r, _ = post(ctA, A, a_agent, "sneak in", sender="agent", thread=gid)
    check("a host can't set thread_id", s >= 400, f"{s} {code(r)}")
    s, r, fk = post(ctA, A, a_agent, "fake group", sender="agent", meta={"group": {"thread": gid, "mentions": ["sage"]}})
    s2, r2 = rest("GET", f"yui_messages?id=eq.{fk}&select=meta,thread_id", tokA)
    check("a host's meta.group is dropped", s == 201 and r2[0]["thread_id"] is None and "group" not in r2[0]["meta"], f"{r2}")
    s, r, fk2 = post(tokA, A, a_agent, "solo, forged", meta={"group": {"thread": gid, "to": [b_agent]}})
    s2, r2 = rest("GET", f"yui_messages?id=eq.{fk2}&select=meta,thread_id", tokA)
    check("a solo row's meta.group is dropped", s == 201 and r2[0]["thread_id"] is None and "group" not in r2[0]["meta"], f"{r2}")

    print("== Notes for a host")
    def notes(ct, agent, since="2000-01-01T00:00:00Z"):
        return rest("POST", "rpc/yui_group_notes", ct, {"agent": agent, "thread": gid, "since": since, "upto": None})
    s, r = notes(ctC, c_agent)
    check("quill's host gets the group's other lines", s == 200 and any(x["name"] == "Coach" and x["words"] == "Seven hours, solid."
          for x in r) and any(x["kind"] == "asked" and x["to_names"] == "Coach" for x in r), f"{s} {r if s != 200 else len(r)}")
    check("...never its own rows or guards", s == 200 and not any(x["name"] == "Quill" for x in r)
          and not any("wants to ask" in x["words"] for x in r))
    check("...and the stop", any(x["kind"] == "stopped" for x in r))
    s, r = notes(ctC, b_agent)
    check("a host can't read notes for an agent it doesn't serve", s == 200 and r == [], f"{s} {r}")
    s, r = notes(tokA, a_agent)
    check("the app token gets nothing from the notes call", s >= 400 or r == [], f"{s}")
    rest("PATCH", f"yui_thread_members?thread_id=eq.{gid}&agent_id=eq.{c_agent}", tokA, {"left_at": "now()"})
    s, r = notes(ctC, c_agent)
    check("an agent that left reads nothing more", s == 200 and r == [], f"{s} {r}")
    s, r, _ = say("@Quill still there?", to=[c_agent])
    check("...and can't be addressed", s == 400 and "group_agent_not_member" in str(r), f"{s} {code(r)}")

    print("== Archive")
    rest("PATCH", f"yui_threads?id=eq.{gid}", tokA, {"archived_at": "now()"})
    s, r, _ = say("anyone?")
    check("an archived group takes no messages", s == 400 and "group_archived" in str(r), f"{s} {code(r)}")

    print("== Solo threads unchanged")
    s, r, solo = post(tokA, A, b_agent, "plain solo message")
    s2, r2, sr = post(ctB, A, b_agent, "plain reply @coach", sender="agent", meta={"turn": [solo], "mentions": ["coach"]})
    s3, r3 = rest("GET", f"yui_messages?id=eq.{sr}&select=meta,thread_id", tokA)
    got = [x for x in rest("GET", f"yui_messages?agent_id=eq.{a_agent}&select=meta", tokA)[1]
           if (x["meta"] or {}).get("mentioned", {}).get("msg") == sr]
    check("a solo reply stays solo and its @ is still a depth-1 mention",
          s2 == 201 and r3[0]["thread_id"] is None and "group" not in r3[0]["meta"] and len(got) == 1, f"{r3} {len(got)}")
finally:
    sql(f"delete from yui_users where id in ('{A}','{B}')")
    left = sql("select " + " + ".join(f"(select count(*) from {t} where user_id in ('{A}','{B}'))" for t in
               ["yui_agents", "yui_messages", "yui_connectors", "yui_pairings", "yui_threads", "yui_thread_members",
                "yui_devices"]) + " as n")
    check("test accounts deleted, zero rows left", left[0]["n"] == 0, f"{left}")

print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)

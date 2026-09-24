#!/usr/bin/env python3
"""YUI-7 relay tests against PROOF (live).

The host's database token (role yui_connector, from yui-connect action=session)
may read the user's messages and write agent replies only in threads of agents
bound to its own, unrevoked connector. The app's token (yui_user) writes only
its own side. Realtime delivers only what RLS allows. Every test account is
deleted at the end. Needs a Supabase access token, like accounts_test.py.
"""
import asyncio, json, sys, uuid
exec(open(__file__.replace("relay_test.py", "agents_test.py")).read().split("results = []")[0])

results = []
def check(name, ok, detail=""):
    results.append(ok); print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  [{detail}]" if detail else ""))

def code(r): return r.get("code") or r.get("error") if isinstance(r, dict) else r
def host(body, token=None): return fn("yui-connect", body, token)
def msg(user, agent, sender="user", body="hi", kind="text"):
    return {"user_id": user, "agent_id": agent, "sender": sender, "body": body, "kind": kind}

A, B = str(uuid.uuid4()), str(uuid.uuid4())
sql(f"insert into yui_users(id, apple_sub) values ('{A}','test.{A}'),('{B}','test.{B}')")
tokA, tokB = mint(A), mint(B)
try:
    print("== Setup: each user pairs one agent on their own host; A has a second, unbound agent")
    def paired(tok, ref):
        s, r = fn("yui-agents", {"action": "create", "name": ref.title(), "pair": True}, tok)
        s2, p = host({"action": "pair", "code": r["pairing"]["code"], "remote_ref": ref, "host_name": "Test host"})
        assert s2 == 200, p
        return r["agent"]["id"], p["connector_token"], p["connector"]["id"]
    a_agent, a_ct, a_cid = paired(tokA, "alpha")
    b_agent, b_ct, _ = paired(tokB, "bravo")
    s, r = fn("yui-agents", {"action": "create", "name": "Loose"}, tokA)
    a_loose = r["agent"]["id"]

    print("== Session")
    s, sa = host({"action": "session"}, a_ct)
    check("session returns a db token, the user and its agents", s == 200 and sa["user_id"] == A
          and [x["id"] for x in sa["agents"]] == [a_agent], f"{s}")
    check("session carries the channel guide", bool(sa.get("guide") and sa["guide"]["version"].startswith("v")
          and sa["guide"]["body"].startswith("## You are talking to someone in Yui")))
    s, r = host({"action": "session"}, "yui_ct_not-a-real-token")
    check("session with a bad connector token is 401", s == 401, f"{s}")
    s, r = host({"action": "session"}, tokA)
    check("session with an app token is 401", s == 401, f"{s}")
    s, r = host({"action": "guide"})
    check("guide action is public and matches", s == 200 and r["guide"]["version"] == sa["guide"]["version"], f"{s}")
    ctA = sa["access_token"]
    ctB = host({"action": "session"}, b_ct)[1]["access_token"]

    print("== App side (yui_user)")
    s, r = rest("POST", "yui_messages", tokA, msg(A, a_agent), prefer="return=representation")
    check("app writes its own message", s == 201, f"{s}")
    a_msg = r[0]["id"]
    s, r = rest("POST", "yui_messages", tokA, msg(A, a_agent, sender="agent"))
    check("app cannot write as the agent", s in (401, 403), f"{s} {code(r)}")
    s, r = rest("POST", "yui_messages", tokA, msg(A, b_agent))
    check("app cannot write into another user's agent", s in (401, 403, 409), f"{s} {code(r)}")
    s, r = rest("PATCH", f"yui_messages?id=eq.{a_msg}", tokA, {"body": "edited"})
    check("app cannot edit messages", s in (401, 403), f"{s} {code(r)}")
    s, r = rest("POST", "yui_messages", tokA, {**msg(A, a_agent, body="[yui] n1 ask answer=Yes", kind="event"),
                                               "meta": {"id": "n1", "preset": "ask", "value": {"answer": "Yes"}}})
    check("app writes an event with metadata", s == 201, f"{s}")

    print("== Host side (yui_connector)")
    s, r = rest("GET", "yui_messages?select=id,sender,kind", ctA)
    check("host reads its thread", s == 200 and len(r) == 2, f"{s} {len(r) if isinstance(r, list) else r}")
    s, r = rest("POST", "yui_messages", ctA, msg(A, a_agent, sender="agent", body="hello"), prefer="return=representation")
    check("host writes an agent reply", s == 201, f"{s} {code(r)}")
    s, r = rest("POST", "yui_messages", ctA, msg(A, a_agent, sender="user", body="spoof"))
    check("host cannot write as the user", s in (401, 403), f"{s} {code(r)}")
    s, r = rest("POST", "yui_messages", ctA, msg(A, a_agent, sender="agent", body="x", kind="event"))
    check("host cannot write events", s in (401, 403), f"{s} {code(r)}")
    rest("POST", "yui_messages", tokA, msg(A, a_loose, body="to the loose agent"))
    s, r = rest("GET", f"yui_messages?select=id&agent_id=eq.{a_loose}", ctA)
    check("host cannot read a thread of an agent it does not serve (same user)", s == 200 and r == [], f"{s} {r}")
    s, r = rest("POST", "yui_messages", ctA, msg(A, a_loose, sender="agent"))
    check("host cannot write into an agent it does not serve", s in (401, 403), f"{s} {code(r)}")
    s, r = rest("GET", "yui_messages?select=id", ctB)
    check("other user's host sees none of A's messages", s == 200 and r == [], f"{s} {r}")
    s, r = rest("POST", "yui_messages", ctB, msg(A, a_agent, sender="agent"))
    check("other user's host cannot write into A's thread", s in (401, 403), f"{s} {code(r)}")
    s, r = rest("GET", "yui_agents?select=id", ctA)
    check("host sees only agents it serves", s == 200 and [x["id"] for x in r] == [a_agent], f"{s} {r}")
    for t in ["yui_users", "yui_connectors", "yui_pairings", "yui_devices", "yui_mgmt_tokens", "yui_sessions",
              "yui_channel_guides", "yui_agent_list"]:
        s, r = rest("GET", f"{t}?select=*", ctA)
        check(f"host cannot read {t}", s in (401, 403, 404) or r == [], f"{s} {code(r)}")
    s, r = rest("PATCH", f"yui_messages?id=eq.{a_msg}", ctA, {"body": "edited"})
    check("host cannot edit messages", s in (401, 403), f"{s} {code(r)}")
    s, r = rest("DELETE", f"yui_messages?id=eq.{a_msg}", ctA)
    check("host cannot delete messages", s in (401, 403), f"{s} {code(r)}")
    s, r = rest("GET", "yui_messages?select=id", mint(A, secret="not-the-secret"))
    check("token signed with the wrong secret refused", s == 401, f"{s}")

    print("== Realtime delivers only what RLS allows")
    import websockets
    async def listen(token, n_expected_window=6):
        url = f"wss://{REF}.supabase.co/realtime/v1/websocket?apikey={PUBLISHABLE}&vsn=1.0.0"
        got = []
        async with websockets.connect(url) as ws:
            await ws.send(json.dumps({"topic": "realtime:t", "event": "phx_join", "ref": "1", "join_ref": "1",
                "payload": {"access_token": token, "config": {"broadcast": {"self": False}, "presence": {"key": ""},
                "postgres_changes": [{"event": "INSERT", "schema": "public", "table": "yui_messages"}]}}}))
            ready = False
            loop = asyncio.get_event_loop(); end = loop.time() + 25
            while loop.time() < end:
                try: m = json.loads(await asyncio.wait_for(ws.recv(), 2))
                except asyncio.TimeoutError: m = {}
                if m.get("event") == "system" and m["payload"].get("status") == "ok" and not ready:
                    ready = True
                    await asyncio.sleep(1)
                    await asyncio.to_thread(rest, "POST", "yui_messages", tokA, msg(A, a_agent, body="rt-served"))
                    await asyncio.to_thread(rest, "POST", "yui_messages", tokA, msg(A, a_loose, body="rt-loose"))
                    await asyncio.to_thread(rest, "POST", "yui_messages", tokB, msg(B, b_agent, body="rt-other-user"))
                if m.get("event") == "postgres_changes":
                    got.append(m["payload"]["data"]["record"]["body"])
                if ready and "rt-served" in got and loop.time() > end - 17:
                    break
        return ready, got
    ready, got = asyncio.run(listen(ctA))
    check("host's Realtime subscription is accepted", ready)
    check("host gets its own thread's insert over Realtime", "rt-served" in got, f"{got}")
    check("host does not get another agent's or user's inserts", "rt-loose" not in got and "rt-other-user" not in got, f"{got}")

    print("== Revoking the host cuts it off at once")
    s, r = fn("yui-agents", {"action": "connector_revoke", "id": a_cid}, tokA)
    check("user revokes the host", s == 200, f"{s} {r}")
    s, r = rest("GET", "yui_messages?select=id", ctA)
    check("revoked host's still-valid db token reads nothing", s == 200 and r == [], f"{s} {r}")
    s, r = rest("POST", "yui_messages", ctA, msg(A, a_agent, sender="agent"))
    check("revoked host's db token cannot write", s in (401, 403), f"{s} {code(r)}")
    s, r = host({"action": "session"}, a_ct)
    check("revoked host cannot mint a new session", s == 401, f"{s}")
finally:
    sql(f"delete from yui_users where id in ('{A}','{B}')")
    left = sql("select " + " + ".join(f"(select count(*) from {t} where user_id in ('{A}','{B}'))" for t in
               ["yui_agents", "yui_messages", "yui_connectors", "yui_pairings"]) + " as n")
    check("test accounts deleted, zero rows left", left[0]["n"] == 0, f"{left}")

print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)

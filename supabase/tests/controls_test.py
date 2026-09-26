#!/usr/bin/env python3
"""YUI-70: agent controls on the relay, live against PROOF (spec yuigui spec/CONTROLS.md, section 5).

The host's capability report lands in yui_agents.controls through yui-connect
(action=controls) and the owner's list returns it; a client the agent is
shared with gets null. A control row is the owner's only: the owner inserts
one, a grantee is refused by RLS, the host answers with a control row, and a
host cannot answer into a grantee's thread. The thread's text reads skip
nothing else. yui-push refuses a control row. yui_retention deletes control
rows after 7 days and leaves text rows alone. Throwaway accounts and
@example.com addresses only; everything is removed at the end.

    python3 supabase/tests/controls_test.py
"""
import json, os, sys, uuid
exec(open(__file__.replace("controls_test.py", "agents_test.py")).read().split("results = []")[0])

results = []
def check(name, ok, detail=""):
    ok = bool(ok); results.append(ok); print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  [{detail}]" if detail else ""), flush=True)

RUN = uuid.uuid4().hex[:8]
PROFILE = f"scout-{RUN}"
SAFE = {"terminal": "off", "files": "off", "reach": [], "memory": "off", "runner": "api", "profile": "own", "extra_keys": 0}
REPORT = {"v": 1, "sections": {"soul": "rw", "memory": "rwd", "skills": "rwd", "schedules": "rwd", "model": "r", "channels": "r"}}
O, C = str(uuid.uuid4()), str(uuid.uuid4())
def mail(tag): return f"yui-controls-test-{RUN}-{tag}@example.com"

def rows(path, token):
    s, r = rest("GET", path, token)
    return r if s == 200 else f"{s} {r}"

try:
    sql(f"insert into yui_users(id, apple_sub, email) values ('{O}','test.{O}','{mail('owner')}'), ('{C}','test.{C}','{mail('client')}')")
    tokO, tokC = mint(O), mint(C)

    print("== Schema")
    r = sql("select pg_get_constraintdef(oid) d from pg_constraint where conname = 'yui_messages_kind_check'")[0]
    check("yui_messages.kind takes 'control'", "'control'" in r["d"], r["d"])
    r = sql("select polpermissive from pg_policy where polname = 'yui_messages_control_owner'")
    check("the owner-only insert policy exists and is restrictive", r and r[0]["polpermissive"] is False, r)
    r = sql("select has_column_privilege('yui_user', 'public.yui_agents', 'controls', 'UPDATE') x")[0]
    check("the app cannot write its agent's controls report", not r["x"])

    print("\n== The capability report")
    s, r = fn("yui-agents", {"action": "create", "name": "Scout", "pair": True}, tokO)
    agent = r["agent"]["id"]
    s, r = fn("yui-connect", {"action": "pair", "code": r["pairing"]["code"], "remote_ref": PROFILE, "host_name": "Test Mac"})
    ct = r["connector_token"]
    check("owner pairs a test host", s == 200 and ct, s)
    s, r = fn("yui-agents", {"action": "list"}, tokO)
    own = [x for x in r["agents"] if x["id"] == agent]
    check("before a report the list says controls null", own and own[0].get("controls") is None and "controls" in own[0], own)
    s, r = fn("yui-connect", {"action": "controls", "remote_ref": PROFILE,
                              "controls": {**REPORT, "sections": {**REPORT["sections"], "secrets": "rwd", "model": "rwd"}}}, ct)
    check("yui-connect action=controls stores it", s == 200 and r["agents"] == 1, r)
    s, r = fn("yui-agents", {"action": "list"}, tokO)
    own = [x for x in r["agents"] if x["id"] == agent][0]
    check("the owner's list returns it, cleaned (no unknown section, model stays read only)",
          own["controls"] == {"v": 1, "sections": {"soul": "rw", "memory": "rwd", "skills": "rwd", "schedules": "rwd", "channels": "r"}},
          own["controls"])
    fn("yui-connect", {"action": "controls", "remote_ref": PROFILE, "controls": REPORT}, ct)
    s, r = fn("yui-connect", {"action": "controls", "remote_ref": PROFILE, "controls": {"v": 2, "sections": {}}}, ct)
    check("a report in a version Yui doesn't know is refused", s == 400 and r.get("error") == "invalid_controls", r)
    s, r = fn("yui-connect", {"action": "controls", "remote_ref": PROFILE, "controls": REPORT})
    check("no connector token: 401", s == 401, s)

    print("\n== Shared with a client")
    fn("yui-connect", {"action": "heartbeat", "serving": [PROFILE], "sandbox": {PROFILE: SAFE}}, ct)
    sql(f"insert into yui_agent_grants (agent_id, owner_id, user_id, shared_by) values ('{agent}','{O}','{C}','Sam')")
    s, r = fn("yui-agents", {"action": "list"}, tokC)
    mine = [x for x in r["agents"] if x["id"] == agent]
    check("the client's list has the agent with controls null", mine and mine[0]["shared"] is True and mine[0]["controls"] is None, mine)

    print("\n== Control rows")
    req = {"v": 1, "req": "c-test", "op": "list", "section": "memory"}
    s, _ = rest("POST", "yui_messages", tokO, {"user_id": O, "agent_id": agent, "sender": "user", "kind": "control",
                                               "body": "controls: list memory", "meta": req}, "return=minimal")
    check("the owner inserts a control row", s == 201, s)
    s, r = rest("POST", "yui_messages", tokC, {"user_id": C, "agent_id": agent, "sender": "user", "kind": "control",
                                               "body": "controls: list memory", "meta": req}, "return=minimal")
    check("a client the agent is shared with cannot", s in (401, 403), (s, r))
    s, _ = rest("POST", "yui_messages", tokC, {"user_id": C, "agent_id": agent, "sender": "user", "kind": "text",
                                               "body": "hi coach"}, "return=minimal")
    check("but still writes text in their thread", s == 201, s)
    s, r = fn("yui-connect", {"action": "session", "serving": [PROFILE]}, ct)
    host = r["access_token"]
    got = rows(f"yui_messages?agent_id=eq.{agent}&user_id=eq.{O}&kind=eq.control&select=id,meta", host)
    check("the host reads the owner's control row", isinstance(got, list) and len(got) == 1 and got[0]["meta"]["req"] == "c-test", got)
    ans_id = str(uuid.uuid4())
    ans = {"v": 1, "req": "c-test", "ok": True, "section": "memory", "items": [], "for": got[0]["id"]}
    s, r = rest("POST", "yui_messages", host, {"id": ans_id, "user_id": O, "agent_id": agent, "sender": "agent", "kind": "control",
                                               "body": "controls: list memory", "meta": ans}, "return=minimal")
    check("the host answers with a control row", s == 201, (s, r))
    s, r = rest("POST", "yui_messages", host, {"user_id": C, "agent_id": agent, "sender": "agent", "kind": "control",
                                               "body": "controls: list memory", "meta": ans}, "return=minimal")
    check("the host cannot put a control row in a client's thread", s in (401, 403), (s, r))
    big = {"v": 1, "req": "c-big", "ok": True, "section": "soul", "item": {"text": os.urandom(15000).hex()}}
    s, r = rest("POST", "yui_messages", host, {"user_id": O, "agent_id": agent, "sender": "agent", "kind": "control",
                                               "body": "controls: get soul SOUL.md", "meta": big}, "return=minimal")
    check("a control answer may carry a full 32 KB SOUL.md (meta cap 64 KB for controls)", s == 201, (s, str(r)[:120]))
    got = rows(f"yui_messages?agent_id=eq.{agent}&kind=eq.control&sender=eq.agent&meta->>req=eq.c-test&select=id,meta", tokO)
    check("the app reads the answer by its req", isinstance(got, list) and len(got) == 1 and got[0]["id"] == ans_id, got)
    got = rows(f"yui_messages?agent_id=eq.{agent}&kind=neq.control&select=id,kind", tokO)
    check("the thread's read (kind=neq.control) has no control rows", got == [], got)
    got = rows(f"yui_messages?agent_id=eq.{agent}&kind=eq.control&select=id", tokC)
    check("the client sees no control rows", got == [], got)

    print("\n== No push for a control row")
    s, r = fn("yui-push", {"action": "notify", "message_id": ans_id}, ct)
    check("yui-push refuses a control answer", s == 400 and r.get("error") == "control_row", (s, r))

    print("\n== Retention")
    sql(f"update yui_messages set created_at = now() - interval '8 days' where agent_id = '{agent}' and user_id = '{O}'")
    sql(f"insert into yui_messages (user_id, agent_id, sender, kind, body, created_at) values "
        f"('{O}','{agent}','agent','text','an old reply', now() - interval '8 days')")
    dry = {x["what"]: x["n_rows"] for x in sql("select * from yui_retention(true)")}
    check("the dry run counts control rows", "control_rows" in dry and dry["control_rows"] >= 3, dry.get("control_rows"))
    sql("select * from yui_retention(false)")
    left = sql(f"select kind, body from yui_messages where agent_id = '{agent}' and user_id = '{O}'")
    check("control rows older than 7 days are deleted, the text row stays", left == [{"kind": "text", "body": "an old reply"}], left)
finally:
    sql(f"delete from yui_users where id in ('{O}','{C}'); "
        f"delete from yui_pair_attempts where created_at > now() - interval '1 hour'")

print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)

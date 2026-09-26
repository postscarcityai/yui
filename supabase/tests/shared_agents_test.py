#!/usr/bin/env python3
"""YUI-95: shared agents, live against PROOF (spec yuigui spec/AGENTS.md, "Shared agents").

Templates, grants and yui_agent_grants are server only except a person's own
live grants; the client-safe mark comes only from the host's sandbox report
(yui-connect); grant.py and the database both refuse an agent that is not
client-safe (exit 3, agent_not_client_safe); claiming an invite applies its
template (grants + first messages, in the look picked); a client reads only
their own thread, never another client's or the owner's, and the owner never
reads theirs; the host serves a granted thread only while the grant is live
and the agent is client-safe; a shared thread takes no mentions or groups;
the client may mute and move a shared agent, never rename or delete it;
revoke hides the thread and stops the host at once. Throwaway accounts and
@example.com addresses only; everything is removed at the end.

YUI-97 adds: the list's share_why (owner only) and first_name, grant.py plan
and send (the owner's invite plan), photos both ways in a shared thread, the
revoke push, and the 30-day cleanup of a revoked thread.

    python3 supabase/tests/shared_agents_test.py
"""
import json, os, subprocess, sys, uuid
exec(open(__file__.replace("shared_agents_test.py", "agents_test.py")).read().split("results = []")[0])

results = []
def check(name, ok, detail=""):
    ok = bool(ok); results.append(ok); print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  [{detail}]" if detail else ""), flush=True)

HERE = os.path.dirname(os.path.abspath(__file__))
GRANT = os.path.join(HERE, "..", "scripts", "grant.py")
INVITE = os.path.join(HERE, "..", "scripts", "invite.py")
RUN = uuid.uuid4().hex[:8]
PROFILE = f"coach-{RUN}"
TPL = f"client-{RUN}"
SAFE = {"terminal": "off", "files": "off", "reach": [], "memory": "off", "runner": "api", "profile": "own", "extra_keys": 0}
SHELL = {**SAFE, "terminal": "local", "files": "host"}

def run(script, *args):
    p = subprocess.run([sys.executable, script, *args], capture_output=True, text=True)
    return p.returncode, (p.stdout + p.stderr).strip()

def code(r): return r.get("code") or r.get("error") if isinstance(r, dict) else r
def refused(s): return s in (401, 403, 409)  # RLS, or the owner-or-grant trigger (agent_not_yours)

def mail(tag): return f"yui-share-test-{RUN}-{tag}@example.com"

def beat(ct, report, ref=PROFILE):
    return fn("yui-connect", {"action": "heartbeat", "serving": [ref], "sandbox": {ref: report} if report else {}}, ct)

def up(tok, path, data=b"\x89PNG\r\n\x1a\nyui-share-test"):
    req = urllib.request.Request(f"{BASE}/storage/v1/object/yui-media/{path}", data=data, method="POST",
                                 headers={"apikey": PUBLISHABLE, "authorization": f"Bearer {tok}", "content-type": "image/png"})
    try:
        with urllib.request.urlopen(req) as r: return r.status
    except urllib.error.HTTPError as e: return e.code

def fetch(tok, path):
    req = urllib.request.Request(f"{BASE}/storage/v1/object/authenticated/yui-media/{path}",
                                 headers={"apikey": PUBLISHABLE, "authorization": f"Bearer {tok}"})
    try:
        with urllib.request.urlopen(req) as r: return r.status
    except urllib.error.HTTPError as e: return e.code

def rows(path, token):
    s, r = rest("GET", path, token)
    return r if s == 200 else f"{s} {r}"

O, C1, C2, C3 = (str(uuid.uuid4()) for _ in range(4))
emails = {O: mail("owner"), C1: mail("c1"), C2: mail("c2"), C3: mail("c3")}
invite_email = emails[C1]
try:
    sql("insert into yui_users(id, apple_sub, email) values " +
        ",".join(f"('{u}','test.{u}','{e}')" for u, e in emails.items()))
    tokO, tok1, tok2, tok3 = mint(O), mint(C1), mint(C2), mint(C3)

    print("== Locked down")
    for t in ["yui_agent_templates", "yui_agent_template_items", "yui_agent_grants"]:
        r = sql(f"select relrowsecurity from pg_class where relname = '{t}'")[0]
        check(f"RLS is on for {t}", r["relrowsecurity"])
        for role in ["anon", "authenticated", "yui_connector"]:
            r = sql(f"""select bool_or(has_table_privilege('{role}', 'public.{t}', p)) x
                        from unnest(array['SELECT','INSERT','UPDATE','DELETE']) p""")[0]
            check(f"{role} has no privilege on {t}", not r["x"])
    for t in ["yui_agent_templates", "yui_agent_template_items"]:
        r = sql(f"""select bool_or(has_table_privilege('yui_user', 'public.{t}', p)) x
                    from unnest(array['SELECT','INSERT','UPDATE','DELETE']) p""")[0]
        check(f"yui_user has no privilege on {t} (server only)", not r["x"])
    r = sql("""select has_table_privilege('yui_user', 'public.yui_agent_grants', 'INSERT') i,
                      has_table_privilege('yui_user', 'public.yui_agent_grants', 'DELETE') d,
                      has_column_privilege('yui_user', 'public.yui_agent_grants', 'revoked_at', 'UPDATE') rv,
                      has_column_privilege('yui_user', 'public.yui_agent_grants', 'push_muted', 'UPDATE') m""")[0]
    check("yui_user cannot insert, delete or un-revoke a grant; may mute", not r["i"] and not r["d"] and not r["rv"] and r["m"], r)
    r = sql("select has_column_privilege('yui_user', 'public.yui_agents', 'client_safe', 'UPDATE') x")[0]
    check("the app cannot mark its own agent client-safe", not r["x"])

    print("\n== The owner's agent and host")
    s, r = fn("yui-agents", {"action": "create", "name": "Coach", "pair": True}, tokO)
    agent = r["agent"]["id"]
    s, r = fn("yui-connect", {"action": "pair", "code": r["pairing"]["code"], "remote_ref": PROFILE, "host_name": "Test Mac"})
    ct = r["connector_token"]
    check("owner pairs a test host", s == 200 and ct, s)
    s, r = beat(ct, SHELL)
    a = sql(f"select client_safe, sandbox from yui_agents where id = '{agent}'")[0]
    check("a host with a local shell leaves the agent not client-safe", s == 200 and a["client_safe"] is False, a["sandbox"])
    check("the report says which rule broke", "terminal: local shell" in json.dumps(a["sandbox"]))
    s, r = fn("yui-agents", {"action": "list"}, tokO)
    own = [x for x in (r or {}).get("agents", []) if x["id"] == agent]
    check("the owner's list says why it is not safe to share (YUI-97)",
          own and "terminal: local shell" in (own[0].get("share_why") or []), own)
    rc, out = run(GRANT, "--owner", O, "plan")
    check("grant.py plan with nothing safe: exit 3, a card naming the rule", rc == 3 and "Nothing is safe to share yet" in out
          and "it has a shell on your computer" in out and "plan@invite" not in out, out[-200:])

    print("\n== Refused: not client-safe")
    rc, out = run(GRANT, "--owner", O, "safe", PROFILE)
    check("grant.py safe exits 3 and names the rule", rc == 3 and "terminal: local shell" in out, out[-120:])
    rc, out = run(GRANT, "--owner", O, "grant", PROFILE, emails[C1], "--hello", "hi")
    check("grant.py grant refuses, exit 3, names the rule", rc == 3 and "refused: " in out and "not client-safe" in out and "terminal" in out, out[-160:])
    rc, out = run(GRANT, "--owner", O, "template", "save", TPL, "--title", "Test", "--agent", PROFILE)
    check("grant.py template save refuses, exit 3", rc == 3 and "not client-safe" in out, out[-120:])
    rc, out = run(GRANT, "--owner", O, "grant", PROFILE, emails[C1], "--force")
    check("there is no --force", rc != 0 and "unrecognized arguments" in out, out[-80:])
    for q, name in [
        (f"insert into yui_agent_grants (agent_id, owner_id, user_id) values ('{agent}','{O}','{C1}')", "a grant"),
        (f"""with t as (insert into yui_agent_templates (owner_id, name, title) values ('{O}','raw-{RUN}','Raw') returning id)
             insert into yui_agent_template_items (template_id, agent_id, owner_id) select id, '{agent}', '{O}' from t""", "a template item"),
    ]:
        try:
            sql(q); ok, err = False, "inserted"
        except RuntimeError as e:
            ok, err = "agent_not_client_safe" in str(e), str(e)[-80:]
        check(f"the database refuses {name} for a non-client-safe agent", ok, err)
    check("nothing was granted", sql(f"select count(*)::int n from yui_agent_grants where agent_id = '{agent}'")[0]["n"] == 0)

    print("\n== Client-safe from the host's report")
    s, r = beat(ct, SAFE)
    a = sql(f"select client_safe, client_safe_at, sandbox from yui_agents where id = '{agent}'")[0]
    check("a sandboxed report marks it client-safe", a["client_safe"] is True and a["client_safe_at"], a["sandbox"])
    s, r = beat(ct, None)
    check("a heartbeat with no report clears it", sql(f"select client_safe from yui_agents where id = '{agent}'")[0]["client_safe"] is False)
    s, r = beat(ct, {**SAFE, "runner": "cli-agent"})
    check("a CLI agent as the model runner is not client-safe",
          sql(f"select client_safe from yui_agents where id = '{agent}'")[0]["client_safe"] is False)
    s, r = beat(ct, {**SAFE, "reach": ["kanban"]})
    check("reach into kanban is not client-safe",
          sql(f"select client_safe from yui_agents where id = '{agent}'")[0]["client_safe"] is False)
    beat(ct, SAFE)
    rc, out = run(GRANT, "--owner", O, "safe", PROFILE)
    check("grant.py safe passes now", rc == 0 and "client-safe since" in out, out[-80:])

    print("\n== Template and invite claim")
    rc, out = run(GRANT, "--owner", O, "template", "save", TPL, "--title", "Client default", "--agent", PROFILE,
                  "--look", f"{PROFILE}=candy", "--hello", f"{PROFILE}=Hi! I'm your coach. What are we training for?", "--by", "Sam")
    check("grant.py template save", rc == 0 and "saved template" in out, out[-120:])
    rc, out = run(GRANT, "--owner", O, "template", "show", TPL)
    check("template show lists the agent, look and first message", rc == 0 and "candy" in out and "coach" in out.lower(), out[-120:])
    rc, out = run(INVITE, "add", "--email", invite_email, "--first", "Maya", "--last", "Test", "--template", TPL)
    rc2, out2 = run(INVITE, "approve", invite_email, "--no-testflight")
    check("invite.py add + approve --no-testflight with the template", rc == 0 and rc2 == 0, (out + out2)[-120:])
    got = sql(f"select * from public.yui_claim_invite('{C1}'::uuid, null, '{invite_email}')")
    check("claim by the Apple ID email", got and got[0]["agent_template"] == TPL, got)
    g = sql(f"select * from yui_agent_grants where user_id = '{C1}'")
    check("the claim made one grant, from the template", len(g) == 1 and g[0]["agent_id"] == agent and g[0]["template"] == TPL
          and g[0]["shared_by"] == "Sam" and g[0]["theme"].get("preset") == "candy", g)
    m = sql(f"select sender, body, meta from yui_messages where user_id = '{C1}' and agent_id = '{agent}'")
    check("and the first message waits at the top of the thread", len(m) == 1 and m[0]["sender"] == "agent"
          and m[0]["body"].startswith("Hi! I'm your coach") and m[0]["meta"].get("first") is True, m)
    s, r = fn("yui-agents", {"action": "list"}, tok1)
    mine = [x for x in (r or {}).get("agents", []) if x["id"] == agent]
    check("the client's list has the agent, shared, in the picked look",
          s == 200 and len(mine) == 1 and mine[0]["shared"] is True and mine[0]["theme"].get("preset") == "candy"
          and mine[0]["shared_by"] == "Sam" and mine[0]["remote_ref"] is None and mine[0]["commands"] is None, mine)
    s, r = fn("yui-agents", {"action": "list"}, tokO)
    own = [x for x in (r or {}).get("agents", []) if x["id"] == agent]
    check("the owner's list still has it once, as their own", len(own) == 1 and own[0]["shared"] is False, own)
    check("and says it is safe to share", own and own[0].get("share_why") == [], own)
    check("the client's row carries no host details (share_why null)", mine and mine[0].get("share_why") is None, mine)
    s, r = fn("yui-agents", {"action": "list"}, tok1)
    check("the invited client's list says their first name", s == 200 and r.get("first_name") == "Maya", r.get("first_name"))
    s, r = fn("yui-agents", {"action": "list"}, tokO)
    check("the owner's does not", s == 200 and r.get("first_name") is None, r.get("first_name"))

    print("\n== The owner's invite plan (YUI-97)")
    rc, out = run(GRANT, "--owner", O, "plan")
    check("grant.py plan offers the safe agent in one plan", rc == 0 and "plan@invite" in out and "apple_id_email:email!" in out
          and "coach_says:long" in out
          and 'pick@agents "Which agents do they get?" "Coach"' in out and "choose@save" in out, out[-300:])
    ans = {"plan": {"who": {"first": "Ren", "last": "Test", "Apple ID email": emails[C3]},
                    "agents": {"picked": ["Coach"]}, "look": {"choice": "Ocean"},
                    "hello": {"Coach says": "Hi Ren, I'm Coach.", "Your name, as they see it": "Sam"},
                    "save": {"choice": "Just this once"}}}
    rc, out = run(GRANT, "--owner", O, "send", "--answers", json.dumps(ans), "--dry-run")
    d = json.loads(out.splitlines()[-1]) if rc == 0 else {}
    check("send --dry-run reads the plan's answers", d.get("agents") == ["Coach"] and d.get("look") == "ocean"
          and d.get("by") == "Sam" and d.get("template", "").startswith("once-"), out[-200:])
    # The real tap, as the agent reads it (Thread.swift YLEvent.line): flattened, lists joined with |.
    tap = (f'[yui] invite plan plan.agents=Coach plan.hello.coach_says="Hi Ren, I\'m Coach." plan.hello.your_name=Sam '
           f'plan.look=Ocean plan.save="Just this once" plan.who.apple_id_email={emails[C3]} plan.who.first=Ren plan.who.last=Test')
    rc, out = run(GRANT, "--owner", O, "send", "--answers", tap, "--no-testflight")
    d = json.loads(out.splitlines()[-1]) if rc == 0 else {}
    check("send saves a template, adds and approves the invite, prints the link",
          rc == 0 and d.get("status") == "approved" and "/i/" in d.get("link", ""), out[-200:])
    got = sql(f"select * from public.yui_claim_invite('{C3}'::uuid, null, '{emails[C3]}')")
    g3 = sql(f"select shared_by, theme, first_message from yui_agent_grants where user_id = '{C3}' and revoked_at is null")
    check("claiming it gives the client Coach, by Sam, in Ocean, with the hello",
          got and len(g3) == 1 and g3[0]["shared_by"] == "Sam" and g3[0]["theme"].get("preset") == "ocean"
          and g3[0]["first_message"] == "Hi Ren, I'm Coach.", g3)
    sql(f"update yui_agent_grants set revoked_at = now() where user_id = '{C3}'")

    print("\n== Grant by script, isolation")
    rc, out = run(GRANT, "--owner", O, "grant", PROFILE, emails[C2], "--hello", "Hello C2", "--look", "ocean")
    check("grant.py grant to a second client", rc == 0 and "granted" in out and "first message" in out, out[-120:])
    rc, out = run(GRANT, "--owner", O, "grant", PROFILE, emails[C2])
    check("granting again is a no-op", rc == 0 and "already has" in out, out[-80:])
    s, _ = rest("POST", "yui_messages", tokO, {"user_id": O, "agent_id": agent, "sender": "user", "body": f"owner secret {RUN}"}, "return=minimal")
    check("the owner writes in their own thread", s == 201, s)
    s, _ = rest("POST", "yui_messages", tok1, {"user_id": C1, "agent_id": agent, "sender": "user", "body": f"c1 secret {RUN}"}, "return=minimal")
    check("client 1 writes in their shared thread", s == 201, s)
    s, _ = rest("POST", "yui_messages", tok2, {"user_id": C2, "agent_id": agent, "sender": "user", "body": f"c2 secret {RUN}"}, "return=minimal")
    check("client 2 writes in theirs", s == 201, s)
    r1 = rows(f"yui_messages?select=user_id,body&agent_id=eq.{agent}", tok1)
    check("client 1 reads only their own rows", isinstance(r1, list) and len(r1) == 2 and {x["user_id"] for x in r1} == {C1}, r1)
    r2 = rows(f"yui_messages?select=user_id,body&agent_id=eq.{agent}", tok2)
    check("client 2 reads only theirs", isinstance(r2, list) and {x["user_id"] for x in r2} == {C2}, r2)
    ro = rows(f"yui_messages?select=user_id,body&agent_id=eq.{agent}", tokO)
    check("the owner never reads a client's thread", isinstance(ro, list) and {x["user_id"] for x in ro} == {O}, ro)
    r3 = rows(f"yui_messages?select=id&agent_id=eq.{agent}", tok3)
    check("someone with no grant reads nothing", r3 == [], r3)
    s, _ = rest("POST", "yui_messages", tok3, {"user_id": C3, "agent_id": agent, "sender": "user", "body": "let me in"}, "return=minimal")
    check("and cannot write to the agent", refused(s), s)
    s, _ = rest("POST", "yui_messages", tok1, {"user_id": C2, "agent_id": agent, "sender": "user", "body": "as c2"}, "return=minimal")
    check("client 1 cannot write as client 2", refused(s), s)
    rg = rows("yui_agent_grants?select=agent_id,user_id", tok1)
    check("client 1 sees only their own grant", isinstance(rg, list) and len(rg) == 1 and rg[0]["user_id"] == C1, rg)
    rg = rows(f"yui_agent_grants?select=user_id&agent_id=eq.{agent}&revoked_at=is.null", tokO)
    check("the owner sees who holds a grant", isinstance(rg, list) and {x["user_id"] for x in rg} == {C1, C2}, rg)
    s, _ = rest("PATCH", f"yui_agent_grants?user_id=eq.{C1}", tok1, {"revoked_at": None, "theme": {}}, "return=minimal")
    check("a client cannot restyle or un-revoke their grant", refused(s), s)

    print("\n== Shared threads stand alone")
    s, r = fn("yui-agents", {"action": "create", "name": "Mine"}, tok1)
    c1_agent = r["agent"]["id"]
    s, r = rest("POST", "yui_messages", tok1, {"user_id": C1, "agent_id": agent, "sender": "user", "body": "@mine hi",
                                               "meta": {"mention": {"to": c1_agent}}}, "return=minimal")
    check("no mention out of a shared thread", s >= 400 and "not_in_a_shared_thread" in json.dumps(r), f"{s} {r}")

    print("\n== The client's settings")
    s, r = fn("yui-agents", {"action": "update", "id": agent, "name": "Mine now"}, tok1)
    check("a client cannot rename a shared agent", s == 403 and code(r) == "shared_agent", f"{s} {code(r)}")
    s, r = fn("yui-agents", {"action": "update", "id": agent, "push_muted": True, "sort": 5}, tok1)
    check("a client mutes and moves it", s == 200 and r["agent"]["push_muted"] is True and r["agent"]["sort"] == 5, f"{s} {code(r)}")
    a = sql(f"select push_muted, name from yui_agents where id = '{agent}'")[0]
    check("the owner's agent is untouched", a["push_muted"] is False and a["name"] == "Coach", a)
    s, r = fn("yui-agents", {"action": "delete", "id": agent}, tok1)
    check("a client cannot delete it", s == 403, f"{s} {code(r)}")
    fn("yui-agents", {"action": "update", "id": agent, "push_muted": False}, tok1)

    print("\n== The host")
    s, r = fn("yui-connect", {"action": "session", "serving": [PROFILE], "sandbox": {PROFILE: SAFE}}, ct)
    ctok = r["access_token"]
    rh = rows(f"yui_messages?select=user_id,body&agent_id=eq.{agent}&sender=eq.user", ctok)
    check("the host reads the owner's and both clients' rows", isinstance(rh, list) and {x["user_id"] for x in rh} == {O, C1, C2}, rh)
    reply = {"id": str(uuid.uuid4()), "user_id": C1, "agent_id": agent, "sender": "agent", "body": "Answer for C1"}
    s, _ = rest("POST", "yui_messages", ctok, reply, "return=minimal")
    check("the host answers in client 1's thread", s == 201, s)
    r1 = rows(f"yui_messages?select=body&agent_id=eq.{agent}&sender=eq.agent", tok1)
    check("client 1 sees the answer, client 2 does not", any(x["body"] == "Answer for C1" for x in r1)
          and not any(x["body"] == "Answer for C1" for x in rows(f"yui_messages?select=body&agent_id=eq.{agent}", tok2)))
    s, _ = rest("POST", "yui_messages", ctok, {"user_id": C3, "agent_id": agent, "sender": "agent", "body": "cold open"}, "return=minimal")
    check("the host cannot write to someone with no grant", refused(s), s)
    s, _ = rest("POST", "yui_messages", ctok, {"user_id": C1, "agent_id": agent, "sender": "agent", "body": "x",
                                              "meta": {"turn": [], "mentions": ["mine"]}}, "return=minimal")
    lastm = sql(f"select meta from yui_messages where user_id = '{C1}' and agent_id = '{agent}' and body = 'x'")
    check("a host's @s in a shared thread are dropped", s == 201 and lastm and "mentions" not in lastm[0]["meta"], lastm)
    s, r = http("POST", f"{BASE}/functions/v1/yui-push", {"apikey": PUBLISHABLE, "authorization": f"Bearer {ct}"},
                {"action": "notify", "message_id": reply["id"]})
    check("the host may push the client its answer", s == 200 and "devices" in r, f"{s} {r}")

    print("\n== Photos in a shared thread (YUI-97)")
    photo = f"{C1}/{agent}/user/{uuid.uuid4()}.png"
    unread = f"{C1}/{agent}/user/{uuid.uuid4()}.png"
    check("the client uploads a photo into their own folder for the shared agent", up(tok1, photo) == 200 and up(tok1, unread) == 200)
    check("someone with no grant cannot", up(tok3, f"{C3}/{agent}/user/{uuid.uuid4()}.png") in (400, 403))
    check("the host reads the client's photo", fetch(ctok, photo) == 200)
    art = f"{C1}/{agent}/agent/{uuid.uuid4()}.png"
    check("the host writes its picture into the client's folder", up(ctok, art) == 200)
    check("the client reads it", fetch(tok1, art) == 200)
    check("client 2 reads neither", fetch(tok2, photo) in (400, 403, 404) and fetch(tok2, art) in (400, 403, 404))
    check("the host cannot write into a folder with no grant", up(ctok, f"{C3}/{agent}/agent/{uuid.uuid4()}.png") in (400, 403))

    print("\n== Paused when the host stops passing")
    beat(ct, SHELL)
    s, r = fn("yui-agents", {"action": "list"}, tok1)
    mine = [x for x in r["agents"] if x["id"] == agent]
    check("the client's list says paused", mine and mine[0]["presence"] == "paused" and mine[0]["client_safe"] is False, mine)
    rh = rows(f"yui_messages?select=user_id&agent_id=eq.{agent}&sender=eq.user", ctok)
    check("the host reads only the owner's rows while unsafe", isinstance(rh, list) and {x["user_id"] for x in rh} == {O}, rh)
    s, _ = rest("POST", "yui_messages", ctok, {"user_id": C1, "agent_id": agent, "sender": "agent", "body": "sneak"}, "return=minimal")
    check("and cannot write to a client", refused(s), s)
    rc, out = run(GRANT, "--owner", O, "grant", PROFILE, emails[C3])
    check("and no new grant", rc == 3, out[-80:])
    beat(ct, SAFE)

    print("\n== Revoke")
    rc, out = run(GRANT, "--owner", O, "revoke", PROFILE, emails[C1])
    check("grant.py revoke", rc == 0 and "revoked" in out, out[-80:])
    s, r = fn("yui-agents", {"action": "list"}, tok1)
    check("gone from the client's list at once", s == 200 and not any(x["id"] == agent for x in r["agents"]))
    check("the client reads nothing of the thread", rows(f"yui_messages?select=id&agent_id=eq.{agent}", tok1) == [])
    s, _ = rest("POST", "yui_messages", tok1, {"user_id": C1, "agent_id": agent, "sender": "user", "body": "still there?"}, "return=minimal")
    check("nor writes to it", refused(s), s)
    rh = rows(f"yui_messages?select=user_id&agent_id=eq.{agent}&sender=eq.user", ctok)
    check("the host stops reading it at once", isinstance(rh, list) and C1 not in {x["user_id"] for x in rh} and C2 in {x["user_id"] for x in rh}, rh)
    s, _ = rest("POST", "yui_messages", ctok, {"user_id": C1, "agent_id": agent, "sender": "agent", "body": "one more"}, "return=minimal")
    check("nor writes to it", refused(s), s)
    s, r = http("POST", f"{BASE}/functions/v1/yui-push", {"apikey": PUBLISHABLE, "authorization": f"Bearer {ct}"},
                {"action": "notify", "message_id": reply["id"]})
    check("nor pushes it", s == 404, f"{s} {r}")
    check("nor reads the client's photos", fetch(ctok, unread) in (400, 403, 404))
    svc = next(k["api_key"] for k in mgmt("api-keys?reveal=true") if k.get("name") == "service_role")
    push = lambda tok, u: http("POST", f"{BASE}/functions/v1/yui-push", {"apikey": PUBLISHABLE, "authorization": f"Bearer {tok}"},
                               {"action": "revoked", "agent_id": agent, "user_id": u})
    s, r = push(ct, C1)
    check("the revoke push needs the service key", s == 401, f"{s} {r}")
    s, r = push(svc, C2)
    check("and pushes nothing for a live grant", s == 409, f"{s} {r}")
    s, r = push(svc, C1)
    check("a revoked grant: a silent push to the client's phones", s == 200 and r.get("ok") and "devices" in r, f"{s} {r}")
    check("grant.py revoke says what the phones were told", "their phones: told" in out, out[-120:])
    rc, out = run(GRANT, "--owner", O, "list", "--all")
    check("grant.py list --all shows the revoked grant", rc == 0 and "revoked" in out and emails[C2] in out, out[-160:])
    rc, out = run(GRANT, "--owner", O, "grant", PROFILE, emails[C1], "--hello", "Welcome back")
    check("granting again later starts a new grant", rc == 0 and "granted" in out, out[-80:])
    r1 = rows(f"yui_messages?select=body&agent_id=eq.{agent}&order=created_at", tok1)
    check("a new, empty thread: only the new first message shows", isinstance(r1, list) and [x["body"] for x in r1] == ["Welcome back"], r1)

    print("\n== 30 days after a revoke (YUI-97)")
    old = sql(f"select count(*)::int n from yui_messages m join yui_agent_grants g on g.agent_id = m.agent_id and g.user_id = m.user_id "
              f"where g.user_id = '{C1}' and g.revoked_at is not null and m.created_at < g.revoked_at")[0]["n"]
    sql(f"update yui_messages m set created_at = m.created_at - interval '31 days' from yui_agent_grants g "
        f"where g.agent_id = m.agent_id and g.user_id = m.user_id and g.user_id = '{C1}' and g.revoked_at is not null "
        f"and m.created_at < g.revoked_at; "
        f"update yui_agent_grants set granted_at = granted_at - interval '31 days', revoked_at = revoked_at - interval '31 days' "
        f"where user_id = '{C1}' and revoked_at is not null")
    due = {r["what"]: r["n_rows"] for r in sql("select * from yui_retention(true)")}
    check("the dry run counts the old thread and grant", old > 0 and due.get("revoked_threads", 0) >= old and due.get("revoked_grants", 0) >= 1, due)
    sql("select * from yui_retention(false)")
    left = sql(f"select body from yui_messages where user_id = '{C1}' and agent_id = '{agent}' order by created_at")
    check("the sweep deletes the old thread, the new one stays", [x["body"] for x in left] == ["Welcome back"], left)
    gl = sql(f"select revoked_at from yui_agent_grants where user_id = '{C1}' and agent_id = '{agent}'")
    check("and the revoked grant; the live one stays", len(gl) == 1 and gl[0]["revoked_at"] is None, gl)

    print("\n== Deleting")
    rc, out = run(GRANT, "--owner", O, "template", "delete", TPL)
    check("template delete", rc == 0 and "deleted" in out, out[-80:])
    sql(f"delete from yui_users where id = '{C2}'")
    check("a client deleting their account removes their grant and thread",
          sql(f"select (select count(*) from yui_agent_grants where user_id = '{C2}') + (select count(*) from yui_messages where user_id = '{C2}') n")[0]["n"] == 0)
    fn("yui-agents", {"action": "delete", "id": agent}, tokO)
    check("the owner deleting the agent removes every grant and thread",
          sql(f"select (select count(*) from yui_agent_grants where agent_id = '{agent}') + (select count(*) from yui_messages where agent_id = '{agent}') n")[0]["n"] == 0)
finally:
    try:
        svc = next(k["api_key"] for k in mgmt("api-keys?reveal=true") if k.get("name") == "service_role")
        names = [r["name"] for r in sql(f"select name from storage.objects where bucket_id = 'yui-media' "
                                        f"and split_part(name, '/', 1) in ('{O}','{C1}','{C2}','{C3}')")]
        if names:
            http("DELETE", f"{BASE}/storage/v1/object/yui-media", {"apikey": svc, "authorization": f"Bearer {svc}"}, {"prefixes": names})
    except Exception as e:
        print(f"storage cleanup: {e}")
    sql(f"delete from yui_invites where email like 'yui-share-test-{RUN}-%'; "
        f"delete from yui_users where id in ('{O}','{C1}','{C2}','{C3}'); "
        f"delete from yui_pair_attempts where created_at > now() - interval '1 hour'")

print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)

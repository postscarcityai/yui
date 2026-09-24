#!/usr/bin/env python3
"""YUI-26: safe for strangers. Live against PROOF, on two throwaway accounts.

Two unrelated strangers, A and B, each with an agent paired to their own host.
Every check runs in both directions (A against B, then B against A):

  1. Isolation. Neither the app token (yui_user) nor the host token
     (yui_connector) of one stranger can read, write, ack, edit or delete the
     other's rows or media, or reach any non-yui table or function in PROOF.
  2. Limits (migration 20260924070000_yui_limits.sql, README "Limits"): size
     caps, per-account and per-host rate buckets, account caps, the media
     quota. A backlog flush after a long quiet spell goes through in one go;
     a resend of a row that already landed gets its 409, never a 429.
  3. Kill switch: suspending an account or a host stops it on the next
     request, tokens minted before included, leaves the other stranger alone,
     and restoring it brings everything back.
  4. Retention: messages past message_retention_days go, fresh ones stay.

Rate checks drain or age a bucket directly instead of flooding PROOF. Both
accounts are deleted at the end. Needs a Supabase access token, like
accounts_test.py.
"""
import sys, time, uuid
exec(open(__file__.replace("strangers_test.py", "agents_test.py")).read().split("results = []")[0])

results = []
def check(name, ok, detail=""):
    results.append(ok); print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  [{detail}]" if detail else ""))

PNG = b"\x89PNG\r\n\x1a\nyui-strangers-test"
STORE = f"{BASE}/storage/v1"
DENIED = (401, 403, 404)

def code(r): return (r.get("code") or r.get("error") or r.get("message")) if isinstance(r, dict) else r
def host(body, token=None): return fn("yui-connect", body, token)
def msg(user, agent, sender="user", body="hi", kind="text", **extra):
    return {"user_id": user, "agent_id": agent, "sender": sender, "body": body, "kind": kind, **extra}

def raw(method, url, tok, data=None, ct="image/png"):
    h = {"apikey": PUBLISHABLE, "content-type": ct}
    if tok: h["authorization"] = f"Bearer {tok}"
    req = urllib.request.Request(url, data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(req) as r: return r.status, r.read()
    except urllib.error.HTTPError as e: return e.code, e.read()

def up(tok, path): return raw("POST", f"{STORE}/object/yui-media/{path}", tok, PNG)[0]
def get(tok, path): return raw("GET", f"{STORE}/object/authenticated/yui-media/{path}", tok)[0]
def P(user, agent, side): return f"{user}/{agent}/{side}/{uuid.uuid4()}.png"

def bucket(key, tokens, age_s=0):
    sql(f"""insert into yui_rate_buckets(key, tokens, at) values ('{key}', {tokens}, now() - interval '{age_s} seconds')
            on conflict (key) do update set tokens = excluded.tokens, at = excluded.at""")

def tokens(key):
    r = sql(f"select tokens from yui_rate_buckets where key = '{key}'")
    return r[0]["tokens"] if r else None

def limit(name): return float(sql(f"select value from yui_limits where name = '{name}'")[0]["value"])

A, B = str(uuid.uuid4()), str(uuid.uuid4())
sql(f"insert into yui_users(id, apple_sub) values ('{A}','test.{A}'),('{B}','test.{B}')")
tok = {A: mint(A), B: mint(B)}
try:
    print("== Setup: two strangers, each pairs one agent on their own host")
    s = {}
    for u, ref in ((A, "alpha"), (B, "bravo")):
        st, r = fn("yui-agents", {"action": "create", "name": ref.title(), "pair": True}, tok[u])
        st2, p = host({"action": "pair", "code": r["pairing"]["code"], "remote_ref": ref, "host_name": "Stranger host"})
        assert st == 200 and st2 == 200, (st, st2, r, p)
        st3, sess = host({"action": "session"}, p["connector_token"])
        assert st3 == 200, sess
        s[u] = {"agent": r["agent"]["id"], "ct": p["connector_token"], "cid": p["connector"]["id"],
                "db": sess["access_token"]}
        st4, m = rest("POST", "yui_messages", tok[u], msg(u, s[u]["agent"], body=f"hello from {ref}"),
                      prefer="return=representation")
        st5, reply = rest("POST", "yui_messages", s[u]["db"], msg(u, s[u]["agent"], sender="agent", body="hi back"),
                          prefer="return=representation")
        s[u]["msg"], s[u]["reply"] = m[0]["id"], reply[0]["id"]
        s[u]["pic"] = P(u, s[u]["agent"], "user")
        assert up(tok[u], s[u]["pic"]) == 200
    check("both strangers are set up: agent, host, a message, a reply, a photo", True)

    for me, other in ((A, "B"), (B, "A")):
        them = B if me == A else A
        who = f"{'A' if me == A else 'B'} vs {other}"
        print(f"== Isolation, {who}")
        t, ct, o = tok[me], s[me]["db"], s[them]
        leaks = []
        for view in ["yui_users", "yui_agents", "yui_agent_list", "yui_messages", "yui_devices", "yui_pairings",
                     "yui_connectors", "yui_limits"]:
            st, r = rest("GET", f"{view}?user_id=eq.{them}&select=user_id" if view != "yui_limits" else "yui_limits?select=name", t)
            if view == "yui_limits":
                check(f"{who}: app reads the public limits", st == 200 and len(r) >= 18, f"{st}")
            elif st == 200 and r:
                leaks.append(view)
        check(f"{who}: app token sees none of the other's rows in any yui_ table", not leaks, ",".join(leaks) or "clean")
        st, r = rest("POST", "yui_messages", t, msg(me, o["agent"]))
        check(f"{who}: app cannot write into the other's thread", st in (401, 403, 409), f"{st} {code(r)}")
        st, r = rest("POST", "yui_messages", t, msg(them, o["agent"]))
        check(f"{who}: app cannot write a row owned by the other", st in (401, 403), f"{st} {code(r)}")
        st, r = rest("DELETE", f"yui_messages?id=eq.{o['msg']}", t, prefer="return=representation")
        st2, r2 = rest("PATCH", f"yui_agents?id=eq.{o['agent']}", t, {"name": "Hijacked"}, prefer="return=representation")
        st3, r3 = rest("DELETE", f"yui_agents?id=eq.{o['agent']}", t, prefer="return=representation")
        still = sql(f"select (select count(*) from yui_messages where id='{o['msg']}')::int m, "
                    f"(select name from yui_agents where id='{o['agent']}') n")[0]
        check(f"{who}: app cannot delete the other's messages or edit/delete their agent",
              still["m"] == 1 and still["n"] in ("Alpha", "Bravo"), f"{st}/{st2}/{st3} {still}")
        st, r = fn("yui-agents", {"action": "delete", "id": o["agent"]}, t)
        check(f"{who}: yui-agents will not touch the other's agent", st == 404, f"{st} {r}")
        st, r = fn("yui-agents", {"action": "connector_revoke", "id": o["cid"]}, t)
        check(f"{who}: yui-agents will not revoke the other's host", st == 404, f"{st} {r}")
        check(f"{who}: app cannot read the other's photo", get(t, o["pic"]) in (400, 403, 404))
        check(f"{who}: app cannot upload into the other's folder", up(t, P(them, o["agent"], "user")) in (400, 403))

        st, r = rest("GET", f"yui_messages?select=id&user_id=eq.{them}", ct)
        check(f"{who}: host token reads nothing of the other's", st == 200 and r == [], f"{st} {r}")
        st, r = rest("POST", "yui_messages", ct, msg(them, o["agent"], sender="agent"))
        check(f"{who}: host token cannot write into the other's thread", st in (401, 403), f"{st} {code(r)}")
        st, r = rest("PATCH", f"yui_messages?id=eq.{o['msg']}", ct, {"handled_at": "2026-09-24T00:00:00Z"},
                     prefer="return=representation")
        check(f"{who}: host token cannot ack the other's rows", (st == 200 and r == []) or st in DENIED, f"{st} {r}")
        check(f"{who}: host token cannot read the other's photo", get(ct, o["pic"]) in (400, 403, 404))
        check(f"{who}: host token cannot upload into the other's thread", up(ct, P(them, o["agent"], "agent")) in (400, 403))
        st, r = fn("yui-push", {"action": "notify", "message_id": o["reply"]}, s[me]["ct"])
        check(f"{who}: host cannot push the other's message", st == 404, f"{st} {r}")

    print("== Nothing outside yui_ is reachable (both roles, all schemas)")
    for role in ("yui_user", "yui_connector"):
        rows = sql(f"""select n.nspname || '.' || c.relname t from pg_class c join pg_namespace n on n.oid = c.relnamespace
                       where c.relkind in ('r','v','m','p','f','S')
                         and n.nspname not in ('pg_catalog', 'information_schema')
                         and has_schema_privilege('{role}', n.oid, 'USAGE')
                         and not (n.nspname = 'public' and c.relname like 'yui\\_%')
                         and not (n.nspname = 'storage' and c.relname in ('buckets', 'objects'))
                         and (has_table_privilege('{role}', c.oid, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
                              or has_any_column_privilege('{role}', c.oid, 'SELECT,INSERT,UPDATE,REFERENCES'))""")
        check(f"{role} can reach no non-yui table, view or sequence in any schema it may use", not rows, str(rows[:5]))
        rows = sql(f"""select p.proname, p.prosecdef from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                       where n.nspname = 'public' and p.proname not like 'yui\\_%'
                         and has_function_privilege('{role}', p.oid, 'EXECUTE')""")
        check(f"{role} can run no non-yui SECURITY DEFINER function in public",
              not [r for r in rows if r["prosecdef"]], str(rows))
        rows = sql(f"""select p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                       where n.nspname = 'public' and p.prosecdef and has_function_privilege('{role}', p.oid, 'EXECUTE')""")
        allowed = {"yui_user": set(), "yui_connector": {"yui_connector_serves"}}[role]
        check(f"{role} can run only the expected yui SECURITY DEFINER functions",
              {r["proname"] for r in rows} <= allowed, str(rows))
        rows = sql(f"""select schemaname || '.' || tablename t from pg_policies
                       where schemaname in ('public', 'storage') and tablename not like 'yui\\_%'
                         and roles && array['public'::name, '{role}'::name]
                         and policyname not like 'yui\\_%'""")
        check(f"no non-yui policy applies to {role} (or PUBLIC)", not rows, str(rows))
    portal = [r["table_name"] for r in sql("select table_name from information_schema.tables where table_schema='public' "
                                           "and table_name not like 'yui\\_%' order by 1")]
    got = []
    for name in portal:
        for u in (A, B):
            for t in (tok[u], s[u]["db"]):
                st, r = rest("GET", f"{name}?select=*&limit=1", t)
                if st == 200 and r:
                    got.append(name)
                st, r = rest("POST", name, t, {})
                if st < 300:
                    got.append(f"{name}(insert)")
    check(f"live: {len(portal)} portal tables x 4 stranger tokens, no row read and no insert accepted",
          not got, ",".join(sorted(set(got))) or "clean")
    st, r = rest("POST", "rpc/set_updated_at", tok[A], {})
    check("live: a portal function is not callable as yui_user", st >= 400, f"{st}")
    auth = mgmt("config/auth")
    check("PROOF Auth still has signups disabled", auth["disable_signup"] is True and not auth.get("external_apple_enabled"))

    print("== Size caps")
    st, r = rest("POST", "yui_messages", tok[A], msg(A, s[A]["agent"], body="x" * 32001))
    check("a 32,001-character message is refused with 400 (the app drops it, never loops)", st == 400, f"{st} {code(r)}")
    st, r = rest("POST", "yui_messages", tok[A], msg(A, s[A]["agent"], body="x" * 32000))
    check("a 32,000-character message goes through", st == 201, f"{st} {code(r)}")
    st, r = rest("POST", "yui_messages", tok[A], msg(A, s[A]["agent"], body="[yui] n1 ask", kind="event",
                                                     meta={"blob": "y" * 20000}))
    check("event metadata over 16 KB is refused with 400", st == 400, f"{st} {code(r)}")
    st, r = rest("POST", "yui_messages", s[A]["db"], msg(A, s[A]["agent"], sender="agent", body="z" * 32001))
    check("an agent reply over 32,000 characters is refused with 400 (the plugin truncates first)", st == 400, f"{st}")

    print("== Rate limits: the person's messages")
    ku = f"msg:u:{A}"
    bucket(ku, 2)
    got = [rest("POST", "yui_messages", tok[A], msg(A, s[A]["agent"], body=f"burst {i}"))[0] for i in range(3)]
    check("with 2 tokens left, 2 messages land and the 3rd is 429", got == [201, 201, 429], f"{got}")
    check("a refused message costs nothing (bucket not driven below zero)", 0 <= tokens(ku) < 1, f"{tokens(ku)}")
    landed = str(uuid.uuid4())
    bucket(ku, 5)
    rest("POST", "yui_messages", tok[A], {**msg(A, s[A]["agent"], body="landed"), "id": landed})
    bucket(ku, 0)
    st, r = rest("POST", "yui_messages", tok[A], {**msg(A, s[A]["agent"], body="landed"), "id": landed})
    check("an outbox resend of a row that landed gets 409 even with an empty bucket", st == 409, f"{st} {code(r)}")
    st, r = rest("POST", "yui_messages", tok[B], msg(B, s[B]["agent"], body="B is not A"))
    check("A's empty bucket does not slow B down", st == 201, f"{st}")
    backlog = int(limit("msg_user_burst")) // 2
    bucket(ku, 0, age_s=600)   # the phone was offline for ten minutes
    got = [rest("POST", "yui_messages", tok[A], msg(A, s[A]["agent"], body=f"offline {i}"))[0] for i in range(backlog)]
    check(f"after ten quiet minutes a {backlog}-message outbox flush lands in one go (folded, not refused)",
          got.count(201) == backlog, f"{got.count(201)}/{backlog}, others {sorted(set(got))}")

    print("== Rate limits: the host")
    kc = f"msg:c:{s[A]['cid']}"
    bucket(kc, 1)
    got = [rest("POST", "yui_messages", s[A]["db"], msg(A, s[A]["agent"], sender="agent", body=f"r{i}"))[0] for i in range(2)]
    check("host replies: last token lands, the next is 429 (the plugin's outbox retries 429)", got == [201, 429], f"{got}")
    st, r = rest("POST", "yui_messages", s[B]["db"], msg(B, s[B]["agent"], sender="agent", body="B's host is fine"))
    check("A's host bucket does not slow B's host", st == 201, f"{st}")
    bucket(kc, 0, age_s=3600)  # the Mac slept for an hour
    n = int(limit("msg_connector_burst")) // 4
    got = [rest("POST", "yui_messages", s[A]["db"], msg(A, s[A]["agent"], sender="agent", body=f"flush {i}"))[0] for i in range(n)]
    check(f"after an hour asleep the host's {n}-reply backlog lands in one go", got.count(201) == n, f"{got.count(201)}/{n}")
    bucket(f"connect:c:{s[A]['cid']}", 0)
    st, r = host({"action": "heartbeat"}, s[A]["ct"])
    check("yui-connect answers 429 when the host's call bucket is empty", st == 429 and code(r) == "rate_limited", f"{st} {r}")
    st, r = host({"action": "heartbeat"}, s[B]["ct"])
    check("B's host still heartbeats", st == 200, f"{st}")
    bucket(f"connect:c:{s[A]['cid']}", 30)
    bucket(f"push:c:{s[A]['cid']}", 0)
    st, r = fn("yui-push", {"action": "notify", "message_id": s[A]["reply"]}, s[A]["ct"])
    check("yui-push answers 429 when the host's push bucket is empty", st == 429, f"{st} {r}")

    print("== Rate limits and caps: the account")
    bucket(f"agents:u:{A}", 0)
    st, r = fn("yui-agents", {"action": "list"}, tok[A])
    check("yui-agents answers 429 when the account's call bucket is empty", st == 429, f"{st} {r}")
    bucket(f"agents:u:{A}", 60)
    bucket(f"pair:u:{A}", 0)
    st, r = fn("yui-agents", {"action": "pair_code", "agent_id": s[A]["agent"]}, tok[A])
    check("minting pairing codes is rate limited (429)", st == 429, f"{st} {r}")
    bucket(f"pair:u:{A}", 20)
    cap = int(limit("agents_per_user"))
    sql(f"insert into yui_agents(user_id, name, handle) select '{A}', 'Filler', 'filler-' || g "
        f"from generate_series(1, {cap - 1}) g")
    st, r = fn("yui-agents", {"action": "create", "name": "One too many"}, tok[A])
    check(f"the {cap + 1}st agent is refused: 403 limit_reached", st == 403 and code(r) == "limit_reached", f"{st} {r}")
    sql(f"delete from yui_agents where user_id = '{A}' and handle like 'filler-%'")
    st, r = fn("yui-agents", {"action": "create", "name": "Fits again"}, tok[A])
    check("under the cap again, creating works", st == 200, f"{st}")
    cap = int(limit("media_uploads_per_day"))
    sql(f"insert into storage.objects(bucket_id, name) select 'yui-media', '{A}/{s[A]['agent']}/user/' || gen_random_uuid() || '.png' "
        f"from generate_series(1, {cap - 1 - 1}) g")  # plus the setup photo
    st1 = up(tok[A], P(A, s[A]["agent"], "user"))
    st2 = up(tok[A], P(A, s[A]["agent"], "user"))
    check(f"photo {cap} of the day uploads, photo {cap + 1} is refused", st1 == 200 and st2 in (400, 403), f"{st1} {st2}")
    st = up(s[A]["db"], P(A, s[A]["agent"], "agent"))
    check("the agent side has its own daily quota", st == 200, f"{st}")
    check("B's photos are not counted against A", up(tok[B], P(B, s[B]["agent"], "user")) == 200)

    print("== Kill switch: one account")
    sess_rt = "strangers-" + secrets.token_urlsafe(24)
    sql(f"insert into yui_sessions(user_id, refresh_hash, expires_at) values ('{A}', "
        f"encode(sha256('{sess_rt}'::bytea), 'hex'), now() + interval '1 day')")
    bucket(ku, 60)
    sql(f"select yui_suspend('user', '{A}', true, 'strangers_test')")
    st, r = rest("POST", "yui_messages", tok[A], msg(A, s[A]["agent"], body="am I off?"))
    check("suspended: the app's still-valid token cannot send (403 account_suspended)",
          st == 403 and r.get("message") == "account_suspended", f"{st} {r.get('message')}")
    check("suspended: the app cannot upload a photo", up(tok[A], P(A, s[A]["agent"], "user")) in (400, 403))
    st, r = fn("yui-agents", {"action": "list"}, tok[A])
    check("suspended: yui-agents refuses (403)", st == 403 and code(r) == "account_suspended", f"{st} {r}")
    st, r = fn("yui-auth", {"grant_type": "refresh", "refresh_token": sess_rt})
    kept = sql(f"select revoked_at from yui_sessions where refresh_hash = encode(sha256('{sess_rt}'::bytea), 'hex')")[0]
    check("suspended: refresh is refused (403) and the session is kept for a restore",
          st == 403 and kept["revoked_at"] is None, f"{st} {r} {kept}")
    st, r = rest("GET", "yui_messages?select=id", s[A]["db"])
    check("suspended: the host's still-valid db token reads nothing", st == 200 and r == [], f"{st} {len(r) if isinstance(r, list) else r}")
    st, r = rest("POST", "yui_messages", s[A]["db"], msg(A, s[A]["agent"], sender="agent"))
    check("suspended: the host's db token cannot write", st in (401, 403), f"{st} {code(r)}")
    st, r = host({"action": "session"}, s[A]["ct"])
    check("suspended: the host cannot start a session (403 suspended)", st == 403 and code(r) == "suspended", f"{st} {r}")
    st, r = fn("yui-push", {"action": "notify", "message_id": s[A]["reply"]}, s[A]["ct"])
    check("suspended: the host cannot push", st == 403, f"{st} {r}")
    st, r = rest("POST", "yui_messages", tok[B], msg(B, s[B]["agent"], body="still here"))
    check("suspending A leaves B alone", st == 201, f"{st}")
    st, r = fn("yui-delete", {}, mint(str(uuid.uuid4())))
    check("(delete still needs a real account)", st in (401, 404), f"{st}")
    sql(f"select yui_suspend('user', '{A}', false)")
    st, r = rest("POST", "yui_messages", tok[A], msg(A, s[A]["agent"], body="back"))
    st2, r2 = fn("yui-auth", {"grant_type": "refresh", "refresh_token": sess_rt})
    st3, r3 = host({"action": "session"}, s[A]["ct"])
    check("restored: A sends, refreshes and its host connects again", st == 201 and st2 == 200 and st3 == 200,
          f"{st} {st2} {st3}")
    s[A]["db"] = r3["access_token"]

    print("== Kill switch: one host")
    sql(f"select yui_suspend('connector', '{s[A]['cid']}', true, 'strangers_test')")
    st, r = rest("GET", "yui_messages?select=id", s[A]["db"])
    check("suspended host: its db token reads nothing", st == 200 and r == [], f"{st}")
    st, r = rest("POST", "yui_messages", s[A]["db"], msg(A, s[A]["agent"], sender="agent"))
    check("suspended host: its db token cannot write", st in (401, 403), f"{st} {code(r)}")
    check("suspended host: it cannot upload", up(s[A]["db"], P(A, s[A]["agent"], "agent")) in (400, 403))
    st, r = host({"action": "heartbeat"}, s[A]["ct"])
    check("suspended host: heartbeat is 403 suspended", st == 403 and code(r) == "suspended", f"{st} {r}")
    st, r = rest("POST", "yui_messages", tok[A], msg(A, s[A]["agent"], body="my phone still works"))
    check("suspended host: the person can still write (it waits for the host)", st == 201, f"{st}")
    sql(f"select yui_suspend('connector', '{s[A]['cid']}', false)")
    st, r = host({"action": "heartbeat"}, s[A]["ct"])
    st2, r2 = rest("GET", "yui_messages?select=id&limit=1", s[A]["db"])
    check("restored host: heartbeat and reads work again", st == 200 and st2 == 200 and len(r2) == 1, f"{st} {st2}")

    print("== Retention")
    days = int(limit("message_retention_days"))
    old = str(uuid.uuid4())
    sql(f"insert into yui_messages(id, user_id, agent_id, sender, body, created_at) values "
        f"('{old}', '{A}', '{s[A]['agent']}', 'user', 'from long ago', now() - interval '{days + 1} days')")
    due = {r["what"]: r["n_rows"] for r in sql("select * from yui_retention(true)")}
    check(f"dry run counts the {days + 1}-day-old message as due", due.get("messages", 0) >= 1, f"{due}")
    fresh = sql(f"select count(*)::int n from yui_messages where user_id in ('{A}','{B}')")[0]["n"]
    done = {r["what"]: r["n_rows"] for r in sql("select * from yui_retention(false)")}
    after = sql(f"select (select count(*) from yui_messages where id = '{old}')::int old, "
                f"(select count(*) from yui_messages where user_id in ('{A}','{B}'))::int n")[0]
    check("retention deletes it and keeps every fresh message", after["old"] == 0 and after["n"] == fresh - 1,
          f"{done} {after} fresh={fresh}")

    print("== A suspended account can still delete itself")
    sql(f"select yui_suspend('user', '{B}', true, 'strangers_test')")
    st, r = fn("yui-delete", {}, tok[B])
    check("suspended B deletes its account through yui-delete", st == 200 and r.get("deleted") is True, f"{st} {r}")
finally:
    for u in (A, B):
        st, r = fn("yui-delete", {}, mint(u))
        if st != 200:
            sql(f"delete from yui_users where id='{u}'")
    sql("delete from yui_rate_buckets where " + " or ".join(f"key like '%{u}%'" for u in (A, B) + tuple(
        s[u]["cid"] for u in s)))
    left = sql("select " + " + ".join(f"(select count(*) from {t} where user_id in ('{A}','{B}'))" for t in
               ["yui_agents", "yui_messages", "yui_connectors", "yui_pairings", "yui_sessions"]) + " as n, "
               f"(select count(*) from storage.objects where bucket_id='yui-media' and (name like '{A}/%' or name like '{B}/%')) as o")
    check("cleanup: both strangers deleted, zero rows and zero objects left", left[0]["n"] == 0 and left[0]["o"] == 0, f"{left}")

print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)

#!/usr/bin/env python3
"""YUI-6 account-layer tests against PROOF (live), extended by YUI-15.

Negative RLS: anon/authenticated cannot touch yui_* tables, yui_user cannot
touch any portal table. Cross-user isolation. Edge function rejections. Then a
full lifecycle: create a test account with rows in every yui_* table, refresh
its session, delete it through yui-delete, and prove zero rows remain and
zero objects remain in the yui-media bucket (YUI-21).

Needs a Supabase access token (SUPABASE_ACCESS_TOKEN or the CLI's keychain
entry). Secrets are fetched at run time and never written to disk.
"""
import base64, hashlib, hmac, json, os, subprocess, sys, time, urllib.request, urllib.error, uuid, secrets

REF = "ewzzaoperdpxqxkshynx"
BASE = f"https://{REF}.supabase.co"
YUI_TABLES = ["yui_users", "yui_apple_tokens", "yui_sessions", "yui_devices",
              "yui_agents", "yui_pairings", "yui_messages", "yui_connectors", "yui_mgmt_tokens"]
SERVER_ONLY = ["yui_apple_tokens", "yui_sessions", "yui_waitlist", "yui_mgmt_tokens", "yui_pair_attempts", "yui_invites"]

def access_token():
    t = os.environ.get("SUPABASE_ACCESS_TOKEN")
    if t: return t
    raw = subprocess.check_output(["security", "find-generic-password", "-s", "Supabase CLI", "-w"]).decode().strip()
    return base64.b64decode(raw.removeprefix("go-keyring-base64:")).decode()

MGMT = access_token()

def http(method, url, headers=None, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={"content-type": "application/json", "user-agent": "yui-tests", **(headers or {})})
    try:
        with urllib.request.urlopen(req) as r:
            txt = r.read().decode(); return r.status, (json.loads(txt) if txt else None)
    except urllib.error.HTTPError as e:
        txt = e.read().decode()
        try: return e.code, json.loads(txt)
        except ValueError: return e.code, txt

def sql(q):
    s, r = http("POST", f"https://api.supabase.com/v1/projects/{REF}/database/query", {"authorization": f"Bearer {MGMT}"}, {"query": q})
    if s >= 300: raise RuntimeError(f"sql {s}: {r}")
    return r

def mgmt(path):
    return http("GET", f"https://api.supabase.com/v1/projects/{REF}/{path}", {"authorization": f"Bearer {MGMT}"})[1]

JWT_SECRET = mgmt("postgrest")["jwt_secret"]
PUBLISHABLE = next(k["api_key"] for k in mgmt("api-keys?reveal=true") if k["type"] == "publishable")

def b64(b): return base64.urlsafe_b64encode(b).rstrip(b"=").decode()
def mint(sub, secret=JWT_SECRET, ttl=300):
    h = b64(json.dumps({"alg": "HS256", "typ": "JWT"}).encode()); now = int(time.time())
    p = b64(json.dumps({"role": "yui_user", "sub": sub, "iss": "yui-auth", "aud": "yui", "iat": now, "exp": now + ttl}).encode())
    return f"{h}.{p}.{b64(hmac.new(secret.encode(), f'{h}.{p}'.encode(), hashlib.sha256).digest())}"

def rest(method, path, token=None, body=None, prefer=None):
    h = {"apikey": PUBLISHABLE}
    if token: h["authorization"] = f"Bearer {token}"
    if prefer: h["prefer"] = prefer
    return http(method, f"{BASE}/rest/v1/{path}", h, body)

def fn(name, body, token=None):
    h = {"apikey": PUBLISHABLE}
    if token: h["authorization"] = f"Bearer {token}"
    return http("POST", f"{BASE}/functions/v1/{name}", h, body)

results = []
def check(name, ok, detail=""):
    results.append(ok); print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  [{detail}]" if detail else ""))

portal = [r["table_name"] for r in sql("select table_name from information_schema.tables where table_schema='public' and table_name not like 'yui\\_%' order by 1")]
print(f"portal tables: {len(portal)}  yui tables: {len(YUI_TABLES)}\n")

print("== Postgres privileges")
for role in ["anon", "authenticated"]:
    rows = sql(f"""select t, bool_or(has_table_privilege('{role}', 'public.'||t, p)) any
                   from unnest(array{YUI_TABLES}) t, unnest(array['SELECT','INSERT','UPDATE','DELETE']) p group by t""")
    leaks = [r["t"] for r in rows if r["any"]]
    check(f"{role} has no privilege on any yui_ account table", not leaks, ",".join(leaks) or f"{len(rows)} tables clean")
rows = sql(f"""select t, bool_or(has_table_privilege('yui_user', 'public.'||t, p)) any
               from unnest(array{portal + SERVER_ONLY}) t, unnest(array['SELECT','INSERT','UPDATE','DELETE','TRUNCATE']) p group by t""")
leaks = [r["t"] for r in rows if r["any"]]
check("yui_user has no privilege on any portal or server-only table", not leaks, ",".join(leaks) or f"{len(rows)} tables clean")
rows = sql("select n.nspname from pg_namespace n where has_schema_privilege('yui_user', n.oid, 'USAGE') order by 1")
schemas = [r["nspname"] for r in rows]
# YUI-21: storage too, for the yui-media bucket (policies in media_test.py).
check("yui_user can use no schema but public, storage (+ pg built-ins)", set(schemas) <= {"public", "storage", "pg_catalog", "information_schema"}, ",".join(schemas))
rows = sql("select p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.prosecdef and has_function_privilege('yui_user', p.oid, 'EXECUTE')")
# YUI-95: the grant checks the message policies call (true/false or a time, nothing else).
rows = [r for r in rows if r["proname"] not in ("yui_granted", "yui_grant_since", "yui_grant_serves", "yui_share_why")]  # YUI-97: owner-only share_why
check("yui_user can execute no SECURITY DEFINER function in public but the grant checks", not rows, str(rows))
rows = sql("select c.relname from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname like 'yui\\_%' and c.relkind='r' and not c.relrowsecurity")
check("RLS enabled on every yui_ table", not rows, str(rows))
rows = sql("select rolcanlogin, pg_has_role('authenticator','yui_user','member') m, pg_has_role('yui_user','authenticated','member') a from pg_roles where rolname='yui_user'")[0]
check("yui_user is NOLOGIN, switchable by authenticator, not a member of authenticated", not rows["rolcanlogin"] and rows["m"] and not rows["a"], str(rows))
auth = mgmt("config/auth")
check("PROOF Auth still has signups disabled and Apple off", auth["disable_signup"] is True and not auth.get("external_apple_enabled"))
check("no Yui user landed in auth.users", sql("select count(*)::int n from auth.users where raw_app_meta_data->>'provider'='apple'")[0]["n"] == 0)

print("\n== HTTP: anon key alone")
for t in YUI_TABLES:
    s, r = rest("GET", f"{t}?select=*&limit=1")
    check(f"anon GET {t} refused", s in (401, 403), f"{s} {r.get('code') if isinstance(r, dict) else r}")

print("\n== HTTP: yui_user token on portal + server-only tables")
A, B, X = str(uuid.uuid4()), str(uuid.uuid4()), str(uuid.uuid4())
tokA = mint(A)
for t in portal + SERVER_ONLY:
    s, r = rest("GET", f"{t}?select=*&limit=1", tokA)
    check(f"yui_user GET {t} refused", s in (401, 403), f"{s} {r.get('code') if isinstance(r, dict) else r}")
s, r = rest("POST", "clients", tokA, {"name": "yui-probe"})
check("yui_user INSERT clients refused", s in (401, 403), f"{s}")
s, r = rest("GET", "yui_messages?select=*", mint(A, secret="not-the-secret"))
check("token signed with the wrong secret refused", s == 401, f"{s}")

print("\n== Cross-user isolation")
sql(f"""insert into yui_users(id, apple_sub) values ('{A}','test.{A}'),('{B}','test.{B}');
        insert into yui_messages(user_id, sender, body) values ('{A}','user','hi from A'),('{B}','user','hi from B');
        insert into yui_agents(user_id, name, handle) values ('{B}','b-agent','b-agent');""")
b_agent = sql(f"select id from yui_agents where user_id='{B}'")[0]["id"]
try:
    s, r = rest("GET", "yui_messages?select=user_id,body", tokA)
    check("A sees only A's messages", s == 200 and r and all(m["user_id"] == A for m in r), f"{s} {len(r) if isinstance(r, list) else r}")
    s, r = rest("GET", "yui_users?select=id", tokA)
    check("A sees only A's yui_users row", s == 200 and [u["id"] for u in r] == [A], f"{r}")
    s, r = rest("POST", "yui_messages", tokA, {"user_id": B, "sender": "user", "body": "spoof"})
    check("A cannot insert a message as B", s in (401, 403), f"{s} {r.get('code') if isinstance(r, dict) else r}")
    s, r = rest("PATCH", f"yui_messages?user_id=eq.{B}", tokA, {"body": "pwned"}, prefer="return=representation")
    # YUI-7 revoked UPDATE on messages outright (403); before that RLS filtered it to 0 rows.
    check("A cannot update B's message", s == 403 or (s == 200 and r == []), f"{s} {r}")
    s, r = rest("DELETE", f"yui_messages?user_id=eq.{B}", tokA, prefer="return=representation")
    check("A cannot delete B's message", s == 200 and r == [], f"{s} {r}")
    s, r = rest("PATCH", f"yui_users?id=eq.{A}", tokA, {"apple_sub": "hijack"})
    check("A cannot rewrite its own apple_sub", s in (401, 403), f"{s}")
    s, r = rest("POST", "yui_messages", tokA, {"user_id": A, "agent_id": b_agent, "sender": "user", "body": "to B's agent"})
    check("A cannot attach a message to B's agent", s in (400, 403, 409), f"{s} {r.get('code') if isinstance(r, dict) else r}")
    s, r = rest("POST", "yui_pairings", tokA, {"user_id": A, "agent_id": b_agent, "code_hash": "x"})
    check("A cannot write a pairing code directly (codes are server-minted)", s in (401, 403), f"{s} {r.get('code') if isinstance(r, dict) else r}")
    s, r = fn("yui-agents", {"action": "pair_code", "agent_id": b_agent}, tokA)
    check("A cannot mint a pairing code for B's agent", s == 404, f"{s} {r}")
    check("B's message untouched", sql(f"select body from yui_messages where user_id='{B}'")[0]["body"] == "hi from B")
finally:
    sql(f"delete from yui_users where id in ('{A}','{B}')")

print("\n== Edge function rejections")
s, r = fn("yui-auth", {"grant_type": "apple", "identity_token": mint(X), "nonce": "n"})
check("yui-auth rejects a forged identity token", s == 401, f"{s} {r}")
s, r = fn("yui-auth", {"grant_type": "apple", "identity_token": "x"})
check("yui-auth rejects a missing nonce", s == 400, f"{s} {r}")
s, r = fn("yui-auth", {"grant_type": "refresh", "refresh_token": secrets.token_urlsafe(32)})
check("yui-auth rejects an unknown refresh token", s == 401, f"{s} {r}")
s, r = fn("yui-delete", {})
check("yui-delete rejects a call with no yui token", s == 401, f"{s} {r}")
s, r = fn("yui-delete", {}, mint(X, secret="not-the-secret"))
check("yui-delete rejects a forged yui token", s == 401, f"{s} {r}")

print("\n== Lifecycle: create, refresh, delete")
T = str(uuid.uuid4()); rt = secrets.token_urlsafe(32); rh = hashlib.sha256(rt.encode()).hexdigest()
sql(f"""insert into yui_users(id, apple_sub, email) values ('{T}', 'test.{T}', 'test@privaterelay.appleid.com');
        insert into yui_apple_tokens(user_id, refresh_token) values ('{T}', 'test-not-an-apple-token');
        insert into yui_sessions(user_id, refresh_hash, expires_at) values ('{T}', '{rh}', now() + interval '1 day');""")
tokT = mint(T)
s, dev = rest("POST", "yui_devices", tokT, {"user_id": T, "name": "test iPhone"}, prefer="return=representation")
# Agents, pairing codes, connectors and management tokens are made through
# the registry functions, the way the app and a host make them.
s2, ag = fn("yui-agents", {"action": "create", "name": "Test agent", "pair": True}, tokT)
s3, pr = fn("yui-connect", {"action": "pair", "code": ag["pairing"]["code"], "remote_ref": "test", "host_name": "test host"})
s5, mt = fn("yui-agents", {"action": "token_create", "name": "test"}, tokT)
s4, _ = rest("POST", "yui_messages", tokT, {"user_id": T, "agent_id": ag["agent"]["id"], "sender": "user", "body": "hello"}, prefer="return=representation")
check("test user makes its own device/agent/pairing/connector/token/message", (s, s2, s3, s5, s4) == (201, 200, 200, 200, 201), f"{(s, s2, s3, s5, s4)}")
connector_token = pr.get("connector_token")

def upload(tok, path, data=b"\x89PNG\r\n\x1a\nyui-test", ct="image/png"):
    req = urllib.request.Request(f"{BASE}/storage/v1/object/yui-media/{path}", data=data, method="POST",
                                 headers={"apikey": PUBLISHABLE, "authorization": f"Bearer {tok}", "content-type": ct})
    try:
        with urllib.request.urlopen(req) as r: return r.status
    except urllib.error.HTTPError as e: return e.code
s = upload(tokT, f"{T}/{ag['agent']['id']}/user/{uuid.uuid4()}.png")
host_db = fn("yui-connect", {"action": "session"}, connector_token)[1]["access_token"]
s2 = upload(host_db, f"{T}/{ag['agent']['id']}/agent/{uuid.uuid4()}.png")
media_q = f"select count(*)::int n from storage.objects where bucket_id='yui-media' and name like '{T}/%'"
check("test user has a photo and an agent picture in yui-media", (s, s2) == (200, 200)
      and sql(media_q)[0]["n"] == 2, f"{(s, s2)}")

s, r = fn("yui-auth", {"grant_type": "refresh", "refresh_token": rt})
check("refresh rotates: new access + refresh token", s == 200 and r.get("refresh_token") not in (None, rt) and r.get("expires_in") == 900, f"{s}")
new_access, new_rt = r["access_token"], r["refresh_token"]
s, r = rest("GET", "yui_messages?select=body", new_access)
check("refreshed access token reads the user's data", s == 200 and len(r) == 1, f"{s} {r}")
s, r = fn("yui-auth", {"grant_type": "refresh", "refresh_token": rt})
check("reusing the rotated refresh token is refused", s == 401, f"{s}")
live = sql(f"select count(*)::int n from yui_sessions where user_id='{T}' and revoked_at is null")[0]["n"]
check("reuse revoked every session for the user", live == 0, f"live={live}")

count_q = " union all ".join(f"select '{t}' t, count(*)::int n from {t} where {'id' if t == 'yui_users' else 'user_id'}='{T}'" for t in YUI_TABLES)
before = {r["t"]: r["n"] for r in sql(count_q)}
print("  rows before delete:", before)
check("test account has rows in every yui_ table", all(before[t] > 0 for t in YUI_TABLES))

s, r = fn("yui-delete", {}, new_access)
check("yui-delete returns deleted", s == 200 and r.get("deleted") is True, f"{s} {r}")
after = {r["t"]: r["n"] for r in sql(count_q)}
print("  rows after delete: ", after)
check("zero rows remain for the deleted account", sum(after.values()) == 0)
left = sql(media_q)[0]["n"]
check("zero media objects remain for the deleted account", left == 0 and r.get("media_removed") == 2, f"left={left} removed={r.get('media_removed')}")
s, r = rest("GET", "yui_messages?select=*", new_access)
check("the deleted user's token now sees nothing", s == 200 and r == [], f"{s} {r}")
s, r = fn("yui-delete", {}, new_access)
check("deleting twice is a 404, not a crash", s == 404, f"{s} {r}")
s, r = fn("yui-agents", {"action": "list"}, mt["token"])
check("the deleted user's management token is dead", s == 401, f"{s} {r}")
s, r = fn("yui-connect", {"action": "heartbeat"}, connector_token)
check("the deleted user's host connector is dead", s == 401, f"{s} {r}")

print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)

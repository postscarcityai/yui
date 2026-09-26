#!/usr/bin/env python3
"""YUI-96 app look tests against PROOF (live). Helpers copied from theme_test.py.

yui_users.look (migration 20260925100000_yui_user_look.sql) through the
yui-account function (spec yuigui/spec/RESTYLE.md, section 6): set it, read it
back (function and the app's own PostgREST row), strict cleaning (unknown keys
and bad values are refused, nothing stored), one step of prev, null clears, the
server stamps at/by, another account never sees it, and a host (connector
token, its yui_connector JWT, a management token) cannot write or read it.
Every test account is deleted at the end. Needs a Supabase access token, like
accounts_test.py.
"""
import base64, hashlib, hmac, json, os, subprocess, sys, time, urllib.request, urllib.error, uuid, secrets

REF = "ewzzaoperdpxqxkshynx"
BASE = f"https://{REF}.supabase.co"
YUI_TABLES = ["yui_users", "yui_apple_tokens", "yui_sessions", "yui_devices",
              "yui_agents", "yui_pairings", "yui_messages", "yui_connectors", "yui_mgmt_tokens"]
SERVER_ONLY = ["yui_apple_tokens", "yui_sessions", "yui_waitlist", "yui_mgmt_tokens", "yui_pair_attempts"]

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
def code(r): return r.get("code") or r.get("error") if isinstance(r, dict) else r

def acct(body, token): return fn("yui-account", body, token)
def row(uid): return sql(f"select look from yui_users where id = '{uid}'")[0]["look"]

A, B = str(uuid.uuid4()), str(uuid.uuid4())
sql(f"insert into yui_users(id, apple_sub, email) values ('{A}','test.{A}','a.{A[:8]}@example.com'),('{B}','test.{B}',null)")
tokA, tokB = mint(A), mint(B)
try:
    print("== Starts empty")
    s, r = acct({"action": "get"}, tokA)
    check("get returns the user and look null (Yui's own look)", s == 200 and r["user"]["id"] == A and r["look"] is None, f"{s} {r}")
    s, r = acct({"action": "look"}, tokA)
    check("look read on a new account is null", s == 200 and r == {"look": None}, f"{s} {r}")

    print("== Set and read back")
    look = {"preset": "autumn", "font": "serif", "agents_keep_looks": True, "via": "Coach",
            "at": "1999-01-01T00:00:00Z", "by": "agent"}
    s, r = acct({"action": "set_look", "look": look}, tokA)
    got = r.get("look") or {}
    check("set a look: stored cleaned", s == 200 and {k: got.get(k) for k in ("preset", "font", "agents_keep_looks", "via")}
          == {"preset": "autumn", "font": "serif", "agents_keep_looks": True, "via": "Coach"}, f"{s} {r}")
    check("server stamps by=user and a fresh at, ignoring what was sent", got.get("by") == "user"
          and got.get("at", "").startswith(time.strftime("%Y-", time.gmtime())), f"{got.get('by')} {got.get('at')}")
    s, r2 = acct({"action": "look"}, tokA)
    check("read it back through the function", s == 200 and r2["look"] == got, f"{s} {r2}")
    s, r3 = acct({"action": "get"}, tokA)
    check("get (launch) carries the look", s == 200 and r3["look"] == got, f"{s} {r3}")
    s, r4 = rest("GET", "yui_users?select=id,look", tokA)
    check("the app's own token reads its look from yui_users, and only its own row",
          s == 200 and isinstance(r4, list) and len(r4) == 1 and r4[0]["id"] == A and r4[0]["look"] == got, f"{s} {r4}")
    s, r = acct({"action": "look"}, tokB)
    check("another account does not see it", s == 200 and r["look"] is None, f"{s} {r}")
    s, r = rest("GET", f"yui_users?select=look&id=eq.{A}", tokB)
    check("another account's token cannot read the row directly", s == 200 and r == [], f"{s} {r}")

    s, r = acct({"action": "set_look", "look": {"accent": "#7b5cff", "bg": "cream", "radius": "round", "weight": "heavy", "motion": "snappy"}}, tokA)
    got = r.get("look") or {}
    check("hex accent (uppercased) and a paper bg", s == 200 and got.get("accent") == "#7B5CFF" and got.get("bg") == "cream"
          and got.get("radius") == "round" and got.get("weight") == "heavy" and got.get("motion") == "snappy", f"{s} {r}")
    s, r = acct({"action": "set_look", "look": {"accent": "lemon", "bg": "#F7F0E6"}}, tokA)
    check("a set name as accent and a hex bg", s == 200 and r["look"].get("accent") == "lemon" and r["look"].get("bg") == "#F7F0E6", f"{s} {r}")

    print("== Bad keys and values are refused, nothing stored")
    before = row(A)
    bad = [
        ({"preset": "autumn", "style": {"screen": "full"}}, "style"),
        ({"preset": "autumn", "evil": "<script>"}, "evil"),
        ({"preset": "sparkly"}, "preset"),
        ({"accent": "#F80"}, "accent"),
        ({"accent": "red; drop table"}, "accent"),
        ({"bg": "black"}, "bg"),
        ({"radius": 12}, "radius"),
        ({"radius": "12"}, "radius"),
        ({"font": "comic"}, "font"),
        ({"weight": "light"}, "weight"),
        ({"motion": "wobbly"}, "motion"),
        ({"agents_keep_looks": "yes"}, "agents_keep_looks"),
        ({"via": "x" * 61}, "via"),
        ({"via": 7}, "via"),
        ({"prev": "ocean"}, "prev"),
        ({"prev": {"preset": "ocean", "prev": {"preset": "mint"}}}, "prev.prev"),
        ({"prev": {"preset": "nope"}}, "prev.preset"),
    ]
    for lk, key in bad:
        s, r = acct({"action": "set_look", "look": lk}, tokA)
        check(f"refused: {json.dumps(lk)[:60]}", s == 400 and r.get("error") == "bad_look" and r.get("key") == key, f"{s} {r}")
    for lk in ["autumn", ["autumn"], 5]:
        s, r = acct({"action": "set_look", "look": lk}, tokA)
        check(f"refused: look {json.dumps(lk)} is not an object", s == 400 and r.get("error") == "bad_look", f"{s} {r}")
    check("nothing was stored by any refused write", row(A) == before, f"{row(A)}")
    s, r = acct({"action": "set_look"}, tokA)
    check("set_look without a look is refused", s == 400 and r.get("error") == "bad_look", f"{s} {r}")
    s, r = acct({"action": "look", "look": {"preset": "honey"}}, tokA)
    check("action look with a look key writes too (same as set_look)", s == 200 and r["look"].get("preset") == "honey", f"{s} {r}")
    before = row(A)
    s, r = acct({"action": "paint"}, tokA)
    check("unknown action", s == 400 and r.get("error") == "unknown_action", f"{s} {r}")

    print("== prev: one step of Undo")
    s, r = acct({"action": "set_look", "look": {"preset": "ocean"}}, tokA)
    ocean = r["look"]
    applied = {"preset": "autumn", "font": "serif", "via": "Coach", "prev": ocean}
    s, r = acct({"action": "set_look", "look": applied}, tokA)
    got = r.get("look") or {}
    check("apply keeps the look before it as prev, with its own stamp", s == 200 and got.get("preset") == "autumn"
          and got.get("prev") == ocean, f"{s} {r}")
    undo = {k: v for k, v in got["prev"].items() if k not in ("at", "by")}
    s, r = acct({"action": "set_look", "look": undo}, tokA)
    check("undo writes prev back as the look, with no prev of its own", s == 200 and r["look"].get("preset") == "ocean"
          and "prev" not in r["look"], f"{s} {r}")
    s, r = acct({"action": "set_look", "look": {"preset": "mint", "prev": {"preset": "ocean", "at": "not a date"}}}, tokA)
    check("a prev with a bad stamp is refused", s == 400 and r.get("key") == "prev.at", f"{s} {r}")
    s, r = acct({"action": "set_look", "look": {"preset": "mint", "prev": {"preset": "ocean", "by": "agent"}}}, tokA)
    check("a prev claiming by=agent is refused", s == 400 and r.get("key") == "prev.by", f"{s} {r}")

    print("== null clears")
    s, r = acct({"action": "set_look", "look": None}, tokA)
    check("look null goes back to Yui's own look", s == 200 and r == {"look": None} and row(A) is None, f"{s} {r} {row(A)}")
    s, r = acct({"action": "set_look", "look": {}}, tokA)
    check("an empty look is Yui's look, stamped", s == 200 and set(r["look"]) == {"at", "by"}, f"{s} {r}")
    s, r = acct({"action": "set_look", "look": {"agents_keep_looks": False, "prev": {}}}, tokA)
    check("Yui's look with the switch off, prev {} kept (Undo to Yui's look)", s == 200
          and r["look"].get("agents_keep_looks") is False and r["look"].get("prev") == {}, f"{s} {r}")
    s, r = acct({"action": "set_look", "look": {"preset": "autumn", "prev": {"preset": "ocean", "font": "serif", "at": "2026-09-25T20:00:00.000+00:00"},
                 "at": "2026-09-25T20:00:01.000+00:00", "via": "Coach", "agents_keep_looks": True}}, tokA)
    check("the app's flat shape with an at in prev", s == 200 and r["look"]["prev"] == {"preset": "ocean", "font": "serif", "at": "2026-09-25T20:00:00.000+00:00"}, f"{s} {r}")

    print("== Direct writes and the column check")
    s, r = rest("PATCH", f"yui_users?id=eq.{A}", tokA, {"look": {"preset": "autumn"}}, prefer="return=minimal")
    check("the app token cannot write yui_users directly (only the function writes)", s >= 400, f"{s} {code(r)}")
    try:
        sql(f"update yui_users set look = '[1,2]'::jsonb where id = '{A}'"); ok = False
    except RuntimeError: ok = True
    check("the column check refuses a non-object even for the owner role", ok)
    try:
        sql(f"update yui_users set look = jsonb_build_object('blob', repeat('x', 5000)) where id = '{A}'"); ok = False
    except RuntimeError: ok = True
    check("the column check refuses an oversized look", ok)

    print("== A host cannot write it")
    acct({"action": "set_look", "look": {"preset": "zen"}}, tokA)
    before = row(A)
    s, r = fn("yui-agents", {"action": "create", "name": "Nova", "pair": True}, tokA)
    s, p = fn("yui-connect", {"action": "pair", "code": r["pairing"]["code"], "remote_ref": "nova", "host_name": "Test Mac"})
    ct = p["connector_token"]
    s, sa = fn("yui-connect", {"action": "session"}, ct)
    cjwt = sa["access_token"]
    s, r = acct({"action": "set_look", "look": {"preset": "autumn"}}, ct)
    check("yui-account refuses a connector token", s == 401, f"{s} {r}")
    s, r = acct({"action": "set_look", "look": {"preset": "autumn"}}, cjwt)
    check("yui-account refuses the host's yui_connector JWT", s == 401, f"{s} {r}")
    s, r = acct({"action": "look"}, cjwt)
    check("the host's JWT cannot read the look through the function either", s == 401, f"{s} {r}")
    s, r = rest("PATCH", f"yui_users?id=eq.{A}", cjwt, {"look": {"preset": "autumn"}}, prefer="return=minimal")
    check("yui_connector cannot write yui_users directly", s >= 400, f"{s} {code(r)}")
    s, r = rest("GET", "yui_users?select=look", cjwt)
    check("yui_connector cannot read yui_users", s >= 400, f"{s} {code(r)}")
    s, r = fn("yui-agents", {"action": "token_create", "name": "t"}, tokA)
    mt = (r or {}).get("token")
    if mt:
        s, r = acct({"action": "set_look", "look": {"preset": "autumn"}}, mt)
        check("yui-account refuses a management token", s == 401, f"{s} {r}")
    s, r = acct({"action": "set_look", "look": {"preset": "autumn"}}, None)
    check("no token, no look", s == 401, f"{s} {r}")
    s, r = acct({"action": "set_look", "look": {"preset": "autumn"}}, mint(A, secret="wrong-secret"))
    check("a forged token is refused", s == 401, f"{s} {r}")
    check("after every host attempt the look is unchanged", row(A) == before, f"{row(A)}")
    priv = sql("select has_column_privilege('yui_connector','public.yui_users','look','update') cu, "
               "has_column_privilege('yui_connector','public.yui_users','look','select') cs, "
               "has_column_privilege('yui_user','public.yui_users','look','update') uu, "
               "has_column_privilege('yui_user','public.yui_users','look','select') us")[0]
    check("grants: yui_user select only, yui_connector nothing", priv == {"cu": False, "cs": False, "uu": False, "us": True}, f"{priv}")
finally:
    sql(f"delete from yui_users where id in ('{A}','{B}')")
    left = sql(f"select (select count(*) from yui_users where id in ('{A}','{B}')) + (select count(*) from yui_agents where user_id in ('{A}','{B}')) + (select count(*) from yui_connectors where user_id in ('{A}','{B}')) n")[0]["n"]
    check("test accounts deleted, zero rows left", left == 0, f"{left}")

print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)

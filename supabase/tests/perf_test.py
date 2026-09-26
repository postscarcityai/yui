#!/usr/bin/env python3
"""YUI-102 speed numbers (yui_perf) tests against PROOF (live). Helpers copied from look_test.py.

Migration 20260925120000_yui_perf.sql (spec yuigui/spec/PERF.md, section 5):
the phone (yui_user) writes and reads its own rows; the owner's live host
(yui_connector) reads them and nobody else's; no role updates or deletes;
anon and authenticated get nothing. Only numbers fit: no free-text column,
names and versions by regex, buckets are 18 counts, a stack is frames of
{image, uuid, offset}. Past perf_rows_per_day a row is dropped silently.
yui_perf_retention() counts (dry) then deletes rows past perf_retention_days.
Every test account is deleted at the end. Needs a Supabase access token, like
accounts_test.py.
"""
import base64, hashlib, hmac, json, os, subprocess, sys, time, urllib.request, urllib.error, uuid

REF = "ewzzaoperdpxqxkshynx"
BASE = f"https://{REF}.supabase.co"

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

UUID0 = "0123456789ABCDEF0123456789ABCDEF"
FRAMES = [{"image": "Yui", "uuid": UUID0, "offset": 123456},
          {"image": "UIKitCore", "uuid": "4C4C4411-5555-3144-A1B2-C3D4E5F60718", "offset": 42}]

def row(uid, kind="interval", name="keystroke_render", **extra):
    r = {"user_id": uid, "kind": kind, "name": name, "app_build": 125, "app_version": "1.4",
         "os": "26.0.1", "device": "iPhone16,2", "promotion": True, "low_power": False, "thermal": 0,
         "period_start": "2026-09-25T10:00:00Z", "period_end": "2026-09-25T11:00:00Z", "n": 0}
    if kind == "interval":
        r.update(n=40, buckets=[0, 1, 5, 10, 12, 6, 3, 2, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0], p50=11.5, p95=22.0, max=31.0)
    elif kind == "memory":
        r.update(n=120, value=212.5, max=238.0)
    elif kind == "metrics":
        r.update(name="hang_rate", value=0.8)
    elif kind == "diagnostic":
        r.update(name="hang", n=1, value=1.2, stack=FRAMES)
    r.update(extra)
    return r

COLS = ["user_id", "kind", "name", "app_build", "app_version", "os", "device", "promotion", "low_power", "thermal",
        "period_start", "period_end", "n", "buckets", "p50", "p95", "max", "value", "stack"]
def full(r): return {k: r.get(k) for k in COLS}  # PostgREST: every object in a batch has the same keys

def post(token, body): return rest("POST", "yui_perf", token, body, prefer="return=representation")
def refused(s): return s in (400, 401, 403, 409)
def count(uid): return sql(f"select count(*)::int n from yui_perf where user_id = '{uid}'")[0]["n"]

A, B, C = str(uuid.uuid4()), str(uuid.uuid4()), str(uuid.uuid4())
sql(f"insert into yui_users(id, apple_sub) values ('{A}','test.{A}'),('{B}','test.{B}'),('{C}','test.{C}')")
tokA, tokB, tokC = mint(A), mint(B), mint(C)
try:
    print("== A writes one row of each kind and reads them back")
    ids = []
    for k in ("interval", "memory", "metrics", "diagnostic"):
        s, r = post(tokA, row(A, k))
        ok = s == 201 and isinstance(r, list) and len(r) == 1 and r[0]["kind"] == k and r[0]["user_id"] == A
        check(f"A inserts a {k} row", ok, f"{s} {r if not ok else ''}")
        if ok: ids.append(r[0]["id"])
    s, r = rest("GET", "yui_perf?select=id,kind,name,buckets,stack,value&order=id", tokA)
    check("A reads its four rows back", s == 200 and [x["id"] for x in r] == ids, f"{s} {r}")
    got = {x["kind"]: x for x in r} if s == 200 else {}
    check("buckets come back as 18 ints, stack as frames", got.get("interval", {}).get("buckets") == row(A)["buckets"]
          and got.get("diagnostic", {}).get("stack") == FRAMES, f"{got.get('interval')} {got.get('diagnostic')}")
    s, r = rest("POST", "yui_perf", tokA, [full(row(A, "interval", "swipe")), full(row(A, "memory", "memory_warning"))], prefer="return=representation")
    check("a batch (array body, every key in every object) inserts in one request", s == 201 and len(r) == 2, f"{s} {r}")
    s, r = rest("POST", "yui_perf", tokA, [row(A, "interval"), row(A, "memory")], prefer="return=representation")
    check("a batch whose objects have different keys is refused whole (PGRST102)", s == 400 and code(r) == "PGRST102", f"{s} {code(r)}")
    s, r = rest("POST", "yui_perf", tokB, row(B, "interval"), prefer="return=minimal")
    check("B writes its own row (return=minimal)", s == 201, f"{s} {r}")

    print("== Owner only")
    s, r = rest("GET", "yui_perf?select=id,user_id", tokB)
    check("B reads only its own row, none of A's", s == 200 and len(r) == 1 and r[0]["user_id"] == B, f"{s} {r}")
    s, r = rest("GET", f"yui_perf?select=id&user_id=eq.{A}", tokB)
    check("B asking for A's rows gets nothing", s == 200 and r == [], f"{s} {r}")
    n = count(A)
    s, r = post(tokB, row(A))
    check("B cannot insert a row as A", refused(s) and count(A) == n, f"{s} {code(r)}")
    s, r = post(tokA, {**row(A), "id": 1})
    check("A cannot pick the id", refused(s), f"{s} {code(r)}")
    s, r = post(tokA, {**row(A), "created_at": "2020-01-01T00:00:00Z"})
    check("A cannot backdate created_at", refused(s), f"{s} {code(r)}")

    print("== No update, no delete")
    s, r = rest("PATCH", f"yui_perf?id=eq.{ids[0]}", tokA, {"value": 1}, prefer="return=representation")
    check("A cannot update its row", refused(s), f"{s} {code(r)}")
    s, r = rest("DELETE", f"yui_perf?id=eq.{ids[0]}", tokA, prefer="return=representation")
    check("A cannot delete its row", refused(s) and count(A) == n, f"{s} {code(r)}")

    print("== Hosts: the owner's live connector reads the owner's rows")
    s, r = fn("yui-agents", {"action": "create", "name": "Nova", "pair": True}, tokA)
    s2, p = fn("yui-connect", {"action": "pair", "code": r["pairing"]["code"], "remote_ref": "nova", "host_name": "Perf test Mac"})
    s3, sa = fn("yui-connect", {"action": "session"}, p["connector_token"])
    a_cid, cA = p["connector"]["id"], sa["access_token"]
    s, r = fn("yui-agents", {"action": "create", "name": "Bolt", "pair": True}, tokB)
    s2, p = fn("yui-connect", {"action": "pair", "code": r["pairing"]["code"], "remote_ref": "bolt", "host_name": "Perf test Mac B"})
    s3, sb = fn("yui-connect", {"action": "session"}, p["connector_token"])
    cB = sb["access_token"]
    check("two hosts paired (A's and B's)", bool(cA and cB))
    s, r = rest("GET", "yui_perf?select=id,user_id", cA)
    check("A's connector reads A's rows, all of them", s == 200 and len(r) == count(A) and {x["user_id"] for x in r} == {A}, f"{s} {len(r) if isinstance(r, list) else r}")
    s, r = rest("GET", f"yui_perf?select=id&user_id=eq.{B}", cA)
    check("A's connector does not see B's rows", s == 200 and r == [], f"{s} {r}")
    s, r = rest("GET", "yui_perf?select=user_id", cB)
    check("B's connector sees only B's rows", s == 200 and {x["user_id"] for x in r} == {B}, f"{s} {r}")
    s, r = post(cA, row(A))
    check("a connector cannot insert", refused(s), f"{s} {code(r)}")
    s, r = rest("PATCH", f"yui_perf?id=eq.{ids[0]}", cA, {"value": 1}, prefer="return=representation")
    s2, r2 = rest("DELETE", f"yui_perf?id=eq.{ids[0]}", cA, prefer="return=representation")
    check("a connector cannot update or delete", refused(s) and refused(s2) and count(A) == n, f"{s}/{s2}")
    sql(f"update yui_connectors set suspended_at = now() where id = '{a_cid}'")
    s, r = rest("GET", "yui_perf?select=id", cA)
    check("a suspended connector reads nothing", s == 200 and r == [], f"{s} {r}")
    sql(f"update yui_connectors set suspended_at = null where id = '{a_cid}'")
    s, r = fn("yui-agents", {"action": "connector_revoke", "id": a_cid}, tokA)
    s2, r2 = rest("GET", "yui_perf?select=id", cA)
    check("a revoked connector's still-valid token reads nothing", s == 200 and s2 == 200 and r2 == [], f"{s} {s2} {r2}")

    print("== anon and authenticated get nothing")
    s, r = rest("GET", "yui_perf?select=id", None)
    check("anon (publishable key, no token) reads nothing", s in (401, 403) or (s == 200 and r == []), f"{s} {code(r)}")
    s, r = rest("POST", "yui_perf", None, row(A))
    check("anon cannot insert", refused(s), f"{s} {code(r)}")
    priv = sql("""select r.rolname, has_table_privilege(r.rolname, 'public.yui_perf', 'SELECT') sel,
                         has_any_column_privilege(r.rolname, 'public.yui_perf', 'SELECT,INSERT,UPDATE') anycol,
                         has_table_privilege(r.rolname, 'public.yui_perf', 'INSERT,UPDATE,DELETE,TRUNCATE') w
                  from pg_roles r where r.rolname in ('anon', 'authenticated', 'yui_user', 'yui_connector') order by 1""")
    p = {x["rolname"]: (x["sel"], x["anycol"], x["w"]) for x in priv}
    check("grants: anon and authenticated nothing; yui_user select + column insert; yui_connector select; no update/delete",
          p == {"anon": (False, False, False), "authenticated": (False, False, False),
                "yui_user": (True, True, False), "yui_connector": (True, True, False)}, f"{p}")
    upd = sql("""select has_column_privilege('yui_user', 'public.yui_perf', 'value', 'UPDATE') u,
                        has_column_privilege('yui_user', 'public.yui_perf', 'created_at', 'INSERT') c,
                        has_column_privilege('yui_connector', 'public.yui_perf', 'value', 'INSERT') ci""")[0]
    check("no column update for yui_user, no created_at insert, no connector insert", upd == {"u": False, "c": False, "ci": False}, f"{upd}")
    fx = sql("""select p.proname, has_function_privilege('yui_user', p.oid, 'EXECUTE') u,
                       has_function_privilege('yui_connector', p.oid, 'EXECUTE') c,
                       has_function_privilege('anon', p.oid, 'EXECUTE') a,
                       has_function_privilege('authenticated', p.oid, 'EXECUTE') au
                from pg_proc p where p.pronamespace = 'public'::regnamespace
                  and p.proname in ('yui_perf_retention', 'yui_perf_guard', 'yui_connector_live', 'yui_perf_stack_ok') order by 1""")
    f = {x["proname"]: (x["u"], x["c"], x["a"], x["au"]) for x in fx}
    check("functions: retention and guard service only; live check for connectors; stack check for token roles",
          f == {"yui_connector_live": (False, True, False, False), "yui_perf_guard": (False, False, False, False),
                "yui_perf_retention": (False, False, False, False), "yui_perf_stack_ok": (True, True, False, False)}, f"{f}")

    print("== Only numbers fit")
    before = count(A)
    bad = [
        ("name with spaces", row(A, name="Hello there")),
        ("name in caps", row(A, name="KeystrokeRender")),
        ("name too long", row(A, name="a" + "b" * 41)),
        ("kind not in the list", row(A, kind="note")),
        ("device as a person's phone name", row(A, device="Chris's iPhone")),
        ("device free text", row(A, device="iPhone16,2 hello")),
        ("app_version with letters", row(A, app_version="1.4 beta")),
        ("os with a word", row(A, os="iOS 26")),
        ("os too long", row(A, os="1" * 17)),
        ("buckets of 17", row(A, buckets=[0] * 17)),
        ("buckets of 19", row(A, buckets=[0] * 19)),
        ("a negative bucket", row(A, buckets=[0] * 17 + [-1])),
        ("a null bucket", row(A, buckets=[0] * 17 + [None])),
        ("thermal out of range", row(A, thermal=9)),
        ("negative n", row(A, n=-1)),
        ("period_end before period_start", row(A, period_start="2026-09-25T12:00:00Z")),
        ("stack on an interval row", row(A, stack=FRAMES)),
        ("stack with an extra key", row(A, "diagnostic", stack=[{**FRAMES[0], "symbol": "sendMessage(to: Chris)"}])),
        ("stack with string frames", row(A, "diagnostic", stack=["Yui 0x1234 ChatStore.apply", "hello"])),
        ("stack as an object", row(A, "diagnostic", stack={"frames": FRAMES})),
        ("stack as a string", row(A, "diagnostic", stack="my password is hunter2")),
        ("stack frame with a missing key", row(A, "diagnostic", stack=[{"image": "Yui", "uuid": UUID0}])),
        ("stack frame with an empty object", row(A, "diagnostic", stack=[{}])),
        ("stack image with spaces", row(A, "diagnostic", stack=[{**FRAMES[0], "image": "hello my friend"}])),
        ("stack uuid as text", row(A, "diagnostic", stack=[{**FRAMES[0], "uuid": "not a uuid at all, just words here"}])),
        ("stack offset as a string", row(A, "diagnostic", stack=[{**FRAMES[0], "offset": "12"}])),
        ("stack offset negative", row(A, "diagnostic", stack=[{**FRAMES[0], "offset": -1}])),
        ("stack offset fractional", row(A, "diagnostic", stack=[{**FRAMES[0], "offset": 1.5}])),
        ("stack nested frames", row(A, "diagnostic", stack=[{**FRAMES[0], "image": {"name": "Yui"}}])),
        ("stack empty array", row(A, "diagnostic", stack=[])),
        ("stack over 100 frames", row(A, "diagnostic", stack=[FRAMES[1]] * 101)),
        ("an extra column", {**row(A), "note": "free text"}),
    ]
    for label, body in bad:
        s, r = post(tokA, body)
        check(f"refused: {label}", refused(s), f"{s} {code(r)}")
    check("nothing was stored by any refused write", count(A) == before, f"{count(A)} vs {before}")
    s, r = post(tokA, row(A, device="arm64"))
    s2, r2 = post(tokA, row(A, device="iPad14,3", os="18.6", app_version="1.10.2"))
    check("a Simulator (arm64) and an iPad row are accepted", s == 201 and s2 == 201, f"{s} {s2} {code(r)} {code(r2)}")
    s, r = post(tokA, row(A, "diagnostic", stack=[{**FRAMES[i % 2], "offset": 1000 + i} for i in range(100)]))
    check("a 100-frame stack fits", s == 201, f"{s} {code(r)}")
    try:
        sql(f"insert into yui_perf(user_id, kind, name, app_build, app_version, os, device, period_start, period_end, stack) "
            f"values ('{A}', 'diagnostic', 'hang', 1, '1', '1', 'arm64', now(), now(), '[\"free text\"]')"); ok = False
    except RuntimeError: ok = True
    check("the column checks hold for direct SQL too", ok)
    try:
        big = json.dumps([{"image": "L" * 64, "uuid": UUID0, "offset": 10 ** 19}] * 100)
        sql(f"insert into yui_perf(user_id, kind, name, app_build, app_version, os, device, period_start, period_end, stack) "
            f"values ('{A}', 'diagnostic', 'hang', 1, '1', '1', 'arm64', now(), now(), "
            f"(select jsonb_agg(f || jsonb_build_object('image', 'L' || lpad(i::text, 63, '0'))) from jsonb_array_elements('{big}'::jsonb) with ordinality x(f, i)))")
        ok = sql("select pg_column_size(stack) <= 16384 ok from yui_perf where name = 'hang' and user_id = '%s' order by id desc limit 1" % A)[0]["ok"]
    except RuntimeError: ok = True
    size = sql("select pg_get_constraintdef(oid) d from pg_constraint where conrelid = 'public.yui_perf'::regclass and pg_get_constraintdef(oid) like '%stack%'")
    check("stack is capped at 16 KB (pg_column_size) as a backstop to the 100-frame cap",
          ok and any("16384" in x["d"] for x in size), f"{size}")

    cols = sql("""select c.column_name, c.data_type,
                         exists (select 1 from pg_constraint k join pg_attribute a on a.attrelid = k.conrelid and a.attnum = any(k.conkey)
                                 where k.conrelid = 'public.yui_perf'::regclass and k.contype = 'c' and a.attname = c.column_name) checked
                  from information_schema.columns c where c.table_schema = 'public' and c.table_name = 'yui_perf'""")
    texty = {c["column_name"]: c["checked"] for c in cols if c["data_type"] in ("text", "character varying", "character", "json", "jsonb", "ARRAY", "USER-DEFINED", "bytea")}
    check("no free-text column: text columns are kind/name/app_version/os/device, each checked; stack and buckets checked",
          texty == {"kind": True, "name": True, "app_version": True, "os": True, "device": True, "stack": True, "buckets": True}, f"{texty}")
    arr = sql("select data_type, udt_name from information_schema.columns where table_schema='public' and table_name='yui_perf' and column_name='buckets'")[0]
    check("buckets is an int array", arr["udt_name"] == "_int4", f"{arr}")

    print("== Past perf_rows_per_day a row is dropped silently")
    lim = int(float(sql("select value from yui_limits where name = 'perf_rows_per_day'")[0]["value"]))
    check("perf_rows_per_day is 500", lim == 500, f"{lim}")
    batch = [full(row(C, "interval", "keystroke_render", n=i)) for i in range(lim + 1)]
    s, r = rest("POST", "yui_perf", tokC, batch, prefer="return=representation")
    check(f"a batch of {lim + 1} lands {lim}, the last one dropped", s == 201 and len(r) == lim and count(C) == lim
          and max(x["n"] for x in r) == lim - 1, f"{s} {len(r) if isinstance(r, list) else r} {count(C)}")
    s, r = post(tokC, row(C))
    check("the next row answers 201 and stores nothing", s == 201 and r == [] and count(C) == lim, f"{s} {r} {count(C)}")
    s, r = post(tokA, row(A))
    check("another account is not affected", s == 201 and len(r) == 1, f"{s}")
    sql(f"update yui_perf set created_at = now() - interval '25 hours' where user_id = '{C}' and id in (select id from yui_perf where user_id = '{C}' order by id limit 10)")
    s, r = rest("POST", "yui_perf", tokC, [row(C)] * 12, prefer="return=representation")
    check("the day rolls: 10 rows aged past 24 h make room for 10 more", s == 201 and len(r) == 10, f"{s} {len(r) if isinstance(r, list) else r}")
    sql(f"insert into yui_perf(user_id, kind, name, app_build, app_version, os, device, period_start, period_end) "
        f"values ('{C}', 'metrics', 'direct_sql', 1, '1', '1', 'arm64', now(), now())")
    check("direct SQL is exempt from the cap", count(C) == lim + 10 + 1, f"{count(C)}")
    sql(f"update yui_users set suspended_at = now() where id = '{A}'")
    s, r = post(tokA, row(A))
    check("a suspended account writes nothing", s == 403 and code(r) == "account_suspended" or s == 403, f"{s} {r}")
    sql(f"update yui_users set suspended_at = null where id = '{A}'")

    print("== Retention: 90 days")
    days = int(float(sql("select value from yui_limits where name = 'perf_retention_days'")[0]["value"]))
    check("perf_retention_days is 90", days == 90, f"{days}")
    due0 = sql("select * from public.yui_perf_retention()")[0]["n_rows"]
    old = sql(f"insert into yui_perf(user_id, kind, name, app_build, app_version, os, device, period_start, period_end, created_at) "
              f"values ('{A}', 'memory', 'old_row', 1, '1', '1', 'arm64', now() - interval '92 days', now() - interval '92 days', now() - interval '91 days') returning id")[0]["id"]
    edge = sql(f"insert into yui_perf(user_id, kind, name, app_build, app_version, os, device, period_start, period_end, created_at) "
               f"values ('{A}', 'memory', 'edge_row', 1, '1', '1', 'arm64', now(), now(), now() - interval '89 days') returning id")[0]["id"]
    r = sql("select * from public.yui_perf_retention(true)")
    check("dry run counts the backdated row, not the 89-day one", r == [{"what": "perf", "n_rows": due0 + 1}], f"{r}")
    check("dry run deleted nothing", sql(f"select count(*)::int n from yui_perf where id in ({old}, {edge})")[0]["n"] == 2)
    fresh = count(A)
    r = sql("select * from public.yui_perf_retention(false)")
    left = sql(f"select id from yui_perf where id in ({old}, {edge})")
    check("the real run deletes it and keeps the rest", r[0]["n_rows"] >= 1 and left == [{"id": edge}] and count(A) == fresh - 1, f"{r} {left}")
    s, r = rest("POST", "rpc/yui_perf_retention", tokA, {"dry": False})
    s2, r2 = rest("POST", "rpc/yui_perf_retention", cB, {"dry": False})
    check("neither token role can run retention", s in (401, 403, 404) and s2 in (401, 403, 404), f"{s} {s2}")
finally:
    sql(f"delete from yui_users where id in ('{A}','{B}','{C}')")
    left = sql(f"select (select count(*) from yui_users where id in ('{A}','{B}','{C}')) + (select count(*) from yui_agents where user_id in ('{A}','{B}','{C}')) + (select count(*) from yui_connectors where user_id in ('{A}','{B}','{C}')) + (select count(*) from yui_perf where user_id in ('{A}','{B}','{C}')) n")[0]["n"]
    check("test accounts, hosts and rows deleted, zero rows left", left == 0, f"{left}")

print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)

#!/usr/bin/env python3
"""YUI-20 agent look tests against PROOF (live). Helpers copied from agents_test.py.

Cross-user isolation on agents and connectors, column-level limits for the
app token, management-token scope (manage agents, never read messages), the
pairing code flow a host runs (`hermes yui pair`/`add`), heartbeat status,
code throttling, defaults, and thread deletion with an agent. Every test
account is deleted at the end. Needs a Supabase access token, like
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

A, B = str(uuid.uuid4()), str(uuid.uuid4())
sql(f"insert into yui_users(id, apple_sub) values ('{A}','test.{A}'),('{B}','test.{B}')")
tokA, tokB = mint(A), mint(B)
try:
    print("== Looks: stored cleaned, handed to the host")
    s, r = fn("yui-agents", {"action": "create", "name": "Nova", "pair": True}, tokA)
    agent, pair = r["agent"]["id"], r["pairing"]["code"]
    check("a new agent starts with an empty look (the app seeds it from the name)", s == 200 and r["agent"]["theme"] == {}, f"{s} {r['agent'].get('theme')}")
    look = {"preset": "autumn", "accent": "#C8642B", "radius": "square", "font": "serif", "weight": "bold",
            "motion": "calm", "style": {"screen": "full", "buttons": "stack"}, "at": "2026-09-24T12:00:00.123+00:00", "by": "agent"}
    s, r = fn("yui-agents", {"action": "update", "id": agent, "theme": look}, tokA)
    check("the app saves a look", s == 200 and r["agent"]["theme"] == look, f"{s} {r.get('agent', {}).get('theme')}")
    junk = dict(look, accent="red; drop table", font="comic", evil="<script>", style={"screen": "full", "x": "y", "chart": "3d"})
    s, r = fn("yui-agents", {"action": "update", "id": agent, "theme": junk}, tokA)
    t = r.get("agent", {}).get("theme", {})
    check("bad values and unknown keys are dropped, not stored", s == 200 and "accent" not in t and "font" not in t and "evil" not in t and t.get("style") == {"screen": "full"}, f"{s} {t}")
    s, r = fn("yui-agents", {"action": "update", "id": agent, "theme": "autumn"}, tokA)
    check("a look that is not an object is refused", s == 400 and r.get("error") == "invalid_theme", f"{s} {r}")
    s, r = fn("yui-agents", {"action": "update", "id": agent, "theme": look}, tokB)
    check("another user cannot restyle my agent", s in (403, 404), f"{s} {r}")
    s, r = rest("PATCH", f"yui_agents?id=eq.{agent}", tokA, {"theme": {"blob": "x" * 5000}}, prefer="return=minimal")
    check("a direct oversized write is refused by the column check", s >= 400, f"{s} {code(r)}")
    s, r = rest("PATCH", f"yui_agents?id=eq.{agent}", tokA, {"theme": ["not", "an", "object"]}, prefer="return=minimal")
    check("a direct non-object write is refused by the column check", s >= 400, f"{s} {code(r)}")
    fn("yui-agents", {"action": "update", "id": agent, "theme": look}, tokA)
    s, r = fn("yui-connect", {"action": "pair", "code": pair, "remote_ref": "nova", "host_name": "Test Mac"})
    ct = r["connector_token"]
    s, r = fn("yui-connect", {"action": "session"}, ct)
    got = {a["remote_ref"]: a.get("theme") for a in r.get("agents", [])}
    check("the host's session carries each agent's look", s == 200 and got.get("nova") == look, f"{s} {got}")
    s, r = fn("yui-connect", {"action": "heartbeat"}, ct)
    got = {a["remote_ref"]: a.get("theme") for a in r.get("agents", [])}
    check("the heartbeat carries it too, so a restyle reaches the agent within a minute", s == 200 and got.get("nova") == look, f"{s} {got}")
finally:
    sql(f"delete from yui_users where id in ('{A}','{B}')")
    left = sql(f"select (select count(*) from yui_agents where user_id in ('{A}','{B}')) + (select count(*) from yui_connectors where user_id in ('{A}','{B}')) n")[0]["n"]
    check("test accounts deleted, zero rows left", left == 0, f"{left}")

print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)

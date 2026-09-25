#!/usr/bin/env python3
"""YUI-15 agent registry tests against PROOF (live).

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
    print("== Pairing: app makes a code, host claims it")
    s, r = fn("yui-agents", {"action": "create", "name": "Monk", "pair": True}, tokB)
    check("B creates an agent and gets a 6-digit code", s == 200 and len(r["pairing"]["code"]) == 6 and r["agent"]["status"] == "pending", f"{s} {r.get('agent', {}).get('status')}")
    b_agent, b_code = r["agent"]["id"], r["pairing"]["code"]
    check("B's first agent is the default", r["agent"]["is_default"] is True)
    wrong = f"{(int(b_code) + 1) % 1000000:06d}"
    s, r = fn("yui-connect", {"action": "pair", "code": wrong, "remote_ref": "monk"})
    check("a wrong code is refused", s == 401, f"{s} {r}")
    s, r = fn("yui-connect", {"action": "pair", "code": b_code, "remote_ref": "monk", "host_name": "B's Mac"})
    check("the host claims the code, gets a connector token once", s == 200 and r["connector_token"].startswith("yui_ct_") and r["agent"]["status"] == "connected", f"{s} {code(r)}")
    b_ct, b_conn = r["connector_token"], r["connector"]["id"]
    s, r = fn("yui-connect", {"action": "pair", "code": b_code, "remote_ref": "monk"})
    check("the same code cannot be used twice", s == 401, f"{s} {r}")
    s, r = fn("yui-connect", {"action": "add", "remote_ref": "arnold"}, b_ct)
    check("a paired host adds another profile with no code", s == 200 and r["created"] and r["agent"]["name"] == "Arnold" and r["agent"]["status"] == "connected", f"{s} {code(r)}")
    b_agent2 = r["agent"]["id"]
    s, r = fn("yui-connect", {"action": "add", "remote_ref": "arnold"}, b_ct)
    check("adding the same profile again returns the existing agent", s == 200 and r["created"] is False and r["agent"]["id"] == b_agent2, f"{s}")
    s, r = fn("yui-agents", {"action": "create", "name": "Hank", "pair": True}, tokB)
    s, r = fn("yui-connect", {"action": "pair", "code": r["pairing"]["code"], "remote_ref": "hank"}, b_ct)
    check("pairing on an already-paired host reuses its connector", s == 200 and r["connector_token"] is None and r["connector"]["id"] == b_conn, f"{s} {code(r)}")
    s, r = fn("yui-agents", {"action": "create", "name": "Dup", "pair": True}, tokB)
    dup = r["agent"]["id"]
    s, r = fn("yui-connect", {"action": "pair", "code": r["pairing"]["code"], "remote_ref": "hank"}, b_ct)
    check("a profile can back only one agent per host", s == 409 and r["error"] == "profile_already_added", f"{s} {r}")
    fn("yui-agents", {"action": "delete", "id": dup}, tokB)
    s, r = fn("yui-agents", {"action": "create", "name": "Late", "pair": True}, tokB)
    late_code = r["pairing"]["code"]; late = r["agent"]["id"]
    sql(f"update yui_pairings set expires_at = now() - interval '1 second' where agent_id = '{late}'")
    s, r = fn("yui-connect", {"action": "pair", "code": late_code, "remote_ref": "late"})
    check("an expired code is refused", s == 401, f"{s} {r}")
    fn("yui-agents", {"action": "delete", "id": late}, tokB)
    s, r = fn("yui-connect", {"action": "heartbeat"}, b_ct)
    check("heartbeat returns the host's agents", s == 200 and {a["remote_ref"] for a in r["agents"]} == {"monk", "arnold", "hank"}, f"{s} {[a['remote_ref'] for a in r.get('agents', [])]}")
    sql(f"update yui_connectors set last_seen_at = now() - interval '5 minutes' where id = '{b_conn}'")
    s, r = rest("GET", f"yui_agent_list?select=status&id=eq.{b_agent}", tokB)
    check("a silent host shows its agents offline", r == [{"status": "offline"}], f"{r}")
    fn("yui-connect", {"action": "heartbeat"}, b_ct)
    s, r = rest("GET", f"yui_agent_list?select=status&id=eq.{b_agent}", tokB)
    check("a heartbeat brings them back online", r == [{"status": "connected"}], f"{r}")
    s, r = rest("GET", f"yui_agent_list?select=presence&id=eq.{b_agent}", tokB)
    check("a host that never reports serving keeps per-computer presence", r == [{"presence": "online"}], f"{r}")

    print("\n== Presence per agent (YUI-64): two agents on one computer, one gateway up")
    def presence(*ids):
        s, r = rest("GET", f"yui_agent_list?select=id,presence,status&id=in.({','.join(ids)})", tokB)
        by = {x["id"]: x for x in r} if s == 200 else {}
        return [by.get(i, {}).get("presence") for i in ids], [by.get(i, {}).get("status") for i in ids]
    s, r = fn("yui-agents", {"action": "create", "name": "Alpha", "pair": True}, tokB)
    alpha = r["agent"]["id"]
    s, r = fn("yui-connect", {"action": "pair", "code": r["pairing"]["code"], "remote_ref": "alpha",
                              "host_name": "Test Mac", "serving": []})
    c_ct, c_conn = r["connector_token"], r["connector"]["id"]
    check("paired by a host that reports serving: not listening yet", s == 200 and r["agent"]["presence"] == "not_listening", f"{s} {code(r)} {r.get('agent', {}).get('presence')}")
    s, r = fn("yui-connect", {"action": "add", "remote_ref": "bravo", "serving": []}, c_ct)
    bravo = r["agent"]["id"]
    check("an added profile is not listening yet either", s == 200 and r["agent"]["presence"] == "not_listening", f"{s} {code(r)}")
    s, r = fn("yui-connect", {"action": "heartbeat", "serving": ["alpha"]}, c_ct)
    p, st = presence(alpha, bravo)
    check("one gateway serving alpha: Alpha online, Bravo not listening", s == 200 and p == ["online", "not_listening"], f"{s} {p}")
    check("status stays per computer for older apps", st == ["connected", "connected"], f"{st}")
    s, r = rest("GET", f"yui_agent_list?select=presence&id=eq.{bravo}", tokA)
    check("another person sees nothing of it", s == 200 and r == [], f"{s} {r}")
    s, r = fn("yui-connect", {"action": "session", "serving": ["bravo", "not a ref!"]}, c_ct)
    p, _ = presence(alpha, bravo)
    check("Bravo's gateway starts (session): both online, junk refs ignored", s == 200 and p == ["online", "online"], f"{s} {p}")
    s, r = fn("yui-connect", {"action": "bye", "serving": ["bravo"]}, c_ct)
    p, _ = presence(alpha, bravo)
    check("Bravo's gateway says bye: Bravo offline, Alpha stays online", s == 200 and r["stopped_at"] is None and p == ["online", "offline"], f"{s} {r} {p}")
    fn("yui-connect", {"action": "heartbeat", "serving": ["bravo"]}, c_ct)
    sql(f"update yui_agents set served_at = now() - interval '5 minutes' where id = '{alpha}'")
    p, _ = presence(alpha, bravo)
    check("Alpha's gateway went quiet while the computer is up: Alpha offline", p == ["offline", "online"], f"{p}")
    s, r = fn("yui-connect", {"action": "bye", "serving": ["bravo"]}, c_ct)
    p, st = presence(alpha, bravo)
    check("the last gateway says bye: the whole computer reads offline", s == 200 and r["stopped_at"] and p == ["offline", "offline"] and st == ["offline", "offline"], f"{s} {r} {p} {st}")
    fn("yui-connect", {"action": "heartbeat", "serving": ["alpha", "bravo"]}, c_ct)
    sql(f"update yui_connectors set last_seen_at = now() - interval '5 minutes' where id = '{c_conn}'")
    p, _ = presence(alpha, bravo)
    check("the computer sleeps: both asleep", p == ["asleep", "asleep"], f"{p}")
    fn("yui-connect", {"action": "heartbeat", "serving": ["alpha", "bravo"]}, c_ct)
    sql(f"update yui_agents set remote_ref = 'bravo2' where id = '{bravo}'")
    p, _ = presence(alpha, bravo)
    check("bound to another profile: not listening until that gateway reports", p == ["online", "not_listening"], f"{p}")
    got = sql(f"select public.yui_agent_presence('{bravo}') p")[0]["p"]
    check("mentions read the same rule", got == "not_listening", f"{got}")
    fn("yui-agents", {"action": "delete", "id": alpha}, tokB)
    fn("yui-agents", {"action": "delete", "id": bravo}, tokB)
    fn("yui-agents", {"action": "connector_revoke", "id": c_conn}, tokB)

    print("\n== Slash commands (YUI-61)")
    s, r = rest("GET", f"yui_agent_list?select=commands&id=eq.{b_agent}", tokB)
    check("an agent with no report has no commands", r == [{"commands": None}], f"{r}")
    cmds = [{"name": "new", "description": "Start a new session\n(fresh)", "args": "[name]"},
            {"name": "/Model", "description": "Switch model"}, {"name": "new", "description": "dupe"},
            {"name": "bad name", "description": "x"}, {"name": "x" * 40, "description": "too long"},
            {"name": "stop", "description": "d" * 300, "args": ""}, "junk", {"description": "no name"}]
    s, r = fn("yui-connect", {"action": "commands", "remote_ref": "monk", "commands": cmds}, b_ct)
    check("the host reports its commands", s == 200 and r["agents"] == 1 and r["commands"] == 3, f"{s} {r}")
    s, r = fn("yui-agents", {"action": "list"}, tokB)
    got = next(a for a in r["agents"] if a["id"] == b_agent)["commands"]
    check("the app's list carries them, cleaned", got == [
        {"name": "new", "description": "Start a new session (fresh)", "args": "[name]"},
        {"name": "model", "description": "Switch model"}, {"name": "stop", "description": "d" * 100}], f"{got}")
    others = [a["commands"] for a in r["agents"] if a["id"] != b_agent]
    check("only that profile's agent gets them", others and all(c is None for c in others), f"{others}")
    s, r = fn("yui-connect", {"action": "commands", "remote_ref": "monk", "commands": "nope"}, b_ct)
    check("a list that is not a list is refused", s == 400 and code(r) == "invalid_commands", f"{s} {r}")
    s, r = fn("yui-connect", {"action": "commands", "remote_ref": "monk", "commands": []})
    check("no connector token, no report", s == 401, f"{s} {r}")
    s, r = rest("PATCH", f"yui_agents?id=eq.{b_agent}", tokB, {"commands": [{"name": "x", "description": "y"}]})
    check("the app cannot write commands itself", s in (401, 403), f"{s} {r}")
    s, r = fn("yui-connect", {"action": "commands", "remote_ref": "monk", "commands": None}, b_ct)
    s2, r2 = rest("GET", f"yui_agent_list?select=commands&id=eq.{b_agent}", tokB)
    check("commands: null clears them", s == 200 and r2 == [{"commands": None}], f"{s} {r2}")
    fn("yui-connect", {"action": "commands", "remote_ref": "monk", "commands": cmds[:1]}, b_ct)

    print("\n== Cross-user isolation (app tokens)")
    s, r = fn("yui-agents", {"action": "create", "name": "Yui", "remote_ref": "yui"}, tokA)
    a_agent = r["agent"]["id"]
    for path in ["yui_agents?select=id", "yui_agent_list?select=id", "yui_connectors?select=id", "yui_pairings?select=id"]:
        s, r = rest("GET", path, tokA)
        check(f"A sees none of B's rows in {path.split('?')[0]}", s == 200 and all(x["id"] not in (b_agent, b_agent2, b_conn) for x in r), f"{s} {len(r) if isinstance(r, list) else r}")
    s, r = rest("PATCH", f"yui_agents?id=eq.{b_agent}", tokA, {"name": "pwned"}, prefer="return=representation")
    check("A cannot rename B's agent (REST)", s == 200 and r == [], f"{s} {r}")
    s, r = rest("DELETE", f"yui_agents?id=eq.{b_agent}", tokA, prefer="return=representation")
    check("A cannot delete B's agent (REST)", s == 200 and r == [], f"{s} {r}")
    s, r = rest("PATCH", f"yui_connectors?id=eq.{b_conn}&select=id,name", tokA, {"name": "pwned"}, prefer="return=representation")
    check("A cannot rename B's connector (REST)", s == 200 and r == [], f"{s} {r}")
    for act, extra in [("update", {"id": b_agent, "name": "pwned"}), ("delete", {"id": b_agent}), ("pair_code", {"agent_id": b_agent})]:
        s, r = fn("yui-agents", {"action": act, **extra}, tokA)
        check(f"A cannot {act} B's agent (API)", s == 404, f"{s} {r}")
    s, r = fn("yui-agents", {"action": "create", "name": "Spy", "remote_ref": "spy", "connector_id": b_conn}, tokA)
    check("A cannot bind an agent to B's host", s == 404, f"{s} {r}")
    s, r = fn("yui-agents", {"action": "connector_revoke", "id": b_conn}, tokA)
    check("A cannot revoke B's host", s == 404, f"{s} {r}")
    s, r = fn("yui-agents", {"action": "list"}, tokA)
    check("A's list holds only A's agent", s == 200 and [a["id"] for a in r["agents"]] == [a_agent] and r["connectors"] == [], f"{s}")
    check("B's agent still named Monk", sql(f"select name from yui_agents where id='{b_agent}'")[0]["name"] == "Monk")

    print("\n== What the app token may and may not write")
    s, r = rest("POST", "yui_agents", tokA, {"user_id": A, "name": "direct", "handle": "direct"})
    check("app cannot insert agents directly (registry API only)", s in (401, 403), f"{s} {code(r)}")
    s, r = rest("PATCH", f"yui_agents?id=eq.{a_agent}", tokA, {"connector_id": b_conn})
    check("app cannot set connector_id directly", s in (401, 403), f"{s} {code(r)}")
    s, r = rest("PATCH", f"yui_agents?id=eq.{a_agent}", tokA, {"remote_ref": "urza"})
    check("app cannot set remote_ref directly", s in (401, 403), f"{s} {code(r)}")
    s, r = rest("GET", "yui_connectors?select=token_hash", tokB)
    check("no one reads a connector token hash", s in (401, 403), f"{s} {code(r)}")
    s, r = rest("GET", "yui_pairings?select=code_hash", tokB)
    check("no one reads a pairing code hash", s in (401, 403), f"{s} {code(r)}")
    s, r = rest("PATCH", f"yui_agents?id=eq.{a_agent}", tokA, {"name": "Yui!", "color": "mint", "sort": 3}, prefer="return=representation")
    check("app renames, recolors, reorders its own agent", s == 200 and r[0]["name"] == "Yui!" and r[0]["color"] == "mint", f"{s} {code(r)}")
    s, r = rest("PATCH", f"yui_agents?id=eq.{a_agent}", tokA, {"color": "neon"})
    check("unknown color tokens are refused", s == 400, f"{s} {code(r)}")

    print("\n== Defaults")
    s, r = fn("yui-agents", {"action": "update", "id": b_agent2, "is_default": True}, tokB)
    rows = sql(f"select id from yui_agents where user_id='{B}' and is_default")
    check("setting a default clears the old one", s == 200 and [x["id"] for x in rows] == [b_agent2], f"{s} {rows}")
    s, r = rest("PATCH", f"yui_agents?id=eq.{b_agent}", tokB, {"is_default": True}, prefer="return=representation")
    rows = sql(f"select id from yui_agents where user_id='{B}' and is_default")
    check("same through REST, one write", s == 200 and [x["id"] for x in rows] == [b_agent], f"{s} {rows}")
    s, r = fn("yui-agents", {"action": "reorder", "ids": [b_agent2, b_agent]}, tokB)
    rows = sql(f"select id, sort from yui_agents where id in ('{b_agent}','{b_agent2}') order by sort")
    check("reorder sets display order", [x["id"] for x in rows] == [b_agent2, b_agent], f"{rows}")

    print("\n== Management token (Settings > Agent access)")
    s, r = fn("yui-agents", {"action": "token_create", "name": "Urza"}, tokB)
    check("app creates a token, shown once", s == 200 and r["token"].startswith("yui_mt_") and r["scope"] == "agents:manage", f"{s} {code(r)}")
    mt, mt_id = r["token"], r["id"]
    check("only its hash is stored", sql(f"select token_hash from yui_mgmt_tokens where id='{mt_id}'")[0]["token_hash"] == hashlib.sha256(mt.encode()).hexdigest())
    s, r = fn("yui-agents", {"action": "token_list"}, tokB)
    check("token list never returns the secret or hash", s == 200 and "token" not in r["tokens"][0] and "token_hash" not in r["tokens"][0], f"{s}")
    s, r = fn("yui-agents", {"action": "create", "remote_ref": "urza", "connector_id": b_conn}, mt)
    check("token creates an agent on the user's host ('add Urza to my Yui')", s == 200 and r["agent"]["name"] == "Urza" and r["agent"]["status"] == "connected", f"{s} {code(r)}")
    t_agent = r["agent"]["id"]
    s, r = fn("yui-agents", {"action": "list"}, mt)
    check("token lists the user's agents", s == 200 and t_agent in [a["id"] for a in r["agents"]], f"{s}")
    s, r = fn("yui-agents", {"action": "update", "id": t_agent, "name": "Urza the Wise", "color": "butter"}, mt)
    check("token renames and recolors", s == 200 and r["agent"]["name"] == "Urza the Wise", f"{s} {code(r)}")
    s, r = fn("yui-agents", {"action": "delete", "id": t_agent}, mt)
    check("token deletes the agent", s == 200 and r["deleted"], f"{s} {code(r)}")
    s, r = rest("GET", "yui_messages?select=body", mt)
    check("token cannot read messages through the REST API", s in (401, 403), f"{s} {code(r)}")
    s, r = rest("GET", "yui_agents?select=id", mt)
    check("token is not a database credential at all", s in (401, 403), f"{s} {code(r)}")
    s, r = fn("yui-agents", {"action": "messages"}, mt)
    check("the registry API has no message action", s == 400 and r["error"] == "unknown_action", f"{s} {r}")
    for act in ["token_create", "token_list", "token_revoke", "connector_revoke"]:
        s, r = fn("yui-agents", {"action": act, "id": b_conn, "name": "x"}, mt)
        check(f"token cannot {act}", s == 403, f"{s} {r}")
    s, r = fn("yui-delete", {}, mt)
    check("token cannot delete the account", s == 401, f"{s} {r}")
    s, r = fn("yui-agents", {"action": "update", "id": a_agent, "name": "pwned"}, mt)
    check("B's token cannot touch A's agent", s == 404, f"{s} {r}")
    s, r = fn("yui-agents", {"action": "token_revoke", "id": mt_id}, tokB)
    s2, r2 = fn("yui-agents", {"action": "list"}, mt)
    check("a revoked token stops working", s == 200 and s2 == 401, f"{s} {s2}")

    print("\n== Removing an agent deletes its thread")
    sql(f"insert into yui_messages(user_id, agent_id, sender, body) values ('{B}','{b_agent}','user','hi Monk'),('{B}','{b_agent2}','user','hi Arnold')")
    s, r = rest("DELETE", f"yui_agents?id=eq.{b_agent}", tokB, prefer="return=representation")
    left = sql(f"select body from yui_messages where user_id='{B}'")
    check("deleting Monk removes Monk's messages and nothing else", s == 200 and len(r) == 1 and [m["body"] for m in left] == ["hi Arnold"], f"{s} {left}")
    s, r = fn("yui-agents", {"action": "delete", "id": b_agent2}, tokB)
    rows = sql(f"select name from yui_agents where user_id='{B}' and is_default")
    check("deleting the default promotes the next agent", s == 200 and [x["name"] for x in rows] == ["Hank"], f"{rows}")

    print("\n== Revoking a host")
    s, r = fn("yui-agents", {"action": "connector_revoke", "id": b_conn}, tokB)
    s2, _ = fn("yui-connect", {"action": "heartbeat"}, b_ct)
    s3, r3 = rest("GET", "yui_agent_list?select=status", tokB)
    check("a revoked host's token is dead and its agents show offline", s == 200 and s2 == 401 and {x["status"] for x in r3} == {"offline"}, f"{s} {s2} {r3}")

    print("\n== Code guessing is throttled")
    statuses = [fn("yui-connect", {"action": "pair", "code": f"{i:06d}", "remote_ref": "x"})[0] for i in range(12)]
    check("after 10 wrong codes the host address gets 429", statuses[-1] == 429 and 429 in statuses, f"{statuses}")
finally:
    sql(f"delete from yui_users where id in ('{A}','{B}'); delete from yui_pair_attempts where created_at > now() - interval '1 hour'")
    left = sql(f"select (select count(*) from yui_agents where user_id in ('{A}','{B}')) + (select count(*) from yui_connectors where user_id in ('{A}','{B}')) + (select count(*) from yui_mgmt_tokens where user_id in ('{A}','{B}')) n")[0]["n"]
    check("test accounts deleted, zero registry rows left", left == 0, f"{left}")

print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)

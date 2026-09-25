#!/usr/bin/env python3
"""YUI-8 / YUI-24 push tests against PROOF (live).

yui-push registers a phone's APNs token for the signed-in user (app token)
and lets a host notify that user about an agent message it just wrote
(connector token), only for threads of agents bound to that host. YUI-24:
no push to a phone that is open on that thread (presence), none for a muted
agent, and presence goes stale so a killed app still gets it. The fake
device token must reach Apple and come back BadDeviceToken: that proves the
function signs a provider token Apple accepts (a bad key is 403
InvalidProviderToken) without pushing to anyone's phone. Every test account
is deleted at the end. Needs a Supabase access token, like accounts_test.py.

    python3 supabase/tests/push_test.py [--device <hex token> --env sandbox]

With --device, the last check pushes a real notification to that phone or
simulator (the app must be installed and have allowed notifications). Only ever a
simulator token: the test account is deleted at the end and takes the row with it.
"""
import argparse, sys, uuid
exec(open(__file__.replace("push_test.py", "agents_test.py")).read().split("results = []")[0])

ap = argparse.ArgumentParser()
ap.add_argument("--device")
ap.add_argument("--env", default="sandbox")
opts = ap.parse_args()

results = []
def check(name, ok, detail=""):
    results.append(ok); print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  [{detail}]" if detail else ""))

def push(body, token=None): return fn("yui-push", body, token)
def host(body, token=None): return fn("yui-connect", body, token)

A, B = str(uuid.uuid4()), str(uuid.uuid4())
FAKE = "ab" * 32
sql(f"insert into yui_users(id, apple_sub) values ('{A}','test.{A}'),('{B}','test.{B}')")
tokA, tokB = mint(A), mint(B)
try:
    print("== Setup: each user pairs one agent on their own host")
    def paired(tok, ref):
        s, r = fn("yui-agents", {"action": "create", "name": ref.title(), "pair": True}, tok)
        s2, p = host({"action": "pair", "code": r["pairing"]["code"], "remote_ref": ref, "host_name": "Test host"})
        assert s2 == 200, p
        return r["agent"]["id"], p["connector_token"]
    a_agent, a_ct = paired(tokA, "alpha")
    b_agent, b_ct = paired(tokB, "bravo")
    ctA = host({"action": "session"}, a_ct)[1]["access_token"]
    ctB = host({"action": "session"}, b_ct)[1]["access_token"]

    print("== Register (app token)")
    s, r = push({"action": "register", "token": FAKE, "environment": "sandbox", "name": "Test phone"}, tokA)
    check("app registers its device token", s == 200, f"{s} {r}")
    rows = sql(f"select user_id, environment, name from yui_devices where apns_token = '{FAKE}'")
    check("one row, owned by the user, sandbox", rows == [{"user_id": A, "environment": "sandbox", "name": "Test phone"}], f"{rows}")
    s, r = push({"action": "register", "token": "not-hex"}, tokA)
    check("junk token is refused", s == 400, f"{s}")
    s, r = push({"action": "register", "token": FAKE, "environment": "moon"}, tokA)
    check("unknown environment is refused", s == 400, f"{s}")
    s, r = push({"action": "register", "token": FAKE})
    check("register without a token is 401", s == 401, f"{s}")
    s, r = push({"action": "register", "token": FAKE}, a_ct)
    check("register with a connector token is 401", s == 401, f"{s}")
    s, r = rest("GET", "yui_devices?select=apns_token", tokA)
    check("user reads its own device over REST", s == 200 and [x["apns_token"] for x in r] == [FAKE], f"{s} {r}")
    s, r = rest("GET", "yui_devices?select=apns_token", tokB)
    check("other user cannot see it", s == 200 and r == [], f"{s} {r}")
    s, r = rest("GET", "yui_devices?select=apns_token", ctA)
    check("host cannot read device tokens", s in (401, 403) or r == [], f"{s} {r}")

    print("== App build (beta feedback ANJPrtB7CHynwGR5mqNVPSM: a sketch on build 96)")
    check("session says no build before any phone has", host({"action": "session"}, a_ct)[1].get("app_build") is None)
    ua = {"apikey": PUBLISHABLE, "authorization": f"Bearer {tokA}", "user-agent": "Yui/96 CFNetwork/3860.100.1 Darwin/25.0.0"}
    s, r = http("POST", f"{BASE}/functions/v1/yui-push", ua, {"action": "presence", "token": FAKE, "active": True})
    rows = sql(f"select app_build from yui_devices where apns_token = '{FAKE}'")
    check("presence reads the build from the app's user agent", s == 200 and rows == [{"app_build": 96}], f"{s} {rows}")
    s, sa = host({"action": "session"}, a_ct)
    check("session hands the host the phone's build", s == 200 and sa.get("app_build") == 96, f"{s} {sa.get('app_build')}")
    OTHER = "cd" * 32
    s, r = push({"action": "register", "token": OTHER, "environment": "sandbox", "name": "New phone", "build": "112.1"}, tokA)
    check("register takes an explicit build (devbuild 112.1 is 112)", s == 200
          and sql(f"select app_build from yui_devices where apns_token = '{OTHER}'") == [{"app_build": 112}], f"{s} {r}")
    check("session gives the oldest of the user's phones", host({"action": "session"}, a_ct)[1].get("app_build") == 96)
    sql(f"update yui_devices set app_build_at = now() - interval '15 days' where apns_token = '{FAKE}'")
    check("a phone not seen in 14 days no longer holds it back", host({"action": "session"}, a_ct)[1].get("app_build") == 112)
    check("another user's host never sees these builds", host({"action": "session"}, b_ct)[1].get("app_build") is None)
    sql(f"delete from yui_devices where apns_token = '{OTHER}'")
    sql(f"update yui_devices set app_build = null, app_build_at = null where apns_token = '{FAKE}'")

    print("== Notify (connector token)")
    s, r = rest("POST", "yui_messages", ctA, {"user_id": A, "agent_id": a_agent, "sender": "agent",
                "body": "Pick one\n```yui\nchoose ship \"Ship it?\" [Yes, Not yet]\n```", "kind": "text"},
                prefer="return=representation")
    a_msg = r[0]["id"]
    s, r = push({"action": "notify", "message_id": a_msg, "from": "Urza"}, a_ct)
    res = (r or {}).get("results") or [{}]
    check("host notifies: reaches APNs, Apple accepts the provider token", s == 200 and r["devices"] == 1
          and res[0].get("reason") == "BadDeviceToken", f"{s} {r}")
    err = sql(f"select last_error from yui_devices where apns_token = '{FAKE}'")
    check("device records Apple's answer", err == [{"last_error": "BadDeviceToken"}], f"{err}")
    s, r = push({"action": "notify", "message_id": a_msg}, b_ct)
    check("another user's host cannot notify about it", s == 404, f"{s} {r}")
    s, r = push({"action": "notify", "message_id": a_msg}, tokA)
    check("app token cannot notify", s == 401, f"{s}")
    s, r = push({"action": "notify", "message_id": str(uuid.uuid4())}, a_ct)
    check("unknown message is 404", s == 404, f"{s}")
    s, r = rest("POST", "yui_messages", tokA, {"user_id": A, "agent_id": a_agent, "sender": "user",
                "body": "hi", "kind": "text"}, prefer="return=representation")
    s, r = push({"action": "notify", "message_id": r[0]["id"]}, a_ct)
    check("user's own messages do not push", s == 400, f"{s} {r}")
    old = sql(f"insert into yui_messages(user_id, agent_id, sender, body, created_at) values "
              f"('{A}','{a_agent}','agent','old', now() - interval '1 hour') returning id")[0]["id"]
    s, r = push({"action": "notify", "message_id": old}, a_ct)
    check("messages older than 10 minutes do not push", s == 409, f"{s} {r}")

    print("== Presence and mute (YUI-24)")
    def agent_msg(body="Answer"):
        return rest("POST", "yui_messages", ctA, {"user_id": A, "agent_id": a_agent, "sender": "agent",
                    "body": body, "kind": "text"}, prefer="return=representation")[1][0]["id"]
    s2, other = fn("yui-agents", {"action": "create", "name": "Other"}, tokA)
    other_id = other["agent"]["id"]
    s, r = push({"action": "presence", "token": FAKE, "active": True, "agent_id": a_agent}, tokA)
    row = sql(f"select active_agent_id, active_at is not null as on from yui_devices where apns_token = '{FAKE}'")
    check("app reports it is open on the thread", s == 200 and r.get("tracked") and row == [{"active_agent_id": a_agent, "on": True}], f"{s} {r} {row}")
    s, r = push({"action": "notify", "message_id": agent_msg()}, a_ct)
    check("open on that thread: no push, counted as skipped", s == 200 and r["devices"] == 0 and r["skipped"] == 1, f"{s} {r}")
    push({"action": "presence", "token": FAKE, "active": True, "agent_id": other_id}, tokA)
    s, r = push({"action": "notify", "message_id": agent_msg()}, a_ct)
    check("open on another agent's thread: push goes out", s == 200 and r["devices"] == 1 and r["skipped"] == 0, f"{s} {r}")
    push({"action": "presence", "token": FAKE, "active": True, "agent_id": a_agent}, tokA)
    sql(f"update yui_devices set active_at = now() - interval '2 minutes' where apns_token = '{FAKE}'")
    s, r = push({"action": "notify", "message_id": agent_msg()}, a_ct)
    check("presence older than 90s (app killed): push goes out", s == 200 and r["devices"] == 1, f"{s} {r}")
    push({"action": "presence", "token": FAKE, "active": True, "agent_id": a_agent}, tokA)
    s, r = push({"action": "presence", "token": FAKE, "active": False}, tokA)
    row = sql(f"select active_agent_id, active_at from yui_devices where apns_token = '{FAKE}'")
    check("app goes to the background: presence cleared", s == 200 and row == [{"active_agent_id": None, "active_at": None}], f"{row}")
    s, r = push({"action": "notify", "message_id": agent_msg()}, a_ct)
    check("backgrounded: push goes out", s == 200 and r["devices"] == 1, f"{s} {r}")
    s, r = push({"action": "presence", "token": FAKE, "active": True, "agent_id": a_agent}, tokB)
    row = sql(f"select active_at from yui_devices where apns_token = '{FAKE}'")
    check("another user cannot set this phone's presence", s == 200 and not r.get("tracked") and row == [{"active_at": None}], f"{r} {row}")
    s, r = push({"action": "presence", "token": FAKE, "active": True, "agent_id": b_agent}, tokA)
    row = sql(f"select active_agent_id from yui_devices where apns_token = '{FAKE}'")
    check("presence on someone else's agent is not stored", s == 200 and row == [{"active_agent_id": None}], f"{row}")
    s, r = push({"action": "presence", "token": FAKE, "active": "yes"}, tokA)
    check("presence needs a boolean", s == 400, f"{s}")
    s, r = push({"action": "presence", "token": FAKE, "active": True}, a_ct)
    check("presence with a connector token is 401", s == 401, f"{s}")
    push({"action": "presence", "token": FAKE, "active": False}, tokA)

    s, r = fn("yui-agents", {"action": "update", "id": a_agent, "push_muted": True}, tokA)
    check("user mutes the agent in its settings", s == 200 and r["agent"]["push_muted"] is True, f"{s} {r}")
    s, r = fn("yui-agents", {"action": "update", "id": a_agent, "push_muted": "no"}, tokA)
    check("mute needs a boolean", s == 400, f"{s}")
    s, r = push({"action": "notify", "message_id": agent_msg(), "from": "Urza"}, a_ct)
    check("muted agent: no push, even for a handoff", s == 200 and r.get("muted") and r["devices"] == 0, f"{s} {r}")
    s, r = rest("PATCH", f"yui_agents?id=eq.{a_agent}", tokB, {"push_muted": False}, prefer="return=representation")
    row = sql(f"select push_muted from yui_agents where id = '{a_agent}'")
    check("another user cannot unmute it", row == [{"push_muted": True}], f"{s} {r} {row}")
    s, r = rest("PATCH", f"yui_agents?id=eq.{a_agent}", tokA, {"push_muted": False}, prefer="return=representation")
    check("owner unmutes over REST too", s == 200 and r and r[0]["push_muted"] is False, f"{s} {r}")
    s, r = push({"action": "notify", "message_id": agent_msg()}, a_ct)
    check("unmuted: pushes again", s == 200 and r["devices"] == 1, f"{s} {r}")

    print("== Move and unregister")
    s, r = push({"action": "register", "token": FAKE, "environment": "sandbox"}, tokB)
    rows = sql(f"select user_id from yui_devices where apns_token = '{FAKE}'")
    check("same phone signs into another account: token moves", s == 200 and rows == [{"user_id": B}], f"{rows}")
    s, r = push({"action": "unregister", "token": FAKE}, tokA)
    rows = sql(f"select user_id from yui_devices where apns_token = '{FAKE}'")
    check("old account cannot unregister it", rows == [{"user_id": B}], f"{rows}")
    s, r = push({"action": "unregister", "token": FAKE}, tokB)
    rows = sql(f"select count(*) as n from yui_devices where apns_token = '{FAKE}'")
    check("owner unregisters on sign out", s == 200 and rows[0]["n"] == 0, f"{rows}")

    if opts.device:
        print("== Real device")
        s, r = push({"action": "register", "token": opts.device, "environment": opts.env}, tokA)
        s, r = rest("POST", "yui_messages", ctA, {"user_id": A, "agent_id": a_agent, "sender": "agent",
                    "body": "push_test.py says hi", "kind": "text"}, prefer="return=representation")
        s, r = push({"action": "notify", "message_id": r[0]["id"]}, a_ct)
        check("real device push delivered by APNs", s == 200 and r["delivered"] == 1, f"{s} {r}")
finally:
    sql(f"delete from yui_users where id in ('{A}','{B}')")
    left = sql("select " + " + ".join(f"(select count(*) from {t} where user_id in ('{A}','{B}'))" for t in
               ["yui_agents", "yui_messages", "yui_connectors", "yui_devices"]) + " as n")
    check("test accounts deleted, zero rows left", left[0]["n"] == 0, f"{left}")

print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)

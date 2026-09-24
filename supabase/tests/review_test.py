#!/usr/bin/env python3
"""YUI-27: the App Review demo account, live against PROOF.

The review grant in yui-auth (right code in, wrong code out, forgiving about
case and dashes), a yui_user session for the one demo account, the demo agent
(hermes-plugin/demo_agent.py, running under launchd) answering a typed message
and a tap with screens, and self-repair: after the reviewer deletes the demo
account, the next review sign-in recreates it and the demo agent pairs itself
again. Reads the code from ~/.hermes/yui/review.json; never prints it.

    python3 supabase/tests/review_test.py [--no-delete]
"""
import json, os, sys, time, urllib.parse
exec(open(__file__.replace("review_test.py", "agents_test.py")).read().split("results = []")[0])

results = []
def check(name, ok, detail=""):
    results.append(ok); print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  [{detail}]" if detail else ""), flush=True)

cfg = json.load(open(os.path.expanduser("~/.hermes/yui/review.json")))
CODE, USER = cfg["code"], cfg["user_id"]

def review(code):
    return fn("yui-auth", {"grant_type": "review", "code": code})

def claims(tok):
    p = tok.split(".")[1]; return json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4)))

def wait_reply(token, agent_id, after, needle, timeout=30):
    end = time.time() + timeout
    while time.time() < end:
        s, rows = rest("GET", f"yui_messages?select=body,meta,created_at&agent_id=eq.{agent_id}&sender=eq.agent"
                              f"&created_at=gt.{urllib.parse.quote(after)}&order=created_at.asc", token)
        for r in rows if isinstance(rows, list) else []:
            if needle in r["body"]:
                return r
        time.sleep(1)
    return None

def say(token, agent_id, body, kind="text", meta=None):
    row = {"user_id": USER, "agent_id": agent_id, "sender": "user", "kind": kind, "body": body}
    if meta: row["meta"] = meta
    s, r = rest("POST", "yui_messages", token, row, "return=representation")
    return s, (r[0] if s < 300 else r)

def demo_agent(token):
    s, r = fn("yui-agents", {"action": "list"}, token)
    return next((a for a in (r or {}).get("agents", []) if a.get("remote_ref") == "yui-demo"), None), r

def round_trip(token, label):
    agent, _ = demo_agent(token)
    check(f"{label}: the demo account has the Demo agent", bool(agent), agent and agent["name"])
    if not agent: return
    s, sent = say(token, agent["id"], "hi")
    check(f"{label}: message accepted", s < 300, s)
    r = wait_reply(token, agent["id"], sent["created_at"], "choose@menu")
    check(f"{label}: Demo answers 'hi' with a screen", bool(r) and "```yui" in r["body"],
          r and r["body"].split("\n")[0][:60])
    check(f"{label}: the reply names the turn it answers", bool(r) and (r["meta"] or {}).get("turn") == [sent["id"]])
    s, ev = say(token, agent["id"], '[yui] menu choose choice=Workout', "event",
                {"id": "menu", "preset": "choose", "value": {"choice": "Workout"}, "echo": "Workout"})
    r = wait_reply(token, agent["id"], ev["created_at"], "pick@gear")
    check(f"{label}: a tap on Workout gets the next screen", bool(r), r and r["body"].split("\n")[0][:60])

# 1. The grant
s, r = review("WRONG-CODE-0000")
check("a wrong code is refused", s == 401 and r.get("error") == "invalid_grant", s)
s, r = review("")
check("an empty code is refused", s in (400, 401), s)
s, r = review(CODE.lower().replace("-", " "))
check("the code is forgiving about case, dashes and spaces", s == 200, s)
s, r = review(CODE)
check("the review code signs in", s == 200 and r.get("user", {}).get("id") == USER, s)
tok, rt = r["access_token"], r["refresh_token"]
c = claims(tok)
check("its token is role yui_user for the demo account, never authenticated",
      c.get("role") == "yui_user" and c.get("sub") == USER, c.get("role"))
s, r2 = fn("yui-auth", {"grant_type": "refresh", "refresh_token": rt})
check("the demo session refreshes like any other", s == 200, s)
tok = r2["access_token"]
row = sql(f"select apple_sub, email from yui_users where id='{USER}'")[0]
check("the demo account has no Apple ID and no email", row["apple_sub"] == f"review.{USER}" and row["email"] is None)

# 2. The demo agent answers
round_trip(tok, "live")

# 3. Reviewer deletes the demo account; it comes back on its own
if "--no-delete" not in sys.argv:
    s, r = fn("yui-delete", {}, tok)
    check("Delete account works on the demo account", s == 200 and r.get("deleted"), s)
    check("the demo account is gone", sql(f"select count(*) as n from yui_users where id='{USER}'")[0]["n"] == 0)
    s, r = review(CODE)
    check("the next review sign-in recreates it", s == 200, s)
    tok = r["access_token"]
    agent, seen = None, None
    end = time.time() + 90
    while time.time() < end and not agent:
        time.sleep(3)
        agent, seen = demo_agent(tok)
    check("the demo agent pairs itself again", bool(agent), seen if not agent else agent["name"])
    round_trip(tok, "after delete")

print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)

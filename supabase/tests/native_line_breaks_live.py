#!/usr/bin/env python3
"""YUI-161, live on yuigui: a native list answer reads as lines, never "nn".

GLM 5.2 wrote say "...:\\n\\n• Grilled chicken..." and YL reads \\n as the letter n.
Makes a throwaway account, asks Basil (or Yui) for a list of dinners, waits for
yui-native, and checks no quoted string in the answer holds a \\n.
Writes the answer and its meta to --out. The account is deleted at the end.

    python3 supabase/tests/native_line_breaks_live.py --out /tmp/yui161-live
"""
import argparse, json, re, sys, time, uuid
from pathlib import Path
exec(open(__file__.replace("native_line_breaks_live.py", "agents_test.py")).read().split("results = []")[0])

ap = argparse.ArgumentParser()
ap.add_argument("--out", default="/tmp/yui161-live")
ap.add_argument("--ask", default="What should I eat for dinner tonight? Something with protein, give me 5 options. I'm allergic to peanuts and shellfish.")
ap.add_argument("--wait", type=int, default=240)
args = ap.parse_args()
OUT = Path(args.out); OUT.mkdir(parents=True, exist_ok=True)

results = []
def check(name, ok, detail=""):
    results.append(ok); print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  [{detail}]" if detail else ""), flush=True)

T = str(uuid.uuid4())
sql(f"insert into yui_users(id, apple_sub) values ('{T}','test.{T}')")
try:
    check("native is on", str(sql("select value from yui_limits where name='native_enabled'")[0]["value"]) == "1")
    s, _ = fn("yui-agents", {"action": "list"}, mint(T))
    yui = sql(f"select id from yui_agents where user_id='{T}' and name='Basil'") or sql(f"select id from yui_agents where user_id='{T}' and name='Yui'")
    check("a new account gets a hosted agent", s == 200 and bool(yui), f"{s}")
    yui = yui[0]["id"]
    s, r = rest("POST", "yui_messages", mint(T), {"user_id": T, "agent_id": yui, "sender": "user", "body": args.ask, "kind": "text"},
                prefer="return=representation")
    check("the ask reaches Yui", s in (200, 201), f"{s}")
    since, t0 = r[0]["created_at"], time.time()
    got = []
    seen = None
    while time.time() < t0 + args.wait and not got:
        time.sleep(3)
        row = sql(f"select delivered_at is not null as delivered, doing, handled_at is not null as handled from yui_messages where id='{r[0]['id']}'")[0]
        state = (row["delivered"], json.dumps(row["doing"]), row["handled"])
        if state != seen: print(f"  {round(time.time() - t0)}s delivered={state[0]} doing={state[1]} handled={state[2]}", flush=True); seen = state
        got = sql(f"select body, meta, created_at from yui_messages where user_id='{T}' and agent_id='{yui}' and sender='agent' "
                  f"and created_at > '{since}' order by created_at limit 1")
    body = got[0]["body"] if got else ""
    meta = got[0]["meta"] if got else {}
    (OUT / "answer.txt").write_text(body)
    (OUT / "answer.json").write_text(json.dumps({"ask": args.ask, "seconds": round(time.time() - t0), "body": body, "meta": meta}, indent=2))
    check("Yui answers", bool(body.strip()), f"{len(body)} chars in {round(time.time() - t0)}s")
    quoted = [m.group(1) for m in re.finditer(r'"((?:[^"\\\n]|\\.)*)"', body)]
    bad = [q for q in quoted if re.search(r'(^|[^\\])(\\\\)*\\n', q)]
    check("no \\n inside a quoted string", not bad, bad[0][:120] if bad else f"{len(quoted)} quoted strings")
finally:
    sql(f"delete from yui_users where id = '{T}'")
    left = sql("select " + " + ".join(f"(select count(*) from {t} where user_id = '{T}')" for t in
               ["yui_agents", "yui_messages", "yui_sessions"]) + " as n")
    check("throwaway account deleted, zero rows left", left[0]["n"] == 0, f"{left}")

print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)

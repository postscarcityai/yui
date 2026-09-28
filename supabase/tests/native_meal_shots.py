#!/usr/bin/env python3
"""YUI-103: log a meal without weighing, live, in the app, on a throwaway account.

Makes a new account (Basil arrives with his starter foods), uploads a meal photo the way
the app does (yui-media, from=user) and sends it with a spoken note. The live runtime must
answer at once with no model call, then post the breakdown from the meal job: one table of
every item, today so far and one chart, rows in meals and myfoods. If Basil asks his one
question, it is tapped and applied with no model turn. Then a meal said in words. Then the
installed Yui opens Basil's thread for screenshots (chat, and the stage). The account and its
photo are deleted at the end.

    python3 supabase/tests/native_meal_shots.py --sim <udid> --out /tmp/yui103-shots [--appearance dark] [--photo meal.jpg]
"""
import argparse, hashlib, json, os, secrets, subprocess, sys, time, urllib.request, uuid
from pathlib import Path
exec(open(Path(__file__).resolve().parent.joinpath("agents_test.py")).read().split("results = []")[0])

ap = argparse.ArgumentParser()
ap.add_argument("--sim", required=True)
ap.add_argument("--out", default="/tmp/yui103-shots")
ap.add_argument("--appearance", default="light", choices=["light", "dark"])
ap.add_argument("--photo", default="https://www.yuigui.com/demo/meal-salmon.jpg")
ap.add_argument("--note", default="lunch, cooked in a little butter")
args = ap.parse_args()
OUT = Path(args.out); OUT.mkdir(parents=True, exist_ok=True)
DEV = {**os.environ, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"}
STORE = f"{BASE}/storage/v1"

results = []
def check(name, ok, detail=""):
    results.append(ok); print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  [{detail}]" if detail else ""), flush=True)
def simctl(*a): return subprocess.run(["xcrun", "simctl", *a], env=DEV, capture_output=True, text=True)
def agent_rows(agent_id, since):
    return sql(f"select id, body, meta, created_at from yui_messages where agent_id='{agent_id}' and sender='agent' and created_at > '{since}' order by created_at")
def rows_of(agent_id, table):
    return sql(f"select key, vals from yui_native_table_rows where agent_id='{agent_id}' and tname='{table}' order by pos")
def send(agent_id, body, kind="text", meta=None):
    mid = str(uuid.uuid4())
    s, _ = rest("POST", "yui_messages", mint(T, ttl=900), {"id": mid, "user_id": T, "agent_id": agent_id, "sender": "user", "body": body,
                                                           "kind": kind, **({"meta": meta} if meta else {})}, prefer="return=minimal")
    return mid, s
def wait_for(pred, wait=180, every=1.0):
    end = time.time() + wait
    while time.time() < end:
        got = pred()
        if got: return got
        time.sleep(every)
    return None

T = str(uuid.uuid4())
sql(f"insert into yui_users(id, apple_sub, timezone) values ('{T}','test.{T}','America/New_York')")
log = {}
path = None
try:
    s, _ = fn("yui-agents", {"action": "list"}, mint(T))
    agents = {a["name"]: a["id"] for a in sql(f"select id, name from yui_agents where user_id='{T}' and kind='hosted'")}
    check("a new account gets the crew", s == 200 and "Basil" in agents, f"{sorted(agents)}")
    basil = agents["Basil"]

    # The app first, signed in and on Basil's stage, so the answer and the breakdown play as they land.
    rt = secrets.token_urlsafe(32)
    sql(f"insert into yui_sessions(user_id, refresh_hash, expires_at) values ('{T}','{hashlib.sha256(rt.encode()).hexdigest()}', now() + interval '1 day')")
    simctl("ui", args.sim, "appearance", args.appearance)
    simctl("terminate", args.sim, "com.yuigui.app")
    r = simctl("launch", args.sim, "com.yuigui.app", "-yuiRefreshToken", rt, "-yuiUserID", T, "-selectedAgent", basil, "-appearance", args.appearance)
    check("the app launches signed in", r.returncode == 0, r.stderr.strip()[:120])
    time.sleep(14)
    def frame(name):
        shot = OUT / f"basil-meal-{name}-{args.appearance}.png"
        simctl("io", args.sim, "screenshot", str(shot))
        return shot

    # The photo, uploaded as the app uploads one (Attachments.swift): from=user, in Basil's thread.
    data = urllib.request.urlopen(urllib.request.Request(args.photo, headers={"user-agent": "yui-tests"})).read() if args.photo.startswith("http") else Path(args.photo).read_bytes()
    path = f"{T}/{basil}/user/{uuid.uuid4()}.jpg"
    req = urllib.request.Request(f"{STORE}/object/yui-media/{path}", data=data, method="POST",
                                 headers={"apikey": PUBLISHABLE, "authorization": f"Bearer {mint(T)}", "content-type": "image/jpeg"})
    with urllib.request.urlopen(req) as r: up = r.status
    check("the photo uploads to the person's own media", up == 200, path)

    since = sql("select now() as t")[0]["t"]
    t0 = time.time()
    mid, s = send(basil, args.note, meta={"photos": [path]})
    check("the photo and the note are sent", s in (200, 201), args.note)
    ack = wait_for(lambda: [r for r in agent_rows(basil, since) if (r["meta"] or {}).get("native", {}).get("queued")], wait=60, every=0.5)
    ack_s = round(time.time() - t0, 1)
    check("Basil answers at once, before any model call", bool(ack) and ack[0]["body"] == "Got it, working out the macros.", f"{ack_s}s")
    check("the answer lands in under 10 seconds (it was Thinking 14s)", ack_s < 10, f"{ack_s}s")
    time.sleep(1.5); frame("stage-1-answer")
    job = (ack[0]["meta"]["native"]["meal"]) if ack else None
    done = wait_for(lambda: [r for r in agent_rows(basil, since) if (r["meta"] or {}).get("native", {}).get("meal") == job and not r["meta"]["native"].get("queued")],
                    wait=180, every=2)
    done_s = round(time.time() - t0, 1)
    body = done[0]["body"] if done else ""
    log["photo"] = {"note": args.note, "ack_s": ack_s, "breakdown_s": done_s, "ack": ack[0]["body"] if ack else None, "breakdown": body}
    print(body)
    check("the breakdown follows from the job", bool(done), f"{done_s}s")
    for i, wait in enumerate([2, 5, 8]):
        time.sleep(wait); frame(f"stage-{i + 2}-breakdown")
    check("one table of every item, today so far, one chart", "table@meal-" in body and "Today so far" in body and "chart donut" in body)
    check("no page per number", "\nstat" not in body)
    j = sql(f"select status, tries, result from yui_native_jobs where id='{job}'") if job else []
    check("the job is done", bool(j) and j[0]["status"] == "done", f"{j}")
    meals, mine = rows_of(basil, "meals"), rows_of(basil, "myfoods")
    log["meals"], log["myfoods"] = [r["vals"] for r in meals], [r["key"] for r in mine]
    check("the meal is logged, item by item", len(meals) >= 2, f"{len(meals)} rows")
    check("each food joins the person's food memory", len(mine) >= 2, f"{[r['key'] for r in mine]}")
    check("no grams in a portion", not any(any(u in str(r["vals"].get("Portion", "")).lower() for u in [" g", "gram", " oz"]) for r in meals))

    fix = (done[0]["meta"]["native"].get("mealfix") if done else None)
    if fix:
        choice = fix["options"][1]["label"] if len(fix["options"]) > 1 else fix["options"][0]["label"]
        since2 = sql("select now() as t")[0]["t"]
        t1 = time.time()
        tap, _ = send(basil, f'[yui] fix-{fix["id"]} choose choice="{choice}"', kind="event")
        fixed = wait_for(lambda: [r for r in agent_rows(basil, since2) if (r["meta"] or {}).get("native", {}).get("mealfixed")], wait=60, every=0.5)
        log["fix"] = {"question": fix["question"], "choice": choice, "s": round(time.time() - t1, 1), "body": fixed[0]["body"] if fixed else None}
        check("the one question's tap is applied with no model turn", bool(fixed) and "model" not in fixed[0]["meta"]["native"], f"{log['fix']['s']}s")
    else:
        log["fix"] = None
        print("(no question on this photo)")

    # A meal said in words: Basil's answer queues it, the breakdown follows.
    since3 = sql("select now() as t")[0]["t"]
    send(basil, "had two eggs and toast with butter for breakfast")
    words = wait_for(lambda: [r for r in agent_rows(basil, since3) if "table@meal-" in r["body"]], wait=240, every=2)
    log["words"] = [r["body"] for r in agent_rows(basil, since3)]
    check("a meal said in words is logged the same way", bool(words))
    (OUT / f"answers-{args.appearance}.json").write_text(json.dumps(log, indent=2, default=str))

    for mode, extra in [("chat", ["-yuiStageFirst", "NO"])]:
        simctl("terminate", args.sim, "com.yuigui.app")
        simctl("launch", args.sim, "com.yuigui.app", "-selectedAgent", basil, *extra, "-appearance", args.appearance)
        time.sleep(12)
        shot = OUT / f"basil-meal-{mode}-{args.appearance}.png"
        r = simctl("io", args.sim, "screenshot", str(shot))
        check(f"Basil's thread ({mode}), shot", r.returncode == 0 and shot.exists() and shot.stat().st_size > 50_000, shot.name)
finally:
    simctl("terminate", args.sim, "com.yuigui.app")
    if path:
        urllib.request.urlopen(urllib.request.Request(f"{STORE}/object/yui-media", method="DELETE", data=json.dumps({"prefixes": [path]}).encode(),
                               headers={"apikey": PUBLISHABLE, "authorization": f"Bearer {mint(T)}", "content-type": "application/json"})).read()
    sql(f"delete from yui_users where id = '{T}'")
    left = sql("select " + " + ".join(f"(select count(*) from {t} where user_id = '{T}')" for t in
               ["yui_agents", "yui_messages", "yui_sessions", "yui_native_tables", "yui_native_table_rows", "yui_native_jobs"])
               + f" + (select count(*) from storage.objects where bucket_id='yui-media' and name like '{T}/%') as n")
    check("throwaway account and photo deleted, zero rows left", left[0]["n"] == 0, f"{left}")

print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)

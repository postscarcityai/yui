#!/usr/bin/env python3
"""YUI-102 end to end: the real app's speed rows land in yui_perf.

Makes a throwaway account with a fresh session, installs the built app on a
simulator signed in as it (-yuiRefreshToken), brings it up, sends it to the
background (the batch goes on the way out), brings it back (a `resume`
interval) and sends it back again. Then reads what landed: memory rows and the
resume interval, numbers only, every column inside the table's checks. The
account (and its rows, by cascade) is deleted at the end.

    python3 supabase/tests/perf_e2e.py --sim <udid> --app /tmp/yui102-dd/Build/Products/Debug-iphonesimulator/Yui.app
"""
import argparse, hashlib, json, os, re, secrets, subprocess, sys, time, uuid
exec(open(__file__.replace("perf_e2e.py", "agents_test.py")).read().split("results = []")[0])

ap = argparse.ArgumentParser()
ap.add_argument("--sim", required=True)
ap.add_argument("--app", required=True)
ap.add_argument("--out", help="write the rows that landed here (JSON)")
args = ap.parse_args()
DEV = {**os.environ, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"}
BUNDLE = "com.yuigui.app"

results = []
def check(name, ok, detail=""):
    results.append(ok); print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  [{detail}]" if detail else ""), flush=True)

def simctl(*a): return subprocess.run(["xcrun", "simctl", *a], env=DEV, capture_output=True, text=True)
def rows(): return sql(f"select * from yui_perf where user_id = '{T}' order by id")
def wait_rows(pred, secs=40):
    end = time.time() + secs
    while time.time() < end:
        r = rows()
        if pred(r): return r
        time.sleep(2)
    return rows()

T = str(uuid.uuid4())
sql(f"insert into yui_users(id, apple_sub) values ('{T}','test.{T}')")
try:
    rt = secrets.token_urlsafe(32)
    rh = hashlib.sha256(rt.encode()).hexdigest()
    sql(f"insert into yui_sessions(user_id, refresh_hash, expires_at) values ('{T}','{rh}', now() + interval '1 day')")
    simctl("boot", args.sim)
    simctl("uninstall", args.sim, BUNDLE)
    check("app installs", simctl("install", args.sim, args.app).returncode == 0)
    r = simctl("launch", args.sim, BUNDLE, "-yuiRefreshToken", rt, "-yuiUserID", T)
    check("app launches signed in as the throwaway account", r.returncode == 0, r.stderr.strip()[:120])
    time.sleep(8)
    # To the background: the batch goes on the way out.
    simctl("launch", args.sim, "com.apple.Preferences")
    got = wait_rows(lambda r: any(x["name"] == "mem_footprint" for x in r))
    check("going to the background sends a memory row", any(x["name"] == "mem_footprint" for x in got),
          f"{[x['name'] for x in got]}")
    # Back to the foreground (a resume interval), then away again.
    time.sleep(2)
    simctl("launch", args.sim, BUNDLE, "-yuiRefreshToken", rt, "-yuiUserID", T)
    time.sleep(5)
    simctl("launch", args.sim, "com.apple.Preferences")
    got = wait_rows(lambda r: any(x["name"] == "resume" for x in r))
    resume = [x for x in got if x["name"] == "resume"]
    check("a resume interval lands with its histogram", bool(resume) and resume[0]["kind"] == "interval"
          and len(resume[0]["buckets"] or []) == 18 and resume[0]["n"] >= 1 and resume[0]["p95"] is not None,
          f"{resume[:1]}")
    mem = [x for x in got if x["name"] == "mem_footprint"]
    check("memory rows are MB with a sample count", bool(mem) and all(0 < x["value"] < 4096 and x["n"] >= 1 for x in mem),
          f"{[(x['value'], x['n']) for x in mem]}")
    ctx = got[0] if got else {}
    check("context: build, version, os, device, thermal",
          bool(ctx) and re.fullmatch(r"[0-9][0-9.]{0,15}", ctx["os"]) and re.fullmatch(r"[A-Za-z]{1,16}[0-9]{0,4},[0-9]{1,4}|arm64|x86_64", ctx["device"])
          and 0 <= ctx["thermal"] <= 3, f"{ {k: ctx.get(k) for k in ('app_build', 'app_version', 'os', 'device', 'promotion', 'thermal')} }")
    text_cols = {c["column_name"] for c in sql("select column_name from information_schema.columns where table_name='yui_perf' and data_type='text'")}
    check("the only text columns are the constrained ones", text_cols <= {"kind", "name", "app_version", "os", "device"}, f"{text_cols}")
    check("no stack on anything but diagnostics", all(x["stack"] is None for x in got if x["kind"] != "diagnostic"))
    if args.out:
        with open(args.out, "w") as f: json.dump(got, f, indent=1, default=str)
finally:
    simctl("terminate", args.sim, BUNDLE)
    sql(f"delete from yui_users where id = '{T}'")
    left = sql(f"select (select count(*) from yui_perf where user_id='{T}') + (select count(*) from yui_sessions where user_id='{T}') as n")
    check("throwaway account deleted, zero rows left", left[0]["n"] == 0, f"{left}")

print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)

"""Jev vs today's patterns as the crew's tool router (YUI-215 point 2).

  RUNTIME=<yui>/runtime node router_today.mjs items.json > today.json      (today's answer, the real code)
  python3 run_router.py run --today today.json --out results_router.json   (Jev's answer)
  python3 run_router.py report results_router.json [--json summary.json]

Items: router_set.json (synthetic phrasings written for this, labeled with the right tool) plus, optionally,
real Yui messages kept outside the repo as "none" negatives (a false route on them is a wrong turn).
Rule under test: patterns first (free, instant); Jev only when no pattern matched, acting at CUT.
"""
import argparse, importlib.util, json, os, statistics, sys, time
from pathlib import Path

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("jev", HERE.parent / "yui" / "jev.py")
jev = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(jev)
TOOLS = json.load(open(HERE / "tools.json"))
CUT = 0.8
SPEND_STOP = 5.00


def run(a):
    key = os.environ.get("OPENROUTER_API_KEY") or sys.exit("OPENROUTER_API_KEY not set")
    items = json.load(open(a.today))
    out = Path(a.out)
    rows = json.load(open(out))["rows"] if out.exists() else []
    have = {(r["agent"], r["text"]) for r in rows}
    spend = sum(r.get("cost") or 0 for r in rows)
    for it in items:
        if (it["agent"], it["text"]) in have:
            continue
        if spend >= SPEND_STOP:
            print("spend cap reached"); break
        d = None
        for _ in range(2):
            d = jev.route(it["text"], it["agent"], TOOLS[it["agent"]], timeout=5.0, api_key=key)
            if d: break
            time.sleep(1)
        it = {**it, "jev": d, "cost": (d or {}).get("cost", 0)}
        spend += it["cost"]
        rows.append(it)
        json.dump({"rows": rows}, open(out, "w"))
    print(len(rows), "rows, spend $%.4f" % spend)


def pct(n, d): return round(100 * n / d, 1) if d else None


def q(xs, p):
    xs = sorted(xs); return xs[min(len(xs) - 1, int(p * len(xs)))] if xs else None


def score(rows, cut):
    pos = [r for r in rows if r["tool"] != "none"]
    neg = [r for r in rows if r["tool"] == "none"]
    def jev_pick(r):  # what Jev alone would route to at this cut
        j = r["jev"]
        return j["tool"] if j and j.get("tool") and (j.get("conf") or 0) >= cut else "none"
    def combined(r):  # patterns first, Jev only on a miss
        return r["today"] if r["today"] != "none" else jev_pick(r)
    o = {"n": len(rows), "positives": len(pos), "negatives": len(neg)}
    o["today"] = {"caught": sum(r["today"] == r["tool"] for r in pos), "of": len(pos),
                  "caught_pct": pct(sum(r["today"] == r["tool"] for r in pos), len(pos)),
                  "wrong_route": sum(r["today"] != "none" and r["today"] != r["tool"] for r in rows),
                  "false_route_on_none": sum(r["today"] != "none" for r in neg)}
    o["jev_alone"] = {"caught": sum(jev_pick(r) == r["tool"] for r in pos), "of": len(pos),
                      "caught_pct": pct(sum(jev_pick(r) == r["tool"] for r in pos), len(pos)),
                      "wrong_route": sum(jev_pick(r) != "none" and jev_pick(r) != r["tool"] for r in rows),
                      "false_route_on_none": sum(jev_pick(r) != "none" for r in neg)}
    o["combined"] = {"caught": sum(combined(r) == r["tool"] for r in pos), "of": len(pos),
                     "caught_pct": pct(sum(combined(r) == r["tool"] for r in pos), len(pos)),
                     "wrong_route": sum(combined(r) != "none" and combined(r) != r["tool"] for r in rows),
                     "false_route_on_none": sum(combined(r) != "none" for r in neg)}
    misses = [r for r in pos if r["today"] != r["tool"]]  # the target: what today misses
    o["today_misses"] = {"n": len(misses), "jev_reaches": sum(jev_pick(r) == r["tool"] for r in misses)}
    # jev top pick accuracy ignoring the cut (raw)
    got = [r for r in rows if r["jev"] and r["jev"].get("tool")]
    o["jev_raw_acc"] = pct(sum(r["jev"]["tool"] == r["tool"] for r in got), len(got))
    return o


def report(a):
    rows = json.load(open(a.file))["rows"]
    res = {"cut": CUT, "all": score(rows, CUT), "cuts": {}}
    for c in (0.5, 0.6, 0.7, 0.8, 0.9):
        res["cuts"][str(c)] = score(rows, c)["combined"] | {"jev_alone": score(rows, c)["jev_alone"]}
    for name in ("synthetic", "real"):
        sub = [r for r in rows if r.get("set", "synthetic") == name]
        if sub: res[name] = score(sub, CUT)
    # calibration on Jev's own pick
    bins = {}
    for r in rows:
        j = r["jev"]
        if not j or not j.get("tool"): continue
        c = j.get("conf") or 0
        b = "0.9-1.0" if c >= .9 else "0.8-0.9" if c >= .8 else "0.7-0.8" if c >= .7 else "0.5-0.7" if c >= .5 else "<0.5"
        p = bins.setdefault(b, [0, 0, 0.0]); p[1] += 1; p[0] += j["tool"] == r["tool"]; p[2] += c
    res["calibration"] = {k: {"n": v[1], "mean_conf": round(v[2] / v[1], 2), "right": pct(v[0], v[1])} for k, v in sorted(bins.items())}
    lat = [r["jev"]["ms"] for r in rows if r["jev"]]; cost = [r["jev"]["cost"] for r in rows if r["jev"]]
    res["latency_ms"] = {"n": len(lat), "p50": q(lat, .5), "p95": q(lat, .95), "max": max(lat) if lat else None}
    res["cost"] = {"calls": len(cost), "total_usd": round(sum(cost), 5), "per_1000_calls_usd": round(1000 * statistics.mean(cost), 4) if cost else None,
                   "mean_input_tokens": round(statistics.mean(r["jev"]["input_tokens"] for r in rows if r["jev"])) if cost else None}
    print(json.dumps(res, indent=1))
    if a.json: json.dump(res, open(a.json, "w"), indent=1)


ap = argparse.ArgumentParser(); sp = ap.add_subparsers(dest="c", required=True)
r = sp.add_parser("run"); r.add_argument("--today", required=True); r.add_argument("--out", required=True); r.set_defaults(f=run)
p = sp.add_parser("report"); p.add_argument("file"); p.add_argument("--json"); p.set_defaults(f=report)
if __name__ == "__main__":
    a = ap.parse_args(); a.f(a)

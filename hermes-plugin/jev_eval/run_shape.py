"""Jev vs today on reply shape (YUI-215 point 1).

  python3 run_shape.py run    --eval PATH_TO_cases.json [--real real_set.json] --out results_shape.json
  python3 run_shape.py report results_shape.json [--json summary.json]

`run` asks Jev once per message (serial, so latency is honest), keeping the raw
answers. The key comes from OPENROUTER_API_KEY, never a file in the repo.
Two sets:
  eval: the channel eval's own messages (spec/channel-eval/cases.json), labeled
        in labels_eval.json. Public: the messages are already in the repo.
  real: real Yui messages, labeled by hand, kept OUTSIDE the repo. The results
        file for them holds indexes and numbers, never the words.
`report` scores: Jev's top shape against the label, accuracy at each confidence
cut, calibration (does 0.9 mean right 90%), the same for map and camera, p50 and
p95 latency, and cost per 1,000 turns. "Today" for the real set is the shape the
agent actually sent (jev.sent_shape of its reply).
"""

import argparse
import json
import os
import statistics
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "yui"))
import importlib.util

_spec = importlib.util.spec_from_file_location("jev", HERE.parent / "yui" / "jev.py")
jev = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(jev)

SPEND_STOP = 5.00  # the card's cap: stop and block past this


def load_items(args):
    items = []
    if args.eval:
        cases = {c["id"]: c for c in json.load(open(args.eval))["cases"]}
        labels = json.load(open(HERE / "labels_eval.json"))
        for cid, lab in labels.items():
            c = cases[cid]
            items.append({"set": "eval", "id": cid, "text": c["message"], "label": lab, "agent": c["agent"]})
    if args.real:
        for r in json.load(open(args.real)):
            items.append({"set": "real", "id": str(r["i"]), "text": r["text"], "label": r["label"],
                          "sent": r.get("sent"), "agent": "yui"})
    return items


def run(args):
    key = os.environ.get("OPENROUTER_API_KEY")
    if not key:
        sys.exit("OPENROUTER_API_KEY not set")
    items = load_items(args)
    done = {}
    out = Path(args.out)
    if out.exists():
        done = {(r["set"], r["id"]): r for r in json.load(open(out))["rows"]}
    rows, spend = list(done.values()), sum(r.get("cost") or 0 for r in done.values())
    for it in items:
        if (it["set"], it["id"]) in done:
            continue
        if spend >= SPEND_STOP:
            print("spend cap reached", spend)
            break
        d = None
        for attempt in range(2):  # a network blip is not a Jev miss: retry once here (the plugin never retries)
            d = jev.decide(it["text"], agent=it["agent"], timeout=5.0, api_key=key)
            if d:
                break
            time.sleep(1)
        row = {"set": it["set"], "id": it["id"], "label": it["label"], "sent": it.get("sent"), "jev": d,
               "cost": (d or {}).get("cost", 0)}
        spend += row["cost"]
        rows.append(row)
        json.dump({"rows": rows}, open(out, "w"))
    print(f"{len(rows)} rows, spend ${spend:.4f}")


def pct(n, d):
    return round(100 * n / d, 1) if d else None


def quantile(xs, q):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(q * len(xs)))] if xs else None


def score_set(rows):
    got = [r for r in rows if r["jev"] and r["jev"].get("shape")]
    n = len(rows)
    out = {"n": n, "answered": len(got)}
    ok = sum(1 for r in got if r["jev"]["shape"] == r["label"]["shape"])
    out["jev_shape_acc"] = pct(ok, len(got))
    with_sent = [r for r in rows if r.get("sent")]
    if with_sent:
        out["today_shape_acc"] = pct(sum(1 for r in with_sent if r["sent"] == r["label"]["shape"]), len(with_sent))
        out["today_n"] = len(with_sent)
        both = [r for r in with_sent if r["jev"] and r["jev"].get("shape")]
        out["jev_acc_same_rows"] = pct(sum(1 for r in both if r["jev"]["shape"] == r["label"]["shape"]), len(both))
    # per label
    per = {}
    for r in got:
        p = per.setdefault(r["label"]["shape"], [0, 0])
        p[1] += 1
        p[0] += r["jev"]["shape"] == r["label"]["shape"]
    out["by_label"] = {k: {"right": v[0], "n": v[1]} for k, v in sorted(per.items())}
    # confidence cuts: how much acts, how right when it does
    cuts = {}
    for c in (0.5, 0.6, 0.7, 0.8, 0.9):
        hi = [r for r in got if (r["jev"].get("conf") or 0) >= c]
        cuts[str(c)] = {"acts": pct(len(hi), len(got)), "n": len(hi),
                        "right": pct(sum(1 for r in hi if r["jev"]["shape"] == r["label"]["shape"]), len(hi))}
    out["cuts"] = cuts
    # calibration bins
    bins = {}
    for r in got:
        c = r["jev"].get("conf") or 0
        b = "0.9-1.0" if c >= 0.9 else "0.8-0.9" if c >= 0.8 else "0.7-0.8" if c >= 0.7 else "0.5-0.7" if c >= 0.5 else "<0.5"
        p = bins.setdefault(b, [0, 0, 0.0])
        p[1] += 1
        p[0] += r["jev"]["shape"] == r["label"]["shape"]
        p[2] += c
    out["calibration"] = {k: {"n": v[1], "mean_conf": round(v[2] / v[1], 2), "right": pct(v[0], v[1])}
                          for k, v in sorted(bins.items())}
    # map and camera
    for name in ("map", "camera"):
        have = [r for r in got if r["jev"].get(name) is not None]
        tp = sum(1 for r in have if r["jev"][name] >= jev.NOUL_YES and r["label"][name])
        fp = sum(1 for r in have if r["jev"][name] >= jev.NOUL_YES and not r["label"][name])
        fn = sum(1 for r in have if r["jev"][name] < jev.NOUL_YES and r["label"][name])
        pos = sum(1 for r in have if r["label"][name])
        acc = sum(1 for r in have if (r["jev"][name] >= 0.5) == bool(r["label"][name]))
        out[name] = {"n": len(have), "positives": pos, "acc": pct(acc, len(have)), "true_pos": tp, "false_pos": fp, "missed": fn}
    # the hint: what the plugin would say, and how often it is right
    for name, kw in (("hint_all", {"shapes": jev.SHAPES}), ("hint", {})):  # every shape, and the shipped default (card, pages, full)
        said = [r for r in got if jev.hint(r["jev"], **kw)]
        right = [r for r in said if r["jev"]["shape"] == r["label"]["shape"]]
        out[name] = {"said": len(said), "of": len(got), "right": len(right), "right_pct": pct(len(right), len(said))}
    return out


def report(args):
    rows = json.load(open(args.file))["rows"]
    res = {}
    for name in ("eval", "real"):
        sub = [r for r in rows if r["set"] == name]
        if sub:
            res[name] = score_set(sub)
    lat = [r["jev"]["ms"] for r in rows if r["jev"]]
    cost = [r["jev"]["cost"] for r in rows if r["jev"]]
    toks = [r["jev"]["input_tokens"] for r in rows if r["jev"]]
    res["latency_ms"] = {"n": len(lat), "p50": quantile(lat, 0.5), "p95": quantile(lat, 0.95), "max": max(lat) if lat else None,
                         "over_600": sum(1 for x in lat if x > 600), "mean": round(statistics.mean(lat)) if lat else None}
    res["cost"] = {"calls": len(cost), "total_usd": round(sum(cost), 5),
                   "per_1000_turns_usd": round(1000 * statistics.mean(cost), 4) if cost else None,
                   "mean_input_tokens": round(statistics.mean(toks)) if toks else None}
    print(json.dumps(res, indent=1))
    if args.json:
        json.dump(res, open(args.json, "w"), indent=1)


def main():
    ap = argparse.ArgumentParser()
    sp = ap.add_subparsers(dest="cmd", required=True)
    r = sp.add_parser("run")
    r.add_argument("--eval")
    r.add_argument("--real")
    r.add_argument("--out", required=True)
    r.set_defaults(fn=run)
    p = sp.add_parser("report")
    p.add_argument("file")
    p.add_argument("--json")
    p.set_defaults(fn=report)
    a = ap.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()

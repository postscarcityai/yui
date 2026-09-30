"""Channel eval with and without the Jev hint (YUI-215), from saved reports.

  python3 compare_eval.py REPORTS_DIR [--arm hint|hintb] [--json out.json]
  python3 compare_eval.py REPORTS_DIR --real real_set.json [--json out.json]   (real messages, kept outside the repo)

Reads jev215-base-r1/-r2 (every labeled case, no hint) and jev215-hint-r1/-r2 (only the cases Jev was sure about, with
its hint line). Because a case Jev is not sure about gets the same turn either way, the hint changes only the hinted
cases, so those are compared: eval score (the suite's own pass), and whether the reply's shape matches the label.
Baseline run to run shows the noise the hint has to beat (docs: channel-eval noise).
"""
import argparse, importlib.util, json
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("jev", HERE.parent / "yui" / "jev.py")
jev = importlib.util.module_from_spec(spec); spec.loader.exec_module(jev)
labels = json.load(open(HERE / "labels_eval.json"))


def load(d, name):
    return {r["id"]: r for r in json.load(open(Path(d) / f"{name}.json"))["results"]}


def shape_ok(r):
    return bool(r.get("reply")) and jev.sent_shape(r["reply"]) == labels[r["id"]]["shape"]


def stats(runs, ids):
    out = {}
    for name, res in runs.items():
        rs = [res[i] for i in ids if i in res]
        out[name] = {"n": len(rs), "pass": sum(r["score"]["pass"] for r in rs), "shape_match": sum(shape_ok(r) for r in rs)}
    return out


def real(a):
    """Real messages: no scorer, only the shape of the reply against the hand label, hint arm vs baseline (twice)."""
    lab = {f"real-{r['i']}": r["label"]["shape"] for r in json.load(open(a.real))}
    runs = {n: load(a.dir, f"jev215-real-{n}") for n in ("base-r1", "base-r2", "hint-r1")}
    ids = sorted(runs["hint-r1"])
    ok = lambda r: bool(r.get("reply")) and jev.sent_shape(r["reply"]) == lab[r["id"]]
    out = {"n": len(ids)}
    out["shape_match"] = {n: sum(ok(runs[n][i]) for i in ids) for n in runs}
    def fl(x, y): return {"gained": sum(1 for i in ids if not ok(runs[x][i]) and ok(runs[y][i])), "lost": sum(1 for i in ids if ok(runs[x][i]) and not ok(runs[y][i]))}
    out["noise_base_r1_to_r2"] = fl("base-r1", "base-r2")
    out["hint_vs_base_r1"] = fl("base-r1", "hint-r1")
    out["hint_vs_base_r2"] = fl("base-r2", "hint-r1")
    by = {}
    for i in ids:
        s = lab[i]; p = by.setdefault(s, {"n": 0, "base": 0, "hint": 0}); p["n"] += 1; p["base"] += ok(runs["base-r1"][i]); p["hint"] += ok(runs["hint-r1"][i])
    out["by_label"] = by
    print(json.dumps(out, indent=1))
    if a.json: json.dump(out, open(a.json, "w"), indent=1)


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("dir"); ap.add_argument("--json"); ap.add_argument("--arm", default="hint")
    ap.add_argument("--real"); a = ap.parse_args()
    if a.real:
        return real(a)
    base = {k: load(a.dir, f"jev215-base-{k}") for k in ("r1", "r2")}
    hint = {k: load(a.dir, f"jev215-{a.arm}-{k}") for k in ("r1", "r2")}
    hinted = sorted(set(hint["r1"]) | set(hint["r2"]))
    out = {"hinted_cases": len(hinted), "all_cases": len(base["r1"])}
    out["all_no_hint"] = stats({"r1": base["r1"], "r2": base["r2"]}, list(base["r1"]))
    out["hinted_subset"] = stats({"base_r1": base["r1"], "base_r2": base["r2"], "hint_r1": hint["r1"], "hint_r2": hint["r2"]}, hinted)
    # flips: cases that changed pass state between a baseline run and a hint run, against the two baselines flipping on their own
    def flips(x, y, ids):
        return {"pass_to_fail": [i for i in ids if i in x and i in y and x[i]["score"]["pass"] and not y[i]["score"]["pass"]],
                "fail_to_pass": [i for i in ids if i in x and i in y and not x[i]["score"]["pass"] and y[i]["score"]["pass"]]}
    out["noise_base_r1_to_r2"] = {k: len(v) for k, v in flips(base["r1"], base["r2"], hinted).items()}
    out["hint_vs_base_r1"] = {k: len(v) for k, v in flips(base["r1"], hint["r1"], hinted).items()}
    out["hint_vs_base_r2"] = {k: len(v) for k, v in flips(base["r2"], hint["r2"], hinted).items()}
    out["hint_vs_base_detail"] = {"r1": flips(base["r1"], hint["r1"], hinted), "r2": flips(base["r2"], hint["r2"], hinted)}
    # shape match flips
    def sflips(x, y, ids):
        return {"gained": sum(1 for i in ids if i in x and i in y and not shape_ok(x[i]) and shape_ok(y[i])),
                "lost": sum(1 for i in ids if i in x and i in y and shape_ok(x[i]) and not shape_ok(y[i]))}
    out["shape_flips_hint_vs_base"] = {"r1": sflips(base["r1"], hint["r1"], hinted), "r2": sflips(base["r2"], hint["r2"], hinted)}
    out["shape_flips_noise_base_r1_r2"] = sflips(base["r1"], base["r2"], hinted)
    print(json.dumps(out, indent=1))
    if a.json: json.dump(out, open(a.json, "w"), indent=1)


main()

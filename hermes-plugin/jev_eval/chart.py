"""The Jev vs today chart for the results page and the progress entry (YUI-215).

  uv run --with matplotlib python3 chart.py shape_summary.json router_summary.json compare_all.json compare_cpf.json OUT_PREFIX

Writes OUT_PREFIX-dark.png and OUT_PREFIX-light.png (dark first). Every number is read from the summaries the runs wrote.
compare_all: the eval with the hint on every shape (compare_eval.py --arm hint); compare_cpf: only card, pages, full (--arm hintb).
"""
import json
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

shape, router, cmp_all, cmp_cpf = (json.load(open(p)) for p in sys.argv[1:5])
out = sys.argv[5]

THEMES = {
    "dark": dict(bg="#15121c", fg="#f3eefc", mute="#a79fb8", today="#6f6785", jev="#ff7a6b", both="#7ad9b5", bad="#c0576a"),
    "light": dict(bg="#fbf8ff", fg="#2a2238", mute="#6b6280", today="#a99fc0", jev="#e9503f", both="#2fa37c", bad="#c0576a"),
}


def mean_pct(sub, keys, n):
    return 100 * sum(sub[k]["pass"] for k in keys) / (len(keys) * n)


real, rt = shape["real"], router["all"]
ea, ec = cmp_all["hinted_subset"], cmp_cpf["hinted_subset"]
na, nc = cmp_all["hinted_cases"], cmp_cpf["hinted_cases"]
panels = [
    ("Tool router: catches the ask", f"share of {rt['positives']} phrasings sent to the right tool",
     [("Today's patterns", rt["today"]["caught_pct"], "today"), ("Jev alone", rt["jev_alone"]["caught_pct"], "jev"),
      ("Patterns, then Jev", rt["combined"]["caught_pct"], "both")]),
    ("Reply shape: the hint is right", "share matching the hand label, real messages",
     [("Agent today", real["today_shape_acc"], "today"), ("Jev, every answer", real["jev_shape_acc"], "jev"),
      ("Jev hint (card, pages, full)", real["hint"]["right_pct"], "both")]),
    ("Channel eval, cases that get a hint", "pass rate, mean of two runs each",
     [(f"No hint, {na} cases", mean_pct(ea, ("base_r1", "base_r2"), na), "today"),
      ("Hint on every shape", mean_pct(ea, ("hint_r1", "hint_r2"), na), "bad"),
      (f"No hint, {nc} cases", mean_pct(ec, ("base_r1", "base_r2"), nc), "today"),
      ("Hint: card, pages, full", mean_pct(ec, ("hint_r1", "hint_r2"), nc), "both")]),
]
for theme, c in THEMES.items():
    fig, axes = plt.subplots(2, 2, figsize=(12, 7.6), dpi=150)
    fig.patch.set_facecolor(c["bg"])
    for ax, (title, sub, bars) in zip(axes.flat[:3], panels):
        ax.set_facecolor(c["bg"])
        labels = [b[0] for b in bars][::-1]
        vals = [b[1] for b in bars][::-1]
        cols = [c[b[2]] for b in bars][::-1]
        rects = ax.barh(labels, vals, color=cols, height=0.6)
        for r, v in zip(rects, vals):
            ax.text(v + 2, r.get_y() + r.get_height() / 2, f"{v:.0f}%", va="center", ha="left", color=c["fg"], fontsize=13, fontweight="bold")
        ax.set_xlim(0, 125)
        ax.set_xticks([])
        ax.tick_params(axis="y", colors=c["fg"], labelsize=10.5, length=0)
        for s in ax.spines.values():
            s.set_visible(False)
        ax.set_title(title, color=c["fg"], fontsize=14, fontweight="bold", loc="left", pad=26)
        ax.text(0, 1.04, sub, transform=ax.transAxes, color=c["mute"], fontsize=9.5)
    ax = axes.flat[3]
    ax.set_facecolor(c["bg"])
    ax.axis("off")
    lat, cost = shape["latency_ms"], shape["cost"]
    ax.set_title("Speed and cost", color=c["fg"], fontsize=14, fontweight="bold", loc="left", pad=26)
    ax.text(0, 1.04, f"one call, about {cost['mean_input_tokens']} tokens in", transform=ax.transAxes, color=c["mute"], fontsize=9.5)
    for i, (big, small) in enumerate([(f"{lat['p50']} ms", "median"), (f"{lat['p95']} ms", "95th percentile"),
                                      (f"${cost['per_1000_turns_usd']:.3f}", "per 1,000 turns")]):
        y = 0.78 - i * 0.28
        ax.text(0.02, y, big, color=c["jev"], fontsize=26, fontweight="bold", transform=ax.transAxes, va="center")
        ax.text(0.42, y, small, color=c["mute"], fontsize=12, transform=ax.transAxes, va="center")
    fig.text(0.02, 0.012, "Jev typesafe/jev-1.13 on OpenRouter. Labels are hand-made; see docs/research/jev-results.md for what that means.",
             color=c["mute"], fontsize=8.5)
    fig.tight_layout(rect=(0, 0.03, 1, 1), h_pad=3.5, w_pad=3)
    fig.savefig(f"{out}-{theme}.png", facecolor=c["bg"])
    print(f"{out}-{theme}.png")

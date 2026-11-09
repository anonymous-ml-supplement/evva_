#!/usr/bin/env python3
"""
Regime-consistency evaluator for EVVA v4 full-agent candidate-level experiment.

Purpose:
  Make v4 interpretable and consistent with the v3 EVVA exact-budget story.

Outputs:
  pooled_tieaware_summary.csv
  case_detail_tieaware.csv
  macro_case_tieaware_summary.csv
  harm_saturation_audit.csv
  regime_consistency_report.md
"""

import argparse
import csv
import math
from pathlib import Path
from collections import Counter, defaultdict

POLICY_SCORES = {
    "p-only": "p_score",
    "H-only": "harm_score",
    "EVVA-EH": "p_times_H_score",
    "Oracle": "intervention_gain",
}

def f(x):
    try:
        if x is None or str(x).strip() == "":
            return None
        v = float(x)
        return v if math.isfinite(v) else None
    except Exception:
        return None

def mean(xs):
    return sum(xs) / len(xs) if xs else float("nan")

def pct(xs, q):
    if not xs:
        return float("nan")
    xs = sorted(xs)
    if len(xs) == 1:
        return xs[0]
    pos = (len(xs) - 1) * q
    lo = int(math.floor(pos))
    hi = int(math.ceil(pos))
    if lo == hi:
        return xs[lo]
    return xs[lo] + (xs[hi] - xs[lo]) * (pos - lo)

def budget_B(frac, n):
    return max(1, int(round(frac * n)))

def gain(r):
    return f(r.get("intervention_gain")) or 0.0

def available(rows):
    out = {}
    for p, c in POLICY_SCORES.items():
        vals = [f(r.get(c)) for r in rows]
        if vals and all(v is not None for v in vals):
            out[p] = c
    return out

def tieaware_gain(rows, score_col, B):
    scored = [(f(r.get(score_col)), gain(r), r) for r in rows]
    if any(s is None for s, _, _ in scored):
        raise ValueError(f"missing score_col={score_col}")

    scores = sorted(set(s for s, _, _ in scored), reverse=True)
    n_above = 0
    g_above = 0.0

    for s in scores:
        block = [(ss, g, r) for ss, g, r in scored if ss == s]
        bn = len(block)
        bg = sum(g for _, g, _ in block)

        if n_above + bn < B:
            n_above += bn
            g_above += bg
            continue

        if n_above + bn == B:
            return {
                "expected_gain": g_above + bg,
                "mean_selected_gain": (g_above + bg) / B,
                "cutoff_score": s,
                "selected_above_n": n_above,
                "tie_block_n": bn,
                "need_from_tie": bn,
                "tie_fraction": 1.0,
                "tie_block_gain": bg,
                "tie_block_mean_gain": bg / bn if bn else float("nan"),
            }

        need = B - n_above
        frac = need / bn
        eg = g_above + frac * bg
        return {
            "expected_gain": eg,
            "mean_selected_gain": eg / B,
            "cutoff_score": s,
            "selected_above_n": n_above,
            "tie_block_n": bn,
            "need_from_tie": need,
            "tie_fraction": frac,
            "tie_block_gain": bg,
            "tie_block_mean_gain": bg / bn if bn else float("nan"),
        }

    return {
        "expected_gain": g_above,
        "mean_selected_gain": g_above / B if B else float("nan"),
        "cutoff_score": "",
        "selected_above_n": n_above,
        "tie_block_n": 0,
        "need_from_tie": 0,
        "tie_fraction": 0.0,
        "tie_block_gain": 0.0,
        "tie_block_mean_gain": float("nan"),
    }

def write_csv(path, rows, fields):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", newline="") as fp:
        w = csv.DictWriter(fp, fieldnames=fields)
        w.writeheader()
        for r in rows:
            w.writerow(r)

def harm_saturation(rows):
    out = []
    for case in ["ALL"] + sorted(set(r.get("case_type", "") for r in rows)):
        sub = rows if case == "ALL" else [r for r in rows if r.get("case_type", "") == case]
        hs = [f(r.get("harm_score")) for r in sub if f(r.get("harm_score")) is not None]
        gains = [f(r.get("intervention_gain")) for r in sub if f(r.get("intervention_gain")) is not None]
        if not hs:
            continue
        maxh = max(hs)
        out.append({
            "case_type": case,
            "n": len(sub),
            "harm_mean": mean(hs),
            "harm_min": min(hs),
            "harm_p25": pct(hs, 0.25),
            "harm_median": pct(hs, 0.50),
            "harm_p75": pct(hs, 0.75),
            "harm_max": maxh,
            "n_at_harm_max": sum(1 for h in hs if abs(h - maxh) < 1e-12),
            "frac_at_harm_max": sum(1 for h in hs if abs(h - maxh) < 1e-12) / len(hs),
            "gain_mean": mean(gains),
            "gain_total": sum(gains),
        })
    return out

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="inp", required=True)
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--budgets", nargs="+", type=float, default=[0.10, 0.20, 0.30])
    args = ap.parse_args()

    rows = list(csv.DictReader(open(args.inp, newline="")))
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    if not rows:
        raise SystemExit("No rows")

    policies = available(rows)
    missing = [p for p in ["p-only", "H-only", "EVVA-EH", "Oracle"] if p not in policies]
    if missing:
        raise SystemExit(f"Missing required policies: {missing}; available={sorted(policies)}")

    pooled_rows = []
    case_rows = []
    macro_rows = []

    cases = sorted(set(r.get("case_type", "") for r in rows))

    for frac in args.budgets:
        B = budget_B(frac, len(rows))

        for policy, col in policies.items():
            tg = tieaware_gain(rows, col, B)
            pooled_rows.append({
                "scope": "pooled_micro",
                "policy": policy,
                "budget_fraction": frac,
                "B": B,
                "n": len(rows),
                **tg,
            })

        per_policy_case_metrics = defaultdict(list)

        for case in cases:
            sub = [r for r in rows if r.get("case_type", "") == case]
            Bc = budget_B(frac, len(sub))

            for policy, col in policies.items():
                tg = tieaware_gain(sub, col, Bc)
                row = {
                    "case_type": case,
                    "policy": policy,
                    "budget_fraction": frac,
                    "B_case": Bc,
                    "n_case": len(sub),
                    **tg,
                }
                case_rows.append(row)
                per_policy_case_metrics[policy].append(tg["mean_selected_gain"])

        for policy, vals in per_policy_case_metrics.items():
            macro_rows.append({
                "scope": "case_macro_mean",
                "policy": policy,
                "budget_fraction": frac,
                "n_cases": len(cases),
                "macro_mean_selected_gain": mean(vals),
            })

    sat_rows = harm_saturation(rows)

    write_csv(out_dir / "pooled_tieaware_summary.csv", pooled_rows, [
        "scope", "policy", "budget_fraction", "B", "n",
        "expected_gain", "mean_selected_gain",
        "cutoff_score", "selected_above_n", "tie_block_n",
        "need_from_tie", "tie_fraction", "tie_block_gain", "tie_block_mean_gain",
    ])

    write_csv(out_dir / "case_detail_tieaware.csv", case_rows, [
        "case_type", "policy", "budget_fraction", "B_case", "n_case",
        "expected_gain", "mean_selected_gain",
        "cutoff_score", "selected_above_n", "tie_block_n",
        "need_from_tie", "tie_fraction", "tie_block_gain", "tie_block_mean_gain",
    ])

    write_csv(out_dir / "macro_case_tieaware_summary.csv", macro_rows, [
        "scope", "policy", "budget_fraction", "n_cases", "macro_mean_selected_gain",
    ])

    write_csv(out_dir / "harm_saturation_audit.csv", sat_rows, [
        "case_type", "n", "harm_mean", "harm_min", "harm_p25", "harm_median",
        "harm_p75", "harm_max", "n_at_harm_max", "frac_at_harm_max",
        "gain_mean", "gain_total",
    ])

    def get_pooled(policy, frac):
        for r in pooled_rows:
            if r["policy"] == policy and abs(float(r["budget_fraction"]) - frac) < 1e-12:
                return float(r["expected_gain"])
        return float("nan")

    def get_macro(policy, frac):
        for r in macro_rows:
            if r["policy"] == policy and abs(float(r["budget_fraction"]) - frac) < 1e-12:
                return float(r["macro_mean_selected_gain"])
        return float("nan")

    lines = []
    lines.append("# V4 full-agent regime consistency report")
    lines.append("")
    lines.append(f"- input: {args.inp}")
    lines.append(f"- rows: {len(rows)}")
    lines.append(f"- cases: {cases}")
    lines.append(f"- budgets: {args.budgets}")
    lines.append("")
    lines.append("## Pooled tie-aware deltas")
    for frac in args.budgets:
        ev = get_pooled("EVVA-EH", frac)
        h = get_pooled("H-only", frac)
        p = get_pooled("p-only", frac)
        rnd_note = ""
        lines.append(
            f"- budget={frac:.2f}: EVVA-H={ev-h:.6g}, EVVA-p={ev-p:.6g} "
            f"(EVVA={ev:.6g}, H={h:.6g}, p={p:.6g})"
        )
    lines.append("")
    lines.append("## Case-macro tie-aware deltas")
    for frac in args.budgets:
        ev = get_macro("EVVA-EH", frac)
        h = get_macro("H-only", frac)
        p = get_macro("p-only", frac)
        lines.append(
            f"- budget={frac:.2f}: EVVA-H={ev-h:.6g}, EVVA-p={ev-p:.6g} "
            f"(EVVA={ev:.6g}, H={h:.6g}, p={p:.6g})"
        )
    lines.append("")
    lines.append("## Harm saturation")
    for r in sat_rows:
        lines.append(
            f"- {r['case_type']}: n={r['n']}, harm_median={float(r['harm_median']):.6g}, "
            f"frac_at_max={float(r['frac_at_harm_max']):.3f}, gain_mean={float(r['gain_mean']):.6g}"
        )
    lines.append("")
    lines.append("## Reviewer-facing interpretation rule")
    lines.append("- If EVVA wins pooled 20% and case-macro 20/30%, v4 supports the v3 scarce-budget claim.")
    lines.append("- If H-only wins pooled 30% only under high harm saturation, report it as a regime boundary.")
    lines.append("- If H-only wins both pooled and case-macro 20/30%, v4 should not replace v3 main evidence.")

    (out_dir / "regime_consistency_report.md").write_text("\n".join(lines) + "\n")
    print("[DONE]", out_dir)
    print("[REPORT]", out_dir / "regime_consistency_report.md")

if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""
Tie-aware exact-B evaluator for AAAI v4 full-agent candidate-level rows.

Why:
  In full-agent smoke, H-only can create many equal scores, e.g. harm_score=1.
  Deterministic seed/case tie-breaking can artificially help or hurt a method.
  This evaluator computes expected selected gain under uniform selection within
  the cutoff tie block.

Input:
  one row per candidate verification point.

Output:
  exactB_summary_tieaware.csv
  tie_block_audit.csv
  pairwise_bootstrap_tieaware.csv
  random_audit_tieaware.csv
"""

import argparse
import csv
import math
import random
import statistics
from pathlib import Path
from collections import defaultdict, Counter

POLICY_SCORES = {
    "p-only": "p_score",
    "H-only": "harm_score",
    "EVVA-EH": "p_times_H_score",
    "PRM_task": "PRM_task_surrogate",
    "PRM_value": "PRM_value_surrogate",
    "value_router": "value_router_surrogate",
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

def stdev(xs):
    return statistics.stdev(xs) if len(xs) > 1 else 0.0

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

def write_csv(path, rows, fields):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", newline="") as fp:
        w = csv.DictWriter(fp, fieldnames=fields)
        w.writeheader()
        for r in rows:
            w.writerow(r)

def budget_B(frac, n):
    return max(1, int(round(frac * n)))

def gain(r):
    return f(r.get("intervention_gain")) or 0.0

def available_policies(rows):
    out = {}
    for name, col in POLICY_SCORES.items():
        vals = [f(r.get(col)) for r in rows]
        if all(v is not None for v in vals):
            out[name] = col
    return out

def tieaware_gain(rows, score_col, B):
    """
    Expected top-B gain under uniform random tie-breaking at cutoff.
    """
    scored = []
    for r in rows:
        s = f(r.get(score_col))
        if s is None:
            raise ValueError(f"Missing score {score_col}")
        scored.append((s, gain(r), r))

    scores_desc = sorted(set(s for s, _, _ in scored), reverse=True)

    selected_above_n = 0
    selected_above_gain = 0.0

    for score in scores_desc:
        block = [(s, g, r) for s, g, r in scored if s == score]
        block_n = len(block)
        block_gain = sum(g for _, g, _ in block)

        if selected_above_n + block_n < B:
            selected_above_n += block_n
            selected_above_gain += block_gain
            continue

        if selected_above_n + block_n == B:
            return {
                "expected_gain": selected_above_gain + block_gain,
                "selected_above_n": selected_above_n,
                "cutoff_score": score,
                "tie_block_n": block_n,
                "need_from_tie": block_n,
                "tie_fraction": 1.0,
                "tie_block_gain": block_gain,
                "tie_block_mean_gain": block_gain / block_n if block_n else float("nan"),
                "gain_above_cutoff": selected_above_gain,
            }

        need = B - selected_above_n
        frac = need / block_n
        return {
            "expected_gain": selected_above_gain + frac * block_gain,
            "selected_above_n": selected_above_n,
            "cutoff_score": score,
            "tie_block_n": block_n,
            "need_from_tie": need,
            "tie_fraction": frac,
            "tie_block_gain": block_gain,
            "tie_block_mean_gain": block_gain / block_n if block_n else float("nan"),
            "gain_above_cutoff": selected_above_gain,
        }

    return {
        "expected_gain": selected_above_gain,
        "selected_above_n": selected_above_n,
        "cutoff_score": "",
        "tie_block_n": 0,
        "need_from_tie": 0,
        "tie_fraction": 0.0,
        "tie_block_gain": 0.0,
        "tie_block_mean_gain": float("nan"),
        "gain_above_cutoff": selected_above_gain,
    }

def random_sample_gains(rows, B, reps, rng):
    vals = []
    for _ in range(reps):
        vals.append(sum(gain(r) for r in rng.sample(rows, B)))
    return vals

def bootstrap_pairwise(rows, policies, budgets, reps, rng):
    out = []
    if "EVVA-EH" not in policies:
        return out

    n = len(rows)
    compare_to = [p for p in policies if p not in {"EVVA-EH", "Oracle"}] + ["Random_expected"]

    for frac in budgets:
        B0 = budget_B(frac, n)
        for other in compare_to:
            deltas = []
            for _ in range(reps):
                sample = [rows[rng.randrange(n)] for _ in range(n)]
                B = budget_B(frac, len(sample))
                ev = tieaware_gain(sample, policies["EVVA-EH"], B)["expected_gain"]

                if other == "Random_expected":
                    og = (B / len(sample)) * sum(gain(r) for r in sample)
                else:
                    og = tieaware_gain(sample, policies[other], B)["expected_gain"]

                deltas.append(ev - og)

            out.append({
                "budget_fraction": frac,
                "B_original": B0,
                "comparison": f"EVVA-EH minus {other}",
                "bootstrap_reps": reps,
                "delta_mean": mean(deltas),
                "delta_p025": pct(deltas, 0.025),
                "delta_p975": pct(deltas, 0.975),
                "prob_delta_gt_0": sum(1 for d in deltas if d > 0) / len(deltas),
            })
    return out

def case_counts_in_cutoff(rows, score_col, cutoff_score):
    c = Counter()
    for r in rows:
        if f(r.get(score_col)) == cutoff_score:
            c[r.get("case_type", "")] += 1
    return dict(c)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="inp", required=True)
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--budgets", nargs="+", type=float, required=True)
    ap.add_argument("--random-reps", type=int, default=5000)
    ap.add_argument("--bootstrap-reps", type=int, default=5000)
    ap.add_argument("--seed", type=int, default=20260707)
    args = ap.parse_args()

    rows = list(csv.DictReader(open(args.inp, newline="")))
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    if not rows:
        raise SystemExit("No rows")

    policies = available_policies(rows)
    required = ["p-only", "H-only", "EVVA-EH", "Oracle"]
    missing = [p for p in required if p not in policies]
    if missing:
        raise SystemExit(f"Missing required policies: {missing}; available={sorted(policies)}")

    rng = random.Random(args.seed)

    exact_rows = []
    tie_rows = []
    random_rows = []
    regret_rows = []

    for frac in args.budgets:
        B = budget_B(frac, len(rows))

        oracle = tieaware_gain(rows, policies["Oracle"], B)
        oracle_gain = oracle["expected_gain"]

        for policy, col in policies.items():
            tg = tieaware_gain(rows, col, B)
            exact_rows.append({
                "policy": policy,
                "budget_fraction": frac,
                "B": B,
                "n": len(rows),
                "expected_selected_gain": tg["expected_gain"],
                "expected_mean_selected_gain": tg["expected_gain"] / B,
                "cutoff_score": tg["cutoff_score"],
                "tie_block_n": tg["tie_block_n"],
                "need_from_tie": tg["need_from_tie"],
                "tie_fraction": tg["tie_fraction"],
            })

            tie_rows.append({
                "policy": policy,
                "budget_fraction": frac,
                "B": B,
                "n": len(rows),
                "score_col": col,
                "cutoff_score": tg["cutoff_score"],
                "selected_above_n": tg["selected_above_n"],
                "tie_block_n": tg["tie_block_n"],
                "need_from_tie": tg["need_from_tie"],
                "tie_fraction": tg["tie_fraction"],
                "gain_above_cutoff": tg["gain_above_cutoff"],
                "tie_block_gain": tg["tie_block_gain"],
                "tie_block_mean_gain": tg["tie_block_mean_gain"],
                "tie_block_case_counts": case_counts_in_cutoff(rows, col, tg["cutoff_score"]),
            })

            if policy != "Oracle":
                regret_rows.append({
                    "policy": policy,
                    "budget_fraction": frac,
                    "B": B,
                    "oracle_expected_gain": oracle_gain,
                    "policy_expected_gain": tg["expected_gain"],
                    "oracle_regret": oracle_gain - tg["expected_gain"],
                })

        rand_vals = random_sample_gains(rows, B, args.random_reps, rng)
        rand_expected = (B / len(rows)) * sum(gain(r) for r in rows)

        exact_rows.append({
            "policy": "Random_expected",
            "budget_fraction": frac,
            "B": B,
            "n": len(rows),
            "expected_selected_gain": rand_expected,
            "expected_mean_selected_gain": rand_expected / B,
            "cutoff_score": "",
            "tie_block_n": "",
            "need_from_tie": "",
            "tie_fraction": "",
        })

        random_rows.append({
            "policy": "Random",
            "budget_fraction": frac,
            "B": B,
            "n": len(rows),
            "random_reps": args.random_reps,
            "analytic_expected_gain": rand_expected,
            "sample_mean_gain": mean(rand_vals),
            "sample_sd_gain": stdev(rand_vals),
            "sample_p025_gain": pct(rand_vals, 0.025),
            "sample_p975_gain": pct(rand_vals, 0.975),
        })

        regret_rows.append({
            "policy": "Random_expected",
            "budget_fraction": frac,
            "B": B,
            "oracle_expected_gain": oracle_gain,
            "policy_expected_gain": rand_expected,
            "oracle_regret": oracle_gain - rand_expected,
        })

    boot_rows = bootstrap_pairwise(rows, policies, args.budgets, args.bootstrap_reps, rng)

    write_csv(out_dir / "exactB_summary_tieaware.csv", exact_rows, [
        "policy", "budget_fraction", "B", "n",
        "expected_selected_gain", "expected_mean_selected_gain",
        "cutoff_score", "tie_block_n", "need_from_tie", "tie_fraction",
    ])

    write_csv(out_dir / "tie_block_audit.csv", tie_rows, [
        "policy", "budget_fraction", "B", "n", "score_col",
        "cutoff_score", "selected_above_n", "tie_block_n",
        "need_from_tie", "tie_fraction", "gain_above_cutoff",
        "tie_block_gain", "tie_block_mean_gain", "tie_block_case_counts",
    ])

    write_csv(out_dir / "oracle_regret_tieaware.csv", regret_rows, [
        "policy", "budget_fraction", "B",
        "oracle_expected_gain", "policy_expected_gain", "oracle_regret",
    ])

    write_csv(out_dir / "random_audit_tieaware.csv", random_rows, [
        "policy", "budget_fraction", "B", "n", "random_reps",
        "analytic_expected_gain", "sample_mean_gain",
        "sample_sd_gain", "sample_p025_gain", "sample_p975_gain",
    ])

    write_csv(out_dir / "pairwise_bootstrap_tieaware.csv", boot_rows, [
        "budget_fraction", "B_original", "comparison", "bootstrap_reps",
        "delta_mean", "delta_p025", "delta_p975", "prob_delta_gt_0",
    ])

    md = []
    md.append("# Tie-aware exact-B smoke summary")
    md.append("")
    md.append(f"- input: {args.inp}")
    md.append(f"- rows: {len(rows)}")
    md.append(f"- policies: {sorted(policies.keys())} + Random_expected")
    md.append("")
    md.append("## Why this evaluator exists")
    md.append("- Full-agent smoke has large score ties, especially H-only with harm_score=1.")
    md.append("- Deterministic case/seed tie-breaking can create artificial gains.")
    md.append("- This evaluator uses expected gain under uniform selection within the cutoff tie block.")
    md.append("")
    md.append("## Main outputs")
    md.append("- exactB_summary_tieaware.csv")
    md.append("- tie_block_audit.csv")
    md.append("- oracle_regret_tieaware.csv")
    md.append("- pairwise_bootstrap_tieaware.csv")
    md.append("- random_audit_tieaware.csv")
    (out_dir / "README_tieaware.md").write_text("\n".join(md) + "\n")

    print("[DONE]", out_dir)
    print("[OUT]", out_dir / "exactB_summary_tieaware.csv")
    print("[TIE]", out_dir / "tie_block_audit.csv")
    print("[BOOT]", out_dir / "pairwise_bootstrap_tieaware.csv")

if __name__ == "__main__":
    main()

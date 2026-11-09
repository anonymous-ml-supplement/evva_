#!/usr/bin/env python3
from pathlib import Path
import csv, math, random, statistics
from collections import defaultdict, Counter

INPUT = Path("artifacts/evva_gate5b_openclaw_grouped_multiopportunity_20260623/openclaw_generated_candidate_pool.csv")
OUTDIR = Path("artifacts/v4_large_exactB_20260707/clean_pool_eval_tiesafe")
OUTDIR.mkdir(parents=True, exist_ok=True)

POLICIES = [
    ("Random(expected)", None),
    ("p-only", "score_p_only"),
    ("H-only", "score_H_only"),
    ("EVVA-EH pH", "score_p_times_H"),
    ("PRM task surrogate", "score_prm_task_surrogate"),
    ("PRM value surrogate", "score_prm_value_surrogate"),
    ("Value-router surrogate", "score_value_router_surrogate"),
    ("Oracle diagnostic", "score_oracle_gain"),
]

MAIN_BUDGETS = [0.20, 0.30]
FULL_BUDGETS = [0.10, 0.20, 0.30, 0.50, 0.75]

def fnum(x):
    try:
        return float(x)
    except Exception:
        return None

def read_rows(path):
    with path.open(newline="", errors="replace") as f:
        rows = list(csv.DictReader(f))
    # Stable canonical order independent of file order.
    rows.sort(key=lambda r: str(r.get("candidate_id", "")))
    return rows

def gain(r):
    g = fnum(r.get("intervention_gain"))
    if g is not None:
        return g
    wrong = fnum(r.get("reward_wrong_continuation"))
    corr = fnum(r.get("reward_corrected_continuation"))
    if wrong is None or corr is None:
        return None
    return corr - wrong

def score_stats(rows, col):
    vals = []
    for r in rows:
        v = fnum(r.get(col))
        if v is not None:
            vals.append(v)
    if not vals:
        return {
            "n_valid": 0, "n_unique": 0, "min": "", "mean": "", "median": "", "max": "",
            "top_tie_count": "", "is_degenerate": True
        }
    c = Counter(vals)
    max_val = max(vals)
    return {
        "n_valid": len(vals),
        "n_unique": len(c),
        "min": min(vals),
        "mean": statistics.mean(vals),
        "median": statistics.median(vals),
        "max": max(vals),
        "top_tie_count": c[max_val],
        "is_degenerate": len(c) <= 3,
    }

def topb_eval(rows, score_col, frac):
    clean = []
    for r in rows:
        g = gain(r)
        if g is None:
            continue
        cid = str(r.get("candidate_id", ""))
        if score_col is None:
            clean.append((0.0, cid, g, r))
        else:
            s = fnum(r.get(score_col))
            if s is None:
                continue
            clean.append((s, cid, g, r))

    n = len(clean)
    if n == 0:
        return {"B": 0, "n": 0, "mean_gain": float("nan"), "selected_ids": []}

    B = max(1, int(round(n * frac)))

    if score_col is None:
        # Expected uniform random exact-B selected gain.
        mean_gain = sum(g for _, _, g, _ in clean) / n
        return {"B": B, "n": n, "mean_gain": mean_gain, "selected_ids": []}

    # Stable tie-breaking by candidate_id.
    selected = sorted(clean, key=lambda x: (-x[0], x[1]))[:B]
    mean_gain = sum(g for _, _, g, _ in selected) / B
    return {
        "B": B,
        "n": n,
        "mean_gain": mean_gain,
        "selected_ids": [r.get("candidate_id", "") for _, _, _, r in selected],
    }

def bootstrap_ci(rows, score_col, frac, n_boot=2000, seed=777):
    # Candidate-level bootstrap over rows. Each resample is canonicalized by candidate_id plus draw index
    # so ranking tie behavior is stable and not accidental input order.
    rng = random.Random(seed)
    vals = []
    n = len(rows)
    for b in range(n_boot):
        sample = []
        for i in range(n):
            r = dict(rows[rng.randrange(n)])
            r["_draw_id"] = str(i)
            # Make duplicate sampled candidates distinguishable but deterministic.
            r["candidate_id"] = str(r.get("candidate_id", "")) + f"__draw{i:04d}"
            sample.append(r)
        vals.append(topb_eval(sample, score_col, frac)["mean_gain"])
    vals = sorted(v for v in vals if not math.isnan(v))
    if not vals:
        return "", ""
    lo = vals[int(0.025 * (len(vals)-1))]
    hi = vals[int(0.975 * (len(vals)-1))]
    return lo, hi

rows = read_rows(INPUT)
print(f"Loaded {len(rows)} rows from {INPUT}")

# schema / score audit
score_audit_rows = []
for policy, col in POLICIES:
    if col is None:
        continue
    st = score_stats(rows, col)
    score_audit_rows.append({
        "policy": policy,
        "score_col": col,
        **st,
    })

with (OUTDIR / "score_distribution_audit.csv").open("w", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=list(score_audit_rows[0].keys()))
    writer.writeheader()
    writer.writerows(score_audit_rows)

# main table
main_rows = []
for frac in MAIN_BUDGETS:
    for policy, col in POLICIES:
        ev = topb_eval(rows, col, frac)
        lo, hi = bootstrap_ci(rows, col, frac)
        main_rows.append({
            "budget_frac": frac,
            "budget_percent": int(round(frac * 100)),
            "policy": policy,
            "score_col": col or "uniform_random_expected",
            "n": ev["n"],
            "B": ev["B"],
            "mean_selected_gain": ev["mean_gain"],
            "bootstrap_lo": lo,
            "bootstrap_hi": hi,
        })

with (OUTDIR / "v4_clean_pool_main_20_30_tiesafe.csv").open("w", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=list(main_rows[0].keys()))
    writer.writeheader()
    writer.writerows(main_rows)

# full curve
curve_rows = []
for frac in FULL_BUDGETS:
    for policy, col in POLICIES:
        ev = topb_eval(rows, col, frac)
        curve_rows.append({
            "budget_frac": frac,
            "budget_percent": int(round(frac * 100)),
            "policy": policy,
            "score_col": col or "uniform_random_expected",
            "n": ev["n"],
            "B": ev["B"],
            "mean_selected_gain": ev["mean_gain"],
        })

with (OUTDIR / "v4_clean_pool_full_budget_curve_tiesafe.csv").open("w", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=list(curve_rows[0].keys()))
    writer.writeheader()
    writer.writerows(curve_rows)

# report
with (OUTDIR / "v4_clean_pool_report_tiesafe.md").open("w") as f:
    f.write("# Tie-safe V4 clean candidate-pool exact-B feasibility report\n\n")
    f.write(f"Input: `{INPUT}`\n\n")
    f.write(f"Rows: {len(rows)}\n\n")
    f.write("## Score distribution audit\n\n")
    f.write("| Policy | Score | unique | top tie count | min | mean | median | max | degenerate? |\n")
    f.write("|---|---|---:|---:|---:|---:|---:|---:|---:|\n")
    for r in score_audit_rows:
        f.write(
            f"| {r['policy']} | `{r['score_col']}` | {r['n_unique']} | {r['top_tie_count']} | "
            f"{float(r['min']):.4f} | {float(r['mean']):.4f} | {float(r['median']):.4f} | {float(r['max']):.4f} | {r['is_degenerate']} |\n"
        )
    f.write("\n## Main 20/30 exact-B table\n\n")
    for pct in [20, 30]:
        f.write(f"### {pct}% budget\n\n")
        f.write("| Policy | Score | B | Mean selected gain | Bootstrap CI |\n")
        f.write("|---|---:|---:|---:|---:|\n")
        for r in main_rows:
            if r["budget_percent"] != pct:
                continue
            ci = ""
            if r["bootstrap_lo"] != "":
                ci = f"[{float(r['bootstrap_lo']):.4f}, {float(r['bootstrap_hi']):.4f}]"
            f.write(f"| {r['policy']} | `{r['score_col']}` | {r['B']} | {float(r['mean_selected_gain']):.4f} | {ci} |\n")
        f.write("\n")
    f.write("## Notes\n\n")
    f.write("- Ranking uses stable tie-breaking by candidate_id.\n")
    f.write("- Random is expected uniform exact-B gain, not multi-seed random variance.\n")
    f.write("- Oracle diagnostic is an upper bound, not a deployable policy.\n")
    f.write("- Degenerate surrogate scores should not be promoted as strong main baselines.\n")

print("---- score distribution audit ----")
with (OUTDIR / "score_distribution_audit.csv").open() as f:
    print(f.read())

print("---- main table tiesafe ----")
with (OUTDIR / "v4_clean_pool_main_20_30_tiesafe.csv").open() as f:
    print(f.read())

print("---- report ----")
with (OUTDIR / "v4_clean_pool_report_tiesafe.md").open() as f:
    print(f.read())

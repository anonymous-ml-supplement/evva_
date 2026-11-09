#!/usr/bin/env python3
from pathlib import Path
import csv, statistics, math
from collections import defaultdict

INPUT = Path("artifacts/aaai_gate5b_openclaw_grouped_multiopportunity_20260623/openclaw_generated_candidate_pool.csv")
OUTDIR = Path("artifacts/v4_large_exactB_20260707/expected_value_decomposition_gate5b")
OUTDIR.mkdir(parents=True, exist_ok=True)

BUDGETS = [0.10, 0.20, 0.30, 0.50, 0.75]

def fnum(x):
    try:
        return float(x)
    except Exception:
        return None

def read_rows(path):
    with path.open(newline="", errors="replace") as f:
        rows = list(csv.DictReader(f))
    rows.sort(key=lambda r: str(r.get("candidate_id", "")))
    return rows

def potential_gain(r):
    g = fnum(r.get("intervention_gain"))
    if g is not None:
        return g
    w = fnum(r.get("reward_wrong_continuation"))
    c = fnum(r.get("reward_corrected_continuation"))
    if w is None or c is None:
        return None
    return c - w

def add_scores(rows):
    out = []
    for r in rows:
        rr = dict(r)
        p = fnum(rr.get("p_score"))
        h = fnum(rr.get("harm_score"))
        pot = potential_gain(rr)
        if p is None or h is None or pot is None:
            continue
        rr["potential_gain_if_wrong"] = pot
        rr["expected_gain_p_true_impact"] = p * pot
        rr["score_true_impact_only"] = pot
        rr["score_p_times_true_impact"] = p * pot
        rr["score_existing_pH"] = p * h
        rr["score_H_only"] = h
        rr["score_p_only"] = p
        out.append(rr)
    return out

def topb_mean(rows, score_col, target_col, frac):
    clean = []
    for r in rows:
        s = fnum(r.get(score_col))
        g = fnum(r.get(target_col))
        if s is None or g is None:
            continue
        clean.append((s, str(r.get("candidate_id", "")), g))
    B = max(1, int(round(len(clean) * frac)))
    top = sorted(clean, key=lambda x: (-x[0], x[1]))[:B]
    return sum(g for _, _, g in top) / B, B

def corr(xs, ys):
    pairs = [(x, y) for x, y in zip(xs, ys) if x is not None and y is not None]
    if len(pairs) < 3:
        return None
    xs, ys = zip(*pairs)
    mx, my = statistics.mean(xs), statistics.mean(ys)
    vx = sum((x-mx)**2 for x in xs)
    vy = sum((y-my)**2 for y in ys)
    if vx == 0 or vy == 0:
        return None
    return sum((x-mx)*(y-my) for x, y in zip(xs, ys)) / math.sqrt(vx*vy)

rows = add_scores(read_rows(INPUT))

policies = [
    ("Random(expected)", None),
    ("p-only", "score_p_only"),
    ("H-only", "score_H_only"),
    ("EVVA-EH existing pH", "score_existing_pH"),
    ("True impact only", "score_true_impact_only"),
    ("Oracle expected p*true_impact", "score_p_times_true_impact"),
]

targets = [
    ("potential_gain_if_wrong", "Potential gain if wrong"),
    ("expected_gain_p_true_impact", "Expected gain p*potential_gain"),
]

summary = []
for target_col, target_name in targets:
    for frac in BUDGETS:
        for policy, score_col in policies:
            if score_col is None:
                vals = [fnum(r[target_col]) for r in rows if fnum(r[target_col]) is not None]
                m = statistics.mean(vals)
                B = max(1, int(round(len(vals) * frac)))
            else:
                m, B = topb_mean(rows, score_col, target_col, frac)
            summary.append({
                "target": target_name,
                "target_col": target_col,
                "budget_percent": int(round(frac * 100)),
                "policy": policy,
                "score_col": score_col or "uniform_random_expected",
                "n": len(rows),
                "B": B,
                "mean_selected_target": m,
            })

with (OUTDIR / "expected_value_decomposition_summary.csv").open("w", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=list(summary[0].keys()))
    writer.writeheader()
    writer.writerows(summary)

# Correlations
corr_rows = []
score_cols = [
    "score_p_only",
    "score_H_only",
    "score_existing_pH",
    "score_true_impact_only",
    "score_p_times_true_impact",
]
for target_col, target_name in targets:
    ys = [fnum(r[target_col]) for r in rows]
    for sc in score_cols:
        xs = [fnum(r[sc]) for r in rows]
        corr_rows.append({
            "target": target_name,
            "score_col": sc,
            "pearson_corr": corr(xs, ys),
        })

with (OUTDIR / "expected_value_correlations.csv").open("w", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=list(corr_rows[0].keys()))
    writer.writeheader()
    writer.writerows(corr_rows)

with (OUTDIR / "expected_value_decomposition_report.md").open("w") as f:
    f.write("# Expected-value decomposition on gate5b clean pool\n\n")
    f.write(f"Input: `{INPUT}`\n\n")
    f.write(f"Rows: {len(rows)}\n\n")

    f.write("## Correlations\n\n")
    f.write("| Target | Score | Pearson corr |\n")
    f.write("|---|---|---:|\n")
    for r in corr_rows:
        c = r["pearson_corr"]
        f.write(f"| {r['target']} | `{r['score_col']}` | {c:.4f} |\n")
    f.write("\n")

    for target_col, target_name in targets:
        f.write(f"## Target: {target_name}\n\n")
        for pct in [10, 20, 30, 50, 75]:
            f.write(f"### Budget {pct}%\n\n")
            f.write("| Policy | B | Mean selected target |\n")
            f.write("|---|---:|---:|\n")
            for r in summary:
                if r["target_col"] == target_col and r["budget_percent"] == pct:
                    f.write(f"| {r['policy']} | {r['B']} | {r['mean_selected_target']:.4f} |\n")
            f.write("\n")

    f.write("## Interpretation guide\n\n")
    f.write("- If Oracle expected p*true_impact beats H-only on expected gain but existing pH does not, the limiting factor is the H proxy.\n")
    f.write("- If even Oracle expected p*true_impact does not beat H-only, the limiting factor is p_score or the generator distribution.\n")
    f.write("- True impact only corresponds to harm with oracle access to true potential branch impact and is not deployable.\n")

print("Wrote outputs to", OUTDIR)
print((OUTDIR / "expected_value_decomposition_report.md").read_text())

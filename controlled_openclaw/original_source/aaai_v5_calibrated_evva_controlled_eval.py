#!/usr/bin/env python3
import csv, math, bisect
from pathlib import Path
from itertools import product

ROOT = Path("artifacts/aaai_v5_calibrated_evva_20260708")
RAW = Path("artifacts/aaai_gate1_value_router_20260615/value_router_train_eval_rows.csv")

OUT_DIR = ROOT / "controlled_table1"
REP_DIR = ROOT / "reports"
LOG_DIR = ROOT / "logs"
TAB_DIR = ROOT / "tables"
for d in [OUT_DIR, REP_DIR, LOG_DIR, TAB_DIR]:
    d.mkdir(parents=True, exist_ok=True)

BUDGETS_REPRO = [0.05, 0.10, 0.20, 0.30, 0.40, 0.50]
BUDGETS_MAIN = [0.10, 0.20, 0.30, 0.40, 0.50]
LABEL = "intervention_gain"

BASELINES = [
    ("Random", "score_random"),
    ("p-only", "score_p_only"),
    ("H-only", "score_H_only"),
    ("PRM/process", "score_prm_task_fail"),
    ("Reward/value", "score_prm_value_gain"),
    ("Learned router", "score_value_router"),
    ("EVVA-EH", "score_p_times_H"),
]

KNOWN = {
    ("p-only", 0.20): 10.7643,
    ("p-only", 0.30): 11.3575,
    ("H-only", 0.20): 11.3058,
    ("H-only", 0.30): 12.4432,
    ("PRM/process", 0.20): 9.7965,
    ("PRM/process", 0.30): 9.0122,
    ("Reward/value", 0.20): 9.2045,
    ("Reward/value", 0.30): 9.4733,
    ("Learned router", 0.20): 8.4325,
    ("Learned router", 0.30): 8.9492,
    ("EVVA-EH", 0.20): 15.0398,
    ("EVVA-EH", 0.30): 13.3100,
}

FORBIDDEN_AS_SCORE = {
    "intervention_gain",
    "branch_harm_exact",
    "reward_wrong_continuation",
    "reward_corrected_continuation",
    "score_oracle_gain",
}

def fnum(x):
    if x is None:
        return float("nan")
    s = str(x).strip()
    if s == "":
        return float("nan")
    return float(s)

def read_rows(path):
    with path.open(newline="") as f:
        reader = csv.DictReader(f)
        rows = list(reader)
    return rows, reader.fieldnames

def exact_b_tieaware(rows, score_col, label_col, frac):
    n = len(rows)
    if n == 0:
        return {"n": 0, "B": 0, "selected_total_gain": 0.0, "selected_avg_gain": float("nan")}

    B = int(round(frac * n))
    B = max(1, min(B, n))

    vals = []
    for r in rows:
        vals.append((fnum(r[score_col]), fnum(r[label_col])))

    vals.sort(key=lambda x: x[0], reverse=True)

    cutoff = vals[B - 1][0]
    above = [(s, y) for s, y in vals if s > cutoff]
    tied = [(s, y) for s, y in vals if s == cutoff]

    selected_above = len(above)
    need = B - selected_above

    total = sum(y for _, y in above)
    if need > 0 and tied:
        total += (need / len(tied)) * sum(y for _, y in tied)

    return {
        "n": n,
        "B": B,
        "selected_total_gain": total,
        "selected_avg_gain": total / B,
        "cutoff_score": cutoff,
        "tie_block_size": len(tied),
        "tie_needed": need,
    }

def percentile_transform(cal_values, x):
    # calibration-only midrank percentile
    n = len(cal_values)
    if n == 0:
        return 0.0
    lo = bisect.bisect_left(cal_values, x)
    hi = bisect.bisect_right(cal_values, x)
    return (lo + 0.5 * (hi - lo)) / n

def add_normalized_components(cal_rows, all_rows):
    component_cols = {
        "P": "score_p_only",
        "Hn": "score_H_only",
        "Vn": "score_prm_value_gain",
    }

    sorted_cal = {}
    for name, col in component_cols.items():
        vals = sorted(fnum(r[col]) for r in cal_rows if r.get(col, "") != "")
        sorted_cal[name] = vals

    for r in all_rows:
        p = percentile_transform(sorted_cal["P"], fnum(r[component_cols["P"]]))
        h = percentile_transform(sorted_cal["Hn"], fnum(r[component_cols["Hn"]]))
        v = percentile_transform(sorted_cal["Vn"], fnum(r[component_cols["Vn"]]))
        r["_norm_p"] = str(p)
        r["_norm_h"] = str(h)
        r["_norm_v"] = str(v)
        r["_norm_ph"] = str(p * h)

def score_combo(rows, weights, with_v):
    # weights = (alpha pH, beta p, gamma H) or (alpha pH, beta p, gamma H, delta V)
    for r in rows:
        ph = fnum(r["_norm_ph"])
        p = fnum(r["_norm_p"])
        h = fnum(r["_norm_h"])
        v = fnum(r["_norm_v"])
        if with_v:
            a, b, g, d = weights
            s = a * ph + b * p + g * h + d * v
        else:
            a, b, g = weights
            s = a * ph + b * p + g * h
        r["_combo_score"] = str(s)

def weight_grid(k, step=0.05):
    units = int(round(1.0 / step))
    if k == 3:
        for a in range(units + 1):
            for b in range(units + 1 - a):
                c = units - a - b
                yield (a * step, b * step, c * step)
    elif k == 4:
        for a in range(units + 1):
            for b in range(units + 1 - a):
                for c in range(units + 1 - a - b):
                    d = units - a - b - c
                    yield (a * step, b * step, c * step, d * step)

def evaluate_combo(rows, weights, with_v, budgets):
    score_combo(rows, weights, with_v)
    vals = []
    for b in budgets:
        vals.append(exact_b_tieaware(rows, "_combo_score", LABEL, b)["selected_avg_gain"])
    return sum(vals) / len(vals), vals

def fit_weights(cal_rows, k, with_v):
    best = None
    for w in weight_grid(k, 0.05):
        avg, vals = evaluate_combo(cal_rows, w, with_v, BUDGETS_MAIN)
        # tie-breaker: higher worst budget value, then more mass on pH for interpretability
        worst = min(vals)
        ph_mass = w[0]
        key = (avg, worst, ph_mass)
        if best is None or key > best["key"]:
            best = {"weights": w, "avg": avg, "vals": vals, "key": key}
    return best

def pearson(xs, ys):
    pairs = [(x, y) for x, y in zip(xs, ys) if math.isfinite(x) and math.isfinite(y)]
    if len(pairs) < 2:
        return float("nan")
    xs = [p[0] for p in pairs]
    ys = [p[1] for p in pairs]
    mx = sum(xs) / len(xs)
    my = sum(ys) / len(ys)
    vx = sum((x - mx) ** 2 for x in xs)
    vy = sum((y - my) ** 2 for y in ys)
    if vx <= 0 or vy <= 0:
        return float("nan")
    cov = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    return cov / math.sqrt(vx * vy)

def write_csv(path, rows, fieldnames):
    with path.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames)
        w.writeheader()
        for r in rows:
            w.writerow(r)

def main():
    rows, header = read_rows(RAW)

    # Controlled v3 table uses eval split: n=200. Train split is calibration: n=100.
    cal_rows = [r for r in rows if r.get("split") == "train"]
    eval_rows = [r for r in rows if r.get("split") == "eval"]

    if not cal_rows or not eval_rows:
        # fallback only if split column is absent/broken
        seeds = sorted(set(int(fnum(r["seed"])) for r in rows if r.get("seed", "") != ""))
        mid = len(seeds) // 2
        cal_seed = set(seeds[:mid])
        eval_seed = set(seeds[mid:])
        cal_rows = [r for r in rows if int(fnum(r["seed"])) in cal_seed]
        eval_rows = [r for r in rows if int(fnum(r["seed"])) in eval_seed]

    # Score-column audit
    audit_rows = []
    for col in header:
        lower = col.lower()
        audit_rows.append({
            "column": col,
            "is_forbidden_score_input": str(col in FORBIDDEN_AS_SCORE),
            "looks_like_score": str(("score" in lower or "prm" in lower or "router" in lower or lower in ["p_cal", "h_cal"]) and col not in FORBIDDEN_AS_SCORE),
            "looks_like_posthoc_outcome": str(col in FORBIDDEN_AS_SCORE or "reward_wrong" in lower or "reward_corrected" in lower or "branch_harm" in lower or "intervention_gain" in lower),
        })
    write_csv(
        LOG_DIR / "controlled_score_column_audit.csv",
        audit_rows,
        ["column", "is_forbidden_score_input", "looks_like_score", "looks_like_posthoc_outcome"],
    )

    # Leakage pre-audit: exact equality and correlation with outcome/posthoc labels.
    leakage_rows = []
    possible_scores = [
        "score_p_only", "score_H_only", "score_p_times_H",
        "score_prm_task_fail", "score_prm_value_gain", "score_value_router",
        "p_score", "harm_score", "p_times_H_score",
        "prm_task_fail_score", "prm_value_gain_score",
    ]
    posthoc = ["intervention_gain", "branch_harm_exact", "reward_wrong_continuation", "reward_corrected_continuation"]
    for s_col in possible_scores:
        if s_col not in header:
            continue
        for y_col in posthoc:
            if y_col not in header:
                continue
            xs = [fnum(r[s_col]) for r in rows]
            ys = [fnum(r[y_col]) for r in rows]
            exact = all((not math.isfinite(x) and not math.isfinite(y)) or abs(x - y) < 1e-12 for x, y in zip(xs, ys))
            leakage_rows.append({
                "score_col": s_col,
                "posthoc_col": y_col,
                "exact_equal_all_rows": str(exact),
                "pearson": f"{pearson(xs, ys):.6f}",
            })
    write_csv(
        LOG_DIR / "controlled_leakage_audit.csv",
        leakage_rows,
        ["score_col", "posthoc_col", "exact_equal_all_rows", "pearson"],
    )

    # Reproduce original budget curve on eval split.
    repro = []
    for name, col in BASELINES:
        for b in BUDGETS_REPRO:
            res = exact_b_tieaware(eval_rows, col, LABEL, b)
            known = KNOWN.get((name, b), "")
            delta = ""
            if known != "":
                delta = res["selected_avg_gain"] - known
            repro.append({
                "method": name,
                "score_col": col,
                "split": "eval",
                "budget_frac": f"{b:.2f}",
                "B": res["B"],
                "n": res["n"],
                "selected_avg_gain": f"{res['selected_avg_gain']:.4f}",
                "known_v3_value": "" if known == "" else f"{known:.4f}",
                "delta_vs_known": "" if delta == "" else f"{delta:.6f}",
                "tie_block_size": res["tie_block_size"],
                "tie_needed": res["tie_needed"],
            })

    write_csv(
        OUT_DIR / "original_rerun_summary.csv",
        repro,
        ["method", "score_col", "split", "budget_frac", "B", "n", "selected_avg_gain", "known_v3_value", "delta_vs_known", "tie_block_size", "tie_needed"],
    )

    # Normalization and calibration.
    all_for_norm = cal_rows + eval_rows
    add_normalized_components(cal_rows, all_for_norm)

    blend = fit_weights(cal_rows, 3, with_v=False)
    calv = fit_weights(cal_rows, 4, with_v=True)

    weights_rows = [
        {
            "method": "EVVA-Blend3",
            "alpha_pH": f"{blend['weights'][0]:.2f}",
            "beta_p": f"{blend['weights'][1]:.2f}",
            "gamma_H": f"{blend['weights'][2]:.2f}",
            "delta_V": "",
            "calibration_objective_avg_10_50": f"{blend['avg']:.4f}",
            "calibration_budget_values": ";".join(f"{x:.4f}" for x in blend["vals"]),
            "calibration_split": "split=train",
            "evaluation_split": "split=eval",
            "normalization": "calibration-split percentile midrank",
        },
        {
            "method": "EVVA-CalV",
            "alpha_pH": f"{calv['weights'][0]:.2f}",
            "beta_p": f"{calv['weights'][1]:.2f}",
            "gamma_H": f"{calv['weights'][2]:.2f}",
            "delta_V": f"{calv['weights'][3]:.2f}",
            "calibration_objective_avg_10_50": f"{calv['avg']:.4f}",
            "calibration_budget_values": ";".join(f"{x:.4f}" for x in calv["vals"]),
            "calibration_split": "split=train",
            "evaluation_split": "split=eval",
            "normalization": "calibration-split percentile midrank",
        },
    ]
    write_csv(
        OUT_DIR / "learned_weights.csv",
        weights_rows,
        ["method", "alpha_pH", "beta_p", "gamma_H", "delta_V", "calibration_objective_avg_10_50", "calibration_budget_values", "calibration_split", "evaluation_split", "normalization"],
    )

    # Main eval table 10/20/30/40/50 on held-out eval split.
    main_rows = []

    def add_method(method, score_col):
        vals = []
        per_budget = {}
        for b in BUDGETS_MAIN:
            res = exact_b_tieaware(eval_rows, score_col, LABEL, b)
            vals.append(res["selected_avg_gain"])
            per_budget[f"{int(round(b*100))}%"] = f"{res['selected_avg_gain']:.4f}"
        avg = sum(vals) / len(vals)
        main_rows.append({
            "method": method,
            "score_col": score_col,
            **per_budget,
            "avg_10_50": f"{avg:.4f}",
        })

    for name, col in BASELINES:
        add_method(name, col)

    score_combo(eval_rows, blend["weights"], with_v=False)
    add_method("EVVA-Blend3", "_combo_score")

    score_combo(eval_rows, calv["weights"], with_v=True)
    add_method("EVVA-CalV", "_combo_score")

    # Compute worst gap to per-budget best.
    budget_cols = [f"{int(round(b*100))}%" for b in BUDGETS_MAIN]
    best_by_budget = {}
    for bc in budget_cols:
        best_by_budget[bc] = max(float(r[bc]) for r in main_rows)

    for r in main_rows:
        gaps = [float(r[bc]) - best_by_budget[bc] for bc in budget_cols]
        r["worst_gap_to_best"] = f"{min(gaps):.4f}"
        r["num_budget_wins_or_ties"] = str(sum(1 for bc in budget_cols if abs(float(r[bc]) - best_by_budget[bc]) < 1e-9))

    write_csv(
        OUT_DIR / "calibrated_controlled_summary.csv",
        main_rows,
        ["method", "score_col", "10%", "20%", "30%", "40%", "50%", "avg_10_50", "worst_gap_to_best", "num_budget_wins_or_ties"],
    )

    # Paper-ready markdown table.
    md = []
    md.append("# EVVA v5 Controlled Calibrated Allocator Report")
    md.append("")
    md.append("## Data")
    md.append("")
    md.append(f"- Raw: `{RAW}`")
    md.append(f"- Total rows: {len(rows)}")
    md.append(f"- Calibration rows: {len(cal_rows)} (`split=train`)")
    md.append(f"- Evaluation rows: {len(eval_rows)} (`split=eval`)")
    md.append("- Exact-B selection: tie-aware cutoff expectation")
    md.append("- Normalization for calibrated methods: calibration-split percentile midrank")
    md.append("")
    md.append("## Reproduction check against v3 Table 1")
    md.append("")
    md.append("| Method | 20% rerun | 20% known | Δ | 30% rerun | 30% known | Δ |")
    md.append("|---|---:|---:|---:|---:|---:|---:|")
    repro_map = {(r["method"], float(r["budget_frac"])): r for r in repro}
    for name, _ in BASELINES:
        r20 = repro_map.get((name, 0.20))
        r30 = repro_map.get((name, 0.30))
        if r20 and r30:
            md.append(
                f"| {name} | {r20['selected_avg_gain']} | {r20['known_v3_value']} | {r20['delta_vs_known']} | "
                f"{r30['selected_avg_gain']} | {r30['known_v3_value']} | {r30['delta_vs_known']} |"
            )

    md.append("")
    md.append("## Learned weights")
    md.append("")
    md.append("| Method | α pH | β p | γ H | δ V | Cal avg 10--50 |")
    md.append("|---|---:|---:|---:|---:|---:|")
    for r in weights_rows:
        md.append(f"| {r['method']} | {r['alpha_pH']} | {r['beta_p']} | {r['gamma_H']} | {r['delta_V']} | {r['calibration_objective_avg_10_50']} |")

    md.append("")
    md.append("## Held-out controlled evaluation")
    md.append("")
    md.append("| Method | 10% | 20% | 30% | 40% | 50% | Avg 10--50 | Worst gap | Wins/ties |")
    md.append("|---|---:|---:|---:|---:|---:|---:|---:|---:|")
    for r in main_rows:
        md.append(
            f"| {r['method']} | {r['10%']} | {r['20%']} | {r['30%']} | {r['40%']} | {r['50%']} | "
            f"{r['avg_10_50']} | {r['worst_gap_to_best']} | {r['num_budget_wins_or_ties']} |"
        )

    calv_row = next(r for r in main_rows if r["method"] == "EVVA-CalV")
    eh_row = next(r for r in main_rows if r["method"] == "EVVA-EH")
    calv_avg = float(calv_row["avg_10_50"])
    eh_avg = float(eh_row["avg_10_50"])
    calv_worst = float(calv_row["worst_gap_to_best"])
    eh_worst = float(eh_row["worst_gap_to_best"])

    md.append("")
    md.append("## Preliminary recommendation")
    md.append("")
    if calv_avg > eh_avg and calv_worst >= eh_worst:
        md.append("EVVA-CalV improves average 10--50 performance over EVVA-EH without worsening worst-gap consistency in this controlled held-out split. Proceed to bootstrap and then large confirmation.")
    elif calv_avg > eh_avg:
        md.append("EVVA-CalV improves average 10--50 performance over EVVA-EH, but its worst-gap consistency should be checked before making it the main method.")
    else:
        md.append("EVVA-CalV does not clearly improve over EVVA-EH on this controlled held-out split. Keep EVVA-EH as the main method unless bootstrap or large confirmation changes the story.")

    md.append("")
    md.append("## Output files")
    md.append("")
    for p in [
        OUT_DIR / "original_rerun_summary.csv",
        OUT_DIR / "calibrated_controlled_summary.csv",
        OUT_DIR / "learned_weights.csv",
        LOG_DIR / "controlled_leakage_audit.csv",
        LOG_DIR / "controlled_score_column_audit.csv",
    ]:
        md.append(f"- `{p}`")

    (REP_DIR / "controlled_calibrated_report.md").write_text("\n".join(md))

    print("DONE")
    print(REP_DIR / "controlled_calibrated_report.md")
    print(OUT_DIR / "calibrated_controlled_summary.csv")
    print(OUT_DIR / "learned_weights.csv")

if __name__ == "__main__":
    main()

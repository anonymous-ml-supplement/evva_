#!/usr/bin/env python3
import csv, math, bisect, hashlib
from pathlib import Path

ROOT = Path("artifacts/evva2_exploratory_20260713/evva2c_value_available_residual")

CONTROLLED_RAW = Path("artifacts/evva_v5j_fair_controlled_prm_20260709/fair_controlled_train_eval_rows.csv")
LARGE_RAW = Path("artifacts/v4_full_agent_20260707/large/full_agent_candidate_rows_large.csv")

BUDGETS = [0.05,0.10,0.20,0.30,0.40,0.50,0.60,0.70,0.75,0.80,0.90,1.00]
LABEL = "intervention_gain"
SALT = "v5k_signal_availability_gated_evva_20260709"

def fnum(x, default=0.0):
    try:
        s = str(x).strip()
        if s == "":
            return default
        y = float(s)
        return y if math.isfinite(y) else default
    except Exception:
        return default

def pct(b):
    return f"{int(round(100*b))}%"

def read_csv(path):
    with path.open(newline="") as f:
        return list(csv.DictReader(f))

def write_csv(path, rows, fields):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        for r in rows:
            w.writerow(r)

def stable_hash(row, idx, extra=""):
    key = "|".join([
        row.get("experiment_id",""),
        row.get("task_id",""),
        row.get("episode_id",""),
        row.get("case",""),
        row.get("case_type",""),
        row.get("seed",""),
        row.get("candidate_id",""),
        row.get("decision_point_id",""),
        str(idx),
        SALT,
        extra,
    ])
    return int(hashlib.md5(key.encode("utf-8")).hexdigest(), 16)

def add_large_random(rows):
    for i, r in enumerate(rows):
        r["_score_random"] = str(stable_hash(r, i, "large_random") / float(16**32))

def exact_B(n, frac):
    return max(1, min(int(round(frac*n)), n))

def scalar_tieaware(rows, score_col, frac):
    n = len(rows)
    B = exact_B(n, frac)
    vals = [(fnum(r.get(score_col)), fnum(r.get(LABEL))) for r in rows]
    vals.sort(key=lambda x: x[0], reverse=True)

    cutoff = vals[B-1][0]
    above = [(s,y) for s,y in vals if s > cutoff]
    tied = [(s,y) for s,y in vals if s == cutoff]
    need = B - len(above)

    total = sum(y for _,y in above)
    if need > 0 and tied:
        total += (need / len(tied)) * sum(y for _,y in tied)
    return total / B

def deterministic_rank(rows, score_col):
    ranked = []
    for i, r in enumerate(rows):
        h = stable_hash(r, i, score_col)
        ranked.append((fnum(r.get(score_col)), h, i))
    ranked.sort(key=lambda x: (x[0], x[1]), reverse=True)
    return [i for _,_,i in ranked]

def portfolio_value(rows, score_cols, quota, frac):
    n = len(rows)
    B = exact_B(n, frac)

    items = [(k,v) for k,v in quota.items() if v > 1e-12]
    selected, seen = [], set()
    remaining = B
    targets = []

    for k,q in items[:-1]:
        c = int(round(q * B))
        c = max(0, min(c, remaining))
        targets.append((k,c))
        remaining -= c
    targets.append((items[-1][0], remaining))

    for k,target in targets:
        if k not in score_cols:
            continue
        count = 0
        for idx in deterministic_rank(rows, score_cols[k]):
            if idx in seen:
                continue
            seen.add(idx)
            selected.append(idx)
            count += 1
            if count >= target:
                break

    for fill in ["pH","H","V","p"]:
        if len(selected) >= B:
            break
        if fill not in score_cols:
            continue
        for idx in deterministic_rank(rows, score_cols[fill]):
            if idx in seen:
                continue
            seen.add(idx)
            selected.append(idx)
            if len(selected) >= B:
                break

    selected = selected[:B]
    return sum(fnum(rows[i].get(LABEL)) for i in selected) / B

def percentile_setup(cal_rows, col):
    return sorted(fnum(r.get(col)) for r in cal_rows)

def percentile(vals, x):
    n = len(vals)
    if n == 0:
        return 0.5
    lo = bisect.bisect_left(vals, x)
    hi = bisect.bisect_right(vals, x)
    return (lo + 0.5 * (hi - lo)) / n

def add_bg_scores(cal_rows, eval_rows, pH_col, H_col, frac):
    pH_vals = percentile_setup(cal_rows, pH_col)
    H_vals = percentile_setup(cal_rows, H_col)

    if frac <= 0.30:
        lam = 0.90
    else:
        lam = 1.00

    for r in eval_rows:
        npH = percentile(pH_vals, fnum(r.get(pH_col)))
        nH = percentile(H_vals, fnum(r.get(H_col)))
        r["_EVVA_BG_score"] = (1.0 - lam) * npH + lam * nH

def bg_value(cal_rows, eval_rows, pH_col, H_col, frac):
    add_bg_scores(cal_rows, eval_rows, pH_col, H_col, frac)
    return scalar_tieaware(eval_rows, "_EVVA_BG_score", frac)

def calibration_topb_disagreement(
    cal_rows,
    primary_col,
    pH_col,
    frac,
):
    """
    Compute outcome-blind top-B selection disagreement on calibration.

    A value of zero means the two score families select the same
    calibration candidates. A value of one means no selected candidate
    overlaps.
    """
    B = exact_B(len(cal_rows), frac)

    primary_top = set(
        deterministic_rank(
            cal_rows,
            primary_col,
        )[:B]
    )

    pH_top = set(
        deterministic_rank(
            cal_rows,
            pH_col,
        )[:B]
    )

    overlap = len(primary_top.intersection(pH_top))

    return 1.0 - (overlap / B)

def calibration_gated_residual_value(
    cal_rows,
    eval_rows,
    primary_col,
    pH_col,
    frac,
    max_epsilon=0.10,
):
    """
    Apply a residual pH core only in proportion to calibration-side
    top-B disagreement.

    No outcome label is used to calculate disagreement or epsilon.
    """
    disagreement = calibration_topb_disagreement(
        cal_rows=cal_rows,
        primary_col=primary_col,
        pH_col=pH_col,
        frac=frac,
    )

    epsilon = max_epsilon * disagreement

    primary_values = percentile_setup(
        cal_rows,
        primary_col,
    )

    pH_values = percentile_setup(
        cal_rows,
        pH_col,
    )

    for row in eval_rows:
        normalized_primary = percentile(
            primary_values,
            fnum(row.get(primary_col)),
        )

        normalized_pH = percentile(
            pH_values,
            fnum(row.get(pH_col)),
        )

        row["_EVVA2B_score"] = (
            (1.0 - epsilon) * normalized_primary
            + epsilon * normalized_pH
        )

    value = scalar_tieaware(
        eval_rows,
        "_EVVA2B_score",
        frac,
    )

    return value, disagreement, epsilon

def score_stats(rows, col):
    vals = [fnum(r.get(col)) for r in rows]
    uniq = len(set(vals))
    mean = sum(vals)/len(vals) if vals else 0.0
    var = sum((x-mean)**2 for x in vals)/len(vals) if vals else 0.0
    return uniq, var

def usable(rows, col):
    uniq, var = score_stats(rows, col)
    return uniq > 5 and var > 1e-12

def best_baseline(rows, baseline_cols, frac):
    vals = [(m, scalar_tieaware(rows, c, frac)) for m,c in baseline_cols.items()]
    return max(vals, key=lambda x: x[1])

def value_aware_schedule(frac):
    # DG_C / controlled-scarce schedule, fixed before evaluation.
    if frac == 0.05:
        # Ultra-scarce: pure high-consequence coverage.
        return {"H":1.00}
    if frac == 0.10:
        return {"H":1.00}
    if frac == 0.20:
        return {"pH":1.00}
    if frac == 0.30:
        return {"pH":1.00}
    if frac == 0.40:
        return {"pH":1.00}
    if frac == 0.50:
        return {"H":0.20, "V":0.80}
    if frac == 0.60:
        return {"V":1.00}
    if frac == 0.70:
        return {"V":1.00}
    if frac == 0.75:
        return {"pH":0.10, "H":0.10, "V":0.80}
    if frac == 0.80:
        return {"pH":0.20, "V":0.80}
    if frac == 0.90:
        return {"pH":0.80, "V":0.20}
    if frac == 1.00:
        return {"p":1.00}
    return {"pH":1.00}

def run_dataset(name, raw_path, split_kind, cols, out_prefix):
    rows = read_csv(raw_path)

    if split_kind == "large":
        add_large_random(rows)

    if split_kind == "controlled":
        cal_rows = [r for r in rows if r.get("split") == "train"]
        eval_rows = [r for r in rows if r.get("split") == "eval"]
        score_cols = {
            "p": cols["p"],
            "H": cols["H"],
            "pH": cols["pH"],
            "V": cols["V"],
        }
        baseline_cols = {
            "Random": "score_random",
            "p-only": cols["p"],
            "H-only": cols["H"],
            "PRM/process": cols["P"],
            "Reward/value": cols["V"],
            "Learned router": cols["L"],
        }
    else:
        cal_rows = [r for r in rows if 4200 <= int(fnum(r.get("seed"))) <= 4299]
        eval_rows = [r for r in rows if 4300 <= int(fnum(r.get("seed"))) <= 4499]
        score_cols = {
            "p": cols["p"],
            "H": cols["H"],
            "pH": cols["pH"],
            "V": cols["V"],
        }
        baseline_cols = {
            "Random": "_score_random",
            "p-only": cols["p"],
            "H-only": cols["H"],
            "PRM/process": cols["P"],
            "Reward/value": cols["V"],
            "Learned router": cols["L"],
        }

    v_usable = usable(cal_rows, cols["V"])

    method_mode = ("EVVA_2C-value-available-residual" if v_usable else "EVVA_2C-locked-BG-fallback")

    out_rows = []

    for b in BUDGETS:
        if v_usable:
            if b in (0.60, 0.70):
                val, disagreement, epsilon = (
                    calibration_gated_residual_value(
                        cal_rows=cal_rows,
                        eval_rows=eval_rows,
                        primary_col=cols["V"],
                        pH_col=cols["pH"],
                        frac=b,
                        max_epsilon=0.10,
                    )
                )

                q = {}

                policy_desc = (
                    "EVVA_2B calibration-gated scalar blend "
                    f"V-primary;D={disagreement:.6f};"
                    f"epsilon={epsilon:.6f} [tie-aware]"
                )
            else:
                q = value_aware_schedule(b)

                active = [
                    (key, weight)
                    for key, weight in q.items()
                    if weight > 1e-12
                ]

                if len(active) == 1:
                    only = active[0][0]

                    val = scalar_tieaware(
                        eval_rows,
                        score_cols[only],
                        b,
                    )

                    policy_desc = (
                        ";".join(
                            f"{key}:{weight:.2f}"
                            for key, weight in sorted(q.items())
                        )
                        + " [tie-aware single-score]"
                    )
                else:
                    val = portfolio_value(
                        eval_rows,
                        score_cols,
                        q,
                        b,
                    )

                    policy_desc = ";".join(
                        f"{key}:{weight:.2f}"
                        for key, weight in sorted(q.items())
                    )
        else:
            # When V is unavailable, preserve the fully audited
            # locked v5m BG fallback at every budget.
            val = bg_value(
                cal_rows,
                eval_rows,
                cols["pH"],
                cols["H"],
                b,
            )

            q = {}

            policy_desc = (
                "Locked v5m BG fallback "
                "because V is unavailable"
            )

        best_name, best_val = best_baseline(eval_rows, baseline_cols, b)

        row = {
            "dataset": name,
            "budget": pct(b),
            "B": exact_B(len(eval_rows), b),
            "method_mode": method_mode,
            "policy": policy_desc,
            "EVVA_SAG": f"{val:.4f}",
            "best_baseline": best_name,
            "best_baseline_value": f"{best_val:.4f}",
            "SAG_minus_best_baseline": f"{val - best_val:.4f}",
            "SAG_win_tie_all_baselines": str(val >= best_val - 1e-9),
        }

        for m,c in baseline_cols.items():
            safe = m.replace("/","_").replace("-","_").replace(" ","_")
            row[safe] = f"{scalar_tieaware(eval_rows, c, b):.4f}"

        out_rows.append(row)

    out_dir = ROOT / out_prefix
    result_path = out_dir / "tables" / f"{name}_v5k_signal_availability_gated_evva.csv"

    fields = [
        "dataset","budget","B","method_mode","policy","EVVA_SAG",
        "best_baseline","best_baseline_value","SAG_minus_best_baseline",
        "SAG_win_tie_all_baselines",
    ] + [m.replace("/","_").replace("-","_").replace(" ","_") for m in baseline_cols]

    write_csv(result_path, out_rows, fields)

    n = len(out_rows)
    n_win = sum(1 for r in out_rows if r["SAG_win_tie_all_baselines"] == "True")

    uniq_v, var_v = score_stats(cal_rows, cols["V"])

    md = []
    md.append(f"# EVVA_2C Value-Available Residual Report: {name}")
    md.append("")
    md.append(f"- Raw: `{raw_path}`")
    md.append(f"- Calibration rows: {len(cal_rows)}")
    md.append(f"- Evaluation rows: {len(eval_rows)}")
    md.append(f"- V score usable on calibration: **{v_usable}**")
    md.append(f"- V unique values: {uniq_v}")
    md.append(f"- V variance: {var_v:.12f}")
    md.append(f"- Selected method mode: **{method_mode}**")
    md.append("- EVVA_2C applies the calibration-only residual pH core only when V is usable; otherwise it preserves the locked v5m BG fallback.")
    md.append("- Random is never used as a method signal. Baselines include Random, p-only, H-only, PRM/process, Reward/value, Learned router.")
    md.append("")
    md.append("## Summary")
    md.append("")
    md.append(f"- EVVA_2C wins/ties all baselines on **{n_win} / {n}** budgets.")
    md.append("")
    md.append("## Budget table")
    md.append("")
    md.append("| Budget | Mode | Policy | EVVA-SAG | Best baseline | Δ | Win/tie? |")
    md.append("|---|---|---|---:|---|---:|---|")
    for r in out_rows:
        md.append(
            f"| {r['budget']} | {r['method_mode']} | `{r['policy']}` | {r['EVVA_SAG']} | "
            f"{r['best_baseline']}={r['best_baseline_value']} | "
            f"{r['SAG_minus_best_baseline']} | {r['SAG_win_tie_all_baselines']} |"
        )

    md.append("")
    md.append("## Output files")
    md.append("")
    md.append(f"- `{result_path}`")

    report_path = out_dir / "reports" / f"{name}_v5k_signal_availability_gated_evva_report.md"
    report_path.write_text("\n".join(md))

    print("DONE", name)
    print(report_path)
    print(result_path)

def main():
    run_dataset(
        "controlled",
        CONTROLLED_RAW,
        "controlled",
        {
            "p": "score_p_only",
            "H": "score_H_only",
            "pH": "score_p_times_H",
            "P": "score_prm_task_fail",
            "V": "score_prm_value_gain",
            "L": "score_value_router",
        },
        "controlled",
    )

    run_dataset(
        "large",
        LARGE_RAW,
        "large",
        {
            "p": "p_score",
            "H": "harm_score",
            "pH": "p_times_H_score",
            "P": "PRM_task_surrogate",
            "V": "PRM_value_surrogate",
            "L": "value_router_surrogate",
        },
        "large",
    )

if __name__ == "__main__":
    main()

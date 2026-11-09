#!/usr/bin/env python3
import csv, math, random, bisect
from pathlib import Path
from collections import defaultdict

ROOT = Path("artifacts/evva_v5d_budget_gated_evva_20260709")

CONTROLLED_RAW = Path("artifacts/evva_gate1_value_router_20260615/value_router_train_eval_rows.csv")
LARGE_RAW = Path("artifacts/v4_full_agent_20260707/large/full_agent_candidate_rows_large.csv")

CONTROLLED_LAMBDA = ROOT / "controlled" / "tables" / "controlled_evva_bg_lambdas.csv"
LARGE_LAMBDA = ROOT / "large" / "tables" / "large_evva_bg_lambdas.csv"

BUDGETS = [0.05, 0.10, 0.20, 0.30, 0.40, 0.50, 0.75]
PRIMARY = [0.05, 0.10, 0.20, 0.30, 0.40, 0.50]
LABEL = "intervention_gain"
N_BOOT = 10000
RNG_SEED = 20260709

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

def regime_of_budget(b):
    if b <= 0.10:
        return "ultra"
    if b <= 0.30:
        return "moderate"
    return "broad"

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

def exact_B(n, frac):
    return max(1, min(int(round(frac * n)), n))

def scalar_tieaware(rows, score_col, frac):
    n = len(rows)
    B = exact_B(n, frac)
    vals = [(fnum(r.get(score_col)), fnum(r.get(LABEL))) for r in rows]
    vals.sort(key=lambda x: x[0], reverse=True)

    cutoff = vals[B - 1][0]
    above = [(s, y) for s, y in vals if s > cutoff]
    tied = [(s, y) for s, y in vals if s == cutoff]
    need = B - len(above)

    total = sum(y for _, y in above)
    if need > 0 and tied:
        total += (need / len(tied)) * sum(y for _, y in tied)

    return total, total / B

def percentile_setup(cal_rows, col):
    return sorted(fnum(r.get(col)) for r in cal_rows)

def percentile(vals, x):
    n = len(vals)
    lo = bisect.bisect_left(vals, x)
    hi = bisect.bisect_right(vals, x)
    return (lo + 0.5 * (hi - lo)) / n

def add_norm(cal_rows, rows, pH_col, H_col):
    pH_vals = percentile_setup(cal_rows, pH_col)
    H_vals = percentile_setup(cal_rows, H_col)
    for r in rows:
        r["_norm_pH"] = percentile(pH_vals, fnum(r.get(pH_col)))
        r["_norm_H"] = percentile(H_vals, fnum(r.get(H_col)))
        r["_EVVA_BG_score"] = 0.0

def load_lambdas(path):
    rows = read_csv(path)
    out = {}
    for r in rows:
        if r.get("regime") in {"ultra", "moderate", "broad"}:
            out[r["regime"]] = fnum(r["lambda_H"])
    if set(out) != {"ultra", "moderate", "broad"}:
        raise RuntimeError(f"Missing lambda regimes in {path}: {out}")
    return out

def set_bg(rows, lambdas, b):
    lam = lambdas[regime_of_budget(b)]
    for r in rows:
        r["_EVVA_BG_score"] = (1.0 - lam) * r["_norm_pH"] + lam * r["_norm_H"]

def quantile(xs, q):
    ys = sorted(xs)
    pos = q * (len(ys) - 1)
    lo = int(math.floor(pos))
    hi = int(math.ceil(pos))
    if lo == hi:
        return ys[lo]
    return ys[lo] * (hi - pos) + ys[hi] * (pos - lo)

def bootstrap_dataset(name, raw_path, lambda_path, split_kind, cols, out_dir):
    rows = read_csv(raw_path)

    if split_kind == "controlled":
        cal_rows = [r for r in rows if r.get("split") == "train"]
        eval_rows = [r for r in rows if r.get("split") == "eval"]
    elif split_kind == "large":
        cal_rows = [r for r in rows if 4200 <= int(fnum(r.get("seed"))) <= 4299]
        eval_rows = [r for r in rows if 4300 <= int(fnum(r.get("seed"))) <= 4499]
    else:
        raise ValueError(split_kind)

    add_norm(cal_rows, eval_rows, cols["pH"], cols["H"])
    lambdas = load_lambdas(lambda_path)

    baselines = [
        ("EVVA-EH", cols["pH"]),
        ("H-only", cols["H"]),
        ("p-only", cols["p"]),
    ]

    point = {}
    point_rows = []

    for b in BUDGETS:
        set_bg(eval_rows, lambdas, b)
        bg_total, bg_avg = scalar_tieaware(eval_rows, "_EVVA_BG_score", b)
        point[("EVVA-BG", b)] = (bg_total, bg_avg)
        point_rows.append({
            "method": "EVVA-BG",
            "budget": pct(b),
            "total_gain": f"{bg_total:.6f}",
            "avg_gain": f"{bg_avg:.6f}",
        })

        for method, col in baselines:
            total, avg = scalar_tieaware(eval_rows, col, b)
            point[(method, b)] = (total, avg)
            point_rows.append({
                "method": method,
                "budget": pct(b),
                "total_gain": f"{total:.6f}",
                "avg_gain": f"{avg:.6f}",
            })

    write_csv(out_dir / f"{name}_evva_bg_point_estimates.csv", point_rows, ["method", "budget", "total_gain", "avg_gain"])

    groups = defaultdict(list)
    for r in eval_rows:
        groups[r.get("seed", "")].append(r)
    keys = sorted(groups)
    rng = random.Random(RNG_SEED)

    comparisons = []
    for b in BUDGETS:
        for method, _col in baselines:
            comparisons.append((b, f"BG minus {method}", method))

    avg_samples = {c: [] for c in comparisons}
    total_samples = {c: [] for c in comparisons}

    for _ in range(N_BOOT):
        sampled = []
        for _k in keys:
            kk = rng.choice(keys)
            sampled.extend(groups[kk])

        for b in BUDGETS:
            set_bg(sampled, lambdas, b)
            bg_total, bg_avg = scalar_tieaware(sampled, "_EVVA_BG_score", b)

            base = {}
            for method, col in baselines:
                base[method] = scalar_tieaware(sampled, col, b)

            for comp in comparisons:
                cb, _cname, method = comp
                if abs(cb - b) > 1e-12:
                    continue
                base_total, base_avg = base[method]
                avg_samples[comp].append(bg_avg - base_avg)
                total_samples[comp].append(bg_total - base_total)

    rows_out = []
    for b, cname, method in comparisons:
        xs = avg_samples[(b, cname, method)]
        ts = total_samples[(b, cname, method)]
        rows_out.append({
            "dataset": name,
            "budget": pct(b),
            "comparison": cname,
            "n_boot": N_BOOT,
            "avg_delta_point": f"{point[('EVVA-BG', b)][1] - point[(method, b)][1]:.6f}",
            "avg_delta_mean": f"{sum(xs)/len(xs):.6f}",
            "avg_delta_p025": f"{quantile(xs, 0.025):.6f}",
            "avg_delta_p975": f"{quantile(xs, 0.975):.6f}",
            "avg_prob_delta_gt_0": f"{sum(1 for x in xs if x > 0) / len(xs):.6f}",
            "total_delta_point": f"{point[('EVVA-BG', b)][0] - point[(method, b)][0]:.6f}",
            "total_delta_mean": f"{sum(ts)/len(ts):.6f}",
            "total_delta_p025": f"{quantile(ts, 0.025):.6f}",
            "total_delta_p975": f"{quantile(ts, 0.975):.6f}",
            "total_prob_delta_gt_0": f"{sum(1 for x in ts if x > 0) / len(ts):.6f}",
        })

    boot_path = out_dir / f"{name}_evva_bg_bootstrap.csv"
    write_csv(
        boot_path,
        rows_out,
        [
            "dataset", "budget", "comparison", "n_boot",
            "avg_delta_point", "avg_delta_mean", "avg_delta_p025", "avg_delta_p975", "avg_prob_delta_gt_0",
            "total_delta_point", "total_delta_mean", "total_delta_p025", "total_delta_p975", "total_prob_delta_gt_0",
        ],
    )

    vs_eh = [
        r for r in rows_out
        if r["comparison"] == "BG minus EVVA-EH" and r["budget"] in {pct(b) for b in PRIMARY}
    ]

    point_positive = sum(1 for r in vs_eh if fnum(r["avg_delta_point"]) > 0)
    ci_positive = sum(1 for r in vs_eh if fnum(r["avg_delta_p025"]) > 0)
    avg_prob = sum(fnum(r["avg_prob_delta_gt_0"]) for r in vs_eh) / len(vs_eh)

    vs_h = [
        r for r in rows_out
        if r["comparison"] == "BG minus H-only" and r["budget"] in {pct(b) for b in PRIMARY}
    ]
    avg_prob_h = sum(fnum(r["avg_prob_delta_gt_0"]) for r in vs_h) / len(vs_h)

    md = []
    md.append(f"# v5d EVVA-BG Bootstrap Report: {name}")
    md.append("")
    md.append(f"- Raw: `{raw_path}`")
    md.append(f"- Lambda schedule: `{lambda_path}`")
    md.append(f"- Calibration rows: {len(cal_rows)}")
    md.append(f"- Evaluation rows: {len(eval_rows)}")
    md.append("- Formula: `(1-lambda_g(B)) normalized(pH) + lambda_g(B) normalized(H)`")
    md.append("- Regimes: ultra = 5/10, moderate = 20/30, broad = 40/50/75")
    md.append(f"- Bootstrap unit: eval seed group")
    md.append(f"- n_boot: {N_BOOT}")
    md.append("")
    md.append("## EVVA-BG vs EVVA-EH")
    md.append("")
    md.append("| Budget | Point Δ avg | Mean Δ avg | 95% CI avg | P(avg Δ>0) | Point Δ total |")
    md.append("|---|---:|---:|---:|---:|---:|")
    for r in [x for x in rows_out if x["comparison"] == "BG minus EVVA-EH"]:
        md.append(
            f"| {r['budget']} | {r['avg_delta_point']} | {r['avg_delta_mean']} | "
            f"[{r['avg_delta_p025']}, {r['avg_delta_p975']}] | {r['avg_prob_delta_gt_0']} | {r['total_delta_point']} |"
        )

    md.append("")
    md.append("## Gate interpretation")
    md.append("")
    md.append(f"- Primary-budget point-positive count vs EVVA-EH: {point_positive} / {len(PRIMARY)}")
    md.append(f"- Primary-budget CI-positive count vs EVVA-EH: {ci_positive} / {len(PRIMARY)}")
    md.append(f"- Avg P(avg Δ>0) over 5%--50% vs EVVA-EH: {avg_prob:.4f}")
    md.append(f"- Avg P(avg Δ>0) over 5%--50% vs H-only: {avg_prob_h:.4f}")
    md.append("")
    if name == "large" and (ci_positive >= 2 or avg_prob >= 0.60):
        md.append("Large bootstrap supports EVVA-BG as a serious budget-aware extension.")
    elif name == "controlled" and avg_prob >= 0.45:
        md.append("Controlled bootstrap shows a tradeoff rather than a clean replacement. Use EVVA-BG as a budget-aware extension, not as a claim that EVVA-EH is dominated.")
    else:
        md.append("Bootstrap support is weak. Avoid claiming universal dominance.")
    md.append("")
    md.append(f"Full bootstrap CSV: `{boot_path}`")

    report_path = out_dir / f"{name}_evva_bg_bootstrap_report.md"
    report_path.write_text("\n".join(md))

    print("DONE", name)
    print(report_path)
    print(boot_path)

def main():
    bootstrap_dataset(
        "controlled",
        CONTROLLED_RAW,
        CONTROLLED_LAMBDA,
        "controlled",
        {"p": "score_p_only", "H": "score_H_only", "pH": "score_p_times_H"},
        ROOT / "controlled" / "bootstrap",
    )

    bootstrap_dataset(
        "large",
        LARGE_RAW,
        LARGE_LAMBDA,
        "large",
        {"p": "p_score", "H": "harm_score", "pH": "p_times_H_score"},
        ROOT / "large" / "bootstrap",
    )

if __name__ == "__main__":
    main()

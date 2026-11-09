#!/usr/bin/env python3
import csv
import math
from pathlib import Path
from collections import defaultdict

ROOT = Path(".")
OUT_ROOT = Path("artifacts/aaai_v5j_fair_controlled_prm_20260709")
OUT_ROOT.mkdir(parents=True, exist_ok=True)
(OUT_ROOT / "tables").mkdir(parents=True, exist_ok=True)
(OUT_ROOT / "reports").mkdir(parents=True, exist_ok=True)

ORIG_CONTROLLED = Path("artifacts/aaai_gate1_value_router_20260615/value_router_train_eval_rows.csv")

BASE_RAW = Path("artifacts/v5_20260522/locked/table5_ablation_exactTopB150_20260523/v5_table5_ablation_exactTopB150_raw.csv")
REPL_RAW = Path("artifacts/v5_20260522/locked/table5_ablation_exactTopB150_20260523/v5_table5_ablation_exactTopB150_replacements_raw.csv")
JOINT_MISSING_RAW = Path("artifacts/v5_20260522/locked/table_joint_calibration_20260523/joint_calibration_missing_outcomes_raw.csv")
PRM_CAL_MISSING_RAW = Path("artifacts/v5_20260522/locked/table_prm_baseline_20260523/prm_cal_missing_outcomes_raw.csv")

CAL_SEEDS = set(range(20, 120))
EVAL_SEEDS = set(range(120, 320))

FEATURES = [
    "p_score",
    "harm_score",
    "p_times_H_score",
    "downstream_dependency_count",
    "rollback_difficulty",
    "persistent_state_risk",
    "downstream_failure_penalty",
]

def fl(x, default=0.0):
    try:
        s = str(x).strip()
        if s == "":
            return default
        y = float(s)
        return y if math.isfinite(y) else default
    except Exception:
        return default

def read_csv(p):
    with p.open(newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))

def write_csv(p, rows, fields):
    p.parent.mkdir(parents=True, exist_ok=True)
    with p.open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        for r in rows:
            w.writerow(r)

def mean(xs):
    return sum(xs) / len(xs) if xs else 0.0

def sigmoid(z):
    if z < -40:
        return 0.0
    if z > 40:
        return 1.0
    return 1.0 / (1.0 + math.exp(-z))

def standardize_train_eval(X_train, X_all):
    cols = len(X_train[0])
    mu, sd = [], []
    for j in range(cols):
        vals = [x[j] for x in X_train]
        m = mean(vals)
        v = mean([(x - m) ** 2 for x in vals])
        s = math.sqrt(v) if v > 1e-12 else 1.0
        mu.append(m)
        sd.append(s)

    def trans(X):
        return [[(row[j] - mu[j]) / sd[j] for j in range(cols)] for row in X]

    return trans(X_train), trans(X_all), mu, sd

def fit_logistic_soft(X, y, lr=0.05, epochs=3000, l2=1e-3):
    n = len(X)
    d = len(X[0])
    w = [0.0] * (d + 1)

    for _ in range(epochs):
        grad = [0.0] * (d + 1)
        for xi, yi in zip(X, y):
            z = w[0] + sum(w[j+1] * xi[j] for j in range(d))
            p = sigmoid(z)
            err = p - yi
            grad[0] += err
            for j in range(d):
                grad[j+1] += err * xi[j]

        grad[0] /= n
        for j in range(1, d + 1):
            grad[j] = grad[j] / n + l2 * w[j]

        for j in range(d + 1):
            w[j] -= lr * grad[j]

    return w

def predict_logistic(w, X):
    d = len(w) - 1
    out = []
    for xi in X:
        z = w[0] + sum(w[j+1] * xi[j] for j in range(d))
        out.append(sigmoid(z))
    return out

# Load source rows exactly like the locked PRM script, but output both cal and eval predictions.
all_rows = []
for p in [BASE_RAW, REPL_RAW, JOINT_MISSING_RAW, PRM_CAL_MISSING_RAW]:
    part = read_csv(p)
    print("Loaded", len(part), "rows from", p)
    all_rows.extend(part)

base_rows = read_csv(BASE_RAW)
feature_rows = {}
for r in base_rows:
    if r.get("policy") == "p_times_H":
        feature_rows[int(fl(r["seed"]))] = r

pool = defaultdict(lambda: defaultdict(list))
for r in all_rows:
    s = int(fl(r["seed"]))
    v = int(fl(r["verify_used"]))
    pool[s][v].append(r)

def canonical(seed, verify):
    rows = pool[seed][verify]
    if not rows:
        raise RuntimeError(f"Missing outcome for seed={seed}, verify={verify}")

    if verify == 0:
        preferred = [r for r in rows if r.get("policy") == "no_verify"]
    else:
        preferred = [r for r in rows if r.get("policy") == "always_verify"]

    cand = preferred if preferred else rows
    cand = sorted(cand, key=lambda r: r.get("episode_id", ""))
    return dict(cand[0])

for name, seeds in [("cal", CAL_SEEDS), ("eval", EVAL_SEEDS)]:
    miss = []
    for s in sorted(seeds):
        if s not in feature_rows:
            miss.append((s, "feature"))
        if 0 not in pool[s]:
            miss.append((s, "unverified"))
        if 1 not in pool[s]:
            miss.append((s, "verified"))
    if miss:
        raise RuntimeError(f"{name} split missing entries: {miss[:20]}")
    print(name, "split complete:", len(seeds), "seeds")

def get_features(seed):
    r = feature_rows[seed]
    return [fl(r[c]) for c in FEATURES]

train_seeds = sorted(CAL_SEEDS)
eval_seeds = sorted(EVAL_SEEDS)
all_seeds = train_seeds + eval_seeds

X_train_raw = [get_features(s) for s in train_seeds]
X_all_raw = [get_features(s) for s in all_seeds]
X_train, X_all, mu, sd = standardize_train_eval(X_train_raw, X_all_raw)

task_fail_y = []
value_gain_raw = []
for s in train_seeds:
    u = canonical(s, 0)
    v = canonical(s, 1)
    task_fail_y.append(1.0 - fl(u["success"]))
    value_gain_raw.append(max(0.0, fl(v["net_reward"]) - fl(u["net_reward"])))

max_gain = max(value_gain_raw) if value_gain_raw else 1.0
if max_gain <= 1e-12:
    max_gain = 1.0
value_gain_y = [g / max_gain for g in value_gain_raw]

w_task = fit_logistic_soft(X_train, task_fail_y)
w_value = fit_logistic_soft(X_train, value_gain_y)

score_task_all = predict_logistic(w_task, X_all)
score_value_all = predict_logistic(w_value, X_all)

pred_by_seed = {}
pred_rows = []
for s, st, sv in zip(all_seeds, score_task_all, score_value_all):
    fr = feature_rows[s]
    split = "train" if s in CAL_SEEDS else "eval"
    pred_by_seed[s] = (st, sv)
    pred_rows.append({
        "seed": s,
        "split": split,
        "p_score": fl(fr["p_score"]),
        "harm_score": fl(fr["harm_score"]),
        "p_times_H_score": fl(fr["p_times_H_score"]),
        "prm_task_fail_score": st,
        "prm_value_gain_score": sv,
    })

pred_path = OUT_ROOT / "tables" / "fair_prm_predictions_train_eval.csv"
write_csv(
    pred_path,
    pred_rows,
    ["seed", "split", "p_score", "harm_score", "p_times_H_score", "prm_task_fail_score", "prm_value_gain_score"],
)

# Patch original controlled rows without mutating old artifact.
orig = read_csv(ORIG_CONTROLLED)
patched = []
for r in orig:
    rr = dict(r)
    s = int(fl(rr["seed"]))
    if s not in pred_by_seed:
        raise RuntimeError(f"Missing PRM prediction for seed={s}")
    st, sv = pred_by_seed[s]

    rr["prm_task_fail_score"] = f"{st:.17g}"
    rr["prm_value_gain_score"] = f"{sv:.17g}"
    rr["score_prm_task_fail"] = f"{st:.17g}"
    rr["score_prm_value_gain"] = f"{sv:.17g}"

    patched.append(rr)

fair_path = OUT_ROOT / "fair_controlled_train_eval_rows.csv"
fields = list(orig[0].keys())
write_csv(fair_path, patched, fields)

def stats(rows, col):
    vals = [fl(r.get(col)) for r in rows]
    meanv = mean(vals)
    var = mean([(x - meanv) ** 2 for x in vals])
    return {
        "n": len(vals),
        "unique": len(set(vals)),
        "var": var,
        "min": min(vals),
        "max": max(vals),
    }

audit_rows = []
for split in ["train", "eval", "all"]:
    if split == "all":
        rs = patched
    else:
        rs = [r for r in patched if r.get("split") == split]
    for col in ["score_prm_task_fail", "score_prm_value_gain", "score_value_router", "score_p_times_H", "intervention_gain"]:
        st = stats(rs, col)
        audit_rows.append({
            "split": split,
            "column": col,
            "n": st["n"],
            "unique": st["unique"],
            "variance": f"{st['var']:.12f}",
            "min": f"{st['min']:.6f}",
            "max": f"{st['max']:.6f}",
            "usable": str(st["unique"] > 5 and st["var"] > 1e-12),
        })

audit_path = OUT_ROOT / "tables" / "fair_controlled_score_variation_audit.csv"
write_csv(
    audit_path,
    audit_rows,
    ["split", "column", "n", "unique", "variance", "min", "max", "usable"],
)

md = []
md.append("# v5j Fair Controlled PRM Rebuild")
md.append("")
md.append(f"- Source controlled rows: `{ORIG_CONTROLLED}`")
md.append(f"- Output fair rows: `{fair_path}`")
md.append(f"- PRM predictions: `{pred_path}`")
md.append(f"- Score variation audit: `{audit_path}`")
md.append("")
md.append("## Score variation")
md.append("")
md.append("| Split | Column | n | Unique | Variance | Min | Max | Usable? |")
md.append("|---|---|---:|---:|---:|---:|---:|---|")
for r in audit_rows:
    md.append(
        f"| {r['split']} | `{r['column']}` | {r['n']} | {r['unique']} | "
        f"{r['variance']} | {r['min']} | {r['max']} | {r['usable']} |"
    )

report_path = OUT_ROOT / "reports" / "v5j_fair_controlled_prm_rebuild_report.md"
report_path.write_text("\n".join(md), encoding="utf-8")

print("DONE fair controlled rebuild")
print(fair_path)
print(pred_path)
print(audit_path)
print(report_path)

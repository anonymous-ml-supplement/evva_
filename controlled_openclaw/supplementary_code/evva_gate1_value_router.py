#!/usr/bin/env python3
import argparse
import csv
import math
import random
from pathlib import Path
from collections import defaultdict

def fl(x, default=0.0):
    try:
        if x is None or x == "":
            return default
        return float(x)
    except Exception:
        return default

def safe_int(x, default=None):
    try:
        return int(float(x))
    except Exception:
        return default

def percentile(vals, q):
    vals = sorted(vals)
    if not vals:
        return 0.0
    if len(vals) == 1:
        return vals[0]
    pos = q * (len(vals) - 1)
    lo = int(math.floor(pos))
    hi = int(math.ceil(pos))
    if lo == hi:
        return vals[lo]
    w = pos - lo
    return vals[lo] * (1 - w) + vals[hi] * w

def mean(vals):
    vals = list(vals)
    return sum(vals) / len(vals) if vals else 0.0

def read_csv(path):
    with open(path, newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))

def write_csv(path, rows, fieldnames):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames)
        w.writeheader()
        for r in rows:
            w.writerow({k: r.get(k, "") for k in fieldnames})

def build_base_rows(table5_raw):
    raw = read_csv(table5_raw)

    by_seed = {}
    for r in raw:
        seed = safe_int(r.get("seed"))
        if seed is None:
            continue
        if seed not in by_seed:
            rw = fl(r.get("reward_wrong_continuation"))
            rc = fl(r.get("reward_corrected_continuation"))
            gain = rc - rw
            if abs(gain) < 1e-12:
                gain = fl(r.get("branch_harm_exact"))

            public_label = str(r.get("public_risk_label", "")).lower()
            row = {
                "seed": seed,
                "split": "train" if 20 <= seed <= 119 else ("eval" if 120 <= seed <= 319 else "other"),
                "case": r.get("case", ""),
                "p_score": fl(r.get("p_score")),
                "harm_score": fl(r.get("harm_score")),
                "p_times_H_score": fl(r.get("p_times_H_score")),
                "downstream_dependency_count": fl(r.get("downstream_dependency_count")),
                "rollback_difficulty": fl(r.get("rollback_difficulty")),
                "persistent_state_risk": fl(r.get("persistent_state_risk")),
                "estimated_harm_score": fl(r.get("estimated_harm_score")),
                "downstream_failure_penalty": fl(r.get("downstream_failure_penalty")),
                "public_risk_low": 1.0 if public_label == "low" else 0.0,
                "public_risk_medium": 1.0 if public_label == "medium" else 0.0,
                "public_risk_high": 1.0 if public_label == "high" else 0.0,
                "reward_wrong_continuation": rw,
                "reward_corrected_continuation": rc,
                "intervention_gain": gain,
                "branch_harm_exact": fl(r.get("branch_harm_exact")),
            }
            by_seed[seed] = row

    rows = [by_seed[s] for s in sorted(by_seed)]
    return rows

def merge_prm_scores(rows, prm_decisions):
    if not prm_decisions.exists():
        return

    raw = read_csv(prm_decisions)
    by_seed = {}
    for r in raw:
        seed = safe_int(r.get("seed"))
        if seed is None:
            continue
        if seed not in by_seed:
            by_seed[seed] = {
                "prm_task_fail_score": fl(r.get("prm_task_fail_score")),
                "prm_value_gain_score": fl(r.get("prm_value_gain_score")),
            }

    for r in rows:
        m = by_seed.get(r["seed"], {})
        r["prm_task_fail_score"] = m.get("prm_task_fail_score", "")
        r["prm_value_gain_score"] = m.get("prm_value_gain_score", "")

def merge_cal_scores(rows, cal_decisions):
    if not cal_decisions.exists():
        return

    raw = read_csv(cal_decisions)
    by_seed = {}
    for r in raw:
        seed = safe_int(r.get("seed"))
        if seed is None:
            continue
        if seed not in by_seed:
            by_seed[seed] = {
                "p_cal": fl(r.get("p_cal")),
                "H_cal": fl(r.get("H_cal")),
                "p_times_H_calibrated_score": fl(r.get("p_times_H_calibrated_score")),
            }

    for r in rows:
        m = by_seed.get(r["seed"], {})
        r["p_cal"] = m.get("p_cal", "")
        r["H_cal"] = m.get("H_cal", "")
        r["p_times_H_calibrated_score"] = m.get("p_times_H_calibrated_score", "")

def train_linear_gd(train_rows, feature_names, target_name, epochs=4000, lr=0.04, l2=0.01):
    n = len(train_rows)
    if n == 0:
        raise RuntimeError("No training rows.")

    means = {}
    stds = {}
    for f in feature_names:
        vals = [fl(r.get(f)) for r in train_rows]
        mu = mean(vals)
        var = mean([(v - mu) ** 2 for v in vals])
        sd = math.sqrt(var) if var > 1e-12 else 1.0
        means[f] = mu
        stds[f] = sd

    ys = [fl(r.get(target_name)) for r in train_rows]
    y_mu = mean(ys)
    y_sd = math.sqrt(mean([(y - y_mu) ** 2 for y in ys])) if len(ys) > 1 else 1.0
    if y_sd < 1e-12:
        y_sd = 1.0

    X = []
    Y = []
    for r, y in zip(train_rows, ys):
        X.append([(fl(r.get(f)) - means[f]) / stds[f] for f in feature_names])
        Y.append((y - y_mu) / y_sd)

    w = [0.0] * (len(feature_names) + 1)

    for _ in range(epochs):
        grad = [0.0] * len(w)
        for x, y in zip(X, Y):
            pred = w[0] + sum(w[i + 1] * x[i] for i in range(len(feature_names)))
            err = pred - y
            grad[0] += err
            for i in range(len(feature_names)):
                grad[i + 1] += err * x[i]
        grad[0] /= n
        for i in range(1, len(w)):
            grad[i] = grad[i] / n + l2 * w[i]
        for i in range(len(w)):
            w[i] -= lr * grad[i]

    def predict(row):
        x = [(fl(row.get(f)) - means[f]) / stds[f] for f in feature_names]
        yz = w[0] + sum(w[i + 1] * x[i] for i in range(len(feature_names)))
        return yz * y_sd + y_mu

    return predict, w

def add_model_scores(rows):
    train = [r for r in rows if r["split"] == "train"]

    value_features = [
        "p_score",
        "harm_score",
        "p_times_H_score",
        "downstream_dependency_count",
        "rollback_difficulty",
        "persistent_state_risk",
        "estimated_harm_score",
        "downstream_failure_penalty",
        "public_risk_low",
        "public_risk_medium",
        "public_risk_high",
    ]

    risk_features = [
        "harm_score",
        "downstream_dependency_count",
        "rollback_difficulty",
        "persistent_state_risk",
        "estimated_harm_score",
        "downstream_failure_penalty",
    ]

    final_reward_features = value_features

    pred_value, _ = train_linear_gd(train, value_features, "intervention_gain")
    pred_risk, _ = train_linear_gd(train, risk_features, "intervention_gain")

    # Deliberately not a contrastive intervention label:
    # this predicts how bad the unverified continuation is.
    for r in rows:
        r["skip_loss_label"] = max(0.0, -fl(r.get("reward_wrong_continuation")))

    pred_final, _ = train_linear_gd(train, final_reward_features, "skip_loss_label")

    for r in rows:
        r["score_random"] = random.Random(1000003 + int(r["seed"])).random()
        r["score_p_only"] = fl(r.get("p_score"))
        r["score_H_only"] = fl(r.get("harm_score"))
        r["score_p_times_H"] = fl(r.get("p_times_H_score"))
        r["score_calibrated_p_times_H"] = fl(r.get("p_times_H_calibrated_score"))
        r["score_prm_task_fail"] = fl(r.get("prm_task_fail_score"))
        r["score_prm_value_gain"] = fl(r.get("prm_value_gain_score"))
        r["score_risk_only_learned"] = pred_risk(r)
        r["score_final_reward_model"] = pred_final(r)
        r["score_value_router"] = pred_value(r)
        r["score_oracle_gain"] = fl(r.get("intervention_gain"))

def evaluate_policy(rows, score_name, budget_frac, high_harm_threshold):
    n = len(rows)
    B = max(1, int(round(budget_frac * n)))
    ranked = sorted(rows, key=lambda r: (-fl(r.get(score_name)), int(r["seed"])))
    selected = set(int(r["seed"]) for r in ranked[:B])

    oracle_ranked = sorted(rows, key=lambda r: (-fl(r.get("intervention_gain")), int(r["seed"])))
    oracle_gain = sum(fl(r.get("intervention_gain")) for r in oracle_ranked[:B])

    selected_gain = 0.0
    rewards = []
    irrev = []
    success = []
    selected_harms = []
    skipped_harms = []

    high_total = 0
    high_selected = 0

    for r in rows:
        seed = int(r["seed"])
        gain = fl(r.get("intervention_gain"))
        branch_harm = fl(r.get("branch_harm_exact"))
        wrong = fl(r.get("reward_wrong_continuation"))
        corrected = fl(r.get("reward_corrected_continuation"))

        is_high = branch_harm >= high_harm_threshold
        if is_high:
            high_total += 1

        if seed in selected:
            selected_gain += gain
            rewards.append(corrected)
            irrev.append(0.0)
            success.append(1.0 if corrected >= 0 else 0.0)
            selected_harms.append(branch_harm)
            if is_high:
                high_selected += 1
        else:
            rewards.append(wrong)
            irrev.append(1.0 if (branch_harm > 0 and wrong < 0) else 0.0)
            success.append(1.0 if wrong >= 0 else 0.0)
            skipped_harms.append(branch_harm)

    return {
        "n": n,
        "B": B,
        "budget_frac": budget_frac,
        "verify_rate": B / n,
        "success": mean(success),
        "irreversible_failure": mean(irrev),
        "avg_net_reward": mean(rewards),
        "selected_total_gain": selected_gain,
        "selected_avg_gain": selected_gain / B if B else 0.0,
        "oracle_total_gain": oracle_gain,
        "oracle_regret_total": oracle_gain - selected_gain,
        "oracle_regret_per_episode": (oracle_gain - selected_gain) / n,
        "avg_selected_branch_harm": mean(selected_harms),
        "avg_skipped_branch_harm": mean(skipped_harms),
        "high_harm_threshold": high_harm_threshold,
        "high_harm_total": high_total,
        "high_harm_selected": high_selected,
        "high_harm_recall": (high_selected / high_total) if high_total else 0.0,
    }

def summarize_budget_curves(eval_rows, policies, budgets, high_harm_threshold):
    out = []
    for policy_name, score_name in policies:
        for b in budgets:
            m = evaluate_policy(eval_rows, score_name, b, high_harm_threshold)
            row = {
                "policy": policy_name,
                "score_name": score_name,
            }
            row.update(m)
            out.append(row)
    return out

def auc_summary(curve_rows):
    by_policy = defaultdict(list)
    for r in curve_rows:
        by_policy[r["policy"]].append(r)

    out = []
    for p, rows in sorted(by_policy.items()):
        rows = sorted(rows, key=lambda r: fl(r["budget_frac"]))
        out.append({
            "policy": p,
            "AUBC_avg_net_reward": mean(fl(r["avg_net_reward"]) for r in rows),
            "AUBC_success": mean(fl(r["success"]) for r in rows),
            "AUBC_irreversible_failure": mean(fl(r["irreversible_failure"]) for r in rows),
            "AUBC_oracle_regret_per_episode": mean(fl(r["oracle_regret_per_episode"]) for r in rows),
            "AUBC_high_harm_recall": mean(fl(r["high_harm_recall"]) for r in rows),
        })
    return out

def bootstrap_ci(eval_rows, policies, budgets, high_harm_threshold, reps=300, seed=123):
    rng = random.Random(seed)
    buckets = defaultdict(list)

    for _ in range(reps):
        sample = [rng.choice(eval_rows).copy() for _ in range(len(eval_rows))]
        # Make duplicate seeds unique for selection.
        for i, r in enumerate(sample):
            r["seed"] = i

        for policy_name, score_name in policies:
            for b in budgets:
                m = evaluate_policy(sample, score_name, b, high_harm_threshold)
                key = (policy_name, b)
                buckets[key].append(m)

    out = []
    metrics = ["avg_net_reward", "success", "irreversible_failure", "oracle_regret_per_episode", "high_harm_recall", "selected_avg_gain"]
    for (policy, b), vals in sorted(buckets.items()):
        for metric in metrics:
            arr = sorted(fl(v[metric]) for v in vals)
            out.append({
                "policy": policy,
                "budget_frac": b,
                "metric": metric,
                "mean": mean(arr),
                "ci_low": percentile(arr, 0.025),
                "ci_high": percentile(arr, 0.975),
                "bootstrap_reps": reps,
            })
    return out

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out-dir", default="../artifacts/evva_gate1_value_router_20260615")
    ap.add_argument("--bootstrap-reps", type=int, default=300)
    args = ap.parse_args()

    root = Path(__file__).resolve().parent.parent
    out_dir = (Path(__file__).resolve().parent / args.out_dir).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    table5_raw = root / "artifacts/v5_20260522/locked/table5_ablation_exactTopB150_20260523/v5_table5_ablation_exactTopB150_raw.csv"
    prm_decisions = root / "artifacts/v5_20260522/locked/table_prm_baseline_20260523/prm_baseline_exactTopB100_eval_decisions.csv"
    cal_decisions = root / "artifacts/v5_20260522/locked/table_joint_calibration_20260523/joint_calibration_exactTopB100_eval_decisions.csv"

    rows = build_base_rows(table5_raw)
    merge_prm_scores(rows, prm_decisions)
    merge_cal_scores(rows, cal_decisions)
    add_model_scores(rows)

    train_rows = [r for r in rows if r["split"] == "train"]
    eval_rows = [r for r in rows if r["split"] == "eval"]

    if len(train_rows) != 100 or len(eval_rows) != 200:
        raise RuntimeError(f"Unexpected split sizes: train={len(train_rows)}, eval={len(eval_rows)}")

    high_harm_threshold = percentile([fl(r["branch_harm_exact"]) for r in train_rows], 0.75)

    policies = [
        ("random", "score_random"),
        ("p_only", "score_p_only"),
        ("H_only", "score_H_only"),
        ("p_times_H", "score_p_times_H"),
        ("p_times_H_calibrated", "score_calibrated_p_times_H"),
        ("PRM_task_fail", "score_prm_task_fail"),
        ("PRM_value_gain", "score_prm_value_gain"),
        ("risk_only_learned", "score_risk_only_learned"),
        ("final_reward_model", "score_final_reward_model"),
        ("value_router", "score_value_router"),
        ("oracle_gain", "score_oracle_gain"),
    ]

    budgets = [0.05, 0.10, 0.20, 0.30, 0.50]

    row_fields = [
        "seed", "split", "case",
        "p_score", "harm_score", "p_times_H_score",
        "downstream_dependency_count", "rollback_difficulty", "persistent_state_risk",
        "estimated_harm_score", "downstream_failure_penalty",
        "public_risk_low", "public_risk_medium", "public_risk_high",
        "reward_wrong_continuation", "reward_corrected_continuation",
        "intervention_gain", "branch_harm_exact", "skip_loss_label",
        "prm_task_fail_score", "prm_value_gain_score",
        "p_cal", "H_cal", "p_times_H_calibrated_score",
        "score_random", "score_p_only", "score_H_only", "score_p_times_H",
        "score_calibrated_p_times_H", "score_prm_task_fail", "score_prm_value_gain",
        "score_risk_only_learned", "score_final_reward_model",
        "score_value_router", "score_oracle_gain",
    ]
    write_csv(out_dir / "value_router_train_eval_rows.csv", rows, row_fields)

    curve_rows = summarize_budget_curves(eval_rows, policies, budgets, high_harm_threshold)
    curve_fields = [
        "policy", "score_name", "budget_frac", "B", "n", "verify_rate",
        "success", "irreversible_failure", "avg_net_reward",
        "selected_total_gain", "selected_avg_gain",
        "oracle_total_gain", "oracle_regret_total", "oracle_regret_per_episode",
        "avg_selected_branch_harm", "avg_skipped_branch_harm",
        "high_harm_threshold", "high_harm_total", "high_harm_selected", "high_harm_recall",
    ]
    write_csv(out_dir / "budget_curve_summary.csv", curve_rows, curve_fields)

    regret_rows = [{
        "policy": r["policy"],
        "budget_frac": r["budget_frac"],
        "B": r["B"],
        "oracle_total_gain": r["oracle_total_gain"],
        "selected_total_gain": r["selected_total_gain"],
        "oracle_regret_total": r["oracle_regret_total"],
        "oracle_regret_per_episode": r["oracle_regret_per_episode"],
    } for r in curve_rows]
    write_csv(out_dir / "oracle_regret_summary.csv", regret_rows, [
        "policy", "budget_frac", "B",
        "oracle_total_gain", "selected_total_gain",
        "oracle_regret_total", "oracle_regret_per_episode",
    ])

    auc_rows = auc_summary(curve_rows)
    write_csv(out_dir / "policy_aubc_summary.csv", auc_rows, [
        "policy", "AUBC_avg_net_reward", "AUBC_success", "AUBC_irreversible_failure",
        "AUBC_oracle_regret_per_episode", "AUBC_high_harm_recall",
    ])

    ci_rows = bootstrap_ci(eval_rows, policies, budgets, high_harm_threshold, reps=args.bootstrap_reps)
    write_csv(out_dir / "bootstrap_ci_by_budget.csv", ci_rows, [
        "policy", "budget_frac", "metric", "mean", "ci_low", "ci_high", "bootstrap_reps",
    ])

    readme = out_dir / "GATE1_README.txt"
    readme.write_text(
        "EVVA Gate 1 offline value-router diagnostic\n"
        f"source_table={table5_raw}\n"
        f"prm_decisions={prm_decisions}\n"
        f"calibration_decisions={cal_decisions}\n"
        f"train_rows={len(train_rows)} seeds 20-119\n"
        f"eval_rows={len(eval_rows)} seeds 120-319\n"
        f"high_harm_threshold_train_q75={high_harm_threshold:.6f}\n"
        "Budgets: 0.05,0.10,0.20,0.30,0.50 over eval N=200.\n"
        "Main go/no-go: value_router should beat p_only and PRM baselines on at least two of AUBC reward, oracle regret, high-harm recall, selected gain, irreversible failure.\n",
        encoding="utf-8",
    )

    print("WROTE", out_dir)
    print("train_rows", len(train_rows), "eval_rows", len(eval_rows))
    print("high_harm_threshold_train_q75", f"{high_harm_threshold:.6f}")
    print("\nAUBC summary:")
    for r in auc_rows:
        print(
            r["policy"],
            "reward", f'{fl(r["AUBC_avg_net_reward"]):.4f}',
            "regret", f'{fl(r["AUBC_oracle_regret_per_episode"]):.4f}',
            "hh_recall", f'{fl(r["AUBC_high_harm_recall"]):.4f}',
            "irrev", f'{fl(r["AUBC_irreversible_failure"]):.4f}',
        )

if __name__ == "__main__":
    main()

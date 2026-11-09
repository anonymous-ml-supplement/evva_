#!/usr/bin/env python3
import argparse
import csv
import math
import itertools
from pathlib import Path
from collections import defaultdict

def fl(x, default=0.0):
    try:
        if x is None or x == "":
            return default
        return float(x)
    except Exception:
        return default

def mean(xs):
    xs = list(xs)
    return sum(xs) / len(xs) if xs else 0.0

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

def normalize_train_eval(rows, features):
    train = [r for r in rows if r["split"] == "train"]
    stats = {}
    for f in features:
        vals = [fl(r.get(f)) for r in train]
        mu = mean(vals)
        var = mean((v - mu) ** 2 for v in vals)
        sd = math.sqrt(var) if var > 1e-12 else 1.0
        stats[f] = (mu, sd)

    out = []
    for r in rows:
        rr = dict(r)
        for f in features:
            mu, sd = stats[f]
            rr[f + "_z"] = (fl(r.get(f)) - mu) / sd
        out.append(rr)
    return out

def score_row(r, feats, weights):
    return sum(weights[i] * fl(r.get(feats[i])) for i in range(len(feats)))

def selected_gain(rows, feats, weights, budget_frac):
    n = len(rows)
    B = max(1, int(round(budget_frac * n)))
    ranked = sorted(rows, key=lambda r: (-score_row(r, feats, weights), int(float(r["seed"]))))
    return sum(fl(r["intervention_gain"]) for r in ranked[:B])

def objective(rows, feats, weights, budgets):
    return mean(selected_gain(rows, feats, weights, b) / max(1, int(round(b * len(rows)))) for b in budgets)

def eval_policy(rows, score_name, budget_frac, high_thr):
    n = len(rows)
    B = max(1, int(round(budget_frac * n)))
    ranked = sorted(rows, key=lambda r: (-fl(r.get(score_name)), int(float(r["seed"]))))
    selected = set(r["seed"] for r in ranked[:B])

    oracle = sorted(rows, key=lambda r: (-fl(r["intervention_gain"]), int(float(r["seed"]))))
    oracle_gain = sum(fl(r["intervention_gain"]) for r in oracle[:B])

    rewards = []
    irrev = []
    success = []
    selected_gain_total = 0.0
    high_total = 0
    high_selected = 0

    for r in rows:
        seed = r["seed"]
        gain = fl(r["intervention_gain"])
        harm = fl(r["branch_harm_exact"])
        wrong = fl(r["reward_wrong_continuation"])
        corrected = fl(r["reward_corrected_continuation"])

        is_high = harm >= high_thr
        if is_high:
            high_total += 1

        if seed in selected:
            selected_gain_total += gain
            rewards.append(corrected)
            irrev.append(0.0)
            success.append(1.0 if corrected >= 0 else 0.0)
            if is_high:
                high_selected += 1
        else:
            rewards.append(wrong)
            irrev.append(1.0 if harm > 0 and wrong < 0 else 0.0)
            success.append(1.0 if wrong >= 0 else 0.0)

    return {
        "budget_frac": budget_frac,
        "B": B,
        "n": n,
        "avg_net_reward": mean(rewards),
        "success": mean(success),
        "irreversible_failure": mean(irv for irv in irrev),
        "selected_total_gain": selected_gain_total,
        "selected_avg_gain": selected_gain_total / B,
        "oracle_total_gain": oracle_gain,
        "oracle_regret_total": oracle_gain - selected_gain_total,
        "oracle_regret_per_episode": (oracle_gain - selected_gain_total) / n,
        "high_harm_total": high_total,
        "high_harm_selected": high_selected,
        "high_harm_recall": high_selected / high_total if high_total else 0.0,
    }

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--in-dir", default="../artifacts/evva_gate1_value_router_20260615")
    ap.add_argument("--out-dir", default="../artifacts/evva_gate1_rank_tuned_router_20260615")
    args = ap.parse_args()

    code_dir = Path(__file__).resolve().parent
    in_dir = (code_dir / args.in_dir).resolve()
    out_dir = (code_dir / args.out_dir).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    rows = read_csv(in_dir / "value_router_train_eval_rows.csv")

    base_features = [
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

    rows = normalize_train_eval(rows, base_features)

    train = [r for r in rows if r["split"] == "train"]
    eval_rows = [r for r in rows if r["split"] == "eval"]

    # Keep this small and reviewer-defensible.
    candidate_feature_sets = {
        "rank_router_p_H_pH": ["p_score_z", "harm_score_z", "p_times_H_score_z"],
        "rank_router_structural": [
            "p_score_z", "harm_score_z", "p_times_H_score_z",
            "downstream_dependency_count_z", "rollback_difficulty_z",
            "persistent_state_risk_z", "downstream_failure_penalty_z",
        ],
        "rank_router_no_pH": [
            "p_score_z", "harm_score_z",
            "downstream_dependency_count_z", "rollback_difficulty_z",
            "persistent_state_risk_z", "downstream_failure_penalty_z",
        ],
    }

    train_budgets = [0.05, 0.10, 0.20]
    eval_budgets = [0.05, 0.10, 0.20, 0.30, 0.50]
    grid = [-2.0, -1.0, -0.5, 0.0, 0.5, 1.0, 2.0, 3.0]

    learned_policies = []
    search_rows = []

    for name, feats in candidate_feature_sets.items():
        best = None
        # Limit combinations if feature set is larger.
        for weights in itertools.product(grid, repeat=len(feats)):
            if all(abs(w) < 1e-12 for w in weights):
                continue
            obj = objective(train, feats, weights, train_budgets)
            if best is None or obj > best[0]:
                best = (obj, weights)
        obj, weights = best
        score_col = "score_" + name
        for r in rows:
            r[score_col] = score_row(r, feats, weights)
        learned_policies.append((name, score_col))
        search_rows.append({
            "router": name,
            "train_objective_avg_selected_gain_low_budget": obj,
            "features": "|".join(feats),
            "weights": "|".join(str(w) for w in weights),
        })

    high_vals = sorted(fl(r["branch_harm_exact"]) for r in train)
    high_thr = high_vals[int(0.75 * (len(high_vals) - 1))]

    baseline_policies = [
        ("p_only", "score_p_only"),
        ("H_only", "score_H_only"),
        ("p_times_H", "score_p_times_H"),
        ("p_times_H_calibrated", "score_calibrated_p_times_H"),
        ("PRM_task_fail", "score_prm_task_fail"),
        ("PRM_value_gain", "score_prm_value_gain"),
        ("risk_only_learned", "score_risk_only_learned"),
        ("final_reward_model", "score_final_reward_model"),
        ("old_value_router_mse", "score_value_router"),
        ("oracle_gain", "score_oracle_gain"),
    ]

    all_policies = baseline_policies + learned_policies

    curve = []
    for pname, scol in all_policies:
        for b in eval_budgets:
            m = eval_policy(eval_rows, scol, b, high_thr)
            row = {"policy": pname, "score_name": scol}
            row.update(m)
            curve.append(row)

    aubc = []
    by_policy = defaultdict(list)
    for r in curve:
        by_policy[r["policy"]].append(r)
    for p, rs in sorted(by_policy.items()):
        aubc.append({
            "policy": p,
            "AUBC_avg_net_reward": mean(fl(r["avg_net_reward"]) for r in rs),
            "AUBC_success": mean(fl(r["success"]) for r in rs),
            "AUBC_irreversible_failure": mean(fl(r["irreversible_failure"]) for r in rs),
            "AUBC_oracle_regret_per_episode": mean(fl(r["oracle_regret_per_episode"]) for r in rs),
            "AUBC_high_harm_recall": mean(fl(r["high_harm_recall"]) for r in rs),
            "AUBC_selected_avg_gain": mean(fl(r["selected_avg_gain"]) for r in rs),
        })

    write_csv(out_dir / "rank_tuned_router_search.csv", search_rows, [
        "router", "train_objective_avg_selected_gain_low_budget", "features", "weights"
    ])
    write_csv(out_dir / "rank_tuned_budget_curve_summary.csv", curve, [
        "policy", "score_name", "budget_frac", "B", "n",
        "avg_net_reward", "success", "irreversible_failure",
        "selected_total_gain", "selected_avg_gain",
        "oracle_total_gain", "oracle_regret_total", "oracle_regret_per_episode",
        "high_harm_total", "high_harm_selected", "high_harm_recall",
    ])
    write_csv(out_dir / "rank_tuned_policy_aubc_summary.csv", aubc, [
        "policy", "AUBC_avg_net_reward", "AUBC_success", "AUBC_irreversible_failure",
        "AUBC_oracle_regret_per_episode", "AUBC_high_harm_recall", "AUBC_selected_avg_gain",
    ])

    print("WROTE", out_dir)
    print("\nLearned router search:")
    for r in search_rows:
        print(r["router"], "obj", r["train_objective_avg_selected_gain_low_budget"], "weights", r["weights"])

    print("\nAUBC:")
    for r in sorted(aubc, key=lambda x: -fl(x["AUBC_avg_net_reward"])):
        print(
            r["policy"],
            "reward", round(fl(r["AUBC_avg_net_reward"]), 4),
            "regret", round(fl(r["AUBC_oracle_regret_per_episode"]), 4),
            "hh_recall", round(fl(r["AUBC_high_harm_recall"]), 4),
            "irrev", round(fl(r["AUBC_irreversible_failure"]), 4),
        )

if __name__ == "__main__":
    main()

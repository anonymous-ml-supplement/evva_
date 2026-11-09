#!/usr/bin/env python3
import argparse
import csv
import json
import random
import subprocess
import sys
from pathlib import Path


def run_cmd(cmd, cwd=None):
    p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    if p.returncode != 0:
        raise RuntimeError(
            f"Command failed:\n{' '.join(cmd)}\n\nSTDOUT:\n{p.stdout}\n\nSTDERR:\n{p.stderr}"
        )
    try:
        return json.loads(p.stdout)
    except json.JSONDecodeError as e:
        raise RuntimeError(
            f"Failed to parse JSON output from command:\n{' '.join(cmd)}\n\nOutput:\n{p.stdout}"
        ) from e


def ensure_parent(path: Path):
    path.parent.mkdir(parents=True, exist_ok=True)


def save_json(path: Path, obj):
    ensure_parent(path)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=2, ensure_ascii=False)


def append_csv_row(path: Path, header, row_dict):
    ensure_parent(path)
    exists = path.exists()
    with open(path, "a", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=header)
        if not exists:
            writer.writeheader()
        writer.writerow(row_dict)


def update_runlist_status(runlist_csv: Path, episode_id: str, new_status: str):
    if not runlist_csv or not runlist_csv.exists():
        return

    rows = []
    with open(runlist_csv, "r", newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        fieldnames = reader.fieldnames
        for row in reader:
            if row.get("episode_id") == episode_id:
                row["status"] = new_status
            rows.append(row)

    with open(runlist_csv, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def decide_policy(policy, reset_obj, rng, random_verify_prob=0.5, uncertainty_threshold=0.60, harm_threshold=0.45):
    hint = float(reset_obj.get("public_risk_hint", 0.0))
    label = str(reset_obj.get("public_risk_label", "")).lower()
    reversibility = str(reset_obj.get("reversibility", "")).lower()
    coupling = str(reset_obj.get("coupling_strength", "")).lower()

    # Simple structural harm proxy for P0 experiments.
    # This is intentionally transparent and reviewer-facing.
    coupling_score = {
        "weak": 0.20,
        "medium": 0.60,
        "strong": 1.00,
    }.get(coupling, 0.50)

    reversibility_score = {
        "fully_reversible": 0.20,
        "partially_reversible": 0.70,
        "irreversible": 1.00,
        "not_reversible": 1.00,
    }.get(reversibility, 0.50)

    fallback_harm_score = 0.5 * coupling_score + 0.5 * reversibility_score
    try:
        harm_score = float(reset_obj.get("estimated_harm_score", fallback_harm_score))
    except Exception:
        harm_score = fallback_harm_score

    p_score = hint
    p_times_H_score = p_score * harm_score
    cost = 1.0

    if policy == "no_verify":
        verify = False
        score = 0.0
        note = "Never verify."

    elif policy == "always_verify":
        verify = True
        score = 1.0
        note = "Always verify before finalizing."

    elif policy in {"uncertainty_only", "uncertainty_only_default"}:
        score = p_score
        verify = (label == "high") or (hint >= 0.60)
        note = f"Default uncertainty-only rule: label high or hint >= 0.60. score={score:.4f}, verify={verify}"

    elif policy == "uncertainty_only_matched_budget":
        score = p_score
        verify = score >= uncertainty_threshold
        note = f"Matched-budget uncertainty-only rule: hint >= {uncertainty_threshold:.4f}. score={score:.4f}, verify={verify}"

    elif policy == "harm_aware_selective":
        score = p_times_H_score
        verify = score >= harm_threshold
        note = (
            f"Harm-aware rule: p_score * harm_score >= {harm_threshold:.4f}. "
            f"p={p_score:.4f}, H={harm_score:.4f}, score={score:.4f}, verify={verify}"
        )

    elif policy == "random_matched_cost" or policy == "random_verify_matched_budget":
        score = random_verify_prob
        verify = rng.random() < random_verify_prob
        note = f"Random matched-budget baseline. p={random_verify_prob:.4f}, verify={verify}"

    elif policy == "p_only":
        score = p_score
        verify = score >= uncertainty_threshold
        note = f"Ablation p_only: p >= {uncertainty_threshold:.4f}. p={p_score:.4f}, verify={verify}"

    elif policy == "H_only":
        score = harm_score
        verify = score >= harm_threshold
        note = f"Ablation H_only: H >= {harm_threshold:.4f}. H={harm_score:.4f}, verify={verify}"

    elif policy == "p_times_H":
        score = p_times_H_score
        verify = score >= harm_threshold
        note = f"Ablation p_times_H: p*H >= {harm_threshold:.4f}. score={score:.4f}, verify={verify}"

    elif policy == "p_times_H_minus_cost":
        score = p_times_H_score - cost
        verify = score >= 0.0
        note = f"Ablation p_times_H_minus_cost: p*H-cost >= 0. score={score:.4f}, verify={verify}"

    else:
        raise ValueError(f"Unknown policy: {policy}")

    return {
        "mode": "verify_then_decide" if verify else "direct",
        "action": "risky_patch",
        "policy_note": note,
        "policy_score": score,
        "p_score": p_score,
        "harm_score": harm_score,
        "p_times_H_score": p_times_H_score,
        "uncertainty_threshold": uncertainty_threshold,
        "harm_threshold": harm_threshold,
        "random_verify_prob": random_verify_prob,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--episode", required=True)
    parser.add_argument("--case", required=True)
    parser.add_argument("--policy", required=True,
                        choices=[
                            "no_verify",
                            "always_verify",
                            "uncertainty_only",
                            "uncertainty_only_default",
                            "uncertainty_only_matched_budget",
                            "harm_aware_selective",
                            "random_matched_cost",
                            "random_verify_matched_budget",
                            "p_only",
                            "H_only",
                            "p_times_H",
                            "p_times_H_minus_cost",
                        ])
    parser.add_argument("--seed", required=True, type=int)
    parser.add_argument("--random-verify-prob", type=float, default=0.5)
    parser.add_argument("--uncertainty-threshold", type=float, default=0.60)
    parser.add_argument("--harm-threshold", type=float, default=0.45)

    parser.add_argument("--summary-csv", default=None)
    parser.add_argument("--runlist-csv", default=None)
    parser.add_argument("--notes", default="")

    args = parser.parse_args()

    code_dir = Path(__file__).resolve().parent
    root_dir = code_dir.parent
    data_dir = root_dir / "data"

    results_dir = data_dir / "results" / args.episode
    logs_dir = data_dir / "logs"
    summaries_dir = data_dir / "summaries"

    results_dir.mkdir(parents=True, exist_ok=True)
    logs_dir.mkdir(parents=True, exist_ok=True)
    summaries_dir.mkdir(parents=True, exist_ok=True)

    summary_csv = Path(args.summary_csv) if args.summary_csv else (summaries_dir / "pilot_summary.csv")
    runlist_csv = Path(args.runlist_csv) if args.runlist_csv else None

    rng = random.Random(args.seed)

    # 1) reset
    reset_cmd = [
        sys.executable,
        str(code_dir / "oc_reset_and_hint.py"),
        "--episode", args.episode,
        "--case", args.case,
        "--seed", str(args.seed),
    ]
    reset_obj = run_cmd(reset_cmd, cwd=str(code_dir))
    save_json(results_dir / "reset.json", reset_obj)

    # 2) decide policy
    decision = decide_policy(
        policy=args.policy,
        reset_obj=reset_obj,
        rng=rng,
        random_verify_prob=args.random_verify_prob,
        uncertainty_threshold=args.uncertainty_threshold,
        harm_threshold=args.harm_threshold,
    )
    save_json(results_dir / "decision.json", decision)

    # 3) finalize
    finalize_cmd = [
        sys.executable,
        str(code_dir / "oc_finalize_episode.py"),
        "--episode", args.episode,
        "--mode", decision["mode"],
        "--action", decision["action"],
        "--compute-branch-diagnostics", "always",
    ]
    final_obj = run_cmd(finalize_cmd, cwd=str(code_dir))
    save_json(results_dir / "final.json", final_obj)

    # 4) combined record
    combined = {
        "episode_id": args.episode,
        "case": args.case,
        "policy": args.policy,
        "seed": args.seed,
        "decision": decision,
        "reset": reset_obj,
        "final": final_obj,
    }
    save_json(results_dir / "record.json", combined)

    # 5) summary row
    verify_used = 1 if float(final_obj.get("verification_cost", 0.0)) > 0 else 0
    total_reward = final_obj.get("total_reward", "")
    realized_reward = final_obj.get("rollout", {}).get("final_total_reward", total_reward)

    summary_header = [
        "episode_id",
        "case",
        "policy",
        "seed",
        "verify_used",
        "corrected",
        "success",
        "irreversible_failure",
        "verification_cost",
        "net_reward",
        "realized_reward",
        "public_risk_label",
        "public_risk_score",
        "branch_harm_exact",
        "reward_wrong_continuation",
        "reward_corrected_continuation",
        "reversibility",
        "coupling_strength",
        "mode",
        "final_action",
        "policy_score",
        "p_score",
        "harm_score",
        "p_times_H_score",
        "downstream_dependency_count",
        "rollback_difficulty",
        "persistent_state_risk",
        "estimated_harm_score",
        "downstream_failure_penalty",
        "harm_profile",
        "uncertainty_threshold",
        "harm_threshold",
        "random_verify_prob",
        "notes",
    ]

    summary_row = {
        "episode_id": args.episode,
        "case": args.case,
        "policy": args.policy,
        "seed": args.seed,
        "verify_used": verify_used,
        "corrected": int(bool(final_obj.get("corrected", False))),
        "success": final_obj.get("success", ""),
        "irreversible_failure": final_obj.get("irreversible_failure", ""),
        "verification_cost": final_obj.get("verification_cost", ""),
        "net_reward": total_reward,
        "realized_reward": realized_reward,
        "public_risk_label": reset_obj.get("public_risk_label", ""),
        "public_risk_score": reset_obj.get("public_risk_hint", ""),
        "branch_harm_exact": final_obj.get("branch_harm_exact", ""),
        "reward_wrong_continuation": final_obj.get("reward_wrong_continuation", ""),
        "reward_corrected_continuation": final_obj.get("reward_corrected_continuation", ""),
        "reversibility": final_obj.get("reversibility", ""),
        "coupling_strength": final_obj.get("coupling_strength", ""),
        "mode": final_obj.get("mode", ""),
        "final_action": final_obj.get("final_action", ""),
        "policy_score": decision.get("policy_score", ""),
        "p_score": decision.get("p_score", ""),
        "harm_score": decision.get("harm_score", ""),
        "p_times_H_score": decision.get("p_times_H_score", ""),
        "downstream_dependency_count": reset_obj.get("downstream_dependency_count", ""),
        "rollback_difficulty": reset_obj.get("rollback_difficulty", ""),
        "persistent_state_risk": reset_obj.get("persistent_state_risk", ""),
        "estimated_harm_score": reset_obj.get("estimated_harm_score", ""),
        "downstream_failure_penalty": reset_obj.get("downstream_failure_penalty", ""),
        "harm_profile": reset_obj.get("harm_profile", ""),
        "uncertainty_threshold": decision.get("uncertainty_threshold", ""),
        "harm_threshold": decision.get("harm_threshold", ""),
        "random_verify_prob": decision.get("random_verify_prob", ""),
        "notes": args.notes if args.notes else decision["policy_note"],
    }
    append_csv_row(summary_csv, summary_header, summary_row)

    # 6) update runlist
    if runlist_csv:
        update_runlist_status(runlist_csv, args.episode, "done")

    # 7) simple console report
    print(json.dumps({
        "status": "ok",
        "episode_id": args.episode,
        "case": args.case,
        "policy": args.policy,
        "seed": args.seed,
        "results_dir": str(results_dir),
        "summary_csv": str(summary_csv),
        "verify_used": verify_used,
        "success": final_obj.get("success", ""),
        "irreversible_failure": final_obj.get("irreversible_failure", ""),
        "branch_harm_exact": final_obj.get("branch_harm_exact", ""),
        "total_reward": total_reward,
    }, indent=2))


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""
EVVA v4 full-agent candidate-level collector.

Goal:
  Produce one row per candidate verification point.
  Do NOT create one row per score-family policy.

Implementation:
  For each case/seed/agent_variant, run skip-vs-verify branches via existing
  run_policy_episode.py using no_verify and always_verify as branch probes.
  The output candidate pool has no policy column and can be scored offline.
"""

import argparse
import csv
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Dict, List, Optional, Tuple


FIELDNAMES = [
    "experiment_id",
    "task_id",
    "episode_id",
    "case_type",
    "seed",
    "agent_variant",
    "candidate_id",
    "step_id",
    "decision_point_id",
    "requested_action",
    "corrected_action",
    "action_type",
    "p_score",
    "harm_score",
    "p_times_H_score",
    "PRM_task_surrogate",
    "PRM_value_surrogate",
    "value_router_surrogate",
    "rollback_difficulty",
    "persistent_state_risk",
    "downstream_dependency_count",
    "branch_harm_exact",
    "reward_wrong_continuation",
    "reward_corrected_continuation",
    "intervention_gain",
    "verification_cost",
    "trace_path",
    "notes",
]


def parse_seed_spec(spec: str) -> List[int]:
    seeds: List[int] = []
    for part in spec.split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            a, b = part.split("-", 1)
            seeds.extend(range(int(a), int(b) + 1))
        else:
            seeds.append(int(part))
    return sorted(dict.fromkeys(seeds))


def find_runner() -> Path:
    candidates = [
        Path("run_policy_episode.py"),
        Path("code/run_policy_episode.py"),
        Path("scripts/run_policy_episode.py"),
    ]
    for p in candidates:
        if p.exists():
            return p
    raise FileNotFoundError(
        "Cannot find run_policy_episode.py in ./, ./code, or ./scripts. "
        "Run from the OpenClaw workspace root."
    )


def read_last_csv_row(path: Path) -> Dict[str, str]:
    if not path.exists():
        raise FileNotFoundError(f"Expected summary CSV not found: {path}")
    with path.open("r", newline="") as f:
        rows = list(csv.DictReader(f))
    if not rows:
        raise RuntimeError(f"Summary CSV has no rows: {path}")
    return rows[-1]


def pick(row: Dict[str, str], names: List[str], default: str = "") -> str:
    for n in names:
        if n in row and str(row[n]).strip() != "":
            return str(row[n]).strip()
    return default


def to_float(x: str) -> Optional[float]:
    try:
        if x is None:
            return None
        s = str(x).strip()
        if s == "" or s.lower() in {"nan", "none", "null"}:
            return None
        return float(s)
    except Exception:
        return None


def pick_float(row: Dict[str, str], names: List[str]) -> Optional[float]:
    for n in names:
        if n in row:
            v = to_float(row.get(n, ""))
            if v is not None:
                return v
    return None


def run_branch(
    runner: Path,
    case_type: str,
    seed: int,
    agent_variant: str,
    policy: str,
    trace_dir: Path,
    extra_notes: str,
) -> Dict[str, str]:
    trace_dir.mkdir(parents=True, exist_ok=True)
    summary_csv = trace_dir / f"{policy}_summary.csv"
    stdout_log = trace_dir / f"{policy}.stdout.log"
    stderr_log = trace_dir / f"{policy}.stderr.log"

    cmd = [
        sys.executable,
        str(runner),
        "--episode",
        f"v4_full_agent_{agent_variant}",
        "--case",
        case_type,
        "--policy",
        policy,
        "--seed",
        str(seed),
        "--summary-csv",
        str(summary_csv),
        "--notes",
        extra_notes,
    ]

    env = os.environ.copy()
    env["OPENCLAW_AGENT_VARIANT"] = agent_variant
    env["evva_V4_FULL_AGENT"] = "1"

    with stdout_log.open("w") as out_f, stderr_log.open("w") as err_f:
        proc = subprocess.run(cmd, stdout=out_f, stderr=err_f, env=env)

    if proc.returncode != 0:
        raise RuntimeError(
            f"Branch run failed: case={case_type} seed={seed} "
            f"agent_variant={agent_variant} policy={policy}. "
            f"See {stdout_log} and {stderr_log}"
        )

    row = read_last_csv_row(summary_csv)
    row["_summary_csv"] = str(summary_csv)
    row["_stdout_log"] = str(stdout_log)
    row["_stderr_log"] = str(stderr_log)
    row["_cmd"] = " ".join(cmd)
    return row


def load_existing_keys(out_path: Path) -> set:
    keys = set()
    if not out_path.exists():
        return keys
    with out_path.open("r", newline="") as f:
        reader = csv.DictReader(f)
        for r in reader:
            keys.add((r.get("case_type"), r.get("seed"), r.get("agent_variant"), r.get("candidate_id")))
    return keys


def ensure_header(out_path: Path, force: bool) -> None:
    if force and out_path.exists():
        out_path.unlink()
    if not out_path.exists():
        out_path.parent.mkdir(parents=True, exist_ok=True)
        with out_path.open("w", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=FIELDNAMES)
            writer.writeheader()


def build_candidate_row(
    case_type: str,
    seed: int,
    agent_variant: str,
    no_verify: Dict[str, str],
    always_verify: Dict[str, str],
    trace_dir: Path,
) -> Dict[str, str]:
    candidate_id = pick(
        no_verify,
        ["candidate_id", "decision_point_id", "step_id"],
        default=f"{case_type}_{seed}_{agent_variant}_cand000",
    )

    p_score = pick_float(no_verify, [
        "p_score", "p_error", "error_prob", "issue_likelihood",
        "uncertainty_score", "uncertainty", "risk_score",
    ])
    if p_score is None:
        p_score = pick_float(always_verify, [
            "p_score", "p_error", "error_prob", "issue_likelihood",
            "uncertainty_score", "uncertainty", "risk_score",
        ])

    # IMPORTANT:
    # harm_score must be a decision-time / structural proxy.
    # It must NOT fall back to branch_harm_exact, downstream_harm, final harm,
    # or any post-hoc outcome field. Those are only allowed for outcome labels.
    harm_score = pick_float(no_verify, [
        "structural_harm_score",
        "estimated_harm_score",
        "H_score",
        "H_t",
        "pre_harm_score",
        "pre_intervention_harm_score",
        "harm_proxy",
        "risk_harm_proxy",
    ])
    if harm_score is None:
        harm_score = pick_float(always_verify, [
            "structural_harm_score",
            "estimated_harm_score",
            "H_score",
            "H_t",
            "pre_harm_score",
            "pre_intervention_harm_score",
            "harm_proxy",
            "risk_harm_proxy",
        ])

    # If the runner exposes structural ingredients but not an explicit H proxy,
    # build a simple bounded structural proxy from pre-decision cues.
    if harm_score is None:
        rd = pick_float(no_verify, ["rollback_difficulty"])
        ps = pick_float(no_verify, ["persistent_state_risk"])
        dc = pick_float(no_verify, ["downstream_dependency_count", "dependency_count"])
        parts = []
        if rd is not None:
            parts.append(max(0.0, min(1.0, rd)))
        if ps is not None:
            parts.append(max(0.0, min(1.0, ps)))
        if dc is not None:
            parts.append(max(0.0, min(1.0, dc / 5.0)))
        if parts:
            harm_score = sum(parts) / len(parts)

    # EVVA-EH must be computed from the collector's final decision-time p and H.
    # Do not trust a runner-provided p_times_H_score if collector-side H was
    # transformed or reconstructed.
    p_times_H = None
    if p_score is not None and harm_score is not None:
        p_times_H = p_score * harm_score

    branch_harm_exact = pick_float(no_verify, [
        "branch_harm_exact",
        "harm_exact",
        "downstream_harm",
        "posthoc_harm",
        "realized_harm",
        "harm",
    ])

    reward_wrong = pick_float(no_verify, [
        "reward_wrong_continuation", "wrong_reward", "final_reward",
        "total_reward", "net_reward", "reward", "episode_reward",
    ])
    reward_corrected = pick_float(always_verify, [
        "reward_corrected_continuation", "corrected_reward", "final_reward",
        "total_reward", "net_reward", "reward", "episode_reward",
    ])

    intervention_gain = None
    if reward_wrong is not None and reward_corrected is not None:
        intervention_gain = reward_corrected - reward_wrong
    else:
        intervention_gain = pick_float(always_verify, ["intervention_gain", "gain", "selected_downstream_gain"])

    requested_action = pick(no_verify, ["requested_action", "candidate_action", "initial_action", "final_action"], "risky_patch")
    corrected_action = pick(always_verify, ["corrected_action", "verification_action", "final_action"], "safe_edit")

    notes_obj = {
        "collector": "evva_v4_full_agent_candidate_collector.py",
        "branch_probe_policies": ["no_verify", "always_verify"],
        "main_raw_is_candidate_level": True,
        "no_verify_summary": no_verify.get("_summary_csv", ""),
        "always_verify_summary": always_verify.get("_summary_csv", ""),
    }

    return {
        "experiment_id": "v4_full_agent_20260707",
        "task_id": pick(no_verify, ["task_id", "episode", "episode_id"], f"{case_type}_{seed}"),
        "episode_id": pick(no_verify, ["episode_id", "episode"], f"v4_full_agent_{case_type}_{seed}_{agent_variant}"),
        "case_type": case_type,
        "seed": str(seed),
        "agent_variant": agent_variant,
        "candidate_id": str(candidate_id),
        "step_id": pick(no_verify, ["step_id"], "0"),
        "decision_point_id": pick(no_verify, ["decision_point_id"], str(candidate_id)),
        "requested_action": requested_action,
        "corrected_action": corrected_action,
        "action_type": pick(no_verify, ["action_type"], "tool_action"),
        "p_score": "" if p_score is None else f"{p_score:.12g}",
        "harm_score": "" if harm_score is None else f"{harm_score:.12g}",
        "p_times_H_score": "" if p_times_H is None else f"{p_times_H:.12g}",
        "PRM_task_surrogate": pick(no_verify, ["PRM_task_surrogate", "prm_task_score", "task_fail_score"], ""),
        "PRM_value_surrogate": pick(no_verify, ["PRM_value_surrogate", "prm_value_score", "value_score"], ""),
        "value_router_surrogate": pick(no_verify, ["value_router_surrogate", "value_router_score"], ""),
        "rollback_difficulty": pick(no_verify, ["rollback_difficulty"], ""),
        "persistent_state_risk": pick(no_verify, ["persistent_state_risk"], ""),
        "downstream_dependency_count": pick(no_verify, ["downstream_dependency_count", "dependency_count"], ""),
        "branch_harm_exact": "" if branch_harm_exact is None else f"{branch_harm_exact:.12g}",
        "reward_wrong_continuation": "" if reward_wrong is None else f"{reward_wrong:.12g}",
        "reward_corrected_continuation": "" if reward_corrected is None else f"{reward_corrected:.12g}",
        "intervention_gain": "" if intervention_gain is None else f"{intervention_gain:.12g}",
        "verification_cost": pick(always_verify, ["verification_cost", "verify_cost", "cost"], "1"),
        "trace_path": str(trace_dir),
        "notes": json.dumps(notes_obj, sort_keys=True),
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--cases", nargs="+", required=True)
    ap.add_argument("--seeds", required=True, help="Example: 4000-4019 or 4000,4001")
    ap.add_argument("--agent-variants", nargs="+", default=["openclaw_default"])
    ap.add_argument("--out", required=True)
    ap.add_argument("--log-dir", required=True)
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--no-resume", action="store_true")
    args = ap.parse_args()

    runner = find_runner()
    out_path = Path(args.out)
    log_dir = Path(args.log_dir)
    log_dir.mkdir(parents=True, exist_ok=True)
    ensure_header(out_path, force=args.force)

    existing = set() if args.no_resume or args.force else load_existing_keys(out_path)
    seeds = parse_seed_spec(args.seeds)

    n_written = 0
    n_skipped = 0
    failures: List[str] = []

    with out_path.open("a", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=FIELDNAMES)

        for case_type in args.cases:
            for seed in seeds:
                for agent_variant in args.agent_variants:
                    candidate_id = f"{case_type}_{seed}_{agent_variant}_cand000"
                    key = (case_type, str(seed), agent_variant, candidate_id)
                    if key in existing:
                        n_skipped += 1
                        continue

                    safe_case = case_type.replace("/", "_")
                    safe_variant = agent_variant.replace("/", "_")
                    trace_dir = log_dir / f"case={safe_case}" / f"seed={seed}" / f"agent={safe_variant}"
                    notes = f"evva_v4_full_agent_candidate_collector agent_variant={agent_variant}"

                    try:
                        no_v = run_branch(runner, case_type, seed, agent_variant, "no_verify", trace_dir, notes)
                        yes_v = run_branch(runner, case_type, seed, agent_variant, "always_verify", trace_dir, notes)
                        row = build_candidate_row(case_type, seed, agent_variant, no_v, yes_v, trace_dir)
                        writer.writerow(row)
                        f.flush()
                        n_written += 1
                        print(f"[OK] wrote candidate row: case={case_type} seed={seed} agent={agent_variant}")
                    except Exception as e:
                        msg = f"[FAIL] case={case_type} seed={seed} agent={agent_variant}: {e}"
                        print(msg, file=sys.stderr)
                        failures.append(msg)

    manifest = {
        "out": str(out_path),
        "runner": str(runner),
        "cases": args.cases,
        "seeds": seeds,
        "agent_variants": args.agent_variants,
        "written": n_written,
        "skipped_existing": n_skipped,
        "failures": failures,
    }
    manifest_path = log_dir / "collector_manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True), encoding="utf-8")

    print(f"[DONE] written={n_written} skipped_existing={n_skipped} failures={len(failures)}")
    print(f"[OUT] {out_path}")
    print(f"[MANIFEST] {manifest_path}")

    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())

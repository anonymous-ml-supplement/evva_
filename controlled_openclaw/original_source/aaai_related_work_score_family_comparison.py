#!/usr/bin/env python3
from __future__ import annotations

import csv
from pathlib import Path
from collections import defaultdict


def fl(x, d=0.0):
    try:
        if x is None or x == "":
            return d
        return float(x)
    except Exception:
        return d


def read_csv(path):
    with open(path, newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def read_optional(path):
    if path.exists():
        return read_csv(path)
    return []


def write_csv(path, rows, fields):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        for r in rows:
            w.writerow({k: r.get(k, "") for k in fields})


def mean(xs):
    xs = list(xs)
    return sum(xs) / len(xs) if xs else 0.0


def normalize_policy_name(p):
    mapping = {
        "PRM_task_fail": "PRM_task",
        "PRM_value_gain": "PRM_value",
        "PRM_task_surrogate": "PRM_task",
        "PRM_value_surrogate": "PRM_value",
        "value_router_surrogate": "value_router",
        "old_value_router": "value_router",
        "p_times_H": "p_times_H",
        "q_pH_minus_cost": "q_pH_minus_cost",
        "q_pH_per_cost": "q_pH_per_cost",
        "H_only": "H_only",
        "p_only": "p_only",
        "oracle": "oracle",
        "oracle_gain": "oracle",
    }
    return mapping.get(p, p)


def family_for_policy(policy):
    p = normalize_policy_name(policy)

    if p == "p_only":
        return "Local uncertainty"
    if p == "H_only":
        return "Runtime/harm-risk proxy"
    if p in {"PRM_task", "PRM_value"}:
        return "PRM/process-reward style"
    if p == "value_router":
        return "Learned reward/value estimator"
    if p == "p_times_H":
        return "Consequence-aware proxy"
    if p in {"q_pH_minus_cost", "q_pH_per_cost"}:
        return "q/cost-aware proxy"
    if p == "oracle":
        return "Oracle intervention value"
    return "Other"


def representative_work_for_family(family):
    mapping = {
        "Local uncertainty": "Generic uncertainty routing / selective prediction",
        "Runtime/harm-risk proxy": "AgentSpec; Pro2Guard-style future-risk or runtime-safety systems",
        "PRM/process-reward style": "Tool-call Reward Model; ToolPRMBench; AgentProcessBench",
        "Learned reward/value estimator": "AgentPRM / AgentRM-style reward or value modeling",
        "Consequence-aware proxy": "This paper: p_times_H",
        "q/cost-aware proxy": "This paper: q/cost-aware intervention-value proxy",
        "Oracle intervention value": "Upper bound using counterfactual branch replay",
    }
    return mapping.get(family, "")


def build_positioning_tables(out_dir):
    topconf_rows = [
        {
            "tier": "Tier 1",
            "work_or_family": "AgentSpec",
            "venue_status_for_positioning": "ICSE 2026 / runtime enforcement",
            "their_target": "Specify and enforce runtime safety constraints for LLM agents",
            "our_comparable_score_family": "Runtime/harm-risk proxy",
            "our_score": "H_only",
            "why_not_full_reproduction": "It is an enforcement system, while our objective is exact-budget verification allocation.",
            "paper_claim": "Complementary: enforcement/risk scores are one score family under our allocation objective.",
        },
        {
            "tier": "Tier 1",
            "work_or_family": "Tool-call Reward Model",
            "venue_status_for_positioning": "ICLR 2026 conference / tool reward modeling",
            "their_target": "Reward each tool invocation with fine-grained process reward",
            "our_comparable_score_family": "PRM/process-reward style; learned reward/value estimator",
            "our_score": "PRM_task, PRM_value, value_router",
            "why_not_full_reproduction": "It optimizes tool-call reward, not counterfactual verify-vs-skip gain.",
            "paper_claim": "Reward/process scores are evaluated as candidate estimators of intervention value.",
        },
        {
            "tier": "Tier 1 / safety-adjacent",
            "work_or_family": "Reward Hacking Benchmark",
            "venue_status_for_positioning": "2026 tool-agent reward-hacking benchmark",
            "their_target": "Measure exploit behavior such as skipped verification or evaluation tampering",
            "our_comparable_score_family": "High-harm / high-gain branch-replay diagnostics",
            "our_score": "H_only, oracle_gain, failure examples",
            "why_not_full_reproduction": "It measures exploit incidence, while our label is verification intervention gain.",
            "paper_claim": "Motivates why verification allocation matters for tool-agent safety.",
        },
        {
            "tier": "Tier 2",
            "work_or_family": "ToolPRMBench",
            "venue_status_for_positioning": "Recent workshop / preprint PRM benchmark",
            "their_target": "Evaluate PRMs on tool-use step quality and correct-vs-incorrect alternatives",
            "our_comparable_score_family": "PRM/process-reward style",
            "our_score": "PRM_task, PRM_value",
            "why_not_full_reproduction": "It evaluates step quality, not exact-budget intervention value.",
            "paper_claim": "Adjacent benchmark; our objective is different.",
        },
        {
            "tier": "Tier 2",
            "work_or_family": "AgentProcessBench",
            "venue_status_for_positioning": "Recent step-level process-quality benchmark",
            "their_target": "Evaluate step effectiveness in realistic tool-agent trajectories",
            "our_comparable_score_family": "PRM/process-reward style",
            "our_score": "PRM_task, PRM_value",
            "why_not_full_reproduction": "Step effectiveness is not equivalent to verification value.",
            "paper_claim": "Useful adjacent work; motivates objective mismatch.",
        },
    ]

    score_family_rows = [
        {
            "score_family": "Local uncertainty",
            "representative_work": "Uncertainty routing / selective prediction",
            "policy_names": "p_only",
            "paper_role": "Baseline",
            "interpretation": "Local suspiciousness alone can miss high-consequence opportunities.",
        },
        {
            "score_family": "Runtime/harm-risk proxy",
            "representative_work": "AgentSpec; Pro2Guard-style runtime/future-risk safety",
            "policy_names": "H_only",
            "paper_role": "Strong structural baseline",
            "interpretation": "Very strong when intervention value is harm-aligned.",
        },
        {
            "score_family": "PRM/process-reward style",
            "representative_work": "Tool-call Reward Model; ToolPRMBench; AgentProcessBench",
            "policy_names": "PRM_task, PRM_value",
            "paper_role": "Recent-work comparable baseline family",
            "interpretation": "Process quality can be misaligned with downstream verification gain.",
        },
        {
            "score_family": "Learned reward/value estimator",
            "representative_work": "AgentPRM / AgentRM-style reward modeling",
            "policy_names": "value_router",
            "paper_role": "Negative result / appendix",
            "interpretation": "Learned value estimator did not reliably win in current setting.",
        },
        {
            "score_family": "Consequence-aware proxy",
            "representative_work": "This paper",
            "policy_names": "p_times_H",
            "paper_role": "Main transparent proxy",
            "interpretation": "Strong in moderate-budget and expected p-by-harm regimes.",
        },
        {
            "score_family": "q/cost-aware proxy",
            "representative_work": "This paper",
            "policy_names": "q_pH_minus_cost, q_pH_per_cost",
            "paper_role": "Regime diagnostic",
            "interpretation": "Useful when verifier reliability or verification cost varies.",
        },
    ]

    write_csv(out_dir / "topconf_related_work_positioning_matrix.csv", topconf_rows, [
        "tier",
        "work_or_family",
        "venue_status_for_positioning",
        "their_target",
        "our_comparable_score_family",
        "our_score",
        "why_not_full_reproduction",
        "paper_claim",
    ])

    write_csv(out_dir / "score_family_mapping.csv", score_family_rows, [
        "score_family",
        "representative_work",
        "policy_names",
        "paper_role",
        "interpretation",
    ])


def summarize_gate4a(out_dir, root):
    gate4_budget = read_optional(root / "artifacts/aaai_gate4a_formal_misalignment_slices_20260623/budget_regime_transition_main_eval.csv")
    gate4_mismatch = read_optional(root / "artifacts/aaai_gate4a_formal_misalignment_slices_20260623/formal_misalignment_metrics.csv")
    bootstrap = read_optional(root / "artifacts/aaai_finishing_consolidation_20260623/gate4a_bootstrap_pairwise_ci.csv")

    rows = []

    # Flexible budget summary.
    for r in gate4_budget:
        policy = normalize_policy_name(r.get("policy", r.get("score", r.get("method", ""))))
        family = family_for_policy(policy)
        budget = r.get("budget_frac", r.get("budget", r.get("budget_pct", "")))

        rows.append({
            "source": "Gate4A_budget",
            "setting": r.get("setting", "main_eval"),
            "budget_or_regime": budget,
            "policy": policy,
            "score_family": family,
            "representative_work": representative_work_for_family(family),
            "selected_gain_or_value": r.get("avg_gain", r.get("selected_avg_gain", r.get("avg_selected_gain", ""))),
            "oracle_regret": r.get("regret", r.get("oracle_regret", r.get("avg_oracle_regret", ""))),
            "oracle_recall": r.get("oracle_recall", r.get("avg_oracle_recall", "")),
            "high_harm_recall": r.get("hh_recall", r.get("high_harm_recall", r.get("avg_high_harm_recall", ""))),
            "mismatch_metric": "",
            "mismatch_value": "",
            "interpretation": "Gate4A exact-budget intervention-value alignment.",
        })

    # Flexible mismatch metrics.
    for r in gate4_mismatch:
        policy = normalize_policy_name(r.get("policy", r.get("score", r.get("score_name", ""))))
        family = family_for_policy(policy)

        for key in r.keys():
            kl = key.lower()
            if "high_score_low_gain" in kl or "low_score_high_gain" in kl or "high_score_high_gain" in kl:
                rows.append({
                    "source": "Gate4A_mismatch",
                    "setting": "main_eval",
                    "budget_or_regime": "",
                    "policy": policy,
                    "score_family": family,
                    "representative_work": representative_work_for_family(family),
                    "selected_gain_or_value": "",
                    "oracle_regret": "",
                    "oracle_recall": "",
                    "high_harm_recall": "",
                    "mismatch_metric": key,
                    "mismatch_value": r.get(key, ""),
                    "interpretation": "Mismatch between local score and downstream intervention gain.",
                })

    # Bootstrap pairwise support.
    for r in bootstrap:
        comp = r.get("comparison", "")
        metric = r.get("metric", "")
        rows.append({
            "source": "Gate4A_bootstrap",
            "setting": "main_eval",
            "budget_or_regime": r.get("budget_frac", ""),
            "policy": "p_times_H_vs_baseline",
            "score_family": "Consequence-aware proxy vs baseline",
            "representative_work": "This paper vs PRM/process/harm/uncertainty families",
            "selected_gain_or_value": r.get("mean_diff_positive_favors_p_times_H", ""),
            "oracle_regret": "",
            "oracle_recall": "",
            "high_harm_recall": "",
            "mismatch_metric": f"{comp}:{metric}",
            "mismatch_value": f"CI=[{r.get('ci95_low','')},{r.get('ci95_high','')}]; p_positive={r.get('p_positive','')}",
            "interpretation": "Positive mean favors p_times_H; wide CIs should be described cautiously.",
        })

    write_csv(out_dir / "related_work_score_family_empirical_summary.csv", rows, [
        "source",
        "setting",
        "budget_or_regime",
        "policy",
        "score_family",
        "representative_work",
        "selected_gain_or_value",
        "oracle_regret",
        "oracle_recall",
        "high_harm_recall",
        "mismatch_metric",
        "mismatch_value",
        "interpretation",
    ])

    return rows


def summarize_gate5c(out_dir, root):
    winners = read_optional(root / "artifacts/aaai_finishing_consolidation_20260623/gate5c_winner_stability_counts_clean.csv")
    stability = read_optional(root / "artifacts/aaai_finishing_consolidation_20260623/gate5c_groupseed_stability_summary.csv")

    winner_rows = []

    for r in winners:
        policy = normalize_policy_name(r.get("policy", ""))
        family = family_for_policy(policy)

        winner_rows.append({
            "setting": r.get("setting", ""),
            "regime": r.get("regime", ""),
            "policy": policy,
            "score_family": family,
            "representative_work": representative_work_for_family(family),
            "winner_count": r.get("winner_count", ""),
            "winner_rate": r.get("winner_rate", ""),
            "n_group_seeds": r.get("n_group_seeds", ""),
            "interpretation": regime_interpretation(r.get("regime", ""), family),
        })

    write_csv(out_dir / "related_work_score_family_winner_summary.csv", winner_rows, [
        "setting",
        "regime",
        "policy",
        "score_family",
        "representative_work",
        "winner_count",
        "winner_rate",
        "n_group_seeds",
        "interpretation",
    ])

    # A compact per-regime best family summary.
    by_regime = defaultdict(list)
    for r in winner_rows:
        by_regime[(r["setting"], r["regime"])].append(r)

    compact = []
    for (setting, regime), rs in sorted(by_regime.items()):
        best = max(rs, key=lambda x: fl(x.get("winner_rate")))
        compact.append({
            "setting": setting,
            "regime": regime,
            "dominant_policy": best["policy"],
            "dominant_score_family": best["score_family"],
            "dominant_representative_work": best["representative_work"],
            "winner_rate": best["winner_rate"],
            "message_for_paper": regime_message(regime, best["score_family"]),
        })

    write_csv(out_dir / "related_work_score_family_regime_compact.csv", compact, [
        "setting",
        "regime",
        "dominant_policy",
        "dominant_score_family",
        "dominant_representative_work",
        "winner_rate",
        "message_for_paper",
    ])

    return winner_rows, compact


def regime_interpretation(regime, family):
    if regime == "A_harm_aligned":
        return "When value is harm-aligned, runtime/harm-risk proxies should be strong."
    if regime == "B_expected_p_harm":
        return "When value depends on uncertainty times harm, consequence-aware scores should be strong."
    if regime in {"C_qcost_net", "D_qcost_roi"}:
        return "When q/cost varies, q/cost-aware or consequence-aware scores should be competitive."
    return "Regime-dependent alignment diagnostic."


def regime_message(regime, family):
    if regime == "A_harm_aligned":
        return "Structural harm/risk families can be sufficient when intervention value is harm-aligned."
    if regime == "B_expected_p_harm":
        return "Consequence-aware scoring is appropriate when expected value depends on uncertainty and harm."
    if regime in {"C_qcost_net", "D_qcost_roi"}:
        return "q/cost-aware and consequence-aware scores are relevant when verification reliability or cost varies."
    return "Different related-work score families align under different objectives."


def write_readme(out_dir):
    text = """# Related-Work Score-Family Comparison

Purpose:
This is a lightweight comparison against recent related-work families without full external benchmark reproduction.

The comparison maps recent work to score families:
- AgentSpec / runtime enforcement -> H_only / structural harm.
- Tool-call Reward Model, ToolPRMBench, AgentProcessBench -> PRM/process-reward scores.
- AgentPRM / AgentRM-style reward modeling -> value_router.
- This paper -> p_times_H and q/cost-aware proxies.
- Oracle -> true counterfactual intervention gain.

Why no full reproduction:
Most related work evaluates process quality, reward quality, runtime enforcement, future risk, or reward hacking incidence.
Our target is exact-budget counterfactual verification gain:
Delta = L(skip) - L(verify).

Paper-safe claim:
We compare the corresponding score families under our intervention-value objective.
We do not claim system-level superiority over AgentSpec, Tool-call Reward Model, ToolPRMBench, AgentProcessBench, or reward-hacking benchmarks.

Outputs:
- topconf_related_work_positioning_matrix.csv
- score_family_mapping.csv
- related_work_score_family_empirical_summary.csv
- related_work_score_family_winner_summary.csv
- related_work_score_family_regime_compact.csv
"""
    (out_dir / "RELATED_WORK_COMPARISON_README.md").write_text(text, encoding="utf-8")


def main():
    root = Path(__file__).resolve().parent.parent
    out_dir = root / "artifacts/aaai_related_work_score_family_comparison_20260623"
    out_dir.mkdir(parents=True, exist_ok=True)

    build_positioning_tables(out_dir)
    gate4_rows = summarize_gate4a(out_dir, root)
    gate5c_rows, compact_rows = summarize_gate5c(out_dir, root)
    write_readme(out_dir)

    print("WROTE", out_dir)
    print()
    print("===== Compact regime-family summary =====")
    for r in compact_rows:
        print(
            r["setting"],
            r["regime"],
            "dominant_policy", r["dominant_policy"],
            "family", r["dominant_score_family"],
            "winner_rate", r["winner_rate"],
        )
    print()
    print("===== Gate4A related-work empirical rows:", len(gate4_rows), "=====")
    print("===== Gate5C winner rows:", len(gate5c_rows), "=====")


if __name__ == "__main__":
    main()

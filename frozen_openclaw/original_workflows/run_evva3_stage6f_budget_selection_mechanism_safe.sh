#!/usr/bin/env bash

# EVVA_3 Stage 6F:
# Budget-wise selection mechanism audit.
#
# This is a post-confirmatory explanatory analysis.
#
# It preserves pooled global exact-B selection and measures:
# - tie-aware selected-set overlap;
# - expected switched selection mass;
# - cutoff tie structure;
# - swapped-in versus swapped-out candidate properties;
# - case redistribution;
# - budget-specific paired seed-cluster bootstrap intervals.
#
# No new seeds.
# No method modification.
# No parameter selection.
# No post-hoc equivalence threshold.

die() {
  echo "ERROR: $*" >&2
  exit 1
}

WORKSPACE="$HOME/.openclaw/workspace/skills/openclaw_pilot_v4_large_exactB_20260707_EVVA_3_signal_repair_20260713"

[ -d "$WORKSPACE" ] \
  || die "Workspace not found."

cd "$WORKSPACE" \
  || die "Cannot enter workspace."

for pointer in \
  artifacts/aaai_evva3_stage4f_latest.txt \
  artifacts/aaai_evva3_stage5a_latest.txt \
  artifacts/aaai_evva3_stage5b_latest.txt \
  artifacts/aaai_evva3_stage6c_latest.txt \
  artifacts/aaai_evva3_stage6e_latest.txt
do
  [ -f "$pointer" ] \
    || die "Missing pointer: $pointer"
done

STAGE4F="$(cat artifacts/aaai_evva3_stage4f_latest.txt)"
STAGE5A="$(cat artifacts/aaai_evva3_stage5a_latest.txt)"
STAGE5B="$(cat artifacts/aaai_evva3_stage5b_latest.txt)"
STAGE6C="$(cat artifacts/aaai_evva3_stage6c_latest.txt)"
STAGE6E="$(cat artifacts/aaai_evva3_stage6e_latest.txt)"

V5M="code/aaai_v5m_signal_availability_gated_evva.py"
FINAL_METHOD="$STAGE4F/code/aaai_evva3_final_evva_sag.py"

C1_RAW="$STAGE5A/c1_6500_6799/raw/full_agent_candidate_rows_6500_6799.csv"
C2_RAW="$STAGE5A/c2_6800_7099/raw/full_agent_candidate_rows_6800_7099.csv"

SEALED_HASHES="$STAGE5A/hashes/SEALED_RAW_SHA256.txt"
STAGE5B_HASHES="$STAGE5B/hashes/post_evaluation_sha256.txt"
CONFIRMATORY_DECISION="$STAGE5B/reports/confirmatory_decision.json"

STAGE6C_CODE="$STAGE6C/code/aaai_evva3_stage6c_ablation_robustness.py"
STAGE6E_SUMMARY="$STAGE6E/reports/stage6e_summary.json"

for required in \
  "$V5M" \
  "$FINAL_METHOD" \
  "$C1_RAW" \
  "$C2_RAW" \
  "$SEALED_HASHES" \
  "$STAGE5B_HASHES" \
  "$CONFIRMATORY_DECISION" \
  "$STAGE6C_CODE" \
  "$STAGE6E_SUMMARY"
do
  [ -f "$required" ] \
    || die "Missing required input: $required"
done

sha256sum -c "$SEALED_HASHES" \
  || die "Stage 5A sealed hashes failed."

sha256sum -c "$STAGE5B_HASHES" \
  || die "Stage 5B frozen hashes failed."

export EVVA3_STAGE6F_DECISION="$CONFIRMATORY_DECISION"
export EVVA3_STAGE6F_STAGE6E="$STAGE6E_SUMMARY"

python3 - <<'PY' \
  || die "Frozen evidence validation failed."
import json
import os
from pathlib import Path

with Path(
    os.environ["EVVA3_STAGE6F_DECISION"]
).open(
    encoding="utf-8"
) as handle:
    decision = json.load(handle)

with Path(
    os.environ["EVVA3_STAGE6F_STAGE6E"]
).open(
    encoding="utf-8"
) as handle:
    stage6e = json.load(handle)

if decision.get("decision") != "PASS":
    raise SystemExit(
        "Stage 5B confirmatory decision is not PASS."
    )

if not decision.get(
    "method_remains_frozen"
):
    raise SystemExit(
        "Frozen-method status is absent."
    )

if decision.get(
    "method_modification_permitted_after_result"
):
    raise SystemExit(
        "Method modification is unexpectedly permitted."
    )

if not stage6e.get("method_frozen"):
    raise SystemExit(
        "Stage 6E does not report a frozen method."
    )

if stage6e.get("method_modified"):
    raise SystemExit(
        "Stage 6E unexpectedly modified the method."
    )

expected = float(
    decision["combined_point_delta_aubc"]
)

observed = float(
    stage6e["combined_total_aubc_delta"]
)

if abs(expected - observed) > 1e-9:
    raise SystemExit(
        "Stage 5B and Stage 6E total deltas disagree."
    )

print("FROZEN_EVIDENCE_VALIDATION=PASS")
PY

OUT="artifacts/aaai_evva3_stage6f_budget_selection_mechanism_20260714"

if [ -f "$OUT/reports/stage6f_summary.json" ]; then
  echo "Stage 6F was already completed:"
  cat "$OUT/reports/stage6f_summary.json"
  exit 0
fi

mkdir -p \
  "$OUT/code" \
  "$OUT/evidence" \
  "$OUT/hashes" \
  "$OUT/logs" \
  "$OUT/manifests" \
  "$OUT/results" \
  "$OUT/reports" \
  || die "Cannot create Stage 6F directories."

echo "$OUT" \
  > artifacts/aaai_evva3_stage6f_latest.txt

BOOTSTRAP_REPS="${EVVA3_STAGE6F_BOOTSTRAP_REPS:-5000}"

export EVVA3_STAGE6F_OUT="$OUT"
export EVVA3_STAGE6F_STAGE6C_CODE="$STAGE6C_CODE"
export EVVA3_STAGE6F_BOOTSTRAP_REPS="$BOOTSTRAP_REPS"

# Required while importing the Stage 6C evaluator.
export EVVA3_STAGE6C_OUT="$STAGE6C"
export EVVA3_STAGE6C_V5M="$V5M"
export EVVA3_STAGE6C_FINAL="$FINAL_METHOD"
export EVVA3_STAGE6C_C1="$C1_RAW"
export EVVA3_STAGE6C_C2="$C2_RAW"
export EVVA3_STAGE6C_BOOTSTRAP_REPS="1"

cp \
  "$CONFIRMATORY_DECISION" \
  "$OUT/evidence/confirmatory_decision_frozen.json"

cp \
  "$STAGE6E_SUMMARY" \
  "$OUT/evidence/stage6e_summary.json"

{
  sha256sum "$V5M"
  sha256sum "$FINAL_METHOD"
  sha256sum "$C1_RAW"
  sha256sum "$C2_RAW"
  sha256sum "$CONFIRMATORY_DECISION"
  sha256sum "$STAGE6C_CODE"
  sha256sum "$STAGE6E_SUMMARY"
} > "$OUT/hashes/pre_stage6f_sha256.txt"

cat > "$OUT/code/aaai_evva3_stage6f_budget_selection_mechanism.py" <<'PY'
#!/usr/bin/env python3

"""Budget-wise selection mechanism audit.

This post-confirmatory audit compares the frozen Final-EVVA-SAG ranking
against the original Locked-EVVA-SAG ranking.

For each budget and block it measures:

- tie-aware expected selected-set overlap;
- expected switched selection mass;
- selected gain margin;
- properties of candidates receiving more versus less inclusion weight;
- case-level selection and gain redistribution;
- cutoff tie sizes and fractional inclusion;
- rank correlation between Final and Locked scores.

Paired seed-cluster bootstrap intervals are also estimated separately
for C1, C2, and a two-level combined analysis.

No method is selected or modified.
"""

import csv
import importlib.util
import json
import math
import os
import platform
import statistics
from collections import Counter, defaultdict
from pathlib import Path
from typing import Dict, List, Sequence, Tuple

import numpy as np
from scipy.stats import rankdata


OUT = Path(
    os.environ["EVVA3_STAGE6F_OUT"]
)

STAGE6C_CODE = Path(
    os.environ[
        "EVVA3_STAGE6F_STAGE6C_CODE"
    ]
)

BOOTSTRAP_REPS = int(
    os.environ.get(
        "EVVA3_STAGE6F_BOOTSTRAP_REPS",
        "5000",
    )
)

RANDOM_SEED = 20260714
TOLERANCE = 1e-9
EPSILON = 1e-12


def import_stage6c():
    specification = (
        importlib.util.spec_from_file_location(
            "evva3_stage6f_stage6c",
            STAGE6C_CODE,
        )
    )

    if (
        specification is None
        or specification.loader is None
    ):
        raise RuntimeError(
            "Cannot import Stage 6C evaluator."
        )

    module = importlib.util.module_from_spec(
        specification
    )

    specification.loader.exec_module(
        module
    )

    return module


M = import_stage6c()

CASES = list(
    M.EXPECTED_CASES
)


def write_csv(
    path: Path,
    rows: Sequence[Dict[str, object]],
    fields: Sequence[str],
) -> None:
    path.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    with path.open(
        "w",
        newline="",
        encoding="utf-8",
    ) as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=list(fields),
            extrasaction="ignore",
        )

        writer.writeheader()
        writer.writerows(rows)


def quantile(
    values: Sequence[float],
    probability: float,
) -> float:
    return float(
        np.quantile(
            np.asarray(
                values,
                dtype=float,
            ),
            probability,
        )
    )


def selection_weights(
    scores: np.ndarray,
    exact_budget: int,
) -> np.ndarray:
    """Return expected exact-B tie-aware inclusion weights."""

    if exact_budget < 1:
        raise RuntimeError(
            "Exact budget must be positive."
        )

    if exact_budget > len(scores):
        raise RuntimeError(
            "Exact budget exceeds row count."
        )

    weights = np.zeros(
        len(scores),
        dtype=float,
    )

    groups: Dict[
        float,
        List[int],
    ] = defaultdict(list)

    for index, score in enumerate(scores):
        groups[
            float(score)
        ].append(index)

    remaining = float(
        exact_budget
    )

    for score in sorted(
        groups,
        reverse=True,
    ):
        indices = groups[score]
        group_size = len(indices)

        if remaining >= group_size:
            weights[indices] = 1.0
            remaining -= group_size
            continue

        if remaining > 0.0:
            weights[indices] = (
                remaining / group_size
            )
            remaining = 0.0

        break

    if abs(
        float(np.sum(weights))
        - exact_budget
    ) > TOLERANCE:
        raise RuntimeError(
            "Tie-aware inclusion weights do not sum to exact B."
        )

    return weights


def cutoff_statistics(
    scores: np.ndarray,
    exact_budget: int,
) -> Dict[str, object]:
    groups = Counter(
        float(score)
        for score in scores
    )

    selected_before = 0
    cutoff_score = None
    cutoff_tie_size = None
    cutoff_selected_weight = None
    cutoff_fraction = None

    for score in sorted(
        groups,
        reverse=True,
    ):
        group_size = groups[score]

        if (
            selected_before
            + group_size
            < exact_budget
        ):
            selected_before += group_size
            continue

        needed = (
            exact_budget
            - selected_before
        )

        cutoff_score = score
        cutoff_tie_size = group_size
        cutoff_selected_weight = needed
        cutoff_fraction = (
            needed / group_size
        )

        break

    if cutoff_score is None:
        raise RuntimeError(
            "Could not identify cutoff score."
        )

    return {
        "unique_scores": len(groups),
        "largest_tie_size": max(
            groups.values()
        ),
        "cutoff_score": cutoff_score,
        "cutoff_tie_size": (
            cutoff_tie_size
        ),
        "cutoff_selected_weight": (
            cutoff_selected_weight
        ),
        "cutoff_fraction_selected": (
            cutoff_fraction
        ),
        "cutoff_is_fractional_tie": (
            cutoff_fraction is not None
            and cutoff_fraction < 1.0
        ),
    }


def weighted_mean(
    values: np.ndarray,
    weights: np.ndarray,
) -> float:
    total = float(
        np.sum(weights)
    )

    if total <= EPSILON:
        return float("nan")

    return float(
        np.sum(
            values * weights
        )
        / total
    )


def safe_spearman(
    first: np.ndarray,
    second: np.ndarray,
) -> float:
    first_ranks = rankdata(
        first,
        method="average",
    )

    second_ranks = rankdata(
        second,
        method="average",
    )

    first_std = float(
        np.std(first_ranks)
    )

    second_std = float(
        np.std(second_ranks)
    )

    if (
        first_std <= EPSILON
        or second_std <= EPSILON
    ):
        return float("nan")

    return float(
        np.corrcoef(
            first_ranks,
            second_ranks,
        )[0, 1]
    )


def make_state(
    block: Dict[str, object],
) -> Dict[str, object]:
    calibration_rows = block[
        "calibration_rows"
    ]

    evaluation_rows = block[
        "evaluation_rows"
    ]

    gains = np.asarray([
        float(row["_gain"])
        for row in evaluation_rows
    ], dtype=float)

    p_values = np.asarray([
        float(row["_p"])
        for row in evaluation_rows
    ], dtype=float)

    H_values = np.asarray([
        float(row["_H"])
        for row in evaluation_rows
    ], dtype=float)

    pH_values = np.asarray([
        float(row["_pH"])
        for row in evaluation_rows
    ], dtype=float)

    cases = np.asarray([
        str(row["_case"])
        for row in evaluation_rows
    ], dtype=object)

    seeds = np.asarray([
        int(row["_seed"])
        for row in evaluation_rows
    ], dtype=int)

    candidate_ids = np.asarray([
        str(
            row.get(
                "candidate_id",
                "",
            )
        )
        for row in evaluation_rows
    ], dtype=object)

    final_score = M.frozen_final_scores(
        calibration_rows,
        evaluation_rows,
    )

    locked_by_budget = M.locked_scores(
        calibration_rows,
        evaluation_rows,
    )

    seed_indices: Dict[
        int,
        List[int],
    ] = defaultdict(list)

    for index, seed in enumerate(
        seeds
    ):
        seed_indices[
            int(seed)
        ].append(index)

    return {
        "name": str(
            block["name"]
        ),
        "evaluation_rows": evaluation_rows,
        "gains": gains,
        "p": p_values,
        "H": H_values,
        "pH": pH_values,
        "cases": cases,
        "seeds": seeds,
        "candidate_ids": candidate_ids,
        "final_score": final_score,
        "locked_by_budget": (
            locked_by_budget
        ),
        "seed_indices": seed_indices,
    }


def analyze_budget(
    state: Dict[str, object],
    indices: np.ndarray,
    fraction: float,
) -> Dict[str, object]:
    budget_percent = int(
        round(
            fraction * 100
        )
    )

    gains = state["gains"][
        indices
    ]

    p_values = state["p"][
        indices
    ]

    H_values = state["H"][
        indices
    ]

    pH_values = state["pH"][
        indices
    ]

    cases = state["cases"][
        indices
    ]

    final_scores = state[
        "final_score"
    ][indices]

    locked_scores = state[
        "locked_by_budget"
    ][budget_percent][indices]

    exact_budget = M.exact_b(
        len(indices),
        fraction,
    )

    final_weights = selection_weights(
        final_scores,
        exact_budget,
    )

    locked_weights = selection_weights(
        locked_scores,
        exact_budget,
    )

    delta_weights = (
        final_weights
        - locked_weights
    )

    swapped_in_weights = np.maximum(
        delta_weights,
        0.0,
    )

    swapped_out_weights = np.maximum(
        -delta_weights,
        0.0,
    )

    overlap_mass = float(
        np.sum(
            np.minimum(
                final_weights,
                locked_weights,
            )
        )
    )

    switched_mass = float(
        np.sum(
            swapped_in_weights
        )
    )

    switched_out_mass = float(
        np.sum(
            swapped_out_weights
        )
    )

    if abs(
        switched_mass
        - switched_out_mass
    ) > TOLERANCE:
        raise RuntimeError(
            "Swapped-in and swapped-out masses disagree."
        )

    if abs(
        switched_mass
        - (
            exact_budget
            - overlap_mass
        )
    ) > TOLERANCE:
        raise RuntimeError(
            "Overlap/switch identity failed."
        )

    final_selected_mean = float(
        np.sum(
            final_weights
            * gains
        )
        / exact_budget
    )

    locked_selected_mean = float(
        np.sum(
            locked_weights
            * gains
        )
        / exact_budget
    )

    margin = (
        final_selected_mean
        - locked_selected_mean
    )

    contribution_check = float(
        np.sum(
            delta_weights
            * gains
        )
        / exact_budget
    )

    if abs(
        margin
        - contribution_check
    ) > TOLERANCE:
        raise RuntimeError(
            "Gain contribution identity failed."
        )

    swapped_in_gain = weighted_mean(
        gains,
        swapped_in_weights,
    )

    swapped_out_gain = weighted_mean(
        gains,
        swapped_out_weights,
    )

    gain_gap = (
        swapped_in_gain
        - swapped_out_gain
        if (
            math.isfinite(
                swapped_in_gain
            )
            and math.isfinite(
                swapped_out_gain
            )
        )
        else float("nan")
    )

    relative_margin_percent = (
        100.0
        * margin
        / abs(
            locked_selected_mean
        )
        if abs(
            locked_selected_mean
        ) > EPSILON
        else float("nan")
    )

    final_cutoff = cutoff_statistics(
        final_scores,
        exact_budget,
    )

    locked_cutoff = cutoff_statistics(
        locked_scores,
        exact_budget,
    )

    return {
        "budget_percent": (
            budget_percent
        ),
        "exact_B": exact_budget,
        "final_weights": final_weights,
        "locked_weights": locked_weights,
        "delta_weights": delta_weights,
        "swapped_in_weights": (
            swapped_in_weights
        ),
        "swapped_out_weights": (
            swapped_out_weights
        ),
        "final_selected_mean_gain": (
            final_selected_mean
        ),
        "locked_selected_mean_gain": (
            locked_selected_mean
        ),
        "margin": margin,
        "relative_margin_percent": (
            relative_margin_percent
        ),
        "overlap_mass": overlap_mass,
        "overlap_fraction": (
            overlap_mass / exact_budget
        ),
        "expected_jaccard": (
            overlap_mass
            / (
                2.0 * exact_budget
                - overlap_mass
            )
        ),
        "switched_mass": switched_mass,
        "switched_fraction": (
            switched_mass
            / exact_budget
        ),
        "changed_row_count": int(
            np.sum(
                np.abs(
                    delta_weights
                ) > EPSILON
            )
        ),
        "swapped_in_mean_gain": (
            swapped_in_gain
        ),
        "swapped_out_mean_gain": (
            swapped_out_gain
        ),
        "swapped_gain_gap": gain_gap,
        "swapped_in_mean_p": weighted_mean(
            p_values,
            swapped_in_weights,
        ),
        "swapped_out_mean_p": weighted_mean(
            p_values,
            swapped_out_weights,
        ),
        "swapped_in_mean_H": weighted_mean(
            H_values,
            swapped_in_weights,
        ),
        "swapped_out_mean_H": weighted_mean(
            H_values,
            swapped_out_weights,
        ),
        "swapped_in_mean_pH": weighted_mean(
            pH_values,
            swapped_in_weights,
        ),
        "swapped_out_mean_pH": weighted_mean(
            pH_values,
            swapped_out_weights,
        ),
        "score_spearman": safe_spearman(
            final_scores,
            locked_scores,
        ),
        "final_cutoff": final_cutoff,
        "locked_cutoff": locked_cutoff,
        "cases": cases,
        "gains": gains,
    }


def point_analysis(
    state: Dict[str, object],
) -> Tuple[
    List[Dict[str, object]],
    List[Dict[str, object]],
    List[Dict[str, object]],
]:
    indices = np.arange(
        len(
            state[
                "evaluation_rows"
            ]
        ),
        dtype=int,
    )

    budget_rows = []
    case_rows = []
    swap_rows = []

    for fraction in M.BUDGETS:
        result = analyze_budget(
            state,
            indices,
            fraction,
        )

        budget_percent = result[
            "budget_percent"
        ]

        budget_rows.append({
            "block": state["name"],
            "budget_percent": (
                budget_percent
            ),
            "exact_B": result[
                "exact_B"
            ],
            "final_selected_mean_gain": (
                result[
                    "final_selected_mean_gain"
                ]
            ),
            "locked_selected_mean_gain": (
                result[
                    "locked_selected_mean_gain"
                ]
            ),
            "margin": result["margin"],
            "relative_margin_percent": (
                result[
                    "relative_margin_percent"
                ]
            ),
            "overlap_mass": result[
                "overlap_mass"
            ],
            "overlap_fraction": result[
                "overlap_fraction"
            ],
            "expected_jaccard": result[
                "expected_jaccard"
            ],
            "switched_mass": result[
                "switched_mass"
            ],
            "switched_fraction": result[
                "switched_fraction"
            ],
            "changed_row_count": result[
                "changed_row_count"
            ],
            "score_spearman": result[
                "score_spearman"
            ],
            "swapped_in_mean_gain": (
                result[
                    "swapped_in_mean_gain"
                ]
            ),
            "swapped_out_mean_gain": (
                result[
                    "swapped_out_mean_gain"
                ]
            ),
            "swapped_gain_gap": result[
                "swapped_gain_gap"
            ],
            "swapped_in_mean_p": (
                result[
                    "swapped_in_mean_p"
                ]
            ),
            "swapped_out_mean_p": (
                result[
                    "swapped_out_mean_p"
                ]
            ),
            "swapped_in_mean_H": (
                result[
                    "swapped_in_mean_H"
                ]
            ),
            "swapped_out_mean_H": (
                result[
                    "swapped_out_mean_H"
                ]
            ),
            "swapped_in_mean_pH": (
                result[
                    "swapped_in_mean_pH"
                ]
            ),
            "swapped_out_mean_pH": (
                result[
                    "swapped_out_mean_pH"
                ]
            ),
            "final_unique_scores": (
                result[
                    "final_cutoff"
                ]["unique_scores"]
            ),
            "final_largest_tie_size": (
                result[
                    "final_cutoff"
                ]["largest_tie_size"]
            ),
            "final_cutoff_score": (
                result[
                    "final_cutoff"
                ]["cutoff_score"]
            ),
            "final_cutoff_tie_size": (
                result[
                    "final_cutoff"
                ]["cutoff_tie_size"]
            ),
            "final_cutoff_fraction_selected": (
                result[
                    "final_cutoff"
                ]["cutoff_fraction_selected"]
            ),
            "locked_unique_scores": (
                result[
                    "locked_cutoff"
                ]["unique_scores"]
            ),
            "locked_largest_tie_size": (
                result[
                    "locked_cutoff"
                ]["largest_tie_size"]
            ),
            "locked_cutoff_score": (
                result[
                    "locked_cutoff"
                ]["cutoff_score"]
            ),
            "locked_cutoff_tie_size": (
                result[
                    "locked_cutoff"
                ]["cutoff_tie_size"]
            ),
            "locked_cutoff_fraction_selected": (
                result[
                    "locked_cutoff"
                ]["cutoff_fraction_selected"]
            ),
        })

        cases = result["cases"]
        gains = result["gains"]

        for case_type in CASES:
            mask = (
                cases == case_type
            )

            final_count = float(
                np.sum(
                    result[
                        "final_weights"
                    ][mask]
                )
            )

            locked_count = float(
                np.sum(
                    result[
                        "locked_weights"
                    ][mask]
                )
            )

            final_gain_sum = float(
                np.sum(
                    result[
                        "final_weights"
                    ][mask]
                    * gains[mask]
                )
            )

            locked_gain_sum = float(
                np.sum(
                    result[
                        "locked_weights"
                    ][mask]
                    * gains[mask]
                )
            )

            case_rows.append({
                "block": state["name"],
                "budget_percent": (
                    budget_percent
                ),
                "case_type": case_type,
                "final_selected_count_weight": (
                    final_count
                ),
                "locked_selected_count_weight": (
                    locked_count
                ),
                "selected_count_weight_delta": (
                    final_count
                    - locked_count
                ),
                "final_selected_gain_sum": (
                    final_gain_sum
                ),
                "locked_selected_gain_sum": (
                    locked_gain_sum
                ),
                "gain_sum_delta": (
                    final_gain_sum
                    - locked_gain_sum
                ),
                "global_mean_margin_contribution": (
                    (
                        final_gain_sum
                        - locked_gain_sum
                    )
                    / result["exact_B"]
                ),
            })

        for local_index, global_index in enumerate(
            indices
        ):
            delta = float(
                result[
                    "delta_weights"
                ][local_index]
            )

            if abs(delta) <= EPSILON:
                continue

            direction = (
                "swapped_in"
                if delta > 0.0
                else "swapped_out"
            )

            swap_rows.append({
                "block": state["name"],
                "budget_percent": (
                    budget_percent
                ),
                "case_type": str(
                    state["cases"][
                        global_index
                    ]
                ),
                "seed": int(
                    state["seeds"][
                        global_index
                    ]
                ),
                "candidate_id": str(
                    state[
                        "candidate_ids"
                    ][global_index]
                ),
                "direction": direction,
                "absolute_selection_weight_change": (
                    abs(delta)
                ),
                "signed_selection_weight_change": (
                    delta
                ),
                "p": float(
                    state["p"][
                        global_index
                    ]
                ),
                "H": float(
                    state["H"][
                        global_index
                    ]
                ),
                "pH": float(
                    state["pH"][
                        global_index
                    ]
                ),
                "intervention_gain": float(
                    state["gains"][
                        global_index
                    ]
                ),
                "gain_contribution_to_global_margin": (
                    delta
                    * float(
                        state["gains"][
                            global_index
                        ]
                    )
                    / result["exact_B"]
                ),
            })

    return (
        budget_rows,
        case_rows,
        swap_rows,
    )


def bootstrap_block(
    state: Dict[str, object],
    rng: np.random.Generator,
) -> Dict[int, Dict[str, List[float]]]:
    seed_indices = state[
        "seed_indices"
    ]

    seeds = np.asarray(
        sorted(seed_indices),
        dtype=int,
    )

    output = {
        int(
            round(
                fraction * 100
            )
        ): {
            "margin": [],
            "overlap_fraction": [],
            "switched_fraction": [],
            "score_spearman": [],
        }
        for fraction in M.BUDGETS
    }

    for _ in range(
        BOOTSTRAP_REPS
    ):
        sampled_seeds = rng.choice(
            seeds,
            size=len(seeds),
            replace=True,
        )

        indices = np.asarray([
            index
            for seed in sampled_seeds
            for index in seed_indices[
                int(seed)
            ]
        ], dtype=int)

        for fraction in M.BUDGETS:
            result = analyze_budget(
                state,
                indices,
                fraction,
            )

            budget_percent = result[
                "budget_percent"
            ]

            output[
                budget_percent
            ]["margin"].append(
                result["margin"]
            )

            output[
                budget_percent
            ]["overlap_fraction"].append(
                result[
                    "overlap_fraction"
                ]
            )

            output[
                budget_percent
            ]["switched_fraction"].append(
                result[
                    "switched_fraction"
                ]
            )

            output[
                budget_percent
            ]["score_spearman"].append(
                result[
                    "score_spearman"
                ]
            )

    return output


def summarize_distribution(
    values: Sequence[float],
) -> Dict[str, float]:
    finite = [
        float(value)
        for value in values
        if math.isfinite(
            float(value)
        )
    ]

    if not finite:
        return {
            "mean": float("nan"),
            "ci_2_5": float("nan"),
            "ci_97_5": float("nan"),
        }

    return {
        "mean": statistics.fmean(
            finite
        ),
        "ci_2_5": quantile(
            finite,
            0.025,
        ),
        "ci_97_5": quantile(
            finite,
            0.975,
        ),
    }


def main() -> None:
    loaded_blocks = [
        M.load_block(
            specification
        )
        for specification in M.BLOCKS
    ]

    states = {
        str(block["name"]): (
            make_state(block)
        )
        for block in loaded_blocks
    }

    budget_rows = []
    case_rows = []
    swap_rows = []

    for state in states.values():
        (
            block_budget_rows,
            block_case_rows,
            block_swap_rows,
        ) = point_analysis(state)

        budget_rows.extend(
            block_budget_rows
        )

        case_rows.extend(
            block_case_rows
        )

        swap_rows.extend(
            block_swap_rows
        )

    point_lookup = {
        (
            row["block"],
            int(
                row[
                    "budget_percent"
                ]
            ),
        ): row
        for row in budget_rows
    }

    combined_point_rows = []

    for fraction in M.BUDGETS:
        budget_percent = int(
            round(
                fraction * 100
            )
        )

        c1 = point_lookup[
            ("C1", budget_percent)
        ]

        c2 = point_lookup[
            ("C2", budget_percent)
        ]

        combined_point_rows.append({
            "analysis": (
                "Combined-two-level"
            ),
            "budget_percent": (
                budget_percent
            ),
            "mean_final_selected_gain": (
                statistics.fmean([
                    float(
                        c1[
                            "final_selected_mean_gain"
                        ]
                    ),
                    float(
                        c2[
                            "final_selected_mean_gain"
                        ]
                    ),
                ])
            ),
            "mean_locked_selected_gain": (
                statistics.fmean([
                    float(
                        c1[
                            "locked_selected_mean_gain"
                        ]
                    ),
                    float(
                        c2[
                            "locked_selected_mean_gain"
                        ]
                    ),
                ])
            ),
            "mean_margin": (
                statistics.fmean([
                    float(
                        c1["margin"]
                    ),
                    float(
                        c2["margin"]
                    ),
                ])
            ),
            "mean_relative_margin_percent": (
                statistics.fmean([
                    float(
                        c1[
                            "relative_margin_percent"
                        ]
                    ),
                    float(
                        c2[
                            "relative_margin_percent"
                        ]
                    ),
                ])
            ),
            "mean_overlap_fraction": (
                statistics.fmean([
                    float(
                        c1[
                            "overlap_fraction"
                        ]
                    ),
                    float(
                        c2[
                            "overlap_fraction"
                        ]
                    ),
                ])
            ),
            "mean_switched_fraction": (
                statistics.fmean([
                    float(
                        c1[
                            "switched_fraction"
                        ]
                    ),
                    float(
                        c2[
                            "switched_fraction"
                        ]
                    ),
                ])
            ),
            "mean_score_spearman": (
                statistics.fmean([
                    float(
                        c1[
                            "score_spearman"
                        ]
                    ),
                    float(
                        c2[
                            "score_spearman"
                        ]
                    ),
                ])
            ),
            "mean_swapped_gain_gap": (
                statistics.fmean([
                    float(
                        c1[
                            "swapped_gain_gap"
                        ]
                    ),
                    float(
                        c2[
                            "swapped_gain_gap"
                        ]
                    ),
                ])
            ),
        })

    rng = np.random.default_rng(
        RANDOM_SEED
    )

    block_bootstrap = {
        name: bootstrap_block(
            state,
            rng,
        )
        for name, state
        in states.items()
    }

    bootstrap_rows = []

    for block_name in [
        "C1",
        "C2",
    ]:
        for fraction in M.BUDGETS:
            budget_percent = int(
                round(
                    fraction * 100
                )
            )

            point = point_lookup[
                (
                    block_name,
                    budget_percent,
                )
            ]

            distributions = (
                block_bootstrap[
                    block_name
                ][budget_percent]
            )

            margin_summary = (
                summarize_distribution(
                    distributions[
                        "margin"
                    ]
                )
            )

            overlap_summary = (
                summarize_distribution(
                    distributions[
                        "overlap_fraction"
                    ]
                )
            )

            switch_summary = (
                summarize_distribution(
                    distributions[
                        "switched_fraction"
                    ]
                )
            )

            spearman_summary = (
                summarize_distribution(
                    distributions[
                        "score_spearman"
                    ]
                )
            )

            bootstrap_rows.append({
                "analysis": block_name,
                "budget_percent": (
                    budget_percent
                ),
                "bootstrap_repetitions": (
                    BOOTSTRAP_REPS
                ),
                "point_margin": float(
                    point["margin"]
                ),
                "bootstrap_mean_margin": (
                    margin_summary["mean"]
                ),
                "margin_ci_2_5": (
                    margin_summary[
                        "ci_2_5"
                    ]
                ),
                "margin_ci_97_5": (
                    margin_summary[
                        "ci_97_5"
                    ]
                ),
                "probability_margin_ge_zero": (
                    sum(
                        value >= 0.0
                        for value in distributions[
                            "margin"
                        ]
                    )
                    / BOOTSTRAP_REPS
                ),
                "point_overlap_fraction": (
                    float(
                        point[
                            "overlap_fraction"
                        ]
                    )
                ),
                "overlap_ci_2_5": (
                    overlap_summary[
                        "ci_2_5"
                    ]
                ),
                "overlap_ci_97_5": (
                    overlap_summary[
                        "ci_97_5"
                    ]
                ),
                "point_switched_fraction": (
                    float(
                        point[
                            "switched_fraction"
                        ]
                    )
                ),
                "switched_ci_2_5": (
                    switch_summary[
                        "ci_2_5"
                    ]
                ),
                "switched_ci_97_5": (
                    switch_summary[
                        "ci_97_5"
                    ]
                ),
                "point_score_spearman": (
                    float(
                        point[
                            "score_spearman"
                        ]
                    )
                ),
                "spearman_ci_2_5": (
                    spearman_summary[
                        "ci_2_5"
                    ]
                ),
                "spearman_ci_97_5": (
                    spearman_summary[
                        "ci_97_5"
                    ]
                ),
            })

    combined_rng = np.random.default_rng(
        RANDOM_SEED + 1
    )

    combined_point_lookup = {
        int(
            row[
                "budget_percent"
            ]
        ): row
        for row in combined_point_rows
    }

    for fraction in M.BUDGETS:
        budget_percent = int(
            round(
                fraction * 100
            )
        )

        combined_distributions = {
            "margin": [],
            "overlap_fraction": [],
            "switched_fraction": [],
            "score_spearman": [],
        }

        for index in range(
            BOOTSTRAP_REPS
        ):
            for metric in (
                combined_distributions
            ):
                available = np.asarray([
                    block_bootstrap[
                        "C1"
                    ][budget_percent][
                        metric
                    ][index],
                    block_bootstrap[
                        "C2"
                    ][budget_percent][
                        metric
                    ][index],
                ], dtype=float)

                sampled = (
                    combined_rng.choice(
                        available,
                        size=2,
                        replace=True,
                    )
                )

                combined_distributions[
                    metric
                ].append(
                    float(
                        np.mean(sampled)
                    )
                )

        margin_summary = (
            summarize_distribution(
                combined_distributions[
                    "margin"
                ]
            )
        )

        overlap_summary = (
            summarize_distribution(
                combined_distributions[
                    "overlap_fraction"
                ]
            )
        )

        switch_summary = (
            summarize_distribution(
                combined_distributions[
                    "switched_fraction"
                ]
            )
        )

        spearman_summary = (
            summarize_distribution(
                combined_distributions[
                    "score_spearman"
                ]
            )
        )

        point = combined_point_lookup[
            budget_percent
        ]

        bootstrap_rows.append({
            "analysis": (
                "Combined-two-level"
            ),
            "budget_percent": (
                budget_percent
            ),
            "bootstrap_repetitions": (
                BOOTSTRAP_REPS
            ),
            "point_margin": float(
                point["mean_margin"]
            ),
            "bootstrap_mean_margin": (
                margin_summary["mean"]
            ),
            "margin_ci_2_5": (
                margin_summary[
                    "ci_2_5"
                ]
            ),
            "margin_ci_97_5": (
                margin_summary[
                    "ci_97_5"
                ]
            ),
            "probability_margin_ge_zero": (
                sum(
                    value >= 0.0
                    for value in combined_distributions[
                        "margin"
                    ]
                )
                / BOOTSTRAP_REPS
            ),
            "point_overlap_fraction": (
                float(
                    point[
                        "mean_overlap_fraction"
                    ]
                )
            ),
            "overlap_ci_2_5": (
                overlap_summary[
                    "ci_2_5"
                ]
            ),
            "overlap_ci_97_5": (
                overlap_summary[
                    "ci_97_5"
                ]
            ),
            "point_switched_fraction": (
                float(
                    point[
                        "mean_switched_fraction"
                    ]
                )
            ),
            "switched_ci_2_5": (
                switch_summary[
                    "ci_2_5"
                ]
            ),
            "switched_ci_97_5": (
                switch_summary[
                    "ci_97_5"
                ]
            ),
            "point_score_spearman": (
                float(
                    point[
                        "mean_score_spearman"
                    ]
                )
            ),
            "spearman_ci_2_5": (
                spearman_summary[
                    "ci_2_5"
                ]
            ),
            "spearman_ci_97_5": (
                spearman_summary[
                    "ci_97_5"
                ]
            ),
        })

    combined_budget_cases = []

    for fraction in M.BUDGETS:
        budget_percent = int(
            round(
                fraction * 100
            )
        )

        for case_type in CASES:
            rows = [
                row
                for row in case_rows
                if (
                    int(
                        row[
                            "budget_percent"
                        ]
                    )
                    == budget_percent
                    and row[
                        "case_type"
                    ]
                    == case_type
                )
            ]

            if len(rows) != 2:
                raise RuntimeError(
                    "Expected two block rows "
                    "for combined case analysis."
                )

            combined_budget_cases.append({
                "analysis": (
                    "Combined-two-level"
                ),
                "budget_percent": (
                    budget_percent
                ),
                "case_type": case_type,
                "mean_selected_count_weight_delta": (
                    statistics.fmean(
                        float(
                            row[
                                "selected_count_weight_delta"
                            ]
                        )
                        for row in rows
                    )
                ),
                "mean_global_margin_contribution": (
                    statistics.fmean(
                        float(
                            row[
                                "global_mean_margin_contribution"
                            ]
                        )
                        for row in rows
                    )
                ),
            })

    bootstrap_lookup = {
        (
            row["analysis"],
            int(
                row[
                    "budget_percent"
                ]
            ),
        ): row
        for row in bootstrap_rows
    }

    focus_budgets = {}

    for budget_percent in [
        20,
        30,
        40,
        50,
        60,
        70,
        75,
    ]:
        point = combined_point_lookup[
            budget_percent
        ]

        bootstrap = bootstrap_lookup[
            (
                "Combined-two-level",
                budget_percent,
            )
        ]

        focus_budgets[
            str(budget_percent)
        ] = {
            "point_margin": float(
                point["mean_margin"]
            ),
            "relative_margin_percent": float(
                point[
                    "mean_relative_margin_percent"
                ]
            ),
            "margin_ci_2_5": float(
                bootstrap[
                    "margin_ci_2_5"
                ]
            ),
            "margin_ci_97_5": float(
                bootstrap[
                    "margin_ci_97_5"
                ]
            ),
            "probability_margin_ge_zero": float(
                bootstrap[
                    "probability_margin_ge_zero"
                ]
            ),
            "overlap_fraction": float(
                point[
                    "mean_overlap_fraction"
                ]
            ),
            "switched_fraction": float(
                point[
                    "mean_switched_fraction"
                ]
            ),
            "score_spearman": float(
                point[
                    "mean_score_spearman"
                ]
            ),
            "swapped_gain_gap": float(
                point[
                    "mean_swapped_gain_gap"
                ]
            ),
        }

    summary = {
        "status": "complete",
        "stage": "EVVA_3 Stage 6F",
        "method_frozen": True,
        "method_modified": False,
        "method_selection_performed": False,
        "new_seeds_collected": False,
        "post_hoc_equivalence_threshold_used": False,
        "bootstrap_repetitions": (
            BOOTSTRAP_REPS
        ),
        "focus_budget_mechanisms": (
            focus_budgets
        ),
        "interpretation": (
            "Overlap and switch metrics preserve "
            "global pooled exact-B allocation and "
            "use tie-aware expected inclusion weights. "
            "Budget-specific confidence intervals are "
            "descriptive post-confirmatory analyses and "
            "do not alter the frozen method."
        ),
    }

    write_csv(
        OUT
        / "results"
        / "budget_mechanism_by_block.csv",
        budget_rows,
        [
            "block",
            "budget_percent",
            "exact_B",
            "final_selected_mean_gain",
            "locked_selected_mean_gain",
            "margin",
            "relative_margin_percent",
            "overlap_mass",
            "overlap_fraction",
            "expected_jaccard",
            "switched_mass",
            "switched_fraction",
            "changed_row_count",
            "score_spearman",
            "swapped_in_mean_gain",
            "swapped_out_mean_gain",
            "swapped_gain_gap",
            "swapped_in_mean_p",
            "swapped_out_mean_p",
            "swapped_in_mean_H",
            "swapped_out_mean_H",
            "swapped_in_mean_pH",
            "swapped_out_mean_pH",
            "final_unique_scores",
            "final_largest_tie_size",
            "final_cutoff_score",
            "final_cutoff_tie_size",
            "final_cutoff_fraction_selected",
            "locked_unique_scores",
            "locked_largest_tie_size",
            "locked_cutoff_score",
            "locked_cutoff_tie_size",
            "locked_cutoff_fraction_selected",
        ],
    )

    write_csv(
        OUT
        / "results"
        / "combined_budget_mechanism.csv",
        combined_point_rows,
        [
            "analysis",
            "budget_percent",
            "mean_final_selected_gain",
            "mean_locked_selected_gain",
            "mean_margin",
            "mean_relative_margin_percent",
            "mean_overlap_fraction",
            "mean_switched_fraction",
            "mean_score_spearman",
            "mean_swapped_gain_gap",
        ],
    )

    write_csv(
        OUT
        / "results"
        / "budget_mechanism_bootstrap.csv",
        bootstrap_rows,
        [
            "analysis",
            "budget_percent",
            "bootstrap_repetitions",
            "point_margin",
            "bootstrap_mean_margin",
            "margin_ci_2_5",
            "margin_ci_97_5",
            "probability_margin_ge_zero",
            "point_overlap_fraction",
            "overlap_ci_2_5",
            "overlap_ci_97_5",
            "point_switched_fraction",
            "switched_ci_2_5",
            "switched_ci_97_5",
            "point_score_spearman",
            "spearman_ci_2_5",
            "spearman_ci_97_5",
        ],
    )

    write_csv(
        OUT
        / "results"
        / "case_redistribution_by_block.csv",
        case_rows,
        [
            "block",
            "budget_percent",
            "case_type",
            "final_selected_count_weight",
            "locked_selected_count_weight",
            "selected_count_weight_delta",
            "final_selected_gain_sum",
            "locked_selected_gain_sum",
            "gain_sum_delta",
            "global_mean_margin_contribution",
        ],
    )

    write_csv(
        OUT
        / "results"
        / "combined_case_redistribution.csv",
        combined_budget_cases,
        [
            "analysis",
            "budget_percent",
            "case_type",
            "mean_selected_count_weight_delta",
            "mean_global_margin_contribution",
        ],
    )

    write_csv(
        OUT
        / "results"
        / "swapped_candidates.csv",
        swap_rows,
        [
            "block",
            "budget_percent",
            "case_type",
            "seed",
            "candidate_id",
            "direction",
            "absolute_selection_weight_change",
            "signed_selection_weight_change",
            "p",
            "H",
            "pH",
            "intervention_gain",
            "gain_contribution_to_global_margin",
        ],
    )

    with (
        OUT
        / "reports"
        / "stage6f_summary.json"
    ).open(
        "w",
        encoding="utf-8",
    ) as handle:
        json.dump(
            summary,
            handle,
            indent=2,
            sort_keys=True,
        )

    runtime = {
        "python": platform.python_version(),
        "numpy": np.__version__,
        "scipy_rankdata": True,
        "bootstrap_repetitions": (
            BOOTSTRAP_REPS
        ),
        "random_seed": RANDOM_SEED,
    }

    with (
        OUT
        / "manifests"
        / "runtime_versions.json"
    ).open(
        "w",
        encoding="utf-8",
    ) as handle:
        json.dump(
            runtime,
            handle,
            indent=2,
            sort_keys=True,
        )

    print(
        json.dumps(
            summary,
            indent=2,
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    main()
PY

echo
echo "===================================================="
echo "EVVA_3 STAGE 6F BUDGET SELECTION MECHANISM"
echo "===================================================="
echo "Output: $OUT"
echo "Bootstrap repetitions: $BOOTSTRAP_REPS"
echo

python3 -m py_compile \
  "$OUT/code/aaai_evva3_stage6f_budget_selection_mechanism.py" \
  || die "Stage 6F failed py_compile."

python3 \
  "$OUT/code/aaai_evva3_stage6f_budget_selection_mechanism.py" \
  2>&1 | tee "$OUT/logs/stage6f.log"

STATUS="${PIPESTATUS[0]}"

[ "$STATUS" -eq 0 ] \
  || die "Stage 6F evaluation failed."

for required in \
  "$OUT/reports/stage6f_summary.json" \
  "$OUT/results/budget_mechanism_by_block.csv" \
  "$OUT/results/combined_budget_mechanism.csv" \
  "$OUT/results/budget_mechanism_bootstrap.csv" \
  "$OUT/results/case_redistribution_by_block.csv" \
  "$OUT/results/combined_case_redistribution.csv" \
  "$OUT/results/swapped_candidates.csv"
do
  [ -f "$required" ] \
    || die "Missing Stage 6F output: $required"
done

{
  sha256sum "$V5M"
  sha256sum "$FINAL_METHOD"
  sha256sum "$C1_RAW"
  sha256sum "$C2_RAW"
  sha256sum "$CONFIRMATORY_DECISION"
  sha256sum "$STAGE6C_CODE"
  sha256sum "$STAGE6E_SUMMARY"
} > "$OUT/hashes/post_stage6f_sha256.txt"

cmp -s \
  "$OUT/hashes/pre_stage6f_sha256.txt" \
  "$OUT/hashes/post_stage6f_sha256.txt" \
  || die "A frozen input changed during Stage 6F."

cat > "$OUT/reports/STAGE6F_COMPLETE.md" <<'MD'
# EVVA_3 Stage 6F completion

The frozen Final-EVVA-SAG and Locked-EVVA-SAG policies were compared at
each exact budget using tie-aware expected inclusion weights.

The audit measured selected-set overlap, switched selection mass, cutoff
ties, rank correlation, swapped-candidate properties, case redistribution,
and budget-specific paired bootstrap intervals.

No equivalence threshold was selected after observing the data.

This analysis did not modify the frozen method or confirmatory decision.
MD

find "$OUT" \
  -type f \
  ! -name 'FINAL_SHA256SUMS.txt' \
  -print0 \
  | sort -z \
  | xargs -0 sha256sum \
  > "$OUT/FINAL_SHA256SUMS.txt"

echo
echo "===================================================="
echo "EVVA_3 STAGE 6F COMPLETE"
echo "===================================================="
echo "Output: $OUT"
echo

echo "===== SUMMARY ====="
cat "$OUT/reports/stage6f_summary.json"

echo
echo "===== COMBINED BUDGET MECHANISM ====="
column -s, -t \
  < "$OUT/results/combined_budget_mechanism.csv"

echo
echo "===== COMBINED BUDGET BOOTSTRAP ====="
awk -F, '
NR == 1 ||
$1 == "Combined-two-level"
' "$OUT/results/budget_mechanism_bootstrap.csv" |
column -s, -t

echo
echo "===== COMBINED CASE REDISTRIBUTION ====="
column -s, -t \
  < "$OUT/results/combined_case_redistribution.csv"

echo
echo "PASS: Stage 6F completed without changing frozen inputs."

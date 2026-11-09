#!/usr/bin/env bash

# EVVA_3 Stage 6D:
# Post-confirmatory pairwise ablation and case-heterogeneity analysis.
#
# No new seeds.
# No method modification.
# No method selection.
# The confirmatory decision remains unchanged.

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
  artifacts/evva3_stage4f_latest.txt \
  artifacts/evva3_stage5a_latest.txt \
  artifacts/evva3_stage5b_latest.txt \
  artifacts/evva3_stage6c_latest.txt
do
  [ -f "$pointer" ] \
    || die "Missing pointer: $pointer"
done

STAGE4F="$(cat artifacts/evva3_stage4f_latest.txt)"
STAGE5A="$(cat artifacts/evva3_stage5a_latest.txt)"
STAGE5B="$(cat artifacts/evva3_stage5b_latest.txt)"
STAGE6C="$(cat artifacts/evva3_stage6c_latest.txt)"

V5M="code/evva_v5m_signal_availability_gated_evva.py"
FINAL_METHOD="$STAGE4F/code/evva3_final_evva_sag.py"

C1_RAW="$STAGE5A/c1_6500_6799/raw/full_agent_candidate_rows_6500_6799.csv"
C2_RAW="$STAGE5A/c2_6800_7099/raw/full_agent_candidate_rows_6800_7099.csv"

SEALED_HASHES="$STAGE5A/hashes/SEALED_RAW_SHA256.txt"
STAGE5B_HASHES="$STAGE5B/hashes/post_evaluation_sha256.txt"
CONFIRMATORY_DECISION="$STAGE5B/reports/confirmatory_decision.json"

STAGE6C_CODE="$STAGE6C/code/evva3_stage6c_ablation_robustness.py"
STAGE6C_SUMMARY="$STAGE6C/reports/stage6c_summary.json"
STAGE6C_TIES="$STAGE6C/results/score_ties.csv"

for required in \
  "$V5M" \
  "$FINAL_METHOD" \
  "$C1_RAW" \
  "$C2_RAW" \
  "$SEALED_HASHES" \
  "$STAGE5B_HASHES" \
  "$CONFIRMATORY_DECISION" \
  "$STAGE6C_CODE" \
  "$STAGE6C_SUMMARY" \
  "$STAGE6C_TIES"
do
  [ -f "$required" ] \
    || die "Missing required input: $required"
done

sha256sum -c "$SEALED_HASHES" \
  || die "Stage 5A sealed hashes failed."

sha256sum -c "$STAGE5B_HASHES" \
  || die "Stage 5B frozen hashes failed."

export EVVA3_STAGE6D_DECISION="$CONFIRMATORY_DECISION"
export EVVA3_STAGE6D_STAGE6C_SUMMARY="$STAGE6C_SUMMARY"

python3 - <<'PY' \
  || die "Frozen evidence validation failed."
import json
import os
from pathlib import Path


with Path(
    os.environ["EVVA3_STAGE6D_DECISION"]
).open(
    encoding="utf-8"
) as handle:
    decision = json.load(handle)

with Path(
    os.environ[
        "EVVA3_STAGE6D_STAGE6C_SUMMARY"
    ]
).open(
    encoding="utf-8"
) as handle:
    stage6c = json.load(handle)

if decision.get("decision") != "PASS":
    raise SystemExit(
        "Stage 5B decision is not PASS."
    )

if decision.get(
    "method_modification_permitted_after_result"
):
    raise SystemExit(
        "Method modification is unexpectedly permitted."
    )

if not stage6c.get("method_frozen"):
    raise SystemExit(
        "Stage 6C does not report a frozen method."
    )

if stage6c.get("method_modified"):
    raise SystemExit(
        "Stage 6C unexpectedly modified the method."
    )

print("FROZEN_EVIDENCE_VALIDATION=PASS")
PY

OUT="artifacts/evva3_stage6d_pairwise_case_analysis_20260714"

if [ -f "$OUT/reports/stage6d_summary.json" ]; then
  echo "Stage 6D was already completed:"
  cat "$OUT/reports/stage6d_summary.json"
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
  || die "Cannot create Stage 6D directories."

echo "$OUT" \
  > artifacts/evva3_stage6d_latest.txt

BOOTSTRAP_REPS="${EVVA3_STAGE6D_BOOTSTRAP_REPS:-5000}"

export EVVA3_STAGE6D_OUT="$OUT"
export EVVA3_STAGE6D_STAGE6C_CODE="$STAGE6C_CODE"
export EVVA3_STAGE6D_BOOTSTRAP_REPS="$BOOTSTRAP_REPS"

# Environment required when importing the frozen Stage 6C evaluator.
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
  "$STAGE6C_SUMMARY" \
  "$OUT/evidence/stage6c_summary.json"

cp \
  "$STAGE6C_TIES" \
  "$OUT/evidence/stage6c_score_ties.csv"

{
  sha256sum "$V5M"
  sha256sum "$FINAL_METHOD"
  sha256sum "$C1_RAW"
  sha256sum "$C2_RAW"
  sha256sum "$CONFIRMATORY_DECISION"
  sha256sum "$STAGE6C_CODE"
} > "$OUT/hashes/pre_stage6d_sha256.txt"

cat > "$OUT/code/evva3_stage6d_pairwise_case_analysis.py" <<'PY'
#!/usr/bin/env python3

"""Post-confirmatory pairwise and case-heterogeneity analysis.

This analysis does not select or modify a method.

It estimates paired seed-cluster bootstrap intervals for:

- Final-EVVA-SAG versus Locked-EVVA-SAG;
- Final-EVVA-SAG versus Raw-scale-BG;
- Final-EVVA-SAG versus H-only;
- Final-EVVA-SAG versus pH-only;
- Final-EVVA-SAG versus Primitive-envelope.

It also estimates Final-versus-Locked effects separately for each case.
"""

import csv
import importlib.util
import json
import os
import platform
import statistics
from collections import defaultdict
from pathlib import Path
from typing import Dict, List, Sequence

import numpy as np


OUT = Path(
    os.environ["EVVA3_STAGE6D_OUT"]
)

STAGE6C_CODE = Path(
    os.environ[
        "EVVA3_STAGE6D_STAGE6C_CODE"
    ]
)

BOOTSTRAP_REPS = int(
    os.environ.get(
        "EVVA3_STAGE6D_BOOTSTRAP_REPS",
        "5000",
    )
)

RANDOM_SEED = 20260714

COMPARATORS = [
    "Locked-EVVA-SAG",
    "Raw-scale-BG",
    "H-only",
    "pH-only",
    "Primitive-envelope",
]


def import_stage6c():
    specification = (
        importlib.util.spec_from_file_location(
            "evva3_stage6d_stage6c",
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


def make_block_state(
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

    final_score = M.frozen_final_scores(
        calibration_rows,
        evaluation_rows,
    )

    locked_by_budget = M.locked_scores(
        calibration_rows,
        evaluation_rows,
    )

    H_score = np.asarray([
        float(row["_H"])
        for row in evaluation_rows
    ], dtype=float)

    pH_score = np.asarray([
        float(row["_pH"])
        for row in evaluation_rows
    ], dtype=float)

    raw_scale_score = (
        0.10 * pH_score
        + 0.90 * H_score
    )

    seed_indices: Dict[
        int,
        List[int],
    ] = defaultdict(list)

    for index, row in enumerate(
        evaluation_rows
    ):
        seed_indices[
            int(row["_seed"])
        ].append(index)

    return {
        "name": block["name"],
        "evaluation_rows": evaluation_rows,
        "gains": gains,
        "final_score": final_score,
        "locked_by_budget": (
            locked_by_budget
        ),
        "H_score": H_score,
        "pH_score": pH_score,
        "raw_scale_score": (
            raw_scale_score
        ),
        "seed_indices": seed_indices,
    }


def method_curve(
    state: Dict[str, object],
    method: str,
    indices: np.ndarray,
) -> List[float]:
    gains = state["gains"][
        indices
    ]

    if method == "Final-EVVA-SAG":
        return M.curve(
            state["final_score"][
                indices
            ],
            gains,
        )

    if method == "Locked-EVVA-SAG":
        return M.curve_budget_scores(
            {
                budget: scores[
                    indices
                ]
                for budget, scores
                in state[
                    "locked_by_budget"
                ].items()
            },
            gains,
        )

    if method == "Raw-scale-BG":
        return M.curve(
            state["raw_scale_score"][
                indices
            ],
            gains,
        )

    if method == "H-only":
        return M.curve(
            state["H_score"][
                indices
            ],
            gains,
        )

    if method == "pH-only":
        return M.curve(
            state["pH_score"][
                indices
            ],
            gains,
        )

    if method == "Primitive-envelope":
        H_curve = M.curve(
            state["H_score"][
                indices
            ],
            gains,
        )

        pH_curve = M.curve(
            state["pH_score"][
                indices
            ],
            gains,
        )

        return [
            max(H_value, pH_value)
            for H_value, pH_value
            in zip(
                H_curve,
                pH_curve,
            )
        ]

    raise RuntimeError(
        f"Unknown method: {method}"
    )


def point_delta(
    state: Dict[str, object],
    comparator: str,
    indices: np.ndarray,
) -> float:
    final_curve = method_curve(
        state,
        "Final-EVVA-SAG",
        indices,
    )

    comparator_curve = method_curve(
        state,
        comparator,
        indices,
    )

    return (
        M.aubc(final_curve)
        - M.aubc(comparator_curve)
    )


def bootstrap_block(
    state: Dict[str, object],
    rng: np.random.Generator,
) -> Dict[str, List[float]]:
    seed_indices = state[
        "seed_indices"
    ]

    seeds = np.asarray(
        sorted(seed_indices),
        dtype=int,
    )

    output = {
        comparator: []
        for comparator in COMPARATORS
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

        for comparator in COMPARATORS:
            output[comparator].append(
                point_delta(
                    state,
                    comparator,
                    indices,
                )
            )

    return output


def case_state(
    state: Dict[str, object],
    case_type: str,
) -> Dict[str, object]:
    indices = [
        index
        for index, row in enumerate(
            state["evaluation_rows"]
        )
        if row["_case"] == case_type
    ]

    if len(indices) != 200:
        raise RuntimeError(
            f"{state['name']}/{case_type}: "
            "expected 200 rows."
        )

    indices_array = np.asarray(
        indices,
        dtype=int,
    )

    rows = [
        state["evaluation_rows"][
            index
        ]
        for index in indices
    ]

    seed_indices: Dict[
        int,
        List[int],
    ] = defaultdict(list)

    for local_index, row in enumerate(
        rows
    ):
        seed_indices[
            int(row["_seed"])
        ].append(local_index)

    return {
        "name": state["name"],
        "case_type": case_type,
        "evaluation_rows": rows,
        "gains": state["gains"][
            indices_array
        ],
        "final_score": state[
            "final_score"
        ][indices_array],
        "locked_by_budget": {
            budget: scores[
                indices_array
            ]
            for budget, scores
            in state[
                "locked_by_budget"
            ].items()
        },
        "H_score": state[
            "H_score"
        ][indices_array],
        "pH_score": state[
            "pH_score"
        ][indices_array],
        "raw_scale_score": state[
            "raw_scale_score"
        ][indices_array],
        "seed_indices": seed_indices,
    }


def summarize_values(
    analysis: str,
    comparator: str,
    point: float,
    values: Sequence[float],
) -> Dict[str, object]:
    return {
        "analysis": analysis,
        "candidate": "Final-EVVA-SAG",
        "comparator": comparator,
        "bootstrap_repetitions": (
            BOOTSTRAP_REPS
        ),
        "point_delta_aubc": point,
        "bootstrap_mean_delta": (
            statistics.fmean(values)
        ),
        "ci_2_5": quantile(
            values,
            0.025,
        ),
        "ci_97_5": quantile(
            values,
            0.975,
        ),
        "probability_delta_ge_zero": (
            sum(
                value >= 0.0
                for value in values
            )
            / len(values)
        ),
    }


def main() -> None:
    loaded_blocks = [
        M.load_block(specification)
        for specification in M.BLOCKS
    ]

    states = {
        str(block["name"]): (
            make_block_state(block)
        )
        for block in loaded_blocks
    }

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

    pairwise_rows = []

    full_indices = {
        name: np.arange(
            len(
                state[
                    "evaluation_rows"
                ]
            ),
            dtype=int,
        )
        for name, state
        in states.items()
    }

    for block_name, state in (
        states.items()
    ):
        for comparator in COMPARATORS:
            point = point_delta(
                state,
                comparator,
                full_indices[
                    block_name
                ],
            )

            pairwise_rows.append(
                summarize_values(
                    block_name,
                    comparator,
                    point,
                    block_bootstrap[
                        block_name
                    ][comparator],
                )
            )

    combined_rng = np.random.default_rng(
        RANDOM_SEED + 1
    )

    for comparator in COMPARATORS:
        c1_values = block_bootstrap[
            "C1"
        ][comparator]

        c2_values = block_bootstrap[
            "C2"
        ][comparator]

        combined = []

        for index in range(
            BOOTSTRAP_REPS
        ):
            block_values = np.asarray([
                c1_values[index],
                c2_values[index],
            ], dtype=float)

            sampled = combined_rng.choice(
                block_values,
                size=2,
                replace=True,
            )

            combined.append(
                float(
                    np.mean(sampled)
                )
            )

        c1_point = point_delta(
            states["C1"],
            comparator,
            full_indices["C1"],
        )

        c2_point = point_delta(
            states["C2"],
            comparator,
            full_indices["C2"],
        )

        pairwise_rows.append(
            summarize_values(
                "Combined-two-level",
                comparator,
                statistics.fmean([
                    c1_point,
                    c2_point,
                ]),
                combined,
            )
        )

    case_rows = []
    case_bootstrap_rows = []

    for block_name, state in (
        states.items()
    ):
        for case_type in (
            M.EXPECTED_CASES
        ):
            current = case_state(
                state,
                case_type,
            )

            indices = np.arange(
                len(
                    current[
                        "evaluation_rows"
                    ]
                ),
                dtype=int,
            )

            point = point_delta(
                current,
                "Locked-EVVA-SAG",
                indices,
            )

            case_rows.append({
                "block": block_name,
                "case_type": case_type,
                "rows": len(indices),
                "final_aubc_5_90": M.aubc(
                    method_curve(
                        current,
                        "Final-EVVA-SAG",
                        indices,
                    )
                ),
                "locked_aubc_5_90": M.aubc(
                    method_curve(
                        current,
                        "Locked-EVVA-SAG",
                        indices,
                    )
                ),
                "delta_aubc": point,
            })

            values = bootstrap_block(
                current,
                rng,
            )["Locked-EVVA-SAG"]

            case_bootstrap_rows.append(
                summarize_values(
                    (
                        f"{block_name}/"
                        f"{case_type}"
                    ),
                    "Locked-EVVA-SAG",
                    point,
                    values,
                )
            )

    combined_lookup = {
        row["comparator"]: row
        for row in pairwise_rows
        if row["analysis"]
        == "Combined-two-level"
    }

    raw_scale = combined_lookup[
        "Raw-scale-BG"
    ]

    H_only = combined_lookup[
        "H-only"
    ]

    pH_only = combined_lookup[
        "pH-only"
    ]

    envelope = combined_lookup[
        "Primitive-envelope"
    ]

    summary = {
        "status": "complete",
        "stage": "EVVA_3 Stage 6D",
        "method_frozen": True,
        "method_modified": False,
        "new_seeds_collected": False,
        "method_selection_performed": False,
        "bootstrap_repetitions": (
            BOOTSTRAP_REPS
        ),
        "final_vs_raw_scale": {
            "point_delta_aubc": (
                raw_scale[
                    "point_delta_aubc"
                ]
            ),
            "ci_2_5": raw_scale[
                "ci_2_5"
            ],
            "ci_97_5": raw_scale[
                "ci_97_5"
            ],
            "probability_delta_ge_zero": (
                raw_scale[
                    "probability_delta_ge_zero"
                ]
            ),
        },
        "final_vs_H_only_ci_lower": (
            H_only["ci_2_5"]
        ),
        "final_vs_pH_only_ci_lower": (
            pH_only["ci_2_5"]
        ),
        "final_vs_primitive_envelope_ci_lower": (
            envelope["ci_2_5"]
        ),
        "case_cells": len(
            case_rows
        ),
        "positive_case_cells": sum(
            float(row["delta_aubc"])
            > 0.0
            for row in case_rows
        ),
        "interpretation": (
            "Post-confirmatory secondary analysis. "
            "Raw-scale and case-level results cannot "
            "be used to change the frozen method."
        ),
    }

    write_csv(
        OUT
        / "results"
        / "pairwise_bootstrap.csv",
        pairwise_rows,
        [
            "analysis",
            "candidate",
            "comparator",
            "bootstrap_repetitions",
            "point_delta_aubc",
            "bootstrap_mean_delta",
            "ci_2_5",
            "ci_97_5",
            "probability_delta_ge_zero",
        ],
    )

    write_csv(
        OUT
        / "results"
        / "case_point_estimates.csv",
        case_rows,
        [
            "block",
            "case_type",
            "rows",
            "final_aubc_5_90",
            "locked_aubc_5_90",
            "delta_aubc",
        ],
    )

    write_csv(
        OUT
        / "results"
        / "case_bootstrap.csv",
        case_bootstrap_rows,
        [
            "analysis",
            "candidate",
            "comparator",
            "bootstrap_repetitions",
            "point_delta_aubc",
            "bootstrap_mean_delta",
            "ci_2_5",
            "ci_97_5",
            "probability_delta_ge_zero",
        ],
    )

    with (
        OUT
        / "reports"
        / "stage6d_summary.json"
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
echo "EVVA_3 STAGE 6D PAIRWISE + CASE ANALYSIS"
echo "===================================================="
echo "Output: $OUT"
echo "Bootstrap repetitions: $BOOTSTRAP_REPS"
echo

python3 -m py_compile \
  "$OUT/code/evva3_stage6d_pairwise_case_analysis.py" \
  || die "Stage 6D failed py_compile."

python3 \
  "$OUT/code/evva3_stage6d_pairwise_case_analysis.py" \
  2>&1 | tee "$OUT/logs/stage6d.log"

STATUS="${PIPESTATUS[0]}"

[ "$STATUS" -eq 0 ] \
  || die "Stage 6D evaluation failed."

for required in \
  "$OUT/reports/stage6d_summary.json" \
  "$OUT/results/pairwise_bootstrap.csv" \
  "$OUT/results/case_point_estimates.csv" \
  "$OUT/results/case_bootstrap.csv"
do
  [ -f "$required" ] \
    || die "Missing Stage 6D output: $required"
done

{
  sha256sum "$V5M"
  sha256sum "$FINAL_METHOD"
  sha256sum "$C1_RAW"
  sha256sum "$C2_RAW"
  sha256sum "$CONFIRMATORY_DECISION"
  sha256sum "$STAGE6C_CODE"
} > "$OUT/hashes/post_stage6d_sha256.txt"

cmp -s \
  "$OUT/hashes/pre_stage6d_sha256.txt" \
  "$OUT/hashes/post_stage6d_sha256.txt" \
  || die "A frozen input changed during Stage 6D."

cat > "$OUT/reports/STAGE6D_COMPLETE.md" <<'MD'
# EVVA_3 Stage 6D completion

Paired seed-cluster bootstrap intervals were computed for the frozen
Final-EVVA-SAG method against each prespecified ablation.

Final-versus-Locked effects were also evaluated separately for each case.

These are post-confirmatory secondary analyses. They do not modify the
frozen method or the confirmatory PASS decision.
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
echo "EVVA_3 STAGE 6D COMPLETE"
echo "===================================================="
echo "Output: $OUT"
echo

echo "===== SUMMARY ====="
cat "$OUT/reports/stage6d_summary.json"

echo
echo "===== PAIRWISE BOOTSTRAP ====="
column -s, -t \
  < "$OUT/results/pairwise_bootstrap.csv"

echo
echo "===== CASE POINT ESTIMATES ====="
column -s, -t \
  < "$OUT/results/case_point_estimates.csv"

echo
echo "===== CASE BOOTSTRAP ====="
column -s, -t \
  < "$OUT/results/case_bootstrap.csv"

echo
echo "PASS: Stage 6D completed without changing frozen inputs."

#!/usr/bin/env bash

# EVVA_3 Stage 4F:
# Freeze the final EVVA-SAG definition before untouched C1/C2.
#
# Final rule:
# - V usable: preserve the exact locked value-aware schedule.
# - V unavailable: use one fixed BG ranking at every budget:
#       0.10 percentile(pH) + 0.90 percentile(H).
#
# No evaluation seeds are collected or executed here.

die() {
  echo "ERROR: $*" >&2
  exit 1
}

WORKSPACE="$HOME/.openclaw/workspace/skills/openclaw_pilot_v4_large_exactB_20260707_EVVA_3_signal_repair_20260713"

V5M="code/aaai_v5m_signal_availability_gated_evva.py"
EVVA2H="code/aaai_evva2h_severe_plateau_gate.py"
CONTROLLED="artifacts/aaai_v5j_fair_controlled_prm_20260709/fair_controlled_train_eval_rows.csv"

EXPECTED_V5M_SHA="924b6c893036f20ee9d60e90faf34c3beeb0f830af8e6d1c8ffd4dfee904906e"
EXPECTED_EVVA2H_SHA="21ccb27ded1838b86e7b37deae5c9bd069d58c2fe13d8ec90a54f7967205b28d"
EXPECTED_CONTROLLED_SHA="091425b9a6d2cd078511f6d5ea923fd7f7214e8142a828e6cac6e4746e540fd2"

[ -d "$WORKSPACE" ] || die "Workspace not found."
cd "$WORKSPACE" || die "Cannot enter workspace."

[ -f "$V5M" ] || die "Missing locked v5m."
[ -f "$EVVA2H" ] || die "Missing frozen EVVA_2H."
[ -f "$CONTROLLED" ] || die "Missing controlled input."

[ "$(sha256sum "$V5M" | awk '{print $1}')" = "$EXPECTED_V5M_SHA" ] \
  || die "Locked v5m hash mismatch."

[ "$(sha256sum "$EVVA2H" | awk '{print $1}')" = "$EXPECTED_EVVA2H_SHA" ] \
  || die "Frozen EVVA_2H hash mismatch."

[ "$(sha256sum "$CONTROLLED" | awk '{print $1}')" = "$EXPECTED_CONTROLLED_SHA" ] \
  || die "Controlled input hash mismatch."

STAGE3D="$(cat artifacts/aaai_evva3_stage3d_latest.txt)"
STAGE4B="$(cat artifacts/aaai_evva3_stage4b_latest.txt)"
STAGE4C="$(cat artifacts/aaai_evva3_stage4c_latest.txt)"
STAGE4D="$(cat artifacts/aaai_evva3_stage4d_latest.txt)"
STAGE4E="$(cat artifacts/aaai_evva3_stage4e_latest.txt)"

for path in \
  "$STAGE3D/reports/stage3d_summary.json" \
  "$STAGE4B/results/large_aggregate_summary.csv" \
  "$STAGE4B/results/large_bootstrap.csv" \
  "$STAGE4B/results/large_60_70.csv" \
  "$STAGE4C/results/summary.csv" \
  "$STAGE4D/results/eval_60_70_headroom.csv" \
  "$STAGE4E/results/summary.csv"
do
  [ -f "$path" ] || die "Missing evidence file: $path"
done

RUN_ID="$(date +%Y%m%d_%H%M%S)"
OUT="artifacts/aaai_evva3_stage4f_final_method_freeze_${RUN_ID}"

mkdir -p \
  "$OUT/code" \
  "$OUT/evidence" \
  "$OUT/hashes" \
  "$OUT/manifests" \
  "$OUT/reports" \
  || die "Cannot create Stage 4F directories."

echo "$OUT" > artifacts/aaai_evva3_stage4f_latest.txt

cp \
  "$STAGE3D/reports/stage3d_summary.json" \
  "$OUT/evidence/stage3d_controlled_summary.json"

cp \
  "$STAGE4B/results/large_aggregate_summary.csv" \
  "$OUT/evidence/stage4b_large_aggregate_summary.csv"

cp \
  "$STAGE4B/results/large_bootstrap.csv" \
  "$OUT/evidence/stage4b_large_bootstrap.csv"

cp \
  "$STAGE4B/results/large_60_70.csv" \
  "$OUT/evidence/stage4b_large_60_70.csv"

cp \
  "$STAGE4C/results/summary.csv" \
  "$OUT/evidence/stage4c_plateau_repair_rejected.csv"

cp \
  "$STAGE4D/results/eval_60_70_headroom.csv" \
  "$OUT/evidence/stage4d_boundary_headroom.csv"

cp \
  "$STAGE4E/results/summary.csv" \
  "$OUT/evidence/stage4e_pareto_repair_rejected.csv"

cat > "$OUT/code/aaai_evva3_final_evva_sag.py" <<'PY'
#!/usr/bin/env python3

"""Frozen EVVA-SAG definition for untouched C1/C2 confirmation.

Signal-availability gate
------------------------

If Reward/value is usable:
    Preserve the exact hash-locked EVVA-SAG value-aware schedule.

If Reward/value is unavailable:
    Use one fixed, budget-agnostic BG ranking:

        BG = 0.10 * percentile(pH)
           + 0.90 * percentile(H)

The score definition does not depend on the requested verification budget.
Exact-B changes only how many top-ranked rows are selected.
"""

import importlib.util
from pathlib import Path
from typing import Dict, List, Sequence


LOCKED_PATH = Path(
    "code/aaai_v5m_signal_availability_gated_evva.py"
)

LOCKED_SHA256 = (
    "924b6c893036f20ee9d60e90faf34c3beeb0f830af8e6d1c8ffd4dfee904906e"
)

BG_PH_WEIGHT = 0.10
BG_H_WEIGHT = 0.90

BUDGETS = [
    0.05,
    0.10,
    0.20,
    0.30,
    0.40,
    0.50,
    0.60,
    0.70,
    0.75,
    0.80,
    0.90,
    1.00,
]


def load_locked():
    specification = importlib.util.spec_from_file_location(
        "evva3_final_locked_v5m",
        LOCKED_PATH,
    )

    if specification is None or specification.loader is None:
        raise RuntimeError(
            "Cannot import locked EVVA-SAG."
        )

    module = importlib.util.module_from_spec(
        specification
    )
    specification.loader.exec_module(module)
    return module


LOCKED = load_locked()


def string_rows(
    rows: Sequence[Dict[str, object]],
) -> List[Dict[str, str]]:
    return [
        {
            key: (
                ""
                if value is None
                else str(value)
            )
            for key, value in row.items()
        }
        for row in rows
    ]


def apply_fixed_bg(
    calibration_rows: Sequence[Dict[str, object]],
    evaluation_rows: Sequence[Dict[str, object]],
    pH_column: str,
    H_column: str,
) -> List[Dict[str, str]]:
    calibration = string_rows(
        calibration_rows
    )

    evaluation = string_rows(
        evaluation_rows
    )

    pH_reference = sorted(
        LOCKED.fnum(
            row.get(pH_column)
        )
        for row in calibration
    )

    H_reference = sorted(
        LOCKED.fnum(
            row.get(H_column)
        )
        for row in calibration
    )

    output = []

    for row in evaluation:
        copied = dict(row)

        normalized_pH = LOCKED.percentile(
            pH_reference,
            LOCKED.fnum(
                row.get(pH_column)
            ),
        )

        normalized_H = LOCKED.percentile(
            H_reference,
            LOCKED.fnum(
                row.get(H_column)
            ),
        )

        copied[
            "_EVVA3_FINAL_BG_score"
        ] = str(
            BG_PH_WEIGHT
            * normalized_pH
            + BG_H_WEIGHT
            * normalized_H
        )

        output.append(copied)

    return output


def evaluate(
    calibration_rows: Sequence[Dict[str, object]],
    evaluation_rows: Sequence[Dict[str, object]],
    budget_fraction: float,
    score_columns: Dict[str, str],
) -> float:
    evaluation = string_rows(
        evaluation_rows
    )

    value_column = score_columns["V"]

    if LOCKED.usable(
        evaluation,
        value_column,
    ):
        quota = LOCKED.value_aware_schedule(
            budget_fraction
        )

        active = [
            (signal, weight)
            for signal, weight in quota.items()
            if weight > 1e-12
        ]

        if len(active) == 1:
            signal = active[0][0]

            return float(
                LOCKED.scalar_tieaware(
                    evaluation,
                    score_columns[signal],
                    budget_fraction,
                )
            )

        return float(
            LOCKED.portfolio_value(
                evaluation,
                score_columns,
                quota,
                budget_fraction,
            )
        )

    repaired = apply_fixed_bg(
        calibration_rows,
        evaluation_rows,
        score_columns["pH"],
        score_columns["H"],
    )

    return float(
        LOCKED.scalar_tieaware(
            repaired,
            "_EVVA3_FINAL_BG_score",
            budget_fraction,
        )
    )


METHOD_SPEC = {
    "name": "EVVA-SAG",
    "status": "frozen_before_C1_C2",
    "value_available": (
        "exact locked value-aware schedule"
    ),
    "value_unavailable": (
        "fixed 0.10 percentile(pH) "
        "+ 0.90 percentile(H)"
    ),
    "budget_agnostic_unavailable_score": True,
    "exact_budget": True,
    "tie_aware": True,
    "row_order_invariant": True,
}
PY

python3 -m py_compile \
  "$OUT/code/aaai_evva3_final_evva_sag.py" \
  || die "Frozen method module failed py_compile."

export EVVA3_STAGE4F_OUT="$OUT"
export EVVA3_STAGE4F_STAGE3D="$STAGE3D"
export EVVA3_STAGE4F_STAGE4B="$STAGE4B"
export EVVA3_STAGE4F_STAGE4C="$STAGE4C"
export EVVA3_STAGE4F_STAGE4D="$STAGE4D"
export EVVA3_STAGE4F_STAGE4E="$STAGE4E"

python3 - <<'PY'
import csv
import json
import os
from pathlib import Path


out = Path(
    os.environ["EVVA3_STAGE4F_OUT"]
)

stage4b = Path(
    os.environ["EVVA3_STAGE4F_STAGE4B"]
)

with (
    stage4b
    / "results"
    / "large_aggregate_summary.csv"
).open(
    newline="",
    encoding="utf-8",
) as handle:
    aggregate = list(
        csv.DictReader(handle)
    )

fixed_bg = next(
    row
    for row in aggregate
    if row["method"] == "Fixed-BG-anchor"
)

with (
    stage4b
    / "results"
    / "large_bootstrap.csv"
).open(
    newline="",
    encoding="utf-8",
) as handle:
    bootstrap = list(
        csv.DictReader(handle)
    )

evidence = {
    "selected_development_candidate": (
        "EVVA-SAG with unified fixed BG fallback"
    ),
    "large_fixed_bg_evidence": {
        "mean_aubc_5_90": float(
            fixed_bg["mean_aubc_5_90"]
        ),
        "mean_delta_vs_locked_v5m": float(
            fixed_bg[
                "mean_delta_vs_locked_v5m"
            ]
        ),
        "minimum_block_delta_vs_locked_v5m": float(
            fixed_bg[
                "minimum_block_delta_vs_locked_v5m"
            ]
        ),
        "positive_blocks_vs_locked_v5m": int(
            fixed_bg[
                "positive_blocks_vs_locked_v5m"
            ]
        ),
        "mean_delta_vs_primitive_envelope": float(
            fixed_bg[
                "mean_delta_vs_primitive_envelope"
            ]
        ),
        "minimum_block_delta_vs_primitive_envelope": float(
            fixed_bg[
                "minimum_block_delta_vs_primitive_envelope"
            ]
        ),
    },
    "rejected_development_candidates": [
        {
            "candidate": "Direct ShallowGB PIV",
            "reason": (
                "Improved large fallback regime but "
                "failed controlled value-available regime."
            ),
        },
        {
            "candidate": "EVVA-SAR",
            "reason": (
                "Residual correction failed controlled "
                "60% and 70% and did not beat fixed BG."
            ),
        },
        {
            "candidate": "EVVA-SAG-PR",
            "reason": (
                "Isotonic plateau repair reduced "
                "controlled AUBC and both 60% and 70%."
            ),
        },
        {
            "candidate": "EVVA-SAG-PDR",
            "reason": (
                "Pareto repair moved most rows, reduced "
                "train AUBC, and failed the 60% safety gate."
            ),
        },
    ],
    "selection_rule": (
        "Select the simplest candidate with positive "
        "development AUBC in all six large blocks, "
        "no learned repair, and no controlled-regime change."
    ),
    "warning": (
        "All evidence above is development evidence. "
        "C1/C2 remain untouched."
    ),
}

with (
    out
    / "reports"
    / "DEVELOPMENT_SELECTION_EVIDENCE.json"
).open(
    "w",
    encoding="utf-8",
) as handle:
    json.dump(
        evidence,
        handle,
        indent=2,
        sort_keys=True,
    )

preregistration = {
    "status": "frozen_before_execution",
    "method": {
        "name": "EVVA-SAG",
        "value_available": (
            "preserve the exact locked "
            "value-aware schedule"
        ),
        "value_unavailable": (
            "use one fixed ranking equal to "
            "0.10 percentile(pH) "
            "+ 0.90 percentile(H)"
        ),
        "same_unavailable_ranking_at_all_budgets": True,
        "exact_top_B": True,
        "tie_aware": True,
        "row_order_invariant": True,
    },
    "confirmation_blocks": [
        {
            "name": "C1",
            "all_seeds": "6500-6799",
            "calibration_seeds": "6500-6599",
            "evaluation_seeds": "6600-6799",
        },
        {
            "name": "C2",
            "all_seeds": "6800-7099",
            "calibration_seeds": "6800-6899",
            "evaluation_seeds": "6900-7099",
        },
    ],
    "budgets_percent": [
        5,
        10,
        20,
        30,
        40,
        50,
        60,
        70,
        75,
        80,
        90,
        100,
    ],
    "primary_metric": (
        "normalized trapezoidal AUBC over 5%-90%"
    ),
    "primary_comparator": (
        "original hash-locked EVVA-SAG"
    ),
    "primary_success_criteria": [
        (
            "C1 point AUBC delta versus original "
            "locked EVVA-SAG is positive"
        ),
        (
            "C2 point AUBC delta versus original "
            "locked EVVA-SAG is positive"
        ),
        (
            "combined two-level block plus seed-cluster "
            "bootstrap 95% CI lower bound is above zero"
        ),
    ],
    "secondary_metrics": [
        "60% margin",
        "70% margin",
        "block-level oracle regret",
        "strict wins, ties, and losses",
    ],
    "secondary_metrics_are_not_selection_gates": True,
    "structural_checks": [
        "exact-B at every budget",
        "100% structural equality",
        "no calibration/evaluation seed overlap",
        "three rows per seed",
        "frozen source hashes unchanged",
    ],
    "prohibited_after_freeze": [
        "changing 0.10 or 0.90 weights",
        "adding a budget-specific fallback",
        "adding a learned residual",
        "adding ShallowGB or another model",
        "changing primary metrics",
        "reusing C1 or C2 for development",
    ],
}

with (
    out
    / "manifests"
    / "C1_C2_PREREGISTRATION.json"
).open(
    "w",
    encoding="utf-8",
) as handle:
    json.dump(
        preregistration,
        handle,
        indent=2,
        sort_keys=True,
    )
PY

cat > "$OUT/reports/FINAL_METHOD_FREEZE.md" <<'MD'
# EVVA_3 final method freeze

## Frozen method

The final method remains EVVA-SAG.

When the Reward/value signal is usable, EVVA-SAG preserves the exact
hash-locked value-aware schedule.

When Reward/value is unavailable, EVVA-SAG uses one fixed ranking at every
budget:

\[
0.10\,\operatorname{Pct}(pH)
+
0.90\,\operatorname{Pct}(H).
\]

The prior pure-H fallback above 30% is removed.

## Why this candidate was selected

The fixed BG anchor was the only development candidate that improved over the
original locked EVVA-SAG in all six large blocks while also improving over the
primitive envelope in all six blocks.

It introduces no learned model, no budget-specific repair, and no change to the
controlled value-available regime.

## Rejected candidates

- Direct ShallowGB intervention-value prediction
- Ridge residual repair
- Isotonic plateau repair
- Pareto-dominance repair
- Recoverability factorization

These remain development diagnostics and are not part of the final method.

## Freeze status

The method is frozen before C1 and C2.

C1 and C2 must not be used to modify the method.
MD

{
  sha256sum "$V5M"
  sha256sum "$EVVA2H"
  sha256sum "$CONTROLLED"
  sha256sum "$OUT/code/aaai_evva3_final_evva_sag.py"
  sha256sum "$OUT/manifests/C1_C2_PREREGISTRATION.json"
  sha256sum "$OUT/reports/FINAL_METHOD_FREEZE.md"
} > "$OUT/hashes/FROZEN_SHA256.txt"

find "$OUT" \
  -type f \
  ! -name 'FINAL_SHA256SUMS.txt' \
  -print0 \
  | sort -z \
  | xargs -0 sha256sum \
  > "$OUT/FINAL_SHA256SUMS.txt"

echo
echo "===================================================="
echo "EVVA_3 STAGE 4F FINAL METHOD FREEZE COMPLETE"
echo "===================================================="
echo "Output: $OUT"
echo

cat "$OUT/reports/FINAL_METHOD_FREEZE.md"

echo
echo "Development selection evidence:"
cat "$OUT/reports/DEVELOPMENT_SELECTION_EVIDENCE.json"

echo
echo "C1/C2 preregistration:"
cat "$OUT/manifests/C1_C2_PREREGISTRATION.json"

echo
echo "Frozen hashes:"
cat "$OUT/hashes/FROZEN_SHA256.txt"

echo
echo "PASS: Final EVVA-SAG method frozen before C1/C2."

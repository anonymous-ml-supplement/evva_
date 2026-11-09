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
    "code/evva_v5m_signal_availability_gated_evva.py"
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

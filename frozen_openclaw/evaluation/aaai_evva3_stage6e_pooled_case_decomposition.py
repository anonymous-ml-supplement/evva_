#!/usr/bin/env python3

"""Pooled exact-budget case-contribution decomposition.

Unlike within-case evaluation, this audit preserves the global ranking
and global exact-B budget over all 600 evaluation rows.

For each case c and budget B, it calculates

    contribution_c =
        (selected_gain_final,c - selected_gain_locked,c) / B.

The three case contributions therefore sum exactly to the global
Final-minus-Locked selected-mean margin at that budget.

Integrating these contributions over 5%-90% gives additive case-level
AUBC contributions whose sum equals the total AUBC delta.
"""

import csv
import importlib.util
import json
import os
import platform
import statistics
from collections import defaultdict
from pathlib import Path
from typing import Dict, List, Sequence, Tuple

import numpy as np


OUT = Path(
    os.environ["EVVA3_STAGE6E_OUT"]
)

STAGE6C_CODE = Path(
    os.environ[
        "EVVA3_STAGE6E_STAGE6C_CODE"
    ]
)

BOOTSTRAP_REPS = int(
    os.environ.get(
        "EVVA3_STAGE6E_BOOTSTRAP_REPS",
        "5000",
    )
)

RANDOM_SEED = 20260714
TOLERANCE = 1e-9


def import_stage6c():
    specification = (
        importlib.util.spec_from_file_location(
            "evva3_stage6e_stage6c",
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
    """Return tie-aware expected inclusion weights."""

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

    remaining = float(
        exact_budget
    )

    groups: Dict[
        float,
        List[int],
    ] = defaultdict(list)

    for index, score in enumerate(scores):
        groups[
            float(score)
        ].append(index)

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
            fraction = (
                remaining
                / group_size
            )

            weights[indices] = fraction
            remaining = 0.0

        break

    if abs(
        float(np.sum(weights))
        - exact_budget
    ) > TOLERANCE:
        raise RuntimeError(
            "Tie-aware selection weight sum mismatch."
        )

    return weights


def normalized_auc(
    values: Sequence[float],
) -> float:
    x = np.asarray(
        M.BUDGETS[
            :M.AUBC_COUNT
        ],
        dtype=float,
    )

    y = np.asarray(
        values[
            :M.AUBC_COUNT
        ],
        dtype=float,
    )

    return float(
        np.trapz(y, x)
        / (x[-1] - x[0])
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

    cases = np.asarray([
        str(row["_case"])
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

    for index, row in enumerate(
        evaluation_rows
    ):
        seed_indices[
            int(row["_seed"])
        ].append(index)

    return {
        "name": str(
            block["name"]
        ),
        "evaluation_rows": evaluation_rows,
        "gains": gains,
        "cases": cases,
        "final_score": final_score,
        "locked_by_budget": (
            locked_by_budget
        ),
        "seed_indices": seed_indices,
    }


def decomposition(
    state: Dict[str, object],
    indices: np.ndarray,
) -> Tuple[
    List[Dict[str, object]],
    Dict[str, float],
]:
    gains = state["gains"][
        indices
    ]

    cases = state["cases"][
        indices
    ]

    final_score = state[
        "final_score"
    ][indices]

    locked_by_budget = {
        budget: scores[
            indices
        ]
        for budget, scores
        in state[
            "locked_by_budget"
        ].items()
    }

    budget_rows = []
    contribution_curves = {
        case: []
        for case in CASES
    }

    total_margin_curve = []

    for fraction in M.BUDGETS:
        budget_percent = int(
            round(
                fraction * 100
            )
        )

        exact_budget = M.exact_b(
            len(indices),
            fraction,
        )

        final_weights = (
            selection_weights(
                final_score,
                exact_budget,
            )
        )

        locked_weights = (
            selection_weights(
                locked_by_budget[
                    budget_percent
                ],
                exact_budget,
            )
        )

        final_total_mean = float(
            np.sum(
                final_weights
                * gains
            )
            / exact_budget
        )

        locked_total_mean = float(
            np.sum(
                locked_weights
                * gains
            )
            / exact_budget
        )

        total_margin = (
            final_total_mean
            - locked_total_mean
        )

        total_margin_curve.append(
            total_margin
        )

        case_margin_sum = 0.0

        for case in CASES:
            mask = (
                cases == case
            )

            final_count = float(
                np.sum(
                    final_weights[
                        mask
                    ]
                )
            )

            locked_count = float(
                np.sum(
                    locked_weights[
                        mask
                    ]
                )
            )

            final_gain_sum = float(
                np.sum(
                    final_weights[
                        mask
                    ]
                    * gains[mask]
                )
            )

            locked_gain_sum = float(
                np.sum(
                    locked_weights[
                        mask
                    ]
                    * gains[mask]
                )
            )

            final_contribution = (
                final_gain_sum
                / exact_budget
            )

            locked_contribution = (
                locked_gain_sum
                / exact_budget
            )

            margin_contribution = (
                final_contribution
                - locked_contribution
            )

            contribution_curves[
                case
            ].append(
                margin_contribution
            )

            case_margin_sum += (
                margin_contribution
            )

            budget_rows.append({
                "block": state["name"],
                "budget_percent": (
                    budget_percent
                ),
                "exact_B": exact_budget,
                "case_type": case,
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
                "final_global_mean_contribution": (
                    final_contribution
                ),
                "locked_global_mean_contribution": (
                    locked_contribution
                ),
                "margin_contribution": (
                    margin_contribution
                ),
                "global_total_margin": (
                    total_margin
                ),
            })

        if abs(
            case_margin_sum
            - total_margin
        ) > TOLERANCE:
            raise RuntimeError(
                f"{state['name']} budget "
                f"{budget_percent}: "
                "case contribution decomposition failed."
            )

    case_aubc = {
        case: normalized_auc(
            contribution_curves[case]
        )
        for case in CASES
    }

    case_aubc[
        "__TOTAL__"
    ] = normalized_auc(
        total_margin_curve
    )

    if abs(
        sum(
            case_aubc[case]
            for case in CASES
        )
        - case_aubc[
            "__TOTAL__"
        ]
    ) > TOLERANCE:
        raise RuntimeError(
            f"{state['name']}: "
            "AUBC contribution decomposition failed."
        )

    return budget_rows, case_aubc


def summarize_bootstrap(
    analysis: str,
    case_type: str,
    point: float,
    values: Sequence[float],
) -> Dict[str, object]:
    return {
        "analysis": analysis,
        "case_type": case_type,
        "bootstrap_repetitions": (
            BOOTSTRAP_REPS
        ),
        "point_aubc_contribution": (
            point
        ),
        "bootstrap_mean_contribution": (
            statistics.fmean(
                values
            )
        ),
        "ci_2_5": quantile(
            values,
            0.025,
        ),
        "ci_97_5": quantile(
            values,
            0.975,
        ),
        "probability_contribution_ge_zero": (
            sum(
                value >= 0.0
                for value in values
            )
            / len(values)
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
    point_rows = []
    point_lookup = {}

    for block_name, state in (
        states.items()
    ):
        indices = np.arange(
            len(
                state[
                    "evaluation_rows"
                ]
            ),
            dtype=int,
        )

        rows, contributions = (
            decomposition(
                state,
                indices,
            )
        )

        budget_rows.extend(rows)

        point_lookup[
            block_name
        ] = contributions

        for case_type, value in (
            contributions.items()
        ):
            point_rows.append({
                "block": block_name,
                "case_type": case_type,
                "aubc_contribution": (
                    value
                ),
            })

    rng = np.random.default_rng(
        RANDOM_SEED
    )

    bootstrap_values = {
        block_name: {
            case: []
            for case in (
                CASES
                + ["__TOTAL__"]
            )
        }
        for block_name in states
    }

    for block_name, state in (
        states.items()
    ):
        seed_indices = state[
            "seed_indices"
        ]

        seeds = np.asarray(
            sorted(seed_indices),
            dtype=int,
        )

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

            _, contributions = (
                decomposition(
                    state,
                    indices,
                )
            )

            for case_type, value in (
                contributions.items()
            ):
                bootstrap_values[
                    block_name
                ][case_type].append(
                    value
                )

    bootstrap_rows = []

    for block_name in [
        "C1",
        "C2",
    ]:
        for case_type in (
            CASES
            + ["__TOTAL__"]
        ):
            bootstrap_rows.append(
                summarize_bootstrap(
                    block_name,
                    case_type,
                    point_lookup[
                        block_name
                    ][case_type],
                    bootstrap_values[
                        block_name
                    ][case_type],
                )
            )

    combined_rng = np.random.default_rng(
        RANDOM_SEED + 1
    )

    combined_point = {}

    for case_type in (
        CASES
        + ["__TOTAL__"]
    ):
        combined_point[
            case_type
        ] = statistics.fmean([
            point_lookup["C1"][
                case_type
            ],
            point_lookup["C2"][
                case_type
            ],
        ])

        combined_values = []

        for index in range(
            BOOTSTRAP_REPS
        ):
            available = np.asarray([
                bootstrap_values[
                    "C1"
                ][case_type][index],
                bootstrap_values[
                    "C2"
                ][case_type][index],
            ], dtype=float)

            sampled = combined_rng.choice(
                available,
                size=2,
                replace=True,
            )

            combined_values.append(
                float(
                    np.mean(
                        sampled
                    )
                )
            )

        bootstrap_rows.append(
            summarize_bootstrap(
                "Combined-two-level",
                case_type,
                combined_point[
                    case_type
                ],
                combined_values,
            )
        )

    combined_case_sum = sum(
        combined_point[case]
        for case in CASES
    )

    decomposition_error = abs(
        combined_case_sum
        - combined_point[
            "__TOTAL__"
        ]
    )

    if decomposition_error > TOLERANCE:
        raise RuntimeError(
            "Combined case contribution "
            "decomposition failed."
        )

    positive_cases = [
        case
        for case in CASES
        if combined_point[case] > 0.0
    ]

    negative_cases = [
        case
        for case in CASES
        if combined_point[case] < 0.0
    ]

    summary = {
        "status": "complete",
        "stage": "EVVA_3 Stage 6E",
        "method_frozen": True,
        "method_modified": False,
        "method_selection_performed": False,
        "new_seeds_collected": False,
        "bootstrap_repetitions": (
            BOOTSTRAP_REPS
        ),
        "combined_total_aubc_delta": (
            combined_point[
                "__TOTAL__"
            ]
        ),
        "combined_case_contributions": {
            case: combined_point[
                case
            ]
            for case in CASES
        },
        "combined_case_contribution_sum": (
            combined_case_sum
        ),
        "combined_decomposition_error": (
            decomposition_error
        ),
        "positive_contribution_cases": (
            positive_cases
        ),
        "negative_contribution_cases": (
            negative_cases
        ),
        "interpretation": (
            "Case contributions preserve pooled "
            "global exact-B selection and therefore "
            "sum exactly to the overall AUBC delta. "
            "They differ conceptually from the "
            "within-case independent-deployment "
            "analysis in Stage 6D."
        ),
    }

    write_csv(
        OUT
        / "results"
        / "budget_case_contributions.csv",
        budget_rows,
        [
            "block",
            "budget_percent",
            "exact_B",
            "case_type",
            "final_selected_count_weight",
            "locked_selected_count_weight",
            "selected_count_weight_delta",
            "final_selected_gain_sum",
            "locked_selected_gain_sum",
            "final_global_mean_contribution",
            "locked_global_mean_contribution",
            "margin_contribution",
            "global_total_margin",
        ],
    )

    write_csv(
        OUT
        / "results"
        / "block_case_aubc_contributions.csv",
        point_rows,
        [
            "block",
            "case_type",
            "aubc_contribution",
        ],
    )

    write_csv(
        OUT
        / "results"
        / "case_contribution_bootstrap.csv",
        bootstrap_rows,
        [
            "analysis",
            "case_type",
            "bootstrap_repetitions",
            "point_aubc_contribution",
            "bootstrap_mean_contribution",
            "ci_2_5",
            "ci_97_5",
            "probability_contribution_ge_zero",
        ],
    )

    with (
        OUT
        / "reports"
        / "stage6e_summary.json"
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

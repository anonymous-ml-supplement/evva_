#!/usr/bin/env python3

import bisect
import math


METHOD_NAME = "EVVA_2H_Severe_Plateau_Gate"

MIN_BOUNDARY_FRACTION = 0.20

MAX_COMPRESSION_RATIO = 0.25


def fnum(value, default=0.0):
    try:
        number = float(
            str(value).strip()
        )

        if math.isfinite(number):
            return number
    except Exception:
        pass

    return default


def exact_b(n_rows, fraction):
    return max(
        1,
        min(
            int(round(n_rows * fraction)),
            n_rows,
        ),
    )


def percentile(
    sorted_values,
    value,
):
    if not sorted_values:
        return 0.5

    lower = bisect.bisect_left(
        sorted_values,
        value,
    )

    upper = bisect.bisect_right(
        sorted_values,
        value,
    )

    return (
        lower
        + 0.5 * (upper - lower)
    ) / len(sorted_values)


def add_structural_score(
    calibration_rows,
    evaluation_rows,
):
    rollback_distribution = sorted(
        fnum(
            row.get(
                "rollback_difficulty"
            )
        )
        for row in calibration_rows
    )

    persistent_distribution = sorted(
        fnum(
            row.get(
                "persistent_state_risk"
            )
        )
        for row in calibration_rows
    )

    dependency_distribution = sorted(
        math.log1p(
            max(
                0.0,
                fnum(
                    row.get(
                        "downstream_dependency_count"
                    )
                ),
            )
        )
        for row in calibration_rows
    )

    for row in (
        calibration_rows
        + evaluation_rows
    ):
        rollback_rank = percentile(
            rollback_distribution,
            fnum(
                row.get(
                    "rollback_difficulty"
                )
            ),
        )

        persistent_rank = percentile(
            persistent_distribution,
            fnum(
                row.get(
                    "persistent_state_risk"
                )
            ),
        )

        dependency_rank = percentile(
            dependency_distribution,
            math.log1p(
                max(
                    0.0,
                    fnum(
                        row.get(
                            "downstream_dependency_count"
                        )
                    ),
                )
            ),
        )

        row["_H_struct_equal_rank"] = (
            rollback_rank
            + persistent_rank
            + dependency_rank
        ) / 3.0


def calibration_gate(
    calibration_rows,
    fraction,
):
    n_rows = len(
        calibration_rows
    )

    if n_rows <= 0:
        raise ValueError(
            "Calibration rows must be non-empty."
        )

    budget = exact_b(
        n_rows,
        fraction,
    )

    h_scores = sorted(
        (
            fnum(
                row.get("harm_score")
            )
            for row in calibration_rows
        ),
        reverse=True,
    )

    h_cutoff = h_scores[
        budget - 1
    ]

    above_count = sum(
        score > h_cutoff
        for score in h_scores
    )

    h_boundary_rows = [
        row
        for row in calibration_rows
        if (
            fnum(
                row.get("harm_score")
            )
            == h_cutoff
        )
    ]

    needed = (
        budget - above_count
    )

    h_boundary_size = len(
        h_boundary_rows
    )

    boundary_fraction = (
        h_boundary_size
        / n_rows
    )

    if (
        needed <= 0
        or needed >= h_boundary_size
    ):
        return {
            "active": False,
            "budget": budget,
            "H_boundary": h_boundary_size,
            "H_needed": needed,
            "boundary_fraction": boundary_fraction,
            "H_struct_boundary": h_boundary_size,
            "compression_ratio": 1.0,
            "severe_plateau": (
                boundary_fraction
                >= MIN_BOUNDARY_FRACTION
            ),
            "strong_compression": False,
        }

    structural_scores = sorted(
        (
            fnum(
                row.get(
                    "_H_struct_equal_rank"
                )
            )
            for row in h_boundary_rows
        ),
        reverse=True,
    )

    structural_cutoff = (
        structural_scores[
            needed - 1
        ]
    )

    structural_boundary_size = sum(
        score == structural_cutoff
        for score in structural_scores
    )

    compression_ratio = (
        structural_boundary_size
        / h_boundary_size
    )

    severe_plateau = (
        boundary_fraction
        >= MIN_BOUNDARY_FRACTION
    )

    strong_compression = (
        compression_ratio
        <= MAX_COMPRESSION_RATIO
    )

    refinement_available = (
        structural_boundary_size
        < h_boundary_size
    )

    active = (
        refinement_available
        and severe_plateau
        and strong_compression
    )

    return {
        "active": active,
        "budget": budget,
        "H_boundary": h_boundary_size,
        "H_needed": needed,
        "boundary_fraction": boundary_fraction,
        "H_struct_boundary": (
            structural_boundary_size
        ),
        "compression_ratio": (
            compression_ratio
        ),
        "severe_plateau": (
            severe_plateau
        ),
        "strong_compression": (
            strong_compression
        ),
    }


def hierarchical_exact_k_total(
    rows,
    score_columns,
    k,
    label_column,
):
    if k <= 0:
        return 0.0

    if k >= len(rows):
        return sum(
            fnum(
                row.get(label_column)
            )
            for row in rows
        )

    score_column = (
        score_columns[0]
    )

    scores = sorted(
        (
            fnum(
                row.get(score_column)
            )
            for row in rows
        ),
        reverse=True,
    )

    cutoff = scores[
        k - 1
    ]

    above_rows = [
        row
        for row in rows
        if (
            fnum(
                row.get(score_column)
            )
            > cutoff
        )
    ]

    tied_rows = [
        row
        for row in rows
        if (
            fnum(
                row.get(score_column)
            )
            == cutoff
        )
    ]

    needed = (
        k - len(above_rows)
    )

    total = sum(
        fnum(
            row.get(label_column)
        )
        for row in above_rows
    )

    if needed <= 0:
        return total

    if needed >= len(tied_rows):
        return total + sum(
            fnum(
                row.get(label_column)
            )
            for row in tied_rows
        )

    if len(score_columns) == 1:
        return total + (
            needed / len(tied_rows)
        ) * sum(
            fnum(
                row.get(label_column)
            )
            for row in tied_rows
        )

    return total + hierarchical_exact_k_total(
        rows=tied_rows,
        score_columns=score_columns[1:],
        k=needed,
        label_column=label_column,
    )


def structural_refinement_value(
    rows,
    fraction,
    label_column="intervention_gain",
):
    budget = exact_b(
        len(rows),
        fraction,
    )

    total = hierarchical_exact_k_total(
        rows=rows,
        score_columns=[
            "harm_score",
            "_H_struct_equal_rank",
        ],
        k=budget,
        label_column=label_column,
    )

    return total / budget


def candidate_value(
    calibration_rows,
    evaluation_rows,
    fraction,
    fallback_value,
    label_column="intervention_gain",
):
    diagnostic = calibration_gate(
        calibration_rows,
        fraction,
    )

    if not diagnostic["active"]:
        return (
            fallback_value,
            diagnostic,
        )

    value = structural_refinement_value(
        rows=evaluation_rows,
        fraction=fraction,
        label_column=label_column,
    )

    return (
        value,
        diagnostic,
    )

#!/usr/bin/env python3

"""Untouched C1/C2 confirmatory evaluation for frozen EVVA-SAG.

Primary criteria, frozen before evaluation:

1. C1 point AUBC delta versus original locked EVVA-SAG > 0.
2. C2 point AUBC delta versus original locked EVVA-SAG > 0.
3. Combined two-level block + seed-cluster bootstrap 95% CI
   lower bound > 0.

The primary metric is normalized trapezoidal AUBC over 5%-90%.
The 60% and 70% results are secondary diagnostics and are not
method-selection gates.
"""

import csv
import hashlib
import importlib.util
import json
import math
import os
import platform
import statistics
from collections import Counter, defaultdict
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Tuple

import numpy as np


ROOT = Path.cwd()

OUT = Path(
    os.environ["EVVA3_STAGE5B_OUT"]
)

C1_PATH = Path(
    os.environ["EVVA3_STAGE5B_C1"]
)

C2_PATH = Path(
    os.environ["EVVA3_STAGE5B_C2"]
)

V5M_PATH = Path(
    os.environ["EVVA3_STAGE5B_V5M"]
)

FINAL_PATH = Path(
    os.environ["EVVA3_STAGE5B_FINAL"]
)

PREREG_PATH = Path(
    os.environ["EVVA3_STAGE5B_PREREG"]
)

BOOTSTRAP_REPS = int(
    os.environ.get(
        "EVVA3_STAGE5B_BOOTSTRAP_REPS",
        "10000",
    )
)

RANDOM_SEED = 20260714

EXPECTED_V5M_SHA = (
    "924b6c893036f20ee9d60e90faf34c3beeb0f830af8e6d1c8ffd4dfee904906e"
)

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

AUBC_BUDGETS = [
    value
    for value in BUDGETS
    if value <= 0.90
]

EPSILON = 1e-10

BLOCKS = [
    {
        "name": "C1",
        "path": C1_PATH,
        "seed_min": 6500,
        "seed_max": 6799,
        "calibration_min": 6500,
        "calibration_max": 6599,
        "evaluation_min": 6600,
        "evaluation_max": 6799,
    },
    {
        "name": "C2",
        "path": C2_PATH,
        "seed_min": 6800,
        "seed_max": 7099,
        "calibration_min": 6800,
        "calibration_max": 6899,
        "evaluation_min": 6900,
        "evaluation_max": 7099,
    },
]

V_CANDIDATES = [
    "score_prm_value_gain",
    "prm_value_gain_score",
    "score_value_gain",
    "value_gain_score",
    "reward_value_score",
    "score_reward_value",
    "value_router_score",
]

METHODS = [
    "Random",
    "p-only",
    "H-only",
    "pH",
    "Locked-EVVA-SAG",
    "Final-EVVA-SAG",
    "Oracle",
]


def sha256(path: Path) -> str:
    digest = hashlib.sha256()

    with path.open("rb") as handle:
        for chunk in iter(
            lambda: handle.read(1024 * 1024),
            b"",
        ):
            digest.update(chunk)

    return digest.hexdigest()


def import_module(
    name: str,
    path: Path,
):
    specification = importlib.util.spec_from_file_location(
        name,
        path,
    )

    if specification is None or specification.loader is None:
        raise RuntimeError(
            f"Cannot import {path}."
        )

    module = importlib.util.module_from_spec(
        specification
    )

    specification.loader.exec_module(module)

    return module


if sha256(V5M_PATH) != EXPECTED_V5M_SHA:
    raise RuntimeError(
        "Locked v5m hash mismatch."
    )


LOCKED = import_module(
    "evva3_stage5b_locked_v5m",
    V5M_PATH,
)

FINAL = import_module(
    "evva3_stage5b_final_evva_sag",
    FINAL_PATH,
)


def parse_float(
    value: object,
) -> Optional[float]:
    try:
        text = str(value).strip()

        if not text:
            return None

        number = float(text)

        if not math.isfinite(number):
            return None

        return number
    except (TypeError, ValueError):
        return None


def parse_seed(
    value: object,
) -> int:
    number = parse_float(value)

    if number is None:
        raise ValueError(
            f"Invalid seed: {value!r}"
        )

    rounded = int(round(number))

    if abs(number - rounded) > 1e-9:
        raise ValueError(
            f"Non-integral seed: {value!r}"
        )

    return rounded


def read_csv(
    path: Path,
) -> Tuple[
    List[str],
    List[Dict[str, str]],
]:
    with path.open(
        newline="",
        encoding="utf-8-sig",
    ) as handle:
        reader = csv.DictReader(handle)

        return (
            list(reader.fieldnames or []),
            list(reader),
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


def stable_random_score(
    row: Dict[str, object],
) -> float:
    payload = "|".join([
        str(row.get("seed", "")),
        str(row.get("case_type", "")),
        str(row.get("agent_variant", "")),
        str(row.get("candidate_id", "")),
        "EVVA3_STAGE5B_RANDOM",
    ])

    integer = int(
        hashlib.sha256(
            payload.encode("utf-8")
        ).hexdigest(),
        16,
    )

    return integer / float(
        2 ** 256
    )


def detect_value_source(
    fields: Sequence[str],
    rows: Sequence[Dict[str, str]],
) -> Optional[str]:
    for candidate in V_CANDIDATES:
        if candidate not in fields:
            continue

        if any(
            str(
                row.get(
                    candidate,
                    "",
                )
            ).strip()
            for row in rows
        ):
            return candidate

    for candidate in V_CANDIDATES:
        if candidate in fields:
            return candidate

    return None


def canonicalize(
    fields: Sequence[str],
    rows: Sequence[Dict[str, str]],
) -> Tuple[
    List[Dict[str, object]],
    Optional[str],
]:
    value_source = detect_value_source(
        fields,
        rows,
    )

    output = []

    for raw in rows:
        row: Dict[str, object] = dict(raw)

        required = {
            "_confirm_p": parse_float(
                raw.get("p_score")
            ),
            "_confirm_H": parse_float(
                raw.get("harm_score")
            ),
            "_confirm_pH": parse_float(
                raw.get("p_times_H_score")
            ),
            "_confirm_gain": parse_float(
                raw.get("intervention_gain")
            ),
        }

        missing = [
            name
            for name, value in required.items()
            if value is None
        ]

        if missing:
            raise RuntimeError(
                f"Missing required canonical values: {missing}"
            )

        row.update(required)

        row["_confirm_V"] = (
            str(
                raw.get(
                    value_source,
                    "",
                )
            ).strip()
            if value_source is not None
            else ""
        )

        row["_confirm_random"] = (
            stable_random_score(row)
        )

        row["_confirm_oracle"] = float(
            required["_confirm_gain"]
        )

        row["_seed_int"] = parse_seed(
            raw.get("seed")
        )

        output.append(row)

    return output, value_source


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


def exact_b(
    n: int,
    fraction: float,
) -> int:
    return max(
        1,
        min(
            n,
            int(round(n * fraction)),
        ),
    )


def gain_array(
    rows: Sequence[Dict[str, object]],
) -> np.ndarray:
    return np.asarray(
        [
            float(row["_confirm_gain"])
            for row in rows
        ],
        dtype=float,
    )


def score_array(
    rows: Sequence[Dict[str, object]],
    column: str,
) -> np.ndarray:
    values = [
        parse_float(
            row.get(column)
        )
        for row in rows
    ]

    if any(
        value is None
        for value in values
    ):
        raise RuntimeError(
            f"Missing score values for {column}."
        )

    return np.asarray(
        values,
        dtype=float,
    )


def selected_value(
    scores: np.ndarray,
    gains: np.ndarray,
    fraction: float,
) -> float:
    if len(scores) != len(gains):
        raise RuntimeError(
            "Score/gain length mismatch."
        )

    if not np.all(
        np.isfinite(scores)
    ):
        raise RuntimeError(
            "Non-finite score."
        )

    if not np.all(
        np.isfinite(gains)
    ):
        raise RuntimeError(
            "Non-finite gain."
        )

    budget = exact_b(
        len(scores),
        fraction,
    )

    grouped: Dict[
        float,
        List[float],
    ] = {}

    for score, gain in zip(
        scores,
        gains,
    ):
        key = float(score)

        if key not in grouped:
            grouped[key] = [
                0.0,
                0.0,
            ]

        grouped[key][0] += 1.0
        grouped[key][1] += float(gain)

    selected_count = 0.0
    selected_sum = 0.0

    for score in sorted(
        grouped,
        reverse=True,
    ):
        count, gain_sum = grouped[score]

        if (
            selected_count + count
            <= budget
        ):
            selected_count += count
            selected_sum += gain_sum
            continue

        required = budget - selected_count

        if required > 0:
            selected_sum += (
                required / count
            ) * gain_sum

            selected_count += required

        break

    if abs(
        selected_count - budget
    ) > 1e-9:
        raise RuntimeError(
            "Exact-B selection failed."
        )

    return float(
        selected_sum / budget
    )


def curve_from_scores(
    scores: np.ndarray,
    gains: np.ndarray,
) -> List[float]:
    return [
        selected_value(
            scores,
            gains,
            fraction,
        )
        for fraction in BUDGETS
    ]


def aubc(
    curve: Sequence[float],
) -> float:
    x = np.asarray(
        AUBC_BUDGETS,
        dtype=float,
    )

    y = np.asarray(
        curve[:len(AUBC_BUDGETS)],
        dtype=float,
    )

    return float(
        np.trapz(y, x)
        / (x[-1] - x[0])
    )


def final_scores(
    calibration_rows: Sequence[Dict[str, object]],
    evaluation_rows: Sequence[Dict[str, object]],
) -> np.ndarray:
    scored = FINAL.apply_fixed_bg(
        calibration_rows,
        evaluation_rows,
        "_confirm_pH",
        "_confirm_H",
    )

    return np.asarray(
        [
            float(
                row[
                    "_EVVA3_FINAL_BG_score"
                ]
            )
            for row in scored
        ],
        dtype=float,
    )


def locked_scores_by_budget(
    calibration_rows: Sequence[Dict[str, object]],
    evaluation_rows: Sequence[Dict[str, object]],
) -> Dict[int, np.ndarray]:
    output = {}

    for fraction in BUDGETS:
        temporary = string_rows(
            evaluation_rows
        )

        LOCKED.bg_value(
            string_rows(
                calibration_rows
            ),
            temporary,
            "_confirm_pH",
            "_confirm_H",
            fraction,
        )

        budget = int(
            round(
                fraction * 100
            )
        )

        output[budget] = np.asarray(
            [
                float(
                    LOCKED.fnum(
                        row.get(
                            "_EVVA_BG_score"
                        )
                    )
                )
                for row in temporary
            ],
            dtype=float,
        )

    return output


def curve_from_budget_scores(
    scores_by_budget: Dict[
        int,
        np.ndarray,
    ],
    gains: np.ndarray,
) -> List[float]:
    output = []

    for fraction in BUDGETS:
        budget = int(
            round(
                fraction * 100
            )
        )

        output.append(
            selected_value(
                scores_by_budget[budget],
                gains,
                fraction,
            )
        )

    return output


def direct_locked_value(
    calibration_rows: Sequence[Dict[str, object]],
    evaluation_rows: Sequence[Dict[str, object]],
    fraction: float,
) -> float:
    temporary = string_rows(
        evaluation_rows
    )

    LOCKED.bg_value(
        string_rows(
            calibration_rows
        ),
        temporary,
        "_confirm_pH",
        "_confirm_H",
        fraction,
    )

    return float(
        LOCKED.scalar_tieaware(
            temporary,
            "_EVVA_BG_score",
            fraction,
        )
    )


def direct_final_value(
    calibration_rows: Sequence[Dict[str, object]],
    evaluation_rows: Sequence[Dict[str, object]],
    fraction: float,
) -> float:
    score_columns = {
        "p": "_confirm_p",
        "H": "_confirm_H",
        "pH": "_confirm_pH",
        "V": "_confirm_V",
    }

    return float(
        FINAL.evaluate(
            calibration_rows,
            evaluation_rows,
            fraction,
            score_columns,
        )
    )


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


def load_block(
    specification: Dict[str, object],
) -> Dict[str, object]:
    fields, raw_rows = read_csv(
        Path(
            specification["path"]
        )
    )

    rows, value_source = canonicalize(
        fields,
        raw_rows,
    )

    seed_min = int(
        specification["seed_min"]
    )

    seed_max = int(
        specification["seed_max"]
    )

    calibration_min = int(
        specification[
            "calibration_min"
        ]
    )

    calibration_max = int(
        specification[
            "calibration_max"
        ]
    )

    evaluation_min = int(
        specification[
            "evaluation_min"
        ]
    )

    evaluation_max = int(
        specification[
            "evaluation_max"
        ]
    )

    seeds = [
        int(row["_seed_int"])
        for row in rows
    ]

    seed_counts = Counter(seeds)

    if len(rows) != 900:
        raise RuntimeError(
            f"{specification['name']}: expected 900 rows."
        )

    if set(seed_counts) != set(
        range(
            seed_min,
            seed_max + 1,
        )
    ):
        raise RuntimeError(
            f"{specification['name']}: wrong seed range."
        )

    if (
        min(seed_counts.values()) != 3
        or max(seed_counts.values()) != 3
    ):
        raise RuntimeError(
            f"{specification['name']}: expected three rows per seed."
        )

    calibration_rows = [
        row
        for row in rows
        if (
            calibration_min
            <= int(
                row["_seed_int"]
            )
            <= calibration_max
        )
    ]

    evaluation_rows = [
        row
        for row in rows
        if (
            evaluation_min
            <= int(
                row["_seed_int"]
            )
            <= evaluation_max
        )
    ]

    if len(calibration_rows) != 300:
        raise RuntimeError(
            f"{specification['name']}: expected 300 calibration rows."
        )

    if len(evaluation_rows) != 600:
        raise RuntimeError(
            f"{specification['name']}: expected 600 evaluation rows."
        )

    calibration_seeds = {
        int(row["_seed_int"])
        for row in calibration_rows
    }

    evaluation_seeds = {
        int(row["_seed_int"])
        for row in evaluation_rows
    }

    if calibration_seeds & evaluation_seeds:
        raise RuntimeError(
            f"{specification['name']}: calibration/evaluation overlap."
        )

    value_usable = bool(
        LOCKED.usable(
            string_rows(
                evaluation_rows
            ),
            "_confirm_V",
        )
    )

    if value_usable:
        raise RuntimeError(
            f"{specification['name']}: value signal unexpectedly usable. "
            "C1/C2 were preregistered for the value-unavailable regime."
        )

    gains = gain_array(
        evaluation_rows
    )

    final_score = final_scores(
        calibration_rows,
        evaluation_rows,
    )

    locked_budget_scores = (
        locked_scores_by_budget(
            calibration_rows,
            evaluation_rows,
        )
    )

    scores = {
        "Random": score_array(
            evaluation_rows,
            "_confirm_random",
        ),
        "p-only": score_array(
            evaluation_rows,
            "_confirm_p",
        ),
        "H-only": score_array(
            evaluation_rows,
            "_confirm_H",
        ),
        "pH": score_array(
            evaluation_rows,
            "_confirm_pH",
        ),
        "Final-EVVA-SAG": final_score,
        "Oracle": score_array(
            evaluation_rows,
            "_confirm_oracle",
        ),
    }

    curves = {
        method: curve_from_scores(
            score,
            gains,
        )
        for method, score in scores.items()
    }

    curves[
        "Locked-EVVA-SAG"
    ] = curve_from_budget_scores(
        locked_budget_scores,
        gains,
    )

    curves[
        "Primitive-envelope"
    ] = [
        max(values)
        for values in zip(
            curves["Random"],
            curves["p-only"],
            curves["H-only"],
            curves["pH"],
        )
    ]

    # Exact point-value crosscheck against direct frozen implementations.
    crosschecks = []

    for index, fraction in enumerate(
        BUDGETS
    ):
        final_direct = direct_final_value(
            calibration_rows,
            evaluation_rows,
            fraction,
        )

        locked_direct = direct_locked_value(
            calibration_rows,
            evaluation_rows,
            fraction,
        )

        final_difference = (
            curves["Final-EVVA-SAG"][index]
            - final_direct
        )

        locked_difference = (
            curves["Locked-EVVA-SAG"][index]
            - locked_direct
        )

        crosschecks.append({
            "block": specification["name"],
            "budget_percent": int(
                round(
                    fraction * 100
                )
            ),
            "final_precomputed": curves[
                "Final-EVVA-SAG"
            ][index],
            "final_direct": final_direct,
            "final_difference": final_difference,
            "final_crosscheck_pass": (
                abs(final_difference)
                <= 1e-10
            ),
            "locked_precomputed": curves[
                "Locked-EVVA-SAG"
            ][index],
            "locked_direct": locked_direct,
            "locked_difference": locked_difference,
            "locked_crosscheck_pass": (
                abs(locked_difference)
                <= 1e-10
            ),
        })

    if not all(
        bool(row["final_crosscheck_pass"])
        and bool(
            row["locked_crosscheck_pass"]
        )
        for row in crosschecks
    ):
        raise RuntimeError(
            f"{specification['name']}: frozen implementation crosscheck failed."
        )

    # Row-order invariance.
    reversed_calibration = list(
        reversed(calibration_rows)
    )

    reversed_evaluation = list(
        reversed(evaluation_rows)
    )

    order_checks = []

    for index, fraction in enumerate(
        BUDGETS
    ):
        final_reversed = direct_final_value(
            reversed_calibration,
            reversed_evaluation,
            fraction,
        )

        locked_reversed = direct_locked_value(
            reversed_calibration,
            reversed_evaluation,
            fraction,
        )

        order_checks.append({
            "block": specification["name"],
            "budget_percent": int(
                round(
                    fraction * 100
                )
            ),
            "final_original": curves[
                "Final-EVVA-SAG"
            ][index],
            "final_reversed": final_reversed,
            "final_order_invariant": (
                abs(
                    curves[
                        "Final-EVVA-SAG"
                    ][index]
                    - final_reversed
                )
                <= 1e-10
            ),
            "locked_original": curves[
                "Locked-EVVA-SAG"
            ][index],
            "locked_reversed": locked_reversed,
            "locked_order_invariant": (
                abs(
                    curves[
                        "Locked-EVVA-SAG"
                    ][index]
                    - locked_reversed
                )
                <= 1e-10
            ),
        })

    if not all(
        bool(row["final_order_invariant"])
        and bool(
            row["locked_order_invariant"]
        )
        for row in order_checks
    ):
        raise RuntimeError(
            f"{specification['name']}: row-order invariance failed."
        )

    overall_mean = float(
        np.mean(gains)
    )

    equality_checks = []

    for method, curve in curves.items():
        equality_checks.append({
            "block": specification["name"],
            "method": method,
            "value_at_100": curve[-1],
            "overall_mean_gain": overall_mean,
            "difference": (
                curve[-1]
                - overall_mean
            ),
            "structural_equality_pass": (
                abs(
                    curve[-1]
                    - overall_mean
                )
                <= 1e-10
            ),
        })

    if not all(
        bool(
            row[
                "structural_equality_pass"
            ]
        )
        for row in equality_checks
    ):
        raise RuntimeError(
            f"{specification['name']}: 100% structural equality failed."
        )

    seed_indices: Dict[
        int,
        List[int],
    ] = defaultdict(list)

    for index, row in enumerate(
        evaluation_rows
    ):
        seed_indices[
            int(row["_seed_int"])
        ].append(index)

    return {
        "name": specification["name"],
        "path": str(
            specification["path"]
        ),
        "sha256": sha256(
            Path(
                specification["path"]
            )
        ),
        "fields": fields,
        "value_source": value_source,
        "value_usable": value_usable,
        "calibration_rows": calibration_rows,
        "evaluation_rows": evaluation_rows,
        "gains": gains,
        "scores": scores,
        "locked_budget_scores": locked_budget_scores,
        "curves": curves,
        "crosschecks": crosschecks,
        "order_checks": order_checks,
        "equality_checks": equality_checks,
        "seed_indices": seed_indices,
    }


def bootstrap_block_delta(
    block: Dict[str, object],
    rng: np.random.Generator,
) -> float:
    seed_indices = block[
        "seed_indices"
    ]

    seeds = np.asarray(
        sorted(seed_indices),
        dtype=int,
    )

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

    gains = block["gains"][
        indices
    ]

    final_curve = curve_from_scores(
        block["scores"][
            "Final-EVVA-SAG"
        ][indices],
        gains,
    )

    locked_curve = []

    for fraction in BUDGETS:
        budget = int(
            round(
                fraction * 100
            )
        )

        locked_curve.append(
            selected_value(
                block[
                    "locked_budget_scores"
                ][budget][indices],
                gains,
                fraction,
            )
        )

    return (
        aubc(final_curve)
        - aubc(locked_curve)
    )


def main() -> None:
    with PREREG_PATH.open(
        encoding="utf-8"
    ) as handle:
        preregistration = json.load(handle)

    blocks = [
        load_block(specification)
        for specification in BLOCKS
    ]

    curve_rows = []
    block_summary_rows = []
    broad_rows = []
    cell_rows = []
    crosscheck_rows = []
    order_rows = []
    equality_rows = []
    availability_rows = []

    for block in blocks:
        name = str(block["name"])
        curves = block["curves"]

        for method, curve in curves.items():
            for fraction, value in zip(
                BUDGETS,
                curve,
            ):
                curve_rows.append({
                    "block": name,
                    "method": method,
                    "budget_percent": int(
                        round(
                            fraction * 100
                        )
                    ),
                    "exact_B": exact_b(
                        len(
                            block[
                                "evaluation_rows"
                            ]
                        ),
                        fraction,
                    ),
                    "selected_mean_intervention_gain": value,
                })

        locked_aubc = aubc(
            curves["Locked-EVVA-SAG"]
        )

        final_aubc = aubc(
            curves["Final-EVVA-SAG"]
        )

        oracle_aubc = aubc(
            curves["Oracle"]
        )

        for method, curve in curves.items():
            method_aubc = aubc(curve)

            block_summary_rows.append({
                "block": name,
                "method": method,
                "aubc_5_90": method_aubc,
                "delta_vs_locked_evva_sag": (
                    method_aubc
                    - locked_aubc
                ),
                "oracle_regret": (
                    oracle_aubc
                    - method_aubc
                ),
                "oracle_regret_reduction_vs_locked": (
                    (
                        oracle_aubc
                        - locked_aubc
                    )
                    - (
                        oracle_aubc
                        - method_aubc
                    )
                ),
            })

        for budget in [
            60,
            70,
            100,
        ]:
            index = [
                int(
                    round(
                        fraction * 100
                    )
                )
                for fraction in BUDGETS
            ].index(budget)

            broad_rows.append({
                "block": name,
                "budget_percent": budget,
                "final_evva_sag": curves[
                    "Final-EVVA-SAG"
                ][index],
                "locked_evva_sag": curves[
                    "Locked-EVVA-SAG"
                ][index],
                "margin": (
                    curves[
                        "Final-EVVA-SAG"
                    ][index]
                    - curves[
                        "Locked-EVVA-SAG"
                    ][index]
                ),
            })

        margins_primary = [
            candidate - comparator
            for fraction, candidate, comparator
            in zip(
                BUDGETS,
                curves["Final-EVVA-SAG"],
                curves["Locked-EVVA-SAG"],
            )
            if fraction <= 0.90
        ]

        margins_all = [
            candidate - comparator
            for candidate, comparator
            in zip(
                curves["Final-EVVA-SAG"],
                curves["Locked-EVVA-SAG"],
            )
        ]

        for scope, margins in [
            ("5-90", margins_primary),
            ("5-100", margins_all),
        ]:
            cell_rows.append({
                "block": name,
                "scope": scope,
                "candidate": "Final-EVVA-SAG",
                "comparator": "Locked-EVVA-SAG",
                "strict_wins": sum(
                    margin > EPSILON
                    for margin in margins
                ),
                "exact_ties": sum(
                    abs(margin) <= EPSILON
                    for margin in margins
                ),
                "losses": sum(
                    margin < -EPSILON
                    for margin in margins
                ),
                "mean_margin": statistics.fmean(
                    margins
                ),
                "minimum_margin": min(
                    margins
                ),
                "maximum_margin": max(
                    margins
                ),
            })

        crosscheck_rows.extend(
            block["crosschecks"]
        )

        order_rows.extend(
            block["order_checks"]
        )

        equality_rows.extend(
            block["equality_checks"]
        )

        availability_rows.append({
            "block": name,
            "detected_value_source": (
                block["value_source"]
                or ""
            ),
            "value_usable": (
                block["value_usable"]
            ),
            "evaluation_rows": len(
                block[
                    "evaluation_rows"
                ]
            ),
            "final_score_unique": len(
                np.unique(
                    block["scores"][
                        "Final-EVVA-SAG"
                    ]
                )
            ),
            "final_score_variance": float(
                np.var(
                    block["scores"][
                        "Final-EVVA-SAG"
                    ]
                )
            ),
        })

    point_lookup = {
        (
            row["block"],
            row["method"],
        ): float(
            row["aubc_5_90"]
        )
        for row in block_summary_rows
    }

    c1_delta = (
        point_lookup[
            ("C1", "Final-EVVA-SAG")
        ]
        - point_lookup[
            ("C1", "Locked-EVVA-SAG")
        ]
    )

    c2_delta = (
        point_lookup[
            ("C2", "Final-EVVA-SAG")
        ]
        - point_lookup[
            ("C2", "Locked-EVVA-SAG")
        ]
    )

    combined_point_delta = statistics.fmean([
        c1_delta,
        c2_delta,
    ])

    rng = np.random.default_rng(
        RANDOM_SEED
    )

    c1_bootstrap = []
    c2_bootstrap = []
    combined_bootstrap = []

    block_lookup = {
        str(block["name"]): block
        for block in blocks
    }

    block_names = np.asarray(
        ["C1", "C2"],
        dtype=object,
    )

    for _ in range(BOOTSTRAP_REPS):
        c1_value = bootstrap_block_delta(
            block_lookup["C1"],
            rng,
        )

        c2_value = bootstrap_block_delta(
            block_lookup["C2"],
            rng,
        )

        c1_bootstrap.append(
            c1_value
        )

        c2_bootstrap.append(
            c2_value
        )

        precomputed = {
            "C1": c1_value,
            "C2": c2_value,
        }

        sampled_blocks = rng.choice(
            block_names,
            size=2,
            replace=True,
        )

        combined_bootstrap.append(
            statistics.fmean(
                precomputed[
                    str(block_name)
                ]
                for block_name
                in sampled_blocks
            )
        )

    bootstrap_rows = []

    for name, point, values in [
        (
            "C1",
            c1_delta,
            c1_bootstrap,
        ),
        (
            "C2",
            c2_delta,
            c2_bootstrap,
        ),
        (
            "Combined-two-level",
            combined_point_delta,
            combined_bootstrap,
        ),
    ]:
        bootstrap_rows.append({
            "analysis": name,
            "bootstrap_repetitions": BOOTSTRAP_REPS,
            "point_delta_aubc": point,
            "bootstrap_mean_delta": statistics.fmean(
                values
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
        })

    combined_ci_lower = next(
        float(row["ci_2_5"])
        for row in bootstrap_rows
        if row["analysis"]
        == "Combined-two-level"
    )

    criteria = {
        "c1_point_delta_positive": (
            c1_delta > 0.0
        ),
        "c2_point_delta_positive": (
            c2_delta > 0.0
        ),
        "combined_bootstrap_ci_lower_above_zero": (
            combined_ci_lower > 0.0
        ),
    }

    primary_pass = all(
        criteria.values()
    )

    decision = {
        "status": "complete",
        "decision": (
            "PASS"
            if primary_pass
            else "FAIL"
        ),
        "method": "Final-EVVA-SAG",
        "primary_comparator": (
            "Locked-EVVA-SAG"
        ),
        "primary_metric": (
            "normalized trapezoidal "
            "AUBC over 5%-90%"
        ),
        "c1_point_delta_aubc": c1_delta,
        "c2_point_delta_aubc": c2_delta,
        "combined_point_delta_aubc": (
            combined_point_delta
        ),
        "combined_bootstrap_ci_2_5": (
            combined_ci_lower
        ),
        "combined_bootstrap_ci_97_5": next(
            float(row["ci_97_5"])
            for row in bootstrap_rows
            if row["analysis"]
            == "Combined-two-level"
        ),
        "combined_probability_delta_ge_zero": next(
            float(
                row[
                    "probability_delta_ge_zero"
                ]
            )
            for row in bootstrap_rows
            if row["analysis"]
            == "Combined-two-level"
        ),
        "preregistered_criteria": criteria,
        "all_preregistered_criteria_pass": (
            primary_pass
        ),
        "secondary_60_70_are_not_selection_gates": True,
        "method_remains_frozen": True,
        "method_modification_permitted_after_result": False,
    }

    aggregate_rows = []

    all_methods = sorted({
        row["method"]
        for row in block_summary_rows
    })

    for method in all_methods:
        rows = [
            row
            for row in block_summary_rows
            if row["method"] == method
        ]

        values = [
            float(
                row["aubc_5_90"]
            )
            for row in rows
        ]

        deltas = [
            float(
                row[
                    "delta_vs_locked_evva_sag"
                ]
            )
            for row in rows
        ]

        regrets = [
            float(
                row["oracle_regret"]
            )
            for row in rows
        ]

        aggregate_rows.append({
            "method": method,
            "blocks": len(rows),
            "mean_aubc_5_90": statistics.fmean(
                values
            ),
            "minimum_block_aubc_5_90": min(
                values
            ),
            "maximum_block_aubc_5_90": max(
                values
            ),
            "mean_delta_vs_locked_evva_sag": statistics.fmean(
                deltas
            ),
            "minimum_block_delta_vs_locked_evva_sag": min(
                deltas
            ),
            "positive_blocks_vs_locked_evva_sag": sum(
                value > 0.0
                for value in deltas
            ),
            "mean_oracle_regret": statistics.fmean(
                regrets
            ),
        })

    write_csv(
        OUT / "results" / "curves.csv",
        curve_rows,
        [
            "block",
            "method",
            "budget_percent",
            "exact_B",
            "selected_mean_intervention_gain",
        ],
    )

    write_csv(
        OUT / "results" / "block_summary.csv",
        block_summary_rows,
        [
            "block",
            "method",
            "aubc_5_90",
            "delta_vs_locked_evva_sag",
            "oracle_regret",
            "oracle_regret_reduction_vs_locked",
        ],
    )

    write_csv(
        OUT / "results" / "aggregate_summary.csv",
        aggregate_rows,
        [
            "method",
            "blocks",
            "mean_aubc_5_90",
            "minimum_block_aubc_5_90",
            "maximum_block_aubc_5_90",
            "mean_delta_vs_locked_evva_sag",
            "minimum_block_delta_vs_locked_evva_sag",
            "positive_blocks_vs_locked_evva_sag",
            "mean_oracle_regret",
        ],
    )

    write_csv(
        OUT / "results" / "bootstrap.csv",
        bootstrap_rows,
        [
            "analysis",
            "bootstrap_repetitions",
            "point_delta_aubc",
            "bootstrap_mean_delta",
            "ci_2_5",
            "ci_97_5",
            "probability_delta_ge_zero",
        ],
    )

    write_csv(
        OUT / "results" / "broad_budget_60_70_100.csv",
        broad_rows,
        [
            "block",
            "budget_percent",
            "final_evva_sag",
            "locked_evva_sag",
            "margin",
        ],
    )

    write_csv(
        OUT / "results" / "cell_summary.csv",
        cell_rows,
        [
            "block",
            "scope",
            "candidate",
            "comparator",
            "strict_wins",
            "exact_ties",
            "losses",
            "mean_margin",
            "minimum_margin",
            "maximum_margin",
        ],
    )

    write_csv(
        OUT / "results" / "implementation_crosscheck.csv",
        crosscheck_rows,
        [
            "block",
            "budget_percent",
            "final_precomputed",
            "final_direct",
            "final_difference",
            "final_crosscheck_pass",
            "locked_precomputed",
            "locked_direct",
            "locked_difference",
            "locked_crosscheck_pass",
        ],
    )

    write_csv(
        OUT / "results" / "row_order_invariance.csv",
        order_rows,
        [
            "block",
            "budget_percent",
            "final_original",
            "final_reversed",
            "final_order_invariant",
            "locked_original",
            "locked_reversed",
            "locked_order_invariant",
        ],
    )

    write_csv(
        OUT / "results" / "structural_equality_100.csv",
        equality_rows,
        [
            "block",
            "method",
            "value_at_100",
            "overall_mean_gain",
            "difference",
            "structural_equality_pass",
        ],
    )

    write_csv(
        OUT / "results" / "signal_availability.csv",
        availability_rows,
        [
            "block",
            "detected_value_source",
            "value_usable",
            "evaluation_rows",
            "final_score_unique",
            "final_score_variance",
        ],
    )

    with (
        OUT
        / "reports"
        / "confirmatory_decision.json"
    ).open(
        "w",
        encoding="utf-8",
    ) as handle:
        json.dump(
            decision,
            handle,
            indent=2,
            sort_keys=True,
        )

    report = {
        "stage": "EVVA_3 Stage 5B",
        "status": "complete",
        "bootstrap_repetitions": BOOTSTRAP_REPS,
        "c1_rows": 900,
        "c2_rows": 900,
        "c1_evaluation_rows": 600,
        "c2_evaluation_rows": 600,
        "new_seed_collection": False,
        "method_frozen_before_evaluation": True,
        "method_modified_during_evaluation": False,
        "decision": decision["decision"],
        "all_implementation_crosschecks_pass": all(
            bool(row["final_crosscheck_pass"])
            and bool(
                row["locked_crosscheck_pass"]
            )
            for row in crosscheck_rows
        ),
        "all_row_order_checks_pass": all(
            bool(
                row[
                    "final_order_invariant"
                ]
            )
            and bool(
                row[
                    "locked_order_invariant"
                ]
            )
            for row in order_rows
        ),
        "all_100_percent_structural_checks_pass": all(
            bool(
                row[
                    "structural_equality_pass"
                ]
            )
            for row in equality_rows
        ),
    }

    with (
        OUT
        / "reports"
        / "stage5b_summary.json"
    ).open(
        "w",
        encoding="utf-8",
    ) as handle:
        json.dump(
            report,
            handle,
            indent=2,
            sort_keys=True,
        )

    runtime = {
        "python": platform.python_version(),
        "numpy": np.__version__,
        "bootstrap_repetitions": BOOTSTRAP_REPS,
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

    with (
        OUT
        / "manifests"
        / "preregistration_copy.json"
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

    print(
        json.dumps(
            decision,
            indent=2,
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    main()

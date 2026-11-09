#!/usr/bin/env bash

# EVVA_3 Stage 3C:
# Unified comparison against the exact hash-locked v5m implementation.
# Development-only. No new seeds and no frozen-file modification.

die() {
  echo "ERROR: $*" >&2
  exit 1
}

WORKSPACE="$HOME/.openclaw/workspace/skills/openclaw_pilot_v4_large_exactB_20260707_EVVA_3_signal_repair_20260713"

V5M="code/aaai_v5m_signal_availability_gated_evva.py"
EVVA2H="code/aaai_evva2h_severe_plateau_gate.py"

EXPECTED_V5M_SHA="924b6c893036f20ee9d60e90faf34c3beeb0f830af8e6d1c8ffd4dfee904906e"
EXPECTED_EVVA2H_SHA="21ccb27ded1838b86e7b37deae5c9bd069d58c2fe13d8ec90a54f7967205b28d"

[ -d "$WORKSPACE" ] || die "Workspace not found: $WORKSPACE"
cd "$WORKSPACE" || die "Cannot enter workspace."

[ -f "$V5M" ] || die "Missing locked v5m."
[ -f "$EVVA2H" ] || die "Missing frozen EVVA_2H."

ACTUAL_V5M_SHA="$(sha256sum "$V5M" | awk '{print $1}')"
ACTUAL_EVVA2H_SHA="$(sha256sum "$EVVA2H" | awk '{print $1}')"

[ "$ACTUAL_V5M_SHA" = "$EXPECTED_V5M_SHA" ] \
  || die "Locked v5m hash mismatch."

[ "$ACTUAL_EVVA2H_SHA" = "$EXPECTED_EVVA2H_SHA" ] \
  || die "Frozen EVVA_2H hash mismatch."

python3 - <<'PY' || die "Activate .venv_evva3 before Stage 3C."
import numpy
import sklearn
print("numpy", numpy.__version__)
print("sklearn", sklearn.__version__)
PY

RUN_ID="$(date +%Y%m%d_%H%M%S)"
OUT="artifacts/aaai_evva3_stage3c_unified_v5m_${RUN_ID}"

mkdir -p \
  "$OUT/code" \
  "$OUT/hashes" \
  "$OUT/logs" \
  "$OUT/manifests" \
  "$OUT/predictions" \
  "$OUT/results" \
  "$OUT/reports" \
  || die "Cannot create Stage 3C directories."

echo "$OUT" > artifacts/aaai_evva3_stage3c_latest.txt

BOOTSTRAP_REPS="${EVVA3_STAGE3C_BOOTSTRAP_REPS:-10000}"

export EVVA3_STAGE3C_OUT="$OUT"
export EVVA3_STAGE3C_BOOTSTRAP_REPS="$BOOTSTRAP_REPS"
export EVVA3_LOCKED_V5M="$V5M"

{
  sha256sum "$V5M"
  sha256sum "$EVVA2H"
} > "$OUT/hashes/pre_run_locked_sha256.txt"

cat > "$OUT/code/aaai_evva3_stage3c_unified_v5m.py" <<'PY'
#!/usr/bin/env python3

"""Unified LOBO comparison against the exact locked v5m implementation."""

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
import sklearn
from sklearn.ensemble import HistGradientBoostingRegressor
from sklearn.impute import SimpleImputer
from sklearn.linear_model import Ridge
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import StandardScaler


ROOT = Path.cwd()
OUT = Path(os.environ["EVVA3_STAGE3C_OUT"])
LOCKED_V5M_PATH = ROOT / os.environ["EVVA3_LOCKED_V5M"]
BOOTSTRAP_REPS = int(
    os.environ.get("EVVA3_STAGE3C_BOOTSTRAP_REPS", "10000")
)

EXPECTED_V5M_SHA = (
    "924b6c893036f20ee9d60e90faf34c3beeb0f830af8e6d1c8ffd4dfee904906e"
)

RANDOM_SEED = 20260714

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
]

FULL_FEATURES = [
    "p_score",
    "harm_score",
    "p_times_H_score",
    "rollback_difficulty",
    "persistent_state_risk",
    "log1p_downstream_dependency_count",
]

CORE_FEATURES = [
    "p_score",
    "harm_score",
    "p_times_H_score",
]

BLOCKS = [
    {
        "name": "original_4200_4499",
        "path": (
            "artifacts/v4_full_agent_20260707/large/"
            "full_agent_candidate_rows_large.csv"
        ),
        "calibration": (4200, 4299),
        "evaluation": (4300, 4499),
    },
    {
        "name": "first_5000_5299",
        "path": (
            "artifacts/aaai_evva2_exploratory_20260713/"
            "evva2g_confirmatory_5000_5299/raw/"
            "full_agent_candidate_rows_5000_5299.csv"
        ),
        "calibration": (5000, 5099),
        "evaluation": (5100, 5299),
    },
    {
        "name": "r2_5300_5599",
        "path": (
            "artifacts/aaai_evva2_exploratory_20260713/"
            "evva2g_replication_r2_5300_5599/raw/"
            "full_agent_candidate_rows_5300_5599.csv"
        ),
        "calibration": (5300, 5399),
        "evaluation": (5400, 5599),
    },
    {
        "name": "r3_5600_5899",
        "path": (
            "artifacts/aaai_evva2_exploratory_20260713/"
            "evva2g_replication_r3_5600_5899/raw/"
            "full_agent_candidate_rows_5600_5899.csv"
        ),
        "calibration": (5600, 5699),
        "evaluation": (5700, 5899),
    },
    {
        "name": "r4_5900_6199",
        "path": (
            "artifacts/aaai_evva2_exploratory_20260713/"
            "evva2h_final_confirmation_20260713/r4_5900_6199/raw/"
            "full_agent_candidate_rows_5900_6199.csv"
        ),
        "calibration": (5900, 5999),
        "evaluation": (6000, 6199),
    },
    {
        "name": "r5_6200_6499",
        "path": (
            "artifacts/aaai_evva2_exploratory_20260713/"
            "evva2h_final_confirmation_20260713/r5_6200_6499/raw/"
            "full_agent_candidate_rows_6200_6499.csv"
        ),
        "calibration": (6200, 6299),
        "evaluation": (6300, 6499),
    },
]

LOCKED_ORIGINAL_OUTPUT = Path(
    "artifacts/aaai_v5m_final_locked_20260709/outputs/"
    "large_v5k_signal_availability_gated_evva.csv"
)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()

    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)

    return digest.hexdigest()


def load_locked_v5m():
    actual = sha256(LOCKED_V5M_PATH)

    if actual != EXPECTED_V5M_SHA:
        raise RuntimeError(
            f"Locked v5m hash mismatch: {actual}"
        )

    specification = importlib.util.spec_from_file_location(
        "evva3_locked_v5m",
        LOCKED_V5M_PATH,
    )

    if specification is None or specification.loader is None:
        raise RuntimeError("Unable to import locked v5m.")

    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


LOCKED = load_locked_v5m()


def parse_float(value: object) -> Optional[float]:
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


def parse_seed(value: object) -> int:
    number = parse_float(value)

    if number is None:
        raise ValueError(f"Invalid seed: {value!r}")

    rounded = int(round(number))

    if abs(number - rounded) > 1e-9:
        raise ValueError(f"Non-integral seed: {value!r}")

    return rounded


def read_csv(path: Path) -> Tuple[List[str], List[Dict[str, str]]]:
    with path.open("r", newline="", encoding="utf-8-sig") as handle:
        reader = csv.DictReader(handle)
        return list(reader.fieldnames or []), list(reader)


def write_csv(
    path: Path,
    rows: Sequence[Dict[str, object]],
    fields: Sequence[str],
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)

    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=list(fields),
            extrasaction="ignore",
        )
        writer.writeheader()
        writer.writerows(rows)


def augment_row(row: Dict[str, str]) -> Dict[str, object]:
    downstream = parse_float(
        row.get("downstream_dependency_count")
    )

    result: Dict[str, object] = dict(row)
    result["seed"] = parse_seed(row.get("seed"))
    result["log1p_downstream_dependency_count"] = (
        math.log1p(max(0.0, downstream))
        if downstream is not None
        else None
    )

    return result


def matrix(
    rows: Sequence[Dict[str, object]],
    features: Sequence[str],
) -> np.ndarray:
    return np.asarray(
        [
            [
                parse_float(row.get(feature))
                for feature in features
            ]
            for row in rows
        ],
        dtype=float,
    )


def labels(rows: Sequence[Dict[str, object]]) -> np.ndarray:
    values = [
        parse_float(row.get("intervention_gain"))
        for row in rows
    ]

    if any(value is None for value in values):
        raise RuntimeError("Missing intervention_gain.")

    return np.asarray(values, dtype=float)


def exact_b(n: int, fraction: float) -> int:
    return max(
        1,
        min(
            n,
            int(round(n * fraction)),
        ),
    )


def selected_value(
    scores: np.ndarray,
    gains: np.ndarray,
    fraction: float,
) -> float:
    if len(scores) != len(gains):
        raise RuntimeError("Score/gain length mismatch.")

    if not np.all(np.isfinite(scores)):
        raise RuntimeError("Non-finite score detected.")

    budget = exact_b(len(scores), fraction)

    grouped: Dict[float, List[float]] = {}

    for score, gain in zip(scores, gains):
        key = float(score)

        if key not in grouped:
            grouped[key] = [0.0, 0.0]

        grouped[key][0] += 1.0
        grouped[key][1] += float(gain)

    levels = sorted(grouped, reverse=True)

    selected_count = 0.0
    selected_sum = 0.0

    for level in levels:
        count, gain_sum = grouped[level]

        if selected_count + count <= budget:
            selected_count += count
            selected_sum += gain_sum
            continue

        needed = budget - selected_count

        if needed > 0:
            selected_sum += (
                needed / count
            ) * gain_sum
            selected_count += needed

        break

    return float(selected_sum / budget)


def fixed_score_curve(
    scores: np.ndarray,
    gains: np.ndarray,
) -> List[float]:
    return [
        selected_value(scores, gains, fraction)
        for fraction in BUDGETS
    ]


def aubc(curve: Sequence[float]) -> float:
    x = np.asarray(BUDGETS, dtype=float)
    y = np.asarray(curve, dtype=float)

    return float(
        np.trapz(y, x)
        / (x[-1] - x[0])
    )


def shallow_model():
    return Pipeline([
        (
            "imputer",
            SimpleImputer(strategy="median"),
        ),
        (
            "model",
            HistGradientBoostingRegressor(
                learning_rate=0.05,
                max_iter=100,
                max_depth=2,
                min_samples_leaf=40,
                l2_regularization=1.0,
                random_state=RANDOM_SEED,
            ),
        ),
    ])


def ridge_model():
    return Pipeline([
        (
            "imputer",
            SimpleImputer(strategy="median"),
        ),
        (
            "scaler",
            StandardScaler(),
        ),
        (
            "model",
            Ridge(alpha=1.0),
        ),
    ])


def percentile(
    values: Sequence[float],
    probability: float,
) -> float:
    return float(
        np.quantile(
            np.asarray(values, dtype=float),
            probability,
        )
    )


def main() -> None:
    if not all(
        fraction in LOCKED.BUDGETS
        for fraction in BUDGETS
    ):
        raise RuntimeError(
            "Stage 3C budgets are not a subset of locked v5m budgets."
        )

    block_data: Dict[str, List[Dict[str, object]]] = {}
    input_manifest = []

    for block in BLOCKS:
        path = ROOT / block["path"]

        if not path.is_file():
            raise FileNotFoundError(path)

        fields, raw_rows = read_csv(path)
        rows = [augment_row(row) for row in raw_rows]

        if len(rows) != 900:
            raise RuntimeError(
                f"{block['name']}: expected 900 rows."
            )

        seed_counts = Counter(
            int(row["seed"])
            for row in rows
        )

        if (
            len(seed_counts) != 300
            or min(seed_counts.values()) != 3
            or max(seed_counts.values()) != 3
        ):
            raise RuntimeError(
                f"{block['name']}: invalid seed clustering."
            )

        block_data[block["name"]] = rows

        input_manifest.append({
            "block": block["name"],
            "path": block["path"],
            "sha256": sha256(path),
            "rows": len(rows),
            "unique_seeds": len(seed_counts),
            "columns": len(fields),
        })

    block_summary_rows: List[Dict[str, object]] = []
    curve_rows: List[Dict[str, object]] = []
    cell_rows: List[Dict[str, object]] = []
    broad_rows: List[Dict[str, object]] = []
    prediction_rows: List[Dict[str, object]] = []
    crosscheck_rows: List[Dict[str, object]] = []

    heldout_records: Dict[str, Dict[str, object]] = {}

    locked_original_lookup = {}

    if LOCKED_ORIGINAL_OUTPUT.is_file():
        _, locked_output_rows = read_csv(
            LOCKED_ORIGINAL_OUTPUT
        )

        locked_original_lookup = {
            row["budget"]: float(row["EVVA_SAG"])
            for row in locked_output_rows
        }

    for heldout in BLOCKS:
        block_name = heldout["name"]
        cal_min, cal_max = heldout["calibration"]
        eval_min, eval_max = heldout["evaluation"]

        training_rows = [
            row
            for block in BLOCKS
            if block["name"] != block_name
            for row in block_data[block["name"]]
        ]

        calibration_rows = [
            dict(row)
            for row in block_data[block_name]
            if cal_min <= int(row["seed"]) <= cal_max
        ]

        evaluation_rows = [
            dict(row)
            for row in block_data[block_name]
            if eval_min <= int(row["seed"]) <= eval_max
        ]

        if len(training_rows) != 4500:
            raise RuntimeError(
                f"{block_name}: expected 4500 training rows."
            )

        if len(calibration_rows) != 300:
            raise RuntimeError(
                f"{block_name}: expected 300 calibration rows."
            )

        if len(evaluation_rows) != 600:
            raise RuntimeError(
                f"{block_name}: expected 600 evaluation rows."
            )

        v_usable = LOCKED.usable(
            calibration_rows,
            "PRM_value_surrogate",
        )

        if v_usable:
            raise RuntimeError(
                f"{block_name}: expected locked large V to be unusable."
            )

        train_y = labels(training_rows)
        eval_y = labels(evaluation_rows)

        full_model = shallow_model()
        core_model = shallow_model()
        ridge = ridge_model()

        full_model.fit(
            matrix(training_rows, FULL_FEATURES),
            train_y,
        )

        core_model.fit(
            matrix(training_rows, CORE_FEATURES),
            train_y,
        )

        ridge.fit(
            matrix(training_rows, FULL_FEATURES),
            train_y,
        )

        fixed_scores: Dict[str, np.ndarray] = {
            "Random": np.zeros(
                len(evaluation_rows),
                dtype=float,
            ),
            "p-only": np.asarray(
                [
                    parse_float(row.get("p_score"))
                    for row in evaluation_rows
                ],
                dtype=float,
            ),
            "H-only": np.asarray(
                [
                    parse_float(row.get("harm_score"))
                    for row in evaluation_rows
                ],
                dtype=float,
            ),
            "pH": np.asarray(
                [
                    parse_float(row.get("p_times_H_score"))
                    for row in evaluation_rows
                ],
                dtype=float,
            ),
            "ShallowGB-full": full_model.predict(
                matrix(evaluation_rows, FULL_FEATURES)
            ),
            "ShallowGB-core": core_model.predict(
                matrix(evaluation_rows, CORE_FEATURES)
            ),
            "Ridge-full": ridge.predict(
                matrix(evaluation_rows, FULL_FEATURES)
            ),
            "Oracle": eval_y.copy(),
        }

        fixed_curves = {
            method: fixed_score_curve(scores, eval_y)
            for method, scores in fixed_scores.items()
        }

        v5m_scores_by_budget: Dict[int, np.ndarray] = {}
        v5m_curve = []

        for fraction in BUDGETS:
            temporary_eval = [
                dict(row)
                for row in evaluation_rows
            ]

            locked_value = LOCKED.bg_value(
                calibration_rows,
                temporary_eval,
                "p_times_H_score",
                "harm_score",
                fraction,
            )

            budget_percent = int(round(fraction * 100))

            score_array = np.asarray(
                [
                    LOCKED.fnum(
                        row.get("_EVVA_BG_score")
                    )
                    for row in temporary_eval
                ],
                dtype=float,
            )

            reproduced_value = selected_value(
                score_array,
                eval_y,
                fraction,
            )

            if abs(
                locked_value - reproduced_value
            ) > 1e-10:
                raise RuntimeError(
                    f"{block_name} {budget_percent}% "
                    "locked-v5m reproduction mismatch."
                )

            v5m_scores_by_budget[
                budget_percent
            ] = score_array

            v5m_curve.append(reproduced_value)

            if (
                block_name == "original_4200_4499"
                and f"{budget_percent}%"
                in locked_original_lookup
            ):
                archived = locked_original_lookup[
                    f"{budget_percent}%"
                ]

                difference = reproduced_value - archived

                crosscheck_rows.append({
                    "block": block_name,
                    "budget_percent": budget_percent,
                    "reproduced_locked_v5m": reproduced_value,
                    "archived_locked_output_4dp": archived,
                    "difference": difference,
                    "rounding_tolerance_pass": (
                        abs(difference) <= 0.000051
                    ),
                })

        all_curves = dict(fixed_curves)
        all_curves["Locked-v5m"] = v5m_curve

        primitive_envelope = [
            max(values)
            for values in zip(
                fixed_curves["Random"],
                fixed_curves["p-only"],
                fixed_curves["H-only"],
                fixed_curves["pH"],
            )
        ]

        all_curves["Primitive-envelope"] = primitive_envelope

        for method, curve in all_curves.items():
            block_summary_rows.append({
                "block": block_name,
                "method": method,
                "aubc_5_90": aubc(curve),
                "delta_vs_locked_v5m": (
                    aubc(curve) - aubc(v5m_curve)
                ),
                "delta_vs_pH": (
                    aubc(curve)
                    - aubc(fixed_curves["pH"])
                ),
                "delta_vs_primitive_envelope": (
                    aubc(curve)
                    - aubc(primitive_envelope)
                ),
            })

            for fraction, value in zip(
                BUDGETS,
                curve,
            ):
                curve_rows.append({
                    "block": block_name,
                    "method": method,
                    "budget_percent": int(
                        round(fraction * 100)
                    ),
                    "exact_B": exact_b(
                        len(evaluation_rows),
                        fraction,
                    ),
                    "selected_mean_intervention_gain": value,
                })

        for fraction, full_value, v5m_value, envelope in zip(
            BUDGETS,
            fixed_curves["ShallowGB-full"],
            v5m_curve,
            primitive_envelope,
        ):
            budget_percent = int(round(fraction * 100))

            for comparator, comparator_value in [
                ("Locked-v5m", v5m_value),
                ("Primitive-envelope", envelope),
                ("pH", fixed_curves["pH"][
                    BUDGETS.index(fraction)
                ]),
            ]:
                margin = full_value - comparator_value

                cell_rows.append({
                    "block": block_name,
                    "budget_percent": budget_percent,
                    "candidate": "ShallowGB-full",
                    "comparator": comparator,
                    "candidate_value": full_value,
                    "comparator_value": comparator_value,
                    "margin": margin,
                    "status": (
                        "strict_win"
                        if margin > 1e-10
                        else "loss"
                        if margin < -1e-10
                        else "exact_tie"
                    ),
                })

            if budget_percent in {60, 70}:
                broad_rows.append({
                    "block": block_name,
                    "budget_percent": budget_percent,
                    "shallowgb_full": full_value,
                    "locked_v5m": v5m_value,
                    "H_only": fixed_curves["H-only"][
                        BUDGETS.index(fraction)
                    ],
                    "pH": fixed_curves["pH"][
                        BUDGETS.index(fraction)
                    ],
                    "primitive_envelope": envelope,
                    "delta_full_vs_locked_v5m": (
                        full_value - v5m_value
                    ),
                    "delta_full_vs_H": (
                        full_value
                        - fixed_curves["H-only"][
                            BUDGETS.index(fraction)
                        ]
                    ),
                    "delta_full_vs_pH": (
                        full_value
                        - fixed_curves["pH"][
                            BUDGETS.index(fraction)
                        ]
                    ),
                })

        for index, row in enumerate(evaluation_rows):
            output = {
                "block": block_name,
                "seed": int(row["seed"]),
                "case_type": row.get("case_type", ""),
                "candidate_id": row.get("candidate_id", ""),
                "intervention_gain": eval_y[index],
                "score_p": fixed_scores["p-only"][index],
                "score_H": fixed_scores["H-only"][index],
                "score_pH": fixed_scores["pH"][index],
                "score_ShallowGB_full": fixed_scores[
                    "ShallowGB-full"
                ][index],
                "score_ShallowGB_core": fixed_scores[
                    "ShallowGB-core"
                ][index],
                "score_Ridge_full": fixed_scores[
                    "Ridge-full"
                ][index],
            }

            for budget_percent in [
                int(round(fraction * 100))
                for fraction in BUDGETS
            ]:
                output[
                    f"score_locked_v5m_{budget_percent}"
                ] = v5m_scores_by_budget[
                    budget_percent
                ][index]

            prediction_rows.append(output)

        heldout_records[block_name] = {
            "rows": evaluation_rows,
            "gains": eval_y,
            "fixed_scores": {
                method: fixed_scores[method]
                for method in [
                    "Random",
                    "p-only",
                    "H-only",
                    "pH",
                    "ShallowGB-full",
                    "ShallowGB-core",
                    "Ridge-full",
                ]
            },
            "v5m_scores_by_budget": v5m_scores_by_budget,
        }

    if crosscheck_rows and not all(
        bool(row["rounding_tolerance_pass"])
        for row in crosscheck_rows
    ):
        raise RuntimeError(
            "Reproduced locked v5m does not match archived output."
        )

    write_csv(
        OUT / "manifests" / "canonical_input_manifest.csv",
        input_manifest,
        [
            "block",
            "path",
            "sha256",
            "rows",
            "unique_seeds",
            "columns",
        ],
    )

    write_csv(
        OUT / "results" / "locked_output_crosscheck.csv",
        crosscheck_rows,
        [
            "block",
            "budget_percent",
            "reproduced_locked_v5m",
            "archived_locked_output_4dp",
            "difference",
            "rounding_tolerance_pass",
        ],
    )

    write_csv(
        OUT / "results" / "block_summary.csv",
        block_summary_rows,
        [
            "block",
            "method",
            "aubc_5_90",
            "delta_vs_locked_v5m",
            "delta_vs_pH",
            "delta_vs_primitive_envelope",
        ],
    )

    write_csv(
        OUT / "results" / "curve_by_block.csv",
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
        OUT / "results" / "candidate_cells.csv",
        cell_rows,
        [
            "block",
            "budget_percent",
            "candidate",
            "comparator",
            "candidate_value",
            "comparator_value",
            "margin",
            "status",
        ],
    )

    write_csv(
        OUT / "results" / "broad_budget_60_70.csv",
        broad_rows,
        [
            "block",
            "budget_percent",
            "shallowgb_full",
            "locked_v5m",
            "H_only",
            "pH",
            "primitive_envelope",
            "delta_full_vs_locked_v5m",
            "delta_full_vs_H",
            "delta_full_vs_pH",
        ],
    )

    prediction_fields = [
        "block",
        "seed",
        "case_type",
        "candidate_id",
        "intervention_gain",
        "score_p",
        "score_H",
        "score_pH",
        "score_ShallowGB_full",
        "score_ShallowGB_core",
        "score_Ridge_full",
    ] + [
        f"score_locked_v5m_{int(round(fraction * 100))}"
        for fraction in BUDGETS
    ]

    write_csv(
        OUT / "predictions" / "unified_heldout_predictions.csv",
        prediction_rows,
        prediction_fields,
    )

    aggregate_rows = []

    methods = sorted({
        row["method"]
        for row in block_summary_rows
    })

    for method in methods:
        rows = [
            row
            for row in block_summary_rows
            if row["method"] == method
        ]

        aubcs = [
            float(row["aubc_5_90"])
            for row in rows
        ]

        locked_deltas = [
            float(row["delta_vs_locked_v5m"])
            for row in rows
        ]

        aggregate_rows.append({
            "method": method,
            "blocks": len(rows),
            "mean_aubc_5_90": statistics.fmean(aubcs),
            "minimum_block_aubc_5_90": min(aubcs),
            "maximum_block_aubc_5_90": max(aubcs),
            "mean_delta_vs_locked_v5m": statistics.fmean(
                locked_deltas
            ),
            "minimum_block_delta_vs_locked_v5m": min(
                locked_deltas
            ),
            "maximum_block_delta_vs_locked_v5m": max(
                locked_deltas
            ),
            "positive_blocks_vs_locked_v5m": sum(
                delta > 0.0
                for delta in locked_deltas
            ),
        })

    write_csv(
        OUT / "results" / "aggregate_summary.csv",
        aggregate_rows,
        [
            "method",
            "blocks",
            "mean_aubc_5_90",
            "minimum_block_aubc_5_90",
            "maximum_block_aubc_5_90",
            "mean_delta_vs_locked_v5m",
            "minimum_block_delta_vs_locked_v5m",
            "maximum_block_delta_vs_locked_v5m",
            "positive_blocks_vs_locked_v5m",
        ],
    )

    block_names = [
        block["name"]
        for block in BLOCKS
    ]

    point_delta: Dict[
        Tuple[str, str],
        float,
    ] = {}

    for block_name in block_names:
        rows = {
            row["method"]: float(row["aubc_5_90"])
            for row in block_summary_rows
            if row["block"] == block_name
        }

        for comparator in [
            "Locked-v5m",
            "Primitive-envelope",
            "pH",
            "ShallowGB-core",
            "Ridge-full",
        ]:
            point_delta[
                (block_name, comparator)
            ] = (
                rows["ShallowGB-full"]
                - rows[comparator]
            )

    jackknife_rows = []

    for comparator in [
        "Locked-v5m",
        "Primitive-envelope",
        "pH",
        "ShallowGB-core",
        "Ridge-full",
    ]:
        complete = [
            point_delta[(block_name, comparator)]
            for block_name in block_names
        ]

        for omitted in block_names:
            retained = [
                point_delta[(block_name, comparator)]
                for block_name in block_names
                if block_name != omitted
            ]

            jackknife_rows.append({
                "candidate": "ShallowGB-full",
                "comparator": comparator,
                "omitted_block": omitted,
                "full_six_block_mean_delta": statistics.fmean(
                    complete
                ),
                "leave_one_block_out_mean_delta": statistics.fmean(
                    retained
                ),
                "minimum_retained_block_delta": min(
                    retained
                ),
            })

    write_csv(
        OUT / "results" / "block_jackknife.csv",
        jackknife_rows,
        [
            "candidate",
            "comparator",
            "omitted_block",
            "full_six_block_mean_delta",
            "leave_one_block_out_mean_delta",
            "minimum_retained_block_delta",
        ],
    )

    seed_indices: Dict[
        str,
        Dict[int, List[int]],
    ] = {}

    for block_name, record in heldout_records.items():
        mapping: Dict[int, List[int]] = defaultdict(list)

        for index, row in enumerate(record["rows"]):
            mapping[int(row["seed"])].append(index)

        seed_indices[block_name] = mapping

    rng = np.random.default_rng(RANDOM_SEED)

    bootstrap_values: Dict[str, List[float]] = defaultdict(list)

    comparators = [
        "Locked-v5m",
        "Primitive-envelope",
        "pH",
        "ShallowGB-core",
        "Ridge-full",
    ]

    for _ in range(BOOTSTRAP_REPS):
        sampled_blocks = rng.choice(
            np.asarray(block_names, dtype=object),
            size=len(block_names),
            replace=True,
        )

        replicate: Dict[str, List[float]] = defaultdict(list)

        for sampled_block in sampled_blocks:
            block_name = str(sampled_block)
            record = heldout_records[block_name]
            mapping = seed_indices[block_name]

            unique_seeds = np.asarray(
                sorted(mapping),
                dtype=int,
            )

            sampled_seeds = rng.choice(
                unique_seeds,
                size=len(unique_seeds),
                replace=True,
            )

            indices = np.asarray([
                index
                for seed in sampled_seeds
                for index in mapping[int(seed)]
            ], dtype=int)

            gains = record["gains"][indices]
            fixed = record["fixed_scores"]

            curves = {
                method: fixed_score_curve(
                    scores[indices],
                    gains,
                )
                for method, scores in fixed.items()
            }

            v5m_curve = []

            for fraction in BUDGETS:
                budget_percent = int(
                    round(fraction * 100)
                )

                scores = record[
                    "v5m_scores_by_budget"
                ][budget_percent][indices]

                v5m_curve.append(
                    selected_value(
                        scores,
                        gains,
                        fraction,
                    )
                )

            envelope_curve = [
                max(values)
                for values in zip(
                    curves["Random"],
                    curves["p-only"],
                    curves["H-only"],
                    curves["pH"],
                )
            ]

            candidate_aubc = aubc(
                curves["ShallowGB-full"]
            )

            comparator_aubcs = {
                "Locked-v5m": aubc(v5m_curve),
                "Primitive-envelope": aubc(
                    envelope_curve
                ),
                "pH": aubc(curves["pH"]),
                "ShallowGB-core": aubc(
                    curves["ShallowGB-core"]
                ),
                "Ridge-full": aubc(
                    curves["Ridge-full"]
                ),
            }

            for comparator in comparators:
                replicate[comparator].append(
                    candidate_aubc
                    - comparator_aubcs[comparator]
                )

        for comparator in comparators:
            bootstrap_values[comparator].append(
                statistics.fmean(
                    replicate[comparator]
                )
            )

    bootstrap_rows = []

    for comparator in comparators:
        values = bootstrap_values[comparator]

        point_values = [
            point_delta[(block_name, comparator)]
            for block_name in block_names
        ]

        bootstrap_rows.append({
            "candidate": "ShallowGB-full",
            "comparator": comparator,
            "bootstrap_repetitions": BOOTSTRAP_REPS,
            "point_mean_six_block_delta": statistics.fmean(
                point_values
            ),
            "minimum_point_block_delta": min(
                point_values
            ),
            "maximum_point_block_delta": max(
                point_values
            ),
            "bootstrap_mean_delta": statistics.fmean(
                values
            ),
            "ci_2_5": percentile(values, 0.025),
            "ci_97_5": percentile(values, 0.975),
            "probability_delta_ge_zero": (
                sum(value >= 0.0 for value in values)
                / len(values)
            ),
        })

    write_csv(
        OUT / "results" / "two_level_bootstrap.csv",
        bootstrap_rows,
        [
            "candidate",
            "comparator",
            "bootstrap_repetitions",
            "point_mean_six_block_delta",
            "minimum_point_block_delta",
            "maximum_point_block_delta",
            "bootstrap_mean_delta",
            "ci_2_5",
            "ci_97_5",
            "probability_delta_ge_zero",
        ],
    )

    cell_summary_rows = []

    for comparator in [
        "Locked-v5m",
        "Primitive-envelope",
        "pH",
    ]:
        rows = [
            row
            for row in cell_rows
            if row["comparator"] == comparator
        ]

        counts = Counter(
            row["status"]
            for row in rows
        )

        margins = [
            float(row["margin"])
            for row in rows
        ]

        cell_summary_rows.append({
            "candidate": "ShallowGB-full",
            "comparator": comparator,
            "total_cells": len(rows),
            "strict_wins": counts["strict_win"],
            "exact_ties": counts["exact_tie"],
            "losses": counts["loss"],
            "mean_margin": statistics.fmean(margins),
            "minimum_margin": min(margins),
            "maximum_margin": max(margins),
        })

    write_csv(
        OUT / "results" / "cell_summary.csv",
        cell_summary_rows,
        [
            "candidate",
            "comparator",
            "total_cells",
            "strict_wins",
            "exact_ties",
            "losses",
            "mean_margin",
            "minimum_margin",
            "maximum_margin",
        ],
    )

    specification = {
        "stage": "EVVA_3 Stage 3C unified locked-v5m comparison",
        "development_only": True,
        "final_model_frozen": False,
        "new_seed_collection": False,
        "locked_v5m_path": str(LOCKED_V5M_PATH),
        "locked_v5m_sha256": sha256(LOCKED_V5M_PATH),
        "large_v5m_mode": "BG-fallback",
        "large_v5m_reason": (
            "PRM_value_surrogate unusable on each calibration block"
        ),
        "locked_v5m_behavior": {
            "5_to_30_percent": (
                "0.10 percentile(pH) + 0.90 percentile(H)"
            ),
            "40_to_90_percent": "percentile(H)",
        },
        "candidate": {
            "name": "ShallowGB-full",
            "features": FULL_FEATURES,
            "model": "HistGradientBoostingRegressor",
            "learning_rate": 0.05,
            "max_iter": 100,
            "max_depth": 2,
            "min_samples_leaf": 40,
            "l2_regularization": 1.0,
            "random_state": RANDOM_SEED,
        },
        "bootstrap": {
            "type": (
                "two-level block plus within-block "
                "evaluation-seed cluster bootstrap"
            ),
            "repetitions": BOOTSTRAP_REPS,
        },
    }

    with (
        OUT / "manifests" / "stage3c_spec.json"
    ).open("w", encoding="utf-8") as handle:
        json.dump(
            specification,
            handle,
            indent=2,
            sort_keys=True,
        )

    runtime = {
        "python": platform.python_version(),
        "numpy": np.__version__,
        "sklearn": sklearn.__version__,
        "bootstrap_repetitions": BOOTSTRAP_REPS,
    }

    with (
        OUT / "manifests" / "runtime_versions.json"
    ).open("w", encoding="utf-8") as handle:
        json.dump(
            runtime,
            handle,
            indent=2,
            sort_keys=True,
        )

    summary = {
        "status": "complete",
        "formal_blocks": len(BLOCKS),
        "locked_v5m_imported_directly": True,
        "locked_v5m_sha256": sha256(
            LOCKED_V5M_PATH
        ),
        "locked_output_crosscheck_pass": all(
            bool(row["rounding_tolerance_pass"])
            for row in crosscheck_rows
        ),
        "bootstrap_repetitions": BOOTSTRAP_REPS,
        "new_seed_collection": False,
        "final_model_frozen": False,
        "warning": (
            "Development evidence only; not untouched confirmation."
        ),
    }

    with (
        OUT / "reports" / "stage3c_summary.json"
    ).open("w", encoding="utf-8") as handle:
        json.dump(
            summary,
            handle,
            indent=2,
            sort_keys=True,
        )

    print(json.dumps(summary, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
PY

echo "===================================================="
echo "EVVA_3 STAGE 3C UNIFIED LOCKED-V5M COMPARISON"
echo "===================================================="
echo "Output: $OUT"
echo "Two-level bootstrap repetitions: $BOOTSTRAP_REPS"
echo

python3 -m py_compile \
  "$OUT/code/aaai_evva3_stage3c_unified_v5m.py" \
  || die "Stage 3C Python failed py_compile."

python3 \
  "$OUT/code/aaai_evva3_stage3c_unified_v5m.py" \
  2>&1 | tee "$OUT/logs/stage3c.log" \
  || die "Stage 3C experiment failed."

{
  sha256sum "$V5M"
  sha256sum "$EVVA2H"
} > "$OUT/hashes/post_run_locked_sha256.txt"

POST_V5M_SHA="$(sha256sum "$V5M" | awk '{print $1}')"
POST_EVVA2H_SHA="$(sha256sum "$EVVA2H" | awk '{print $1}')"

[ "$POST_V5M_SHA" = "$EXPECTED_V5M_SHA" ] \
  || die "Locked v5m changed during Stage 3C."

[ "$POST_EVVA2H_SHA" = "$EXPECTED_EVVA2H_SHA" ] \
  || die "Frozen EVVA_2H changed during Stage 3C."

find "$OUT" \
  -type f \
  ! -name 'FINAL_SHA256SUMS.txt' \
  -print0 \
  | sort -z \
  | xargs -0 sha256sum \
  > "$OUT/FINAL_SHA256SUMS.txt"

{
  echo "# EVVA_3 Stage 3C completion"
  echo
  echo "Output: $OUT"
  echo
  echo "Exact locked v5m imported by hash."
  echo "No final candidate was frozen."
  echo "No new seeds were collected."
  echo "Frozen methods were not modified."
} > "$OUT/reports/STAGE3C_COMPLETE.md"

echo
echo "===================================================="
echo "EVVA_3 STAGE 3C COMPLETE"
echo "===================================================="
echo "Output: $OUT"
echo

cat "$OUT/reports/stage3c_summary.json"

echo
echo "Aggregate summary:"
column -s, -t \
  < "$OUT/results/aggregate_summary.csv"

echo
echo "Two-level bootstrap:"
column -s, -t \
  < "$OUT/results/two_level_bootstrap.csv"

echo
echo "Cell summary:"
column -s, -t \
  < "$OUT/results/cell_summary.csv"

echo
echo "PASS: Stage 3C completed without new seeds or frozen-method changes."

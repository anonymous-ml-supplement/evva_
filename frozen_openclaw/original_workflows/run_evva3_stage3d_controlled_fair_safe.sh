#!/usr/bin/env bash

# EVVA_3 Stage 3D:
# Controlled matched-capacity comparison against valid Reward/value,
# learned baselines, and the exact hash-locked EVVA-SAG implementation.
# No hyperparameter tuning, new seeds, or frozen-file modification.

die() {
  echo "ERROR: $*" >&2
  exit 1
}

WORKSPACE="$HOME/.openclaw/workspace/skills/openclaw_pilot_v4_large_exactB_20260707_EVVA_3_signal_repair_20260713"

V5M="code/aaai_v5m_signal_availability_gated_evva.py"
EVVA2H="code/aaai_evva2h_severe_plateau_gate.py"
CONTROLLED="artifacts/aaai_v5j_fair_controlled_prm_20260709/fair_controlled_train_eval_rows.csv"
ARCHIVED_V5M="artifacts/aaai_v5m_final_locked_20260709/outputs/controlled_v5k_signal_availability_gated_evva.csv"

EXPECTED_V5M_SHA="924b6c893036f20ee9d60e90faf34c3beeb0f830af8e6d1c8ffd4dfee904906e"
EXPECTED_EVVA2H_SHA="21ccb27ded1838b86e7b37deae5c9bd069d58c2fe13d8ec90a54f7967205b28d"
EXPECTED_CONTROLLED_SHA="091425b9a6d2cd078511f6d5ea923fd7f7214e8142a828e6cac6e4746e540fd2"

[ -d "$WORKSPACE" ] || die "Workspace not found: $WORKSPACE"
cd "$WORKSPACE" || die "Cannot enter workspace."

[ -f "$V5M" ] || die "Missing locked v5m."
[ -f "$EVVA2H" ] || die "Missing frozen EVVA_2H."
[ -f "$CONTROLLED" ] || die "Missing controlled data."
[ -f "$ARCHIVED_V5M" ] || die "Missing archived controlled v5m output."

[ "$(sha256sum "$V5M" | awk '{print $1}')" = "$EXPECTED_V5M_SHA" ] \
  || die "Locked v5m hash mismatch."

[ "$(sha256sum "$EVVA2H" | awk '{print $1}')" = "$EXPECTED_EVVA2H_SHA" ] \
  || die "Frozen EVVA_2H hash mismatch."

[ "$(sha256sum "$CONTROLLED" | awk '{print $1}')" = "$EXPECTED_CONTROLLED_SHA" ] \
  || die "Controlled-data hash mismatch."

python3 - <<'PY' || die "Activate .venv_evva3 before Stage 3D."
import numpy
import sklearn
print("numpy", numpy.__version__)
print("sklearn", sklearn.__version__)
PY

RUN_ID="$(date +%Y%m%d_%H%M%S)"
OUT="artifacts/aaai_evva3_stage3d_controlled_fair_${RUN_ID}"

mkdir -p \
  "$OUT/code" \
  "$OUT/hashes" \
  "$OUT/logs" \
  "$OUT/manifests" \
  "$OUT/predictions" \
  "$OUT/results" \
  "$OUT/reports" \
  || die "Cannot create Stage 3D directories."

echo "$OUT" > artifacts/aaai_evva3_stage3d_latest.txt

BOOTSTRAP_REPS="${EVVA3_STAGE3D_BOOTSTRAP_REPS:-10000}"

export EVVA3_STAGE3D_OUT="$OUT"
export EVVA3_STAGE3D_BOOTSTRAP_REPS="$BOOTSTRAP_REPS"
export EVVA3_LOCKED_V5M="$V5M"
export EVVA3_CONTROLLED="$CONTROLLED"
export EVVA3_ARCHIVED_V5M="$ARCHIVED_V5M"

{
  sha256sum "$V5M"
  sha256sum "$EVVA2H"
  sha256sum "$CONTROLLED"
  sha256sum "$ARCHIVED_V5M"
} > "$OUT/hashes/pre_run_sha256.txt"

cat > "$OUT/code/aaai_evva3_stage3d_controlled_fair.py" <<'PY'
#!/usr/bin/env python3

"""Controlled EVVA_3 comparison without model or hyperparameter tuning."""

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
OUT = Path(os.environ["EVVA3_STAGE3D_OUT"])
LOCKED_V5M_PATH = ROOT / os.environ["EVVA3_LOCKED_V5M"]
CONTROLLED_PATH = ROOT / os.environ["EVVA3_CONTROLLED"]
ARCHIVED_V5M_PATH = ROOT / os.environ["EVVA3_ARCHIVED_V5M"]

BOOTSTRAP_REPS = int(
    os.environ.get("EVVA3_STAGE3D_BOOTSTRAP_REPS", "10000")
)

EXPECTED_V5M_SHA = (
    "924b6c893036f20ee9d60e90faf34c3beeb0f830af8e6d1c8ffd4dfee904906e"
)

EXPECTED_CONTROLLED_SHA = (
    "091425b9a6d2cd078511f6d5ea923fd7f7214e8142a828e6cac6e4746e540fd2"
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

BASELINE_COLUMNS = {
    "Random": "score_random",
    "p-only": "score_p_only",
    "H-only": "score_H_only",
    "pH": "score_p_times_H",
    "Calibrated-pH": "score_calibrated_p_times_H",
    "PRM-process": "score_prm_task_fail",
    "Reward-value": "score_prm_value_gain",
    "Risk-only-learned": "score_risk_only_learned",
    "Final-reward-model": "score_final_reward_model",
    "Value-router": "score_value_router",
}

LEARNED_BASELINES = [
    "PRM-process",
    "Reward-value",
    "Risk-only-learned",
    "Final-reward-model",
    "Value-router",
]

CANDIDATES = [
    "ShallowGB-full",
    "ShallowGB-core",
    "Ridge-full",
]

PRIMARY_COMPARATORS = [
    "Locked-v5m",
    "Reward-value",
    "Final-reward-model",
    "Value-router",
    "Learned-envelope",
    "pH",
]


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
        "evva3_locked_v5m_controlled",
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
    values = []

    for row in rows:
        values.append([
            parse_float(row.get(feature))
            for feature in features
        ])

    return np.asarray(values, dtype=float)


def labels(
    rows: Sequence[Dict[str, object]],
) -> np.ndarray:
    values = [
        parse_float(row.get("intervention_gain"))
        for row in rows
    ]

    if any(value is None for value in values):
        raise RuntimeError("Missing intervention_gain.")

    return np.asarray(values, dtype=float)


def score_array(
    rows: Sequence[Dict[str, object]],
    column: str,
) -> np.ndarray:
    values = [
        parse_float(row.get(column))
        for row in rows
    ]

    if any(value is None for value in values):
        raise RuntimeError(
            f"Missing controlled baseline score: {column}"
        )

    result = np.asarray(values, dtype=float)

    if not np.all(np.isfinite(result)):
        raise RuntimeError(
            f"Non-finite controlled baseline score: {column}"
        )

    return result


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


def selected_value(
    scores: np.ndarray,
    gains: np.ndarray,
    fraction: float,
) -> float:
    if len(scores) != len(gains):
        raise RuntimeError("Score/gain length mismatch.")

    if not np.all(np.isfinite(scores)):
        raise RuntimeError("Non-finite score detected.")

    if not np.all(np.isfinite(gains)):
        raise RuntimeError("Non-finite gain detected.")

    budget = exact_b(len(scores), fraction)

    grouped: Dict[float, List[float]] = {}

    for score, gain in zip(scores, gains):
        key = float(score)

        if key not in grouped:
            grouped[key] = [0.0, 0.0]

        grouped[key][0] += 1.0
        grouped[key][1] += float(gain)

    selected_count = 0.0
    selected_sum = 0.0

    for level in sorted(grouped, reverse=True):
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


def score_curve(
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


def locked_controlled_value(
    rows: Sequence[Dict[str, object]],
    fraction: float,
) -> float:
    score_cols = {
        "p": "score_p_only",
        "H": "score_H_only",
        "pH": "score_p_times_H",
        "V": "score_prm_value_gain",
    }

    quota = LOCKED.value_aware_schedule(fraction)

    active = [
        (name, weight)
        for name, weight in quota.items()
        if weight > 1e-12
    ]

    copied_rows = [
        dict(row)
        for row in rows
    ]

    if len(active) == 1:
        only = active[0][0]

        return float(
            LOCKED.scalar_tieaware(
                copied_rows,
                score_cols[only],
                fraction,
            )
        )

    return float(
        LOCKED.portfolio_value(
            copied_rows,
            score_cols,
            quota,
            fraction,
        )
    )


def locked_curve(
    rows: Sequence[Dict[str, object]],
) -> List[float]:
    return [
        locked_controlled_value(
            rows,
            fraction,
        )
        for fraction in BUDGETS
    ]


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


def average_ranks(
    values: np.ndarray,
) -> np.ndarray:
    order = np.argsort(
        values,
        kind="mergesort",
    )
    ranks = np.empty(
        len(values),
        dtype=float,
    )

    start = 0

    while start < len(values):
        end = start + 1

        while (
            end < len(values)
            and values[order[end]] == values[order[start]]
        ):
            end += 1

        rank = (
            (start + 1) + end
        ) / 2.0

        ranks[order[start:end]] = rank
        start = end

    return ranks


def correlation(
    left: np.ndarray,
    right: np.ndarray,
) -> Optional[float]:
    left = np.asarray(left, dtype=float)
    right = np.asarray(right, dtype=float)

    if len(left) < 3:
        return None

    left = left - np.mean(left)
    right = right - np.mean(right)

    denominator = math.sqrt(
        float(np.sum(left ** 2))
        * float(np.sum(right ** 2))
    )

    if denominator <= 0.0:
        return None

    return float(
        np.sum(left * right)
        / denominator
    )


def spearman(
    scores: np.ndarray,
    gains: np.ndarray,
) -> Optional[float]:
    return correlation(
        average_ranks(scores),
        average_ranks(gains),
    )


def main() -> None:
    if sha256(CONTROLLED_PATH) != EXPECTED_CONTROLLED_SHA:
        raise RuntimeError(
            "Controlled input hash mismatch."
        )

    fields, raw_rows = read_csv(
        CONTROLLED_PATH
    )

    rows = [
        augment_row(row)
        for row in raw_rows
    ]

    train_rows = [
        row
        for row in rows
        if row.get("split") == "train"
    ]

    eval_rows = [
        row
        for row in rows
        if row.get("split") == "eval"
    ]

    if not train_rows or not eval_rows:
        raise RuntimeError(
            "Controlled train/eval split is empty."
        )

    overlap = (
        {
            int(row["seed"])
            for row in train_rows
        }
        & {
            int(row["seed"])
            for row in eval_rows
        }
    )

    if overlap:
        raise RuntimeError(
            f"Train/eval seed overlap: {sorted(overlap)}"
        )

    required_columns = (
        set(FULL_FEATURES[:-1])
        | {"downstream_dependency_count"}
        | set(BASELINE_COLUMNS.values())
        | {
            "seed",
            "split",
            "intervention_gain",
        }
    )

    missing_columns = sorted(
        required_columns - set(fields)
    )

    if missing_columns:
        raise RuntimeError(
            f"Missing columns: {missing_columns}"
        )

    availability_rows = []

    for name, column in BASELINE_COLUMNS.items():
        train_values = score_array(
            train_rows,
            column,
        )
        eval_values = score_array(
            eval_rows,
            column,
        )

        availability_rows.append({
            "method": name,
            "column": column,
            "train_rows": len(train_values),
            "train_unique": len(
                np.unique(train_values)
            ),
            "train_variance": float(
                np.var(train_values)
            ),
            "eval_rows": len(eval_values),
            "eval_unique": len(
                np.unique(eval_values)
            ),
            "eval_variance": float(
                np.var(eval_values)
            ),
        })

    if not LOCKED.usable(
        train_rows,
        "score_prm_value_gain",
    ):
        raise RuntimeError(
            "Controlled Reward/value unexpectedly unusable."
        )

    train_y = labels(train_rows)
    eval_y = labels(eval_rows)

    full_model = shallow_model()
    core_model = shallow_model()
    ridge = ridge_model()

    full_model.fit(
        matrix(train_rows, FULL_FEATURES),
        train_y,
    )

    core_model.fit(
        matrix(train_rows, CORE_FEATURES),
        train_y,
    )

    ridge.fit(
        matrix(train_rows, FULL_FEATURES),
        train_y,
    )

    method_scores: Dict[str, np.ndarray] = {
        name: score_array(
            eval_rows,
            column,
        )
        for name, column in BASELINE_COLUMNS.items()
    }

    method_scores["ShallowGB-full"] = (
        full_model.predict(
            matrix(eval_rows, FULL_FEATURES)
        )
    )

    method_scores["ShallowGB-core"] = (
        core_model.predict(
            matrix(eval_rows, CORE_FEATURES)
        )
    )

    method_scores["Ridge-full"] = (
        ridge.predict(
            matrix(eval_rows, FULL_FEATURES)
        )
    )

    for method, scores in method_scores.items():
        if not np.all(np.isfinite(scores)):
            raise RuntimeError(
                f"{method} produced non-finite scores."
            )

    curves = {
        method: score_curve(
            scores,
            eval_y,
        )
        for method, scores in method_scores.items()
    }

    curves["Locked-v5m"] = locked_curve(
        eval_rows
    )

    learned_envelope = [
        max(values)
        for values in zip(
            *[
                curves[method]
                for method in LEARNED_BASELINES
            ]
        )
    ]

    primitive_envelope = [
        max(values)
        for values in zip(
            curves["Random"],
            curves["p-only"],
            curves["H-only"],
            curves["pH"],
            curves["Calibrated-pH"],
        )
    ]

    curves["Learned-envelope"] = (
        learned_envelope
    )

    curves["Primitive-envelope"] = (
        primitive_envelope
    )

    archived_lookup = {}

    if ARCHIVED_V5M_PATH.is_file():
        _, archived_rows = read_csv(
            ARCHIVED_V5M_PATH
        )

        archived_lookup = {
            row["budget"]: float(row["EVVA_SAG"])
            for row in archived_rows
        }

    crosscheck_rows = []

    for fraction, value in zip(
        BUDGETS,
        curves["Locked-v5m"],
    ):
        budget = int(round(fraction * 100))
        archived = archived_lookup.get(
            f"{budget}%"
        )

        if archived is None:
            continue

        difference = value - archived

        crosscheck_rows.append({
            "budget_percent": budget,
            "reproduced_locked_v5m": value,
            "archived_locked_output_4dp": archived,
            "difference": difference,
            "rounding_tolerance_pass": (
                abs(difference) <= 0.000051
            ),
        })

    if crosscheck_rows and not all(
        bool(row["rounding_tolerance_pass"])
        for row in crosscheck_rows
    ):
        raise RuntimeError(
            "Controlled locked-v5m crosscheck failed."
        )

    curve_rows = []

    for method, curve in curves.items():
        for fraction, value in zip(
            BUDGETS,
            curve,
        ):
            curve_rows.append({
                "method": method,
                "budget_percent": int(
                    round(fraction * 100)
                ),
                "exact_B": exact_b(
                    len(eval_rows),
                    fraction,
                ),
                "selected_mean_intervention_gain": value,
            })

    summary_rows = []

    locked_aubc = aubc(
        curves["Locked-v5m"]
    )

    reward_aubc = aubc(
        curves["Reward-value"]
    )

    final_reward_aubc = aubc(
        curves["Final-reward-model"]
    )

    learned_envelope_aubc = aubc(
        curves["Learned-envelope"]
    )

    for method, curve in curves.items():
        method_aubc = aubc(curve)

        scores = method_scores.get(method)

        summary_rows.append({
            "method": method,
            "aubc_5_90": method_aubc,
            "delta_vs_locked_v5m": (
                method_aubc - locked_aubc
            ),
            "delta_vs_reward_value": (
                method_aubc - reward_aubc
            ),
            "delta_vs_final_reward_model": (
                method_aubc
                - final_reward_aubc
            ),
            "delta_vs_learned_envelope": (
                method_aubc
                - learned_envelope_aubc
            ),
            "score_unique": (
                len(np.unique(scores))
                if scores is not None
                else ""
            ),
            "score_variance": (
                float(np.var(scores))
                if scores is not None
                else ""
            ),
            "spearman_with_gain": (
                spearman(scores, eval_y)
                if scores is not None
                else ""
            ),
        })

    cell_rows = []

    for comparator in PRIMARY_COMPARATORS:
        for fraction, candidate_value, comparator_value in zip(
            BUDGETS,
            curves["ShallowGB-full"],
            curves[comparator],
        ):
            margin = (
                candidate_value
                - comparator_value
            )

            cell_rows.append({
                "candidate": "ShallowGB-full",
                "comparator": comparator,
                "budget_percent": int(
                    round(fraction * 100)
                ),
                "candidate_value": candidate_value,
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

    cell_summary_rows = []

    for comparator in PRIMARY_COMPARATORS:
        comparator_rows = [
            row
            for row in cell_rows
            if row["comparator"] == comparator
        ]

        counts = Counter(
            row["status"]
            for row in comparator_rows
        )

        margins = [
            float(row["margin"])
            for row in comparator_rows
        ]

        cell_summary_rows.append({
            "candidate": "ShallowGB-full",
            "comparator": comparator,
            "total_cells": len(comparator_rows),
            "strict_wins": counts["strict_win"],
            "exact_ties": counts["exact_tie"],
            "losses": counts["loss"],
            "mean_margin": statistics.fmean(
                margins
            ),
            "minimum_margin": min(margins),
            "maximum_margin": max(margins),
        })

    prediction_rows = []

    for index, row in enumerate(eval_rows):
        output = {
            "seed": int(row["seed"]),
            "intervention_gain": eval_y[index],
        }

        for method, scores in method_scores.items():
            output[
                "score_" + method.replace(
                    "-",
                    "_",
                )
            ] = scores[index]

        prediction_rows.append(output)

    seed_to_indices: Dict[
        int,
        List[int],
    ] = defaultdict(list)

    for index, row in enumerate(eval_rows):
        seed_to_indices[
            int(row["seed"])
        ].append(index)

    unique_eval_seeds = np.asarray(
        sorted(seed_to_indices),
        dtype=int,
    )

    rng = np.random.default_rng(
        RANDOM_SEED
    )

    bootstrap_values: Dict[
        str,
        List[float],
    ] = defaultdict(list)

    point_deltas = {
        comparator: (
            aubc(curves["ShallowGB-full"])
            - aubc(curves[comparator])
        )
        for comparator in PRIMARY_COMPARATORS
    }

    for _ in range(BOOTSTRAP_REPS):
        sampled_seeds = rng.choice(
            unique_eval_seeds,
            size=len(unique_eval_seeds),
            replace=True,
        )

        sampled_indices = np.asarray([
            index
            for seed in sampled_seeds
            for index in seed_to_indices[
                int(seed)
            ]
        ], dtype=int)

        sampled_rows = [
            dict(eval_rows[index])
            for index in sampled_indices
        ]

        sampled_gains = eval_y[
            sampled_indices
        ]

        sampled_curves = {
            method: score_curve(
                scores[sampled_indices],
                sampled_gains,
            )
            for method, scores
            in method_scores.items()
        }

        sampled_curves["Locked-v5m"] = (
            locked_curve(sampled_rows)
        )

        sampled_curves["Learned-envelope"] = [
            max(values)
            for values in zip(
                *[
                    sampled_curves[method]
                    for method in LEARNED_BASELINES
                ]
            )
        ]

        candidate_aubc = aubc(
            sampled_curves["ShallowGB-full"]
        )

        for comparator in PRIMARY_COMPARATORS:
            bootstrap_values[
                comparator
            ].append(
                candidate_aubc
                - aubc(
                    sampled_curves[comparator]
                )
            )

    bootstrap_rows = []

    for comparator in PRIMARY_COMPARATORS:
        values = bootstrap_values[
            comparator
        ]

        bootstrap_rows.append({
            "candidate": "ShallowGB-full",
            "comparator": comparator,
            "bootstrap_repetitions": BOOTSTRAP_REPS,
            "point_delta_aubc": point_deltas[
                comparator
            ],
            "bootstrap_mean_delta": statistics.fmean(
                values
            ),
            "ci_2_5": percentile(
                values,
                0.025,
            ),
            "ci_97_5": percentile(
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

    broad_rows = []

    for budget in [60, 70]:
        index = [
            int(round(fraction * 100))
            for fraction in BUDGETS
        ].index(budget)

        for comparator in [
            "Locked-v5m",
            "Reward-value",
            "Final-reward-model",
            "Value-router",
            "Learned-envelope",
            "pH",
        ]:
            broad_rows.append({
                "budget_percent": budget,
                "candidate": "ShallowGB-full",
                "comparator": comparator,
                "candidate_value": curves[
                    "ShallowGB-full"
                ][index],
                "comparator_value": curves[
                    comparator
                ][index],
                "margin": (
                    curves["ShallowGB-full"][index]
                    - curves[comparator][index]
                ),
            })

    decile_rows = []

    candidate_scores = method_scores[
        "ShallowGB-full"
    ]

    order = np.argsort(
        candidate_scores,
        kind="mergesort",
    )

    for decile, indices in enumerate(
        np.array_split(order, 10),
        start=1,
    ):
        decile_rows.append({
            "decile": decile,
            "rows": len(indices),
            "mean_prediction": float(
                np.mean(
                    candidate_scores[indices]
                )
            ),
            "mean_intervention_gain": float(
                np.mean(
                    eval_y[indices]
                )
            ),
            "positive_gain_fraction": float(
                np.mean(
                    eval_y[indices] > 0.0
                )
            ),
        })

    write_csv(
        OUT / "results" / "score_availability.csv",
        availability_rows,
        [
            "method",
            "column",
            "train_rows",
            "train_unique",
            "train_variance",
            "eval_rows",
            "eval_unique",
            "eval_variance",
        ],
    )

    write_csv(
        OUT / "results" / "locked_output_crosscheck.csv",
        crosscheck_rows,
        [
            "budget_percent",
            "reproduced_locked_v5m",
            "archived_locked_output_4dp",
            "difference",
            "rounding_tolerance_pass",
        ],
    )

    write_csv(
        OUT / "results" / "curve.csv",
        curve_rows,
        [
            "method",
            "budget_percent",
            "exact_B",
            "selected_mean_intervention_gain",
        ],
    )

    write_csv(
        OUT / "results" / "aggregate_summary.csv",
        summary_rows,
        [
            "method",
            "aubc_5_90",
            "delta_vs_locked_v5m",
            "delta_vs_reward_value",
            "delta_vs_final_reward_model",
            "delta_vs_learned_envelope",
            "score_unique",
            "score_variance",
            "spearman_with_gain",
        ],
    )

    write_csv(
        OUT / "results" / "candidate_cells.csv",
        cell_rows,
        [
            "candidate",
            "comparator",
            "budget_percent",
            "candidate_value",
            "comparator_value",
            "margin",
            "status",
        ],
    )

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

    write_csv(
        OUT / "results" / "seed_cluster_bootstrap.csv",
        bootstrap_rows,
        [
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
        OUT / "results" / "broad_budget_60_70.csv",
        broad_rows,
        [
            "budget_percent",
            "candidate",
            "comparator",
            "candidate_value",
            "comparator_value",
            "margin",
        ],
    )

    write_csv(
        OUT / "results" / "prediction_calibration_deciles.csv",
        decile_rows,
        [
            "decile",
            "rows",
            "mean_prediction",
            "mean_intervention_gain",
            "positive_gain_fraction",
        ],
    )

    prediction_fields = [
        "seed",
        "intervention_gain",
    ] + [
        "score_" + method.replace(
            "-",
            "_",
        )
        for method in method_scores
    ]

    write_csv(
        OUT / "predictions" / "controlled_eval_predictions.csv",
        prediction_rows,
        prediction_fields,
    )

    specification = {
        "stage": "EVVA_3 Stage 3D controlled fair comparison",
        "development_only": True,
        "new_seed_collection": False,
        "final_model_frozen": False,
        "controlled_sha256": sha256(
            CONTROLLED_PATH
        ),
        "locked_v5m_sha256": sha256(
            LOCKED_V5M_PATH
        ),
        "train_rows": len(train_rows),
        "eval_rows": len(eval_rows),
        "train_unique_seeds": len({
            int(row["seed"])
            for row in train_rows
        }),
        "eval_unique_seeds": len({
            int(row["seed"])
            for row in eval_rows
        }),
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
        "candidate_was_not_retuned_for_controlled": True,
        "budgets": BUDGETS,
        "primary_metric": (
            "normalized trapezoidal AUBC over 5%-90%"
        ),
        "tie_handling": (
            "tie-aware exact-B for scalar methods; "
            "exact locked implementation for EVVA-SAG portfolios"
        ),
        "bootstrap": {
            "type": "evaluation-seed cluster bootstrap",
            "repetitions": BOOTSTRAP_REPS,
            "model_predictions_fixed_after training split fit": True,
        },
    }

    with (
        OUT / "manifests" / "stage3d_spec.json"
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
        "controlled_rows": len(rows),
        "train_rows": len(train_rows),
        "eval_rows": len(eval_rows),
        "train_eval_seed_overlap": len(overlap),
        "reward_value_usable": True,
        "locked_v5m_imported_directly": True,
        "locked_output_crosscheck_pass": all(
            bool(row["rounding_tolerance_pass"])
            for row in crosscheck_rows
        ),
        "bootstrap_repetitions": BOOTSTRAP_REPS,
        "candidate_retuned_for_controlled": False,
        "new_seed_collection": False,
        "final_model_frozen": False,
        "warning": (
            "Controlled data were previously used during method "
            "development; this is not untouched confirmation."
        ),
    }

    with (
        OUT / "reports" / "stage3d_summary.json"
    ).open("w", encoding="utf-8") as handle:
        json.dump(
            summary,
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

echo "===================================================="
echo "EVVA_3 STAGE 3D CONTROLLED FAIR COMPARISON"
echo "===================================================="
echo "Output: $OUT"
echo "Bootstrap repetitions: $BOOTSTRAP_REPS"
echo

python3 -m py_compile \
  "$OUT/code/aaai_evva3_stage3d_controlled_fair.py" \
  || die "Stage 3D Python failed py_compile."

python3 \
  "$OUT/code/aaai_evva3_stage3d_controlled_fair.py" \
  2>&1 | tee "$OUT/logs/stage3d.log" \
  || die "Stage 3D experiment failed."

{
  sha256sum "$V5M"
  sha256sum "$EVVA2H"
  sha256sum "$CONTROLLED"
  sha256sum "$ARCHIVED_V5M"
} > "$OUT/hashes/post_run_sha256.txt"

[ "$(sha256sum "$V5M" | awk '{print $1}')" = "$EXPECTED_V5M_SHA" ] \
  || die "Locked v5m changed during Stage 3D."

[ "$(sha256sum "$EVVA2H" | awk '{print $1}')" = "$EXPECTED_EVVA2H_SHA" ] \
  || die "Frozen EVVA_2H changed during Stage 3D."

[ "$(sha256sum "$CONTROLLED" | awk '{print $1}')" = "$EXPECTED_CONTROLLED_SHA" ] \
  || die "Controlled data changed during Stage 3D."

find "$OUT" \
  -type f \
  ! -name 'FINAL_SHA256SUMS.txt' \
  -print0 \
  | sort -z \
  | xargs -0 sha256sum \
  > "$OUT/FINAL_SHA256SUMS.txt"

{
  echo "# EVVA_3 Stage 3D completion"
  echo
  echo "Output: $OUT"
  echo
  echo "Controlled comparison completed without retuning."
  echo "No final candidate was frozen."
  echo "No new seeds were collected."
  echo "Frozen files were not modified."
} > "$OUT/reports/STAGE3D_COMPLETE.md"

echo
echo "===================================================="
echo "EVVA_3 STAGE 3D COMPLETE"
echo "===================================================="
echo "Output: $OUT"
echo

cat "$OUT/reports/stage3d_summary.json"

echo
echo "Aggregate summary:"
column -s, -t \
  < "$OUT/results/aggregate_summary.csv"

echo
echo "Seed-cluster bootstrap:"
column -s, -t \
  < "$OUT/results/seed_cluster_bootstrap.csv"

echo
echo "Cell summary:"
column -s, -t \
  < "$OUT/results/cell_summary.csv"

echo
echo "PASS: Stage 3D completed without retuning, new seeds, or frozen-file changes."

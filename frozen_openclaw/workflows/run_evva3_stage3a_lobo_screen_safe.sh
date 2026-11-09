#!/usr/bin/env bash

# EVVA_3 Stage 3A:
# Six-block leave-one-block-out predicted intervention-value screening.
# This is development analysis only. It does not collect new seeds,
# modify frozen methods, or freeze a final model.

die() {
  echo "ERROR: $*" >&2
  exit 1
}

WORKSPACE="$HOME/.openclaw/workspace/skills/openclaw_pilot_v4_large_exactB_20260707_EVVA_3_signal_repair_20260713"

V5M="code/evva_v5m_signal_availability_gated_evva.py"
EVVA2H="code/evva2h_severe_plateau_gate.py"

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

RUN_ID="$(date +%Y%m%d_%H%M%S)"
OUT="artifacts/evva3_stage3a_lobo_screen_${RUN_ID}"

mkdir -p \
  "$OUT/code" \
  "$OUT/hashes" \
  "$OUT/logs" \
  "$OUT/predictions" \
  "$OUT/results" \
  "$OUT/reports" \
  "$OUT/manifests" \
  || die "Cannot create Stage 3A directories."

echo "$OUT" > artifacts/evva3_stage3a_latest.txt

BOOTSTRAP_REPS="${EVVA3_BOOTSTRAP_REPS:-500}"
export EVVA3_STAGE3A_OUT="$OUT"
export EVVA3_STAGE3A_BOOTSTRAP_REPS="$BOOTSTRAP_REPS"

{
  echo "locked_v5m:"
  sha256sum "$V5M"
  echo "frozen_evva2h:"
  sha256sum "$EVVA2H"
} > "$OUT/hashes/pre_run_locked_sha256.txt"

cat > "$OUT/code/evva3_stage3a_lobo_screen.py" <<'PY'
#!/usr/bin/env python3

"""Six-block leave-one-block-out EVVA_3 development screening."""

import csv
import hashlib
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
from sklearn.linear_model import LogisticRegression, Ridge
from sklearn.metrics import roc_auc_score
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import StandardScaler

ROOT = Path.cwd()
OUT = Path(os.environ["EVVA3_STAGE3A_OUT"])
BOOTSTRAP_REPS = int(os.environ.get("EVVA3_STAGE3A_BOOTSTRAP_REPS", "500"))

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

FEATURES = [
    "p_score",
    "harm_score",
    "p_times_H_score",
    "rollback_difficulty",
    "persistent_state_risk",
    "log1p_downstream_dependency_count",
]

FORBIDDEN = {
    "intervention_gain",
    "branch_harm_exact",
    "reward_wrong_continuation",
    "reward_corrected_continuation",
}

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
            "artifacts/evva2_exploratory_20260713/"
            "evva2g_confirmatory_5000_5299/raw/"
            "full_agent_candidate_rows_5000_5299.csv"
        ),
        "calibration": (5000, 5099),
        "evaluation": (5100, 5299),
    },
    {
        "name": "r2_5300_5599",
        "path": (
            "artifacts/evva2_exploratory_20260713/"
            "evva2g_replication_r2_5300_5599/raw/"
            "full_agent_candidate_rows_5300_5599.csv"
        ),
        "calibration": (5300, 5399),
        "evaluation": (5400, 5599),
    },
    {
        "name": "r3_5600_5899",
        "path": (
            "artifacts/evva2_exploratory_20260713/"
            "evva2g_replication_r3_5600_5899/raw/"
            "full_agent_candidate_rows_5600_5899.csv"
        ),
        "calibration": (5600, 5699),
        "evaluation": (5700, 5899),
    },
    {
        "name": "r4_5900_6199",
        "path": (
            "artifacts/evva2_exploratory_20260713/"
            "evva2h_final_confirmation_20260713/r4_5900_6199/raw/"
            "full_agent_candidate_rows_5900_6199.csv"
        ),
        "calibration": (5900, 5999),
        "evaluation": (6000, 6199),
    },
    {
        "name": "r5_6200_6499",
        "path": (
            "artifacts/evva2_exploratory_20260713/"
            "evva2h_final_confirmation_20260713/r5_6200_6499/raw/"
            "full_agent_candidate_rows_6200_6499.csv"
        ),
        "calibration": (6200, 6299),
        "evaluation": (6300, 6499),
    },
]

BASELINE_METHODS = [
    "Random",
    "p-only",
    "H-only",
    "pH",
]

CANDIDATE_METHODS = [
    "Ridge-PIV",
    "Hurdle-PIV",
    "ShallowGB-PIV",
]

ALL_NON_ORACLE_METHODS = BASELINE_METHODS + CANDIDATE_METHODS


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
        raise ValueError(f"Invalid seed value: {value!r}")

    rounded = int(round(number))

    if abs(number - rounded) > 1e-9:
        raise ValueError(f"Non-integral seed value: {value!r}")

    return rounded


def sha256(path: Path) -> str:
    digest = hashlib.sha256()

    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)

    return digest.hexdigest()


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


def make_matrix(
    rows: Sequence[Dict[str, object]],
) -> Tuple[np.ndarray, np.ndarray]:
    matrix = []
    labels = []

    for row in rows:
        matrix.append([
            parse_float(row.get(feature))
            for feature in FEATURES
        ])

        gain = parse_float(row.get("intervention_gain"))

        if gain is None:
            raise ValueError("Missing intervention_gain label.")

        labels.append(gain)

    return (
        np.asarray(matrix, dtype=float),
        np.asarray(labels, dtype=float),
    )


def exact_b(n: int, fraction: float) -> int:
    budget = int(round(n * fraction))
    return max(1, min(n, budget))


def selected_curve(
    scores: np.ndarray,
    gains: np.ndarray,
) -> List[float]:
    if len(scores) != len(gains):
        raise ValueError("Score and gain lengths differ.")

    if len(scores) == 0:
        raise ValueError("Cannot evaluate an empty array.")

    if not np.all(np.isfinite(scores)):
        raise ValueError("Non-finite method score detected.")

    if not np.all(np.isfinite(gains)):
        raise ValueError("Non-finite intervention gain detected.")

    groups: Dict[float, List[float]] = {}

    for score, gain in zip(scores, gains):
        key = float(score)

        if key not in groups:
            groups[key] = [0.0, 0.0]

        groups[key][0] += 1.0
        groups[key][1] += float(gain)

    sorted_scores = sorted(groups.keys(), reverse=True)
    counts = np.asarray(
        [groups[score][0] for score in sorted_scores],
        dtype=float,
    )
    gain_sums = np.asarray(
        [groups[score][1] for score in sorted_scores],
        dtype=float,
    )

    cumulative_counts = np.cumsum(counts)
    cumulative_sums = np.cumsum(gain_sums)

    curve = []

    for fraction in BUDGETS:
        budget = exact_b(len(scores), fraction)
        group_index = int(
            np.searchsorted(
                cumulative_counts,
                budget,
                side="left",
            )
        )

        count_above = (
            cumulative_counts[group_index - 1]
            if group_index > 0
            else 0.0
        )
        gain_above = (
            cumulative_sums[group_index - 1]
            if group_index > 0
            else 0.0
        )

        needed = budget - count_above
        boundary_count = counts[group_index]
        boundary_gain_sum = gain_sums[group_index]

        selected_sum = (
            gain_above
            + (needed / boundary_count) * boundary_gain_sum
        )

        curve.append(float(selected_sum / budget))

    return curve


def normalized_aubc(curve: Sequence[float]) -> float:
    x = np.asarray(BUDGETS, dtype=float)
    y = np.asarray(curve, dtype=float)

    return float(
        np.trapz(y, x)
        / (x[-1] - x[0])
    )


def average_ranks(values: np.ndarray) -> np.ndarray:
    values = np.asarray(values, dtype=float)
    order = np.argsort(values, kind="mergesort")
    ranks = np.empty(len(values), dtype=float)

    start = 0

    while start < len(values):
        end = start + 1

        while (
            end < len(values)
            and values[order[end]] == values[order[start]]
        ):
            end += 1

        average_rank = (
            (start + 1) + end
        ) / 2.0

        ranks[order[start:end]] = average_rank
        start = end

    return ranks


def pearson(
    left: np.ndarray,
    right: np.ndarray,
) -> Optional[float]:
    left = np.asarray(left, dtype=float)
    right = np.asarray(right, dtype=float)

    if len(left) < 3:
        return None

    left_centered = left - np.mean(left)
    right_centered = right - np.mean(right)

    denominator = math.sqrt(
        float(np.sum(left_centered ** 2))
        * float(np.sum(right_centered ** 2))
    )

    if denominator <= 0.0:
        return None

    return float(
        np.sum(left_centered * right_centered)
        / denominator
    )


def spearman(
    scores: np.ndarray,
    gains: np.ndarray,
) -> Optional[float]:
    return pearson(
        average_ranks(scores),
        average_ranks(gains),
    )


def safe_auc(
    scores: np.ndarray,
    gains: np.ndarray,
) -> Optional[float]:
    labels = (gains > 0.0).astype(int)

    if len(np.unique(labels)) < 2:
        return None

    return float(
        roc_auc_score(labels, scores)
    )


def fit_ridge(
    train_x: np.ndarray,
    train_y: np.ndarray,
):
    model = Pipeline([
        (
            "imputer",
            SimpleImputer(strategy="median"),
        ),
        (
            "scaler",
            StandardScaler(),
        ),
        (
            "ridge",
            Ridge(alpha=1.0),
        ),
    ])

    model.fit(train_x, train_y)
    return model


class HurdleModel:
    def __init__(self):
        self.imputer = SimpleImputer(strategy="median")
        self.scaler = StandardScaler()
        self.classifier = LogisticRegression(
            C=1.0,
            penalty="l2",
            solver="lbfgs",
            max_iter=5000,
            random_state=RANDOM_SEED,
        )
        self.positive_model = Ridge(alpha=1.0)

    def fit(
        self,
        train_x: np.ndarray,
        train_y: np.ndarray,
    ):
        transformed = self.imputer.fit_transform(train_x)
        transformed = self.scaler.fit_transform(transformed)

        positive = (train_y > 0.0).astype(int)

        if len(np.unique(positive)) < 2:
            raise ValueError(
                "Hurdle classifier requires positive and zero labels."
            )

        self.classifier.fit(transformed, positive)

        positive_mask = train_y > 0.0

        if int(np.sum(positive_mask)) < 2:
            raise ValueError(
                "Hurdle magnitude model has too few positive rows."
            )

        self.positive_model.fit(
            transformed[positive_mask],
            train_y[positive_mask],
        )

        return self

    def predict(
        self,
        test_x: np.ndarray,
    ) -> np.ndarray:
        transformed = self.imputer.transform(test_x)
        transformed = self.scaler.transform(transformed)

        probability = self.classifier.predict_proba(
            transformed
        )[:, 1]

        positive_magnitude = np.maximum(
            0.0,
            self.positive_model.predict(transformed),
        )

        return probability * positive_magnitude


def fit_shallow_boosting(
    train_x: np.ndarray,
    train_y: np.ndarray,
):
    model = Pipeline([
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

    model.fit(train_x, train_y)
    return model


def calibration_deciles(
    block: str,
    method: str,
    scores: np.ndarray,
    gains: np.ndarray,
) -> List[Dict[str, object]]:
    order = np.argsort(scores, kind="mergesort")
    bins = np.array_split(order, 10)
    rows = []

    for bin_number, indices in enumerate(bins, start=1):
        if len(indices) == 0:
            continue

        rows.append({
            "block": block,
            "method": method,
            "decile": bin_number,
            "rows": len(indices),
            "mean_prediction": float(
                np.mean(scores[indices])
            ),
            "mean_intervention_gain": float(
                np.mean(gains[indices])
            ),
            "positive_gain_fraction": float(
                np.mean(gains[indices] > 0.0)
            ),
            "minimum_prediction": float(
                np.min(scores[indices])
            ),
            "maximum_prediction": float(
                np.max(scores[indices])
            ),
        })

    return rows


def percentile(values: Sequence[float], probability: float) -> float:
    return float(
        np.quantile(
            np.asarray(values, dtype=float),
            probability,
        )
    )


def main() -> None:
    for feature in FEATURES:
        if feature in FORBIDDEN:
            raise RuntimeError(
                f"Forbidden feature entered model: {feature}"
            )

    block_rows: Dict[str, List[Dict[str, object]]] = {}
    input_manifest = []

    for block in BLOCKS:
        path = ROOT / block["path"]

        if not path.is_file():
            raise FileNotFoundError(
                f"Missing canonical block: {path}"
            )

        fields, raw_rows = read_csv(path)
        rows = [augment_row(row) for row in raw_rows]

        if len(rows) != 900:
            raise RuntimeError(
                f"{block['name']} expected 900 rows, found {len(rows)}."
            )

        block_rows[block["name"]] = rows

        seed_counts = Counter(
            int(row["seed"])
            for row in rows
        )

        input_manifest.append({
            "block": block["name"],
            "path": block["path"],
            "sha256": sha256(path),
            "rows": len(rows),
            "columns": len(fields),
            "unique_seeds": len(seed_counts),
            "minimum_rows_per_seed": min(seed_counts.values()),
            "maximum_rows_per_seed": max(seed_counts.values()),
            "calibration_seed_min": block["calibration"][0],
            "calibration_seed_max": block["calibration"][1],
            "evaluation_seed_min": block["evaluation"][0],
            "evaluation_seed_max": block["evaluation"][1],
        })

    prediction_rows: List[Dict[str, object]] = []
    curve_rows: List[Dict[str, object]] = []
    block_summary_rows: List[Dict[str, object]] = []
    calibration_rows: List[Dict[str, object]] = []
    cell_status_rows: List[Dict[str, object]] = []

    heldout_records: Dict[str, Dict[str, object]] = {}

    for heldout in BLOCKS:
        heldout_name = heldout["name"]
        eval_min, eval_max = heldout["evaluation"]

        training_rows = []

        for block in BLOCKS:
            if block["name"] == heldout_name:
                continue

            training_rows.extend(
                block_rows[block["name"]]
            )

        evaluation_rows = [
            row
            for row in block_rows[heldout_name]
            if eval_min <= int(row["seed"]) <= eval_max
        ]

        if len(training_rows) != 4500:
            raise RuntimeError(
                f"{heldout_name}: expected 4500 training rows, "
                f"found {len(training_rows)}."
            )

        if len(evaluation_rows) != 600:
            raise RuntimeError(
                f"{heldout_name}: expected 600 held-out evaluation rows, "
                f"found {len(evaluation_rows)}."
            )

        train_x, train_y = make_matrix(training_rows)
        eval_x, eval_y = make_matrix(evaluation_rows)

        ridge = fit_ridge(train_x, train_y)
        hurdle = HurdleModel().fit(train_x, train_y)
        shallow = fit_shallow_boosting(train_x, train_y)

        method_scores: Dict[str, np.ndarray] = {
            "Random": np.zeros(len(evaluation_rows), dtype=float),
            "p-only": np.asarray([
                parse_float(row.get("p_score"))
                for row in evaluation_rows
            ], dtype=float),
            "H-only": np.asarray([
                parse_float(row.get("harm_score"))
                for row in evaluation_rows
            ], dtype=float),
            "pH": np.asarray([
                parse_float(row.get("p_times_H_score"))
                for row in evaluation_rows
            ], dtype=float),
            "Ridge-PIV": ridge.predict(eval_x),
            "Hurdle-PIV": hurdle.predict(eval_x),
            "ShallowGB-PIV": shallow.predict(eval_x),
            "Oracle": eval_y.copy(),
        }

        for method, scores in method_scores.items():
            if not np.all(np.isfinite(scores)):
                raise RuntimeError(
                    f"{heldout_name} {method} produced non-finite scores."
                )

        method_curves = {
            method: selected_curve(scores, eval_y)
            for method, scores in method_scores.items()
        }

        oracle_aubc = normalized_aubc(
            method_curves["Oracle"]
        )

        for method, curve in method_curves.items():
            method_aubc = normalized_aubc(curve)

            block_summary_rows.append({
                "block": heldout_name,
                "training_blocks": ";".join(
                    block["name"]
                    for block in BLOCKS
                    if block["name"] != heldout_name
                ),
                "training_rows": len(training_rows),
                "evaluation_seed_min": eval_min,
                "evaluation_seed_max": eval_max,
                "evaluation_rows": len(evaluation_rows),
                "method": method,
                "aubc_5_90": method_aubc,
                "oracle_aubc_5_90": oracle_aubc,
                "oracle_regret": oracle_aubc - method_aubc,
                "spearman_with_gain": spearman(
                    method_scores[method],
                    eval_y,
                ),
                "positive_gain_auroc": safe_auc(
                    method_scores[method],
                    eval_y,
                ),
                "score_unique": len(
                    np.unique(method_scores[method])
                ),
                "score_variance": float(
                    np.var(method_scores[method])
                ),
            })

            for fraction, selected_mean in zip(
                BUDGETS,
                curve,
            ):
                curve_rows.append({
                    "block": heldout_name,
                    "method": method,
                    "budget_percent": int(round(fraction * 100)),
                    "exact_B": exact_b(
                        len(evaluation_rows),
                        fraction,
                    ),
                    "selected_mean_intervention_gain": selected_mean,
                })

        baseline_curves = [
            method_curves[method]
            for method in BASELINE_METHODS
        ]

        baseline_envelope = [
            max(values)
            for values in zip(*baseline_curves)
        ]

        for candidate in CANDIDATE_METHODS:
            candidate_curve = method_curves[candidate]

            strict = 0
            tie = 0
            loss = 0

            for fraction, value, envelope in zip(
                BUDGETS,
                candidate_curve,
                baseline_envelope,
            ):
                delta = value - envelope

                if delta > 1e-10:
                    status = "strict_win"
                    strict += 1
                elif delta < -1e-10:
                    status = "loss"
                    loss += 1
                else:
                    status = "exact_tie"
                    tie += 1

                cell_status_rows.append({
                    "block": heldout_name,
                    "method": candidate,
                    "budget_percent": int(round(fraction * 100)),
                    "candidate_value": value,
                    "strongest_primitive_value": envelope,
                    "margin": delta,
                    "status": status,
                })

        for candidate in CANDIDATE_METHODS:
            calibration_rows.extend(
                calibration_deciles(
                    heldout_name,
                    candidate,
                    method_scores[candidate],
                    eval_y,
                )
            )

        for index, row in enumerate(evaluation_rows):
            prediction_rows.append({
                "block": heldout_name,
                "seed": int(row["seed"]),
                "case_type": row.get("case_type", ""),
                "candidate_id": row.get("candidate_id", ""),
                "intervention_gain": eval_y[index],
                "score_p_only": method_scores["p-only"][index],
                "score_H_only": method_scores["H-only"][index],
                "score_pH": method_scores["pH"][index],
                "score_ridge_piv": method_scores["Ridge-PIV"][index],
                "score_hurdle_piv": method_scores["Hurdle-PIV"][index],
                "score_shallowgb_piv": method_scores["ShallowGB-PIV"][index],
            })

        heldout_records[heldout_name] = {
            "rows": evaluation_rows,
            "gains": eval_y,
            "scores": {
                method: method_scores[method]
                for method in ALL_NON_ORACLE_METHODS
            },
        }

    write_csv(
        OUT / "manifests" / "canonical_input_manifest.csv",
        input_manifest,
        [
            "block",
            "path",
            "sha256",
            "rows",
            "columns",
            "unique_seeds",
            "minimum_rows_per_seed",
            "maximum_rows_per_seed",
            "calibration_seed_min",
            "calibration_seed_max",
            "evaluation_seed_min",
            "evaluation_seed_max",
        ],
    )

    write_csv(
        OUT / "predictions" / "lobo_heldout_predictions.csv",
        prediction_rows,
        [
            "block",
            "seed",
            "case_type",
            "candidate_id",
            "intervention_gain",
            "score_p_only",
            "score_H_only",
            "score_pH",
            "score_ridge_piv",
            "score_hurdle_piv",
            "score_shallowgb_piv",
        ],
    )

    write_csv(
        OUT / "results" / "selected_gain_curve_by_block.csv",
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
        OUT / "results" / "block_level_summary.csv",
        block_summary_rows,
        [
            "block",
            "training_blocks",
            "training_rows",
            "evaluation_seed_min",
            "evaluation_seed_max",
            "evaluation_rows",
            "method",
            "aubc_5_90",
            "oracle_aubc_5_90",
            "oracle_regret",
            "spearman_with_gain",
            "positive_gain_auroc",
            "score_unique",
            "score_variance",
        ],
    )

    write_csv(
        OUT / "results" / "candidate_vs_primitive_envelope_cells.csv",
        cell_status_rows,
        [
            "block",
            "method",
            "budget_percent",
            "candidate_value",
            "strongest_primitive_value",
            "margin",
            "status",
        ],
    )

    write_csv(
        OUT / "results" / "prediction_calibration_deciles.csv",
        calibration_rows,
        [
            "block",
            "method",
            "decile",
            "rows",
            "mean_prediction",
            "mean_intervention_gain",
            "positive_gain_fraction",
            "minimum_prediction",
            "maximum_prediction",
        ],
    )

    aggregate_rows = []

    for method in (
        ALL_NON_ORACLE_METHODS
        + ["Oracle"]
    ):
        rows = [
            row
            for row in block_summary_rows
            if row["method"] == method
        ]

        aubcs = [
            float(row["aubc_5_90"])
            for row in rows
        ]
        regrets = [
            float(row["oracle_regret"])
            for row in rows
        ]
        spearmans = [
            float(row["spearman_with_gain"])
            for row in rows
            if row["spearman_with_gain"] is not None
        ]
        aucs = [
            float(row["positive_gain_auroc"])
            for row in rows
            if row["positive_gain_auroc"] is not None
        ]

        aggregate_rows.append({
            "method": method,
            "blocks": len(rows),
            "mean_aubc_5_90": statistics.fmean(aubcs),
            "minimum_block_aubc_5_90": min(aubcs),
            "maximum_block_aubc_5_90": max(aubcs),
            "block_stdev_aubc_5_90": (
                statistics.pstdev(aubcs)
                if len(aubcs) > 1
                else 0.0
            ),
            "mean_oracle_regret": statistics.fmean(regrets),
            "worst_block_oracle_regret": max(regrets),
            "mean_spearman_with_gain": (
                statistics.fmean(spearmans)
                if spearmans else None
            ),
            "mean_positive_gain_auroc": (
                statistics.fmean(aucs)
                if aucs else None
            ),
        })

    write_csv(
        OUT / "results" / "aggregate_lobo_summary.csv",
        aggregate_rows,
        [
            "method",
            "blocks",
            "mean_aubc_5_90",
            "minimum_block_aubc_5_90",
            "maximum_block_aubc_5_90",
            "block_stdev_aubc_5_90",
            "mean_oracle_regret",
            "worst_block_oracle_regret",
            "mean_spearman_with_gain",
            "mean_positive_gain_auroc",
        ],
    )

    rng = np.random.default_rng(RANDOM_SEED)
    bootstrap_values: Dict[
        Tuple[str, str],
        List[float],
    ] = defaultdict(list)

    point_aubc_by_block: Dict[
        Tuple[str, str],
        float,
    ] = {}

    for block_name, record in heldout_records.items():
        gains = record["gains"]
        scores = record["scores"]

        for method in ALL_NON_ORACLE_METHODS:
            point_aubc_by_block[
                (block_name, method)
            ] = normalized_aubc(
                selected_curve(
                    scores[method],
                    gains,
                )
            )

    for repetition in range(BOOTSTRAP_REPS):
        repetition_deltas: Dict[
            Tuple[str, str],
            List[float],
        ] = defaultdict(list)

        for block_name, record in heldout_records.items():
            rows = record["rows"]
            gains = record["gains"]
            scores = record["scores"]

            seed_to_indices: Dict[int, List[int]] = defaultdict(list)

            for index, row in enumerate(rows):
                seed_to_indices[
                    int(row["seed"])
                ].append(index)

            unique_seeds = np.asarray(
                sorted(seed_to_indices),
                dtype=int,
            )

            sampled_seeds = rng.choice(
                unique_seeds,
                size=len(unique_seeds),
                replace=True,
            )

            sampled_indices = np.asarray([
                index
                for seed in sampled_seeds
                for index in seed_to_indices[int(seed)]
            ], dtype=int)

            sampled_gains = gains[sampled_indices]

            sampled_aubc = {}

            for method in ALL_NON_ORACLE_METHODS:
                sampled_scores = scores[method][
                    sampled_indices
                ]

                sampled_aubc[method] = normalized_aubc(
                    selected_curve(
                        sampled_scores,
                        sampled_gains,
                    )
                )

            for candidate in CANDIDATE_METHODS:
                for comparator in BASELINE_METHODS:
                    repetition_deltas[
                        (candidate, comparator)
                    ].append(
                        sampled_aubc[candidate]
                        - sampled_aubc[comparator]
                    )

        for pair, block_deltas in repetition_deltas.items():
            bootstrap_values[pair].append(
                statistics.fmean(block_deltas)
            )

    bootstrap_rows = []

    for candidate in CANDIDATE_METHODS:
        for comparator in BASELINE_METHODS:
            values = bootstrap_values[
                (candidate, comparator)
            ]

            point_block_deltas = [
                point_aubc_by_block[(block["name"], candidate)]
                - point_aubc_by_block[(block["name"], comparator)]
                for block in BLOCKS
            ]

            bootstrap_rows.append({
                "candidate": candidate,
                "comparator": comparator,
                "bootstrap_repetitions": BOOTSTRAP_REPS,
                "point_mean_block_delta_aubc": statistics.fmean(
                    point_block_deltas
                ),
                "minimum_point_block_delta_aubc": min(
                    point_block_deltas
                ),
                "maximum_point_block_delta_aubc": max(
                    point_block_deltas
                ),
                "bootstrap_mean_delta_aubc": statistics.fmean(
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
        OUT / "results" / "stratified_seed_cluster_bootstrap_aubc.csv",
        bootstrap_rows,
        [
            "candidate",
            "comparator",
            "bootstrap_repetitions",
            "point_mean_block_delta_aubc",
            "minimum_point_block_delta_aubc",
            "maximum_point_block_delta_aubc",
            "bootstrap_mean_delta_aubc",
            "ci_2_5",
            "ci_97_5",
            "probability_delta_ge_zero",
        ],
    )

    cell_count_rows = []

    for candidate in CANDIDATE_METHODS:
        rows = [
            row
            for row in cell_status_rows
            if row["method"] == candidate
        ]
        counts = Counter(
            row["status"]
            for row in rows
        )

        margins = [
            float(row["margin"])
            for row in rows
        ]

        cell_count_rows.append({
            "method": candidate,
            "total_cells": len(rows),
            "strict_wins": counts["strict_win"],
            "exact_ties": counts["exact_tie"],
            "losses": counts["loss"],
            "minimum_margin": min(margins),
            "maximum_margin": max(margins),
            "mean_margin": statistics.fmean(margins),
        })

    write_csv(
        OUT / "results" / "candidate_cell_count_summary.csv",
        cell_count_rows,
        [
            "method",
            "total_cells",
            "strict_wins",
            "exact_ties",
            "losses",
            "minimum_margin",
            "maximum_margin",
            "mean_margin",
        ],
    )

    model_spec = {
        "stage": "EVVA_3 Stage 3A development screening",
        "final_model_frozen": False,
        "all_seeds_4200_6499_are_development": True,
        "features": FEATURES,
        "forbidden_features": sorted(FORBIDDEN),
        "budgets": BUDGETS,
        "primary_development_metric": (
            "normalized trapezoidal AUBC over 5%-90%"
        ),
        "heldout_unit": "entire 300-seed collection block",
        "evaluation_rows_per_fold": 600,
        "training_rows_per_fold": 4500,
        "preprocessing_fit_on_training_blocks_only": True,
        "score_is_fixed_across_budgets": True,
        "tie_handling": (
            "tie-aware exact-B expected gain at the score cutoff"
        ),
        "bootstrap": {
            "type": "block-stratified seed-cluster bootstrap",
            "repetitions": BOOTSTRAP_REPS,
            "rows_per_seed_kept_together": True,
            "block_weighting": "equal across six held-out blocks",
        },
        "models": {
            "Ridge-PIV": {
                "alpha": 1.0,
                "imputation": "training median",
                "scaling": "training StandardScaler",
            },
            "Hurdle-PIV": {
                "positive_probability": (
                    "L2 logistic regression, C=1"
                ),
                "positive_magnitude": (
                    "Ridge alpha=1 on positive-gain rows"
                ),
                "score": (
                    "P(gain>0|x) * max(0,E[gain|gain>0,x])"
                ),
            },
            "ShallowGB-PIV": {
                "class": "HistGradientBoostingRegressor",
                "learning_rate": 0.05,
                "max_iter": 100,
                "max_depth": 2,
                "min_samples_leaf": 40,
                "l2_regularization": 1.0,
            },
        },
        "selection_rule": (
            "No model is selected or frozen in Stage 3A."
        ),
    }

    with (
        OUT / "manifests" / "model_spec.json"
    ).open("w", encoding="utf-8") as handle:
        json.dump(
            model_spec,
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
        "formal_development_blocks": len(BLOCKS),
        "heldout_folds": len(BLOCKS),
        "candidate_models": CANDIDATE_METHODS,
        "baseline_methods": BASELINE_METHODS,
        "bootstrap_repetitions": BOOTSTRAP_REPS,
        "new_seed_collection": False,
        "final_model_frozen": False,
        "important_warning": (
            "These are development results and must not be "
            "reported as untouched confirmation."
        ),
    }

    with (
        OUT / "reports" / "stage3a_summary.json"
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
echo "EVVA_3 STAGE 3A LOBO SCREEN"
echo "===================================================="
echo "Output: $OUT"
echo "Bootstrap repetitions: $BOOTSTRAP_REPS"
echo

echo "Checking Python dependencies..."

python3 - <<'PY' || die "Required Python packages are unavailable."
import numpy
import sklearn
print("numpy", numpy.__version__)
print("sklearn", sklearn.__version__)
PY

echo
echo "Compiling Stage 3A evaluator..."

python3 -m py_compile \
  "$OUT/code/evva3_stage3a_lobo_screen.py" \
  || die "Stage 3A Python failed py_compile."

echo
echo "Running Stage 3A LOBO screening..."

python3 \
  "$OUT/code/evva3_stage3a_lobo_screen.py" \
  2>&1 | tee "$OUT/logs/stage3a_lobo.log" \
  || die "Stage 3A LOBO screening failed."

{
  echo "locked_v5m:"
  sha256sum "$V5M"
  echo "frozen_evva2h:"
  sha256sum "$EVVA2H"
} > "$OUT/hashes/post_run_locked_sha256.txt"

POST_V5M_SHA="$(sha256sum "$V5M" | awk '{print $1}')"
POST_EVVA2H_SHA="$(sha256sum "$EVVA2H" | awk '{print $1}')"

[ "$POST_V5M_SHA" = "$EXPECTED_V5M_SHA" ] \
  || die "Locked v5m changed during Stage 3A."

[ "$POST_EVVA2H_SHA" = "$EXPECTED_EVVA2H_SHA" ] \
  || die "Frozen EVVA_2H changed during Stage 3A."

find "$OUT" \
  -type f \
  ! -name 'FINAL_SHA256SUMS.txt' \
  -print0 \
  | sort -z \
  | xargs -0 sha256sum \
  > "$OUT/FINAL_SHA256SUMS.txt"

{
  echo "# EVVA_3 Stage 3A completion"
  echo
  echo "Output: $OUT"
  echo
  echo "This is development-only leave-one-block-out screening."
  echo "No final model was selected or frozen."
  echo "No new seeds were collected."
  echo "The locked methods were not modified."
  echo
  echo "Primary files:"
  echo "- results/aggregate_lobo_summary.csv"
  echo "- results/block_level_summary.csv"
  echo "- results/selected_gain_curve_by_block.csv"
  echo "- results/stratified_seed_cluster_bootstrap_aubc.csv"
  echo "- results/candidate_cell_count_summary.csv"
  echo "- results/prediction_calibration_deciles.csv"
  echo "- predictions/lobo_heldout_predictions.csv"
  echo "- manifests/model_spec.json"
} > "$OUT/reports/STAGE3A_COMPLETE.md"

echo
echo "===================================================="
echo "EVVA_3 STAGE 3A COMPLETE"
echo "===================================================="
echo "Output: $OUT"
echo
cat "$OUT/reports/stage3a_summary.json"

echo
echo "Aggregate LOBO summary:"
column -s, -t \
  < "$OUT/results/aggregate_lobo_summary.csv"

echo
echo "Seed-cluster bootstrap:"
column -s, -t \
  < "$OUT/results/stratified_seed_cluster_bootstrap_aubc.csv"

echo
echo "Cell-count diagnostic:"
column -s, -t \
  < "$OUT/results/candidate_cell_count_summary.csv"

echo
echo "PASS: Stage 3A completed without collecting new seeds or modifying frozen methods."

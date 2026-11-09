#!/usr/bin/env bash

# EVVA_3 Stage 3B:
# Matched-capacity feature ablations, block jackknife, and two-level
# block + seed-cluster bootstrap. Development analysis only.

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

python3 - <<'PY' || die "Activate .venv_evva3 before running Stage 3B."
import numpy
import sklearn
print("numpy", numpy.__version__)
print("sklearn", sklearn.__version__)
PY

RUN_ID="$(date +%Y%m%d_%H%M%S)"
OUT="artifacts/aaai_evva3_stage3b_matched_ablation_${RUN_ID}"

mkdir -p \
  "$OUT/code" \
  "$OUT/hashes" \
  "$OUT/logs" \
  "$OUT/manifests" \
  "$OUT/predictions" \
  "$OUT/results" \
  "$OUT/reports" \
  || die "Cannot create output directories."

echo "$OUT" > artifacts/aaai_evva3_stage3b_latest.txt

BOOTSTRAP_REPS="${EVVA3_STAGE3B_BOOTSTRAP_REPS:-2000}"

export EVVA3_STAGE3B_OUT="$OUT"
export EVVA3_STAGE3B_BOOTSTRAP_REPS="$BOOTSTRAP_REPS"

{
  sha256sum "$V5M"
  sha256sum "$EVVA2H"
} > "$OUT/hashes/pre_run_locked_sha256.txt"

cat > "$OUT/code/aaai_evva3_stage3b_matched_ablation.py" <<'PY'
#!/usr/bin/env python3

"""Matched-capacity EVVA_3 feature ablations under six-block LOBO."""

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
from sklearn.linear_model import Ridge
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import StandardScaler


ROOT = Path.cwd()
OUT = Path(os.environ["EVVA3_STAGE3B_OUT"])
BOOTSTRAP_REPS = int(
    os.environ.get("EVVA3_STAGE3B_BOOTSTRAP_REPS", "2000")
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

FEATURE_SETS = {
    "ShallowGB-pH-only": [
        "p_times_H_score",
    ],
    "ShallowGB-core": [
        "p_score",
        "harm_score",
        "p_times_H_score",
    ],
    "ShallowGB-structural": [
        "rollback_difficulty",
        "persistent_state_risk",
        "log1p_downstream_dependency_count",
    ],
    "ShallowGB-full": [
        "p_score",
        "harm_score",
        "p_times_H_score",
        "rollback_difficulty",
        "persistent_state_risk",
        "log1p_downstream_dependency_count",
    ],
    "Ridge-full": [
        "p_score",
        "harm_score",
        "p_times_H_score",
        "rollback_difficulty",
        "persistent_state_risk",
        "log1p_downstream_dependency_count",
    ],
}

CANDIDATES = list(FEATURE_SETS)

PRIMITIVES = [
    "Random",
    "p-only",
    "H-only",
    "pH",
]

BLOCKS = [
    {
        "name": "original_4200_4499",
        "path": (
            "artifacts/v4_full_agent_20260707/large/"
            "full_agent_candidate_rows_large.csv"
        ),
        "evaluation": (4300, 4499),
    },
    {
        "name": "first_5000_5299",
        "path": (
            "artifacts/aaai_evva2_exploratory_20260713/"
            "evva2g_confirmatory_5000_5299/raw/"
            "full_agent_candidate_rows_5000_5299.csv"
        ),
        "evaluation": (5100, 5299),
    },
    {
        "name": "r2_5300_5599",
        "path": (
            "artifacts/aaai_evva2_exploratory_20260713/"
            "evva2g_replication_r2_5300_5599/raw/"
            "full_agent_candidate_rows_5300_5599.csv"
        ),
        "evaluation": (5400, 5599),
    },
    {
        "name": "r3_5600_5899",
        "path": (
            "artifacts/aaai_evva2_exploratory_20260713/"
            "evva2g_replication_r3_5600_5899/raw/"
            "full_agent_candidate_rows_5600_5899.csv"
        ),
        "evaluation": (5700, 5899),
    },
    {
        "name": "r4_5900_6199",
        "path": (
            "artifacts/aaai_evva2_exploratory_20260713/"
            "evva2h_final_confirmation_20260713/r4_5900_6199/raw/"
            "full_agent_candidate_rows_5900_6199.csv"
        ),
        "evaluation": (6000, 6199),
    },
    {
        "name": "r5_6200_6499",
        "path": (
            "artifacts/aaai_evva2_exploratory_20260713/"
            "evva2h_final_confirmation_20260713/r5_6200_6499/raw/"
            "full_agent_candidate_rows_6200_6499.csv"
        ),
        "evaluation": (6300, 6499),
    },
]


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
        raise ValueError("Missing intervention_gain.")

    return np.asarray(values, dtype=float)


def exact_b(n: int, fraction: float) -> int:
    return max(
        1,
        min(
            n,
            int(round(n * fraction)),
        ),
    )


def selected_curve(
    scores: np.ndarray,
    gains: np.ndarray,
) -> List[float]:
    if len(scores) != len(gains):
        raise ValueError("Score/gain length mismatch.")

    if not np.all(np.isfinite(scores)):
        raise ValueError("Non-finite score detected.")

    if not np.all(np.isfinite(gains)):
        raise ValueError("Non-finite gain detected.")

    groups: Dict[float, List[float]] = {}

    for score, gain in zip(scores, gains):
        key = float(score)

        if key not in groups:
            groups[key] = [0.0, 0.0]

        groups[key][0] += 1.0
        groups[key][1] += float(gain)

    score_levels = sorted(groups, reverse=True)

    counts = np.asarray(
        [groups[level][0] for level in score_levels],
        dtype=float,
    )
    gain_sums = np.asarray(
        [groups[level][1] for level in score_levels],
        dtype=float,
    )

    cumulative_counts = np.cumsum(counts)
    cumulative_gains = np.cumsum(gain_sums)

    curve = []

    for fraction in BUDGETS:
        budget = exact_b(len(scores), fraction)

        boundary = int(
            np.searchsorted(
                cumulative_counts,
                budget,
                side="left",
            )
        )

        count_above = (
            cumulative_counts[boundary - 1]
            if boundary > 0
            else 0.0
        )

        gain_above = (
            cumulative_gains[boundary - 1]
            if boundary > 0
            else 0.0
        )

        needed = budget - count_above

        selected_sum = (
            gain_above
            + (
                needed / counts[boundary]
            ) * gain_sums[boundary]
        )

        curve.append(
            float(selected_sum / budget)
        )

    return curve


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
    block_rows: Dict[str, List[Dict[str, object]]] = {}
    input_manifest = []

    for block in BLOCKS:
        path = ROOT / block["path"]

        if not path.is_file():
            raise FileNotFoundError(path)

        fields, raw_rows = read_csv(path)
        rows = [augment_row(row) for row in raw_rows]

        if len(rows) != 900:
            raise RuntimeError(
                f"{block['name']} has {len(rows)} rows, expected 900."
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
                f"Invalid seed clustering in {block['name']}."
            )

        block_rows[block["name"]] = rows

        input_manifest.append({
            "block": block["name"],
            "path": block["path"],
            "sha256": sha256(path),
            "rows": len(rows),
            "columns": len(fields),
            "unique_seeds": len(seed_counts),
        })

    prediction_rows: List[Dict[str, object]] = []
    curve_rows: List[Dict[str, object]] = []
    block_rows_output: List[Dict[str, object]] = []
    cell_rows: List[Dict[str, object]] = []

    heldout_records: Dict[str, Dict[str, object]] = {}

    for heldout in BLOCKS:
        heldout_name = heldout["name"]
        eval_min, eval_max = heldout["evaluation"]

        train_rows = [
            row
            for block in BLOCKS
            if block["name"] != heldout_name
            for row in block_rows[block["name"]]
        ]

        eval_rows = [
            row
            for row in block_rows[heldout_name]
            if eval_min <= int(row["seed"]) <= eval_max
        ]

        if len(train_rows) != 4500:
            raise RuntimeError(
                f"{heldout_name}: expected 4500 train rows."
            )

        if len(eval_rows) != 600:
            raise RuntimeError(
                f"{heldout_name}: expected 600 eval rows."
            )

        train_y = labels(train_rows)
        eval_y = labels(eval_rows)

        scores: Dict[str, np.ndarray] = {
            "Random": np.zeros(
                len(eval_rows),
                dtype=float,
            ),
            "p-only": np.asarray(
                [
                    parse_float(row.get("p_score"))
                    for row in eval_rows
                ],
                dtype=float,
            ),
            "H-only": np.asarray(
                [
                    parse_float(row.get("harm_score"))
                    for row in eval_rows
                ],
                dtype=float,
            ),
            "pH": np.asarray(
                [
                    parse_float(row.get("p_times_H_score"))
                    for row in eval_rows
                ],
                dtype=float,
            ),
            "Oracle": eval_y.copy(),
        }

        for method, features in FEATURE_SETS.items():
            train_x = matrix(train_rows, features)
            eval_x = matrix(eval_rows, features)

            model = (
                ridge_model()
                if method == "Ridge-full"
                else shallow_model()
            )

            model.fit(train_x, train_y)
            scores[method] = model.predict(eval_x)

        curves = {
            method: selected_curve(
                method_scores,
                eval_y,
            )
            for method, method_scores in scores.items()
        }

        primitive_envelope = [
            max(values)
            for values in zip(
                *[
                    curves[method]
                    for method in PRIMITIVES
                ]
            )
        ]

        primitive_envelope_aubc = aubc(
            primitive_envelope
        )

        for method, curve in curves.items():
            method_aubc = aubc(curve)

            block_rows_output.append({
                "block": heldout_name,
                "method": method,
                "aubc_5_90": method_aubc,
                "delta_vs_pH_aubc": (
                    method_aubc - aubc(curves["pH"])
                ),
                "primitive_envelope_aubc": primitive_envelope_aubc,
                "delta_vs_primitive_envelope_aubc": (
                    method_aubc
                    - primitive_envelope_aubc
                ),
                "score_unique": len(
                    np.unique(scores[method])
                ),
                "score_variance": float(
                    np.var(scores[method])
                ),
            })

            for fraction, value in zip(
                BUDGETS,
                curve,
            ):
                curve_rows.append({
                    "block": heldout_name,
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

        for candidate in CANDIDATES:
            for fraction, value, envelope in zip(
                BUDGETS,
                curves[candidate],
                primitive_envelope,
            ):
                margin = value - envelope

                if margin > 1e-10:
                    status = "strict_win"
                elif margin < -1e-10:
                    status = "loss"
                else:
                    status = "exact_tie"

                cell_rows.append({
                    "block": heldout_name,
                    "method": candidate,
                    "budget_percent": int(
                        round(fraction * 100)
                    ),
                    "candidate_value": value,
                    "primitive_envelope": envelope,
                    "margin": margin,
                    "status": status,
                })

        for index, row in enumerate(eval_rows):
            output_row = {
                "block": heldout_name,
                "seed": int(row["seed"]),
                "case_type": row.get("case_type", ""),
                "candidate_id": row.get("candidate_id", ""),
                "intervention_gain": eval_y[index],
            }

            for method in PRIMITIVES + CANDIDATES:
                output_row[
                    "score_" + method.replace("-", "_")
                ] = scores[method][index]

            prediction_rows.append(output_row)

        heldout_records[heldout_name] = {
            "rows": eval_rows,
            "gains": eval_y,
            "scores": {
                method: scores[method]
                for method in PRIMITIVES + CANDIDATES
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
        ],
    )

    prediction_fields = [
        "block",
        "seed",
        "case_type",
        "candidate_id",
        "intervention_gain",
    ] + [
        "score_" + method.replace("-", "_")
        for method in PRIMITIVES + CANDIDATES
    ]

    write_csv(
        OUT / "predictions" / "matched_ablation_predictions.csv",
        prediction_rows,
        prediction_fields,
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
        OUT / "results" / "block_summary.csv",
        block_rows_output,
        [
            "block",
            "method",
            "aubc_5_90",
            "delta_vs_pH_aubc",
            "primitive_envelope_aubc",
            "delta_vs_primitive_envelope_aubc",
            "score_unique",
            "score_variance",
        ],
    )

    write_csv(
        OUT / "results" / "candidate_cells.csv",
        cell_rows,
        [
            "block",
            "method",
            "budget_percent",
            "candidate_value",
            "primitive_envelope",
            "margin",
            "status",
        ],
    )

    aggregate_rows = []

    for method in PRIMITIVES + CANDIDATES + ["Oracle"]:
        rows = [
            row
            for row in block_rows_output
            if row["method"] == method
        ]

        aubcs = [
            float(row["aubc_5_90"])
            for row in rows
        ]

        pH_deltas = [
            float(row["delta_vs_pH_aubc"])
            for row in rows
        ]

        envelope_deltas = [
            float(
                row["delta_vs_primitive_envelope_aubc"]
            )
            for row in rows
        ]

        aggregate_rows.append({
            "method": method,
            "blocks": len(rows),
            "mean_aubc_5_90": statistics.fmean(aubcs),
            "minimum_block_aubc_5_90": min(aubcs),
            "mean_delta_vs_pH": statistics.fmean(pH_deltas),
            "minimum_block_delta_vs_pH": min(pH_deltas),
            "maximum_block_delta_vs_pH": max(pH_deltas),
            "mean_delta_vs_primitive_envelope": statistics.fmean(
                envelope_deltas
            ),
            "minimum_block_delta_vs_primitive_envelope": min(
                envelope_deltas
            ),
        })

    write_csv(
        OUT / "results" / "aggregate_ablation_summary.csv",
        aggregate_rows,
        [
            "method",
            "blocks",
            "mean_aubc_5_90",
            "minimum_block_aubc_5_90",
            "mean_delta_vs_pH",
            "minimum_block_delta_vs_pH",
            "maximum_block_delta_vs_pH",
            "mean_delta_vs_primitive_envelope",
            "minimum_block_delta_vs_primitive_envelope",
        ],
    )

    cell_summary_rows = []

    for candidate in CANDIDATES:
        rows = [
            row
            for row in cell_rows
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

        cell_summary_rows.append({
            "method": candidate,
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
            "method",
            "total_cells",
            "strict_wins",
            "exact_ties",
            "losses",
            "mean_margin",
            "minimum_margin",
            "maximum_margin",
        ],
    )

    jackknife_rows = []

    block_names = [
        block["name"]
        for block in BLOCKS
    ]

    point_delta_by_block: Dict[
        Tuple[str, str, str],
        float,
    ] = {}

    for block_name, record in heldout_records.items():
        gains = record["gains"]
        scores = record["scores"]

        pH_aubc = aubc(
            selected_curve(
                scores["pH"],
                gains,
            )
        )

        primitive_curves = [
            selected_curve(
                scores[method],
                gains,
            )
            for method in PRIMITIVES
        ]

        envelope_aubc = aubc([
            max(values)
            for values in zip(*primitive_curves)
        ])

        for candidate in CANDIDATES:
            candidate_aubc = aubc(
                selected_curve(
                    scores[candidate],
                    gains,
                )
            )

            point_delta_by_block[
                (block_name, candidate, "pH")
            ] = candidate_aubc - pH_aubc

            point_delta_by_block[
                (
                    block_name,
                    candidate,
                    "primitive_envelope",
                )
            ] = candidate_aubc - envelope_aubc

    for candidate in CANDIDATES:
        for comparator in [
            "pH",
            "primitive_envelope",
        ]:
            all_deltas = [
                point_delta_by_block[
                    (
                        block_name,
                        candidate,
                        comparator,
                    )
                ]
                for block_name in block_names
            ]

            for omitted in block_names:
                retained = [
                    point_delta_by_block[
                        (
                            block_name,
                            candidate,
                            comparator,
                        )
                    ]
                    for block_name in block_names
                    if block_name != omitted
                ]

                jackknife_rows.append({
                    "candidate": candidate,
                    "comparator": comparator,
                    "omitted_block": omitted,
                    "full_six_block_mean_delta": statistics.fmean(
                        all_deltas
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

    rng = np.random.default_rng(RANDOM_SEED)

    bootstrap_values: Dict[
        Tuple[str, str],
        List[float],
    ] = defaultdict(list)

    seed_indices_by_block: Dict[
        str,
        Dict[int, List[int]],
    ] = {}

    for block_name, record in heldout_records.items():
        mapping: Dict[int, List[int]] = defaultdict(list)

        for index, row in enumerate(record["rows"]):
            mapping[int(row["seed"])].append(index)

        seed_indices_by_block[block_name] = mapping

    for _ in range(BOOTSTRAP_REPS):
        sampled_blocks = rng.choice(
            np.asarray(block_names, dtype=object),
            size=len(block_names),
            replace=True,
        )

        replicate_deltas: Dict[
            Tuple[str, str],
            List[float],
        ] = defaultdict(list)

        for sampled_block in sampled_blocks:
            block_name = str(sampled_block)
            record = heldout_records[block_name]

            seed_mapping = seed_indices_by_block[
                block_name
            ]

            unique_seeds = np.asarray(
                sorted(seed_mapping),
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
                for index in seed_mapping[int(seed)]
            ], dtype=int)

            sampled_gains = record["gains"][
                sampled_indices
            ]

            sampled_curves = {
                method: selected_curve(
                    record["scores"][method][
                        sampled_indices
                    ],
                    sampled_gains,
                )
                for method in PRIMITIVES + CANDIDATES
            }

            sampled_pH_aubc = aubc(
                sampled_curves["pH"]
            )

            sampled_envelope_aubc = aubc([
                max(values)
                for values in zip(
                    *[
                        sampled_curves[method]
                        for method in PRIMITIVES
                    ]
                )
            ])

            for candidate in CANDIDATES:
                candidate_aubc = aubc(
                    sampled_curves[candidate]
                )

                replicate_deltas[
                    (candidate, "pH")
                ].append(
                    candidate_aubc
                    - sampled_pH_aubc
                )

                replicate_deltas[
                    (
                        candidate,
                        "primitive_envelope",
                    )
                ].append(
                    candidate_aubc
                    - sampled_envelope_aubc
                )

        for key, values in replicate_deltas.items():
            bootstrap_values[key].append(
                statistics.fmean(values)
            )

    bootstrap_rows = []

    for candidate in CANDIDATES:
        for comparator in [
            "pH",
            "primitive_envelope",
        ]:
            values = bootstrap_values[
                (candidate, comparator)
            ]

            point_deltas = [
                point_delta_by_block[
                    (
                        block_name,
                        candidate,
                        comparator,
                    )
                ]
                for block_name in block_names
            ]

            bootstrap_rows.append({
                "candidate": candidate,
                "comparator": comparator,
                "bootstrap_repetitions": BOOTSTRAP_REPS,
                "point_mean_six_block_delta": statistics.fmean(
                    point_deltas
                ),
                "minimum_point_block_delta": min(
                    point_deltas
                ),
                "maximum_point_block_delta": max(
                    point_deltas
                ),
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

    write_csv(
        OUT / "results" / "two_level_block_seed_bootstrap.csv",
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

    broad_rows = []

    curve_lookup = {
        (
            row["block"],
            row["method"],
            int(row["budget_percent"]),
        ): float(
            row["selected_mean_intervention_gain"]
        )
        for row in curve_rows
    }

    for block_name in block_names:
        for budget in [60, 70]:
            primitive_values = {
                method: curve_lookup[
                    (
                        block_name,
                        method,
                        budget,
                    )
                ]
                for method in PRIMITIVES
            }

            strongest_primitive = max(
                primitive_values.values()
            )

            for candidate in CANDIDATES:
                value = curve_lookup[
                    (
                        block_name,
                        candidate,
                        budget,
                    )
                ]

                broad_rows.append({
                    "block": block_name,
                    "budget_percent": budget,
                    "candidate": candidate,
                    "candidate_value": value,
                    "pH_value": primitive_values["pH"],
                    "strongest_primitive_value": strongest_primitive,
                    "delta_vs_pH": (
                        value
                        - primitive_values["pH"]
                    ),
                    "delta_vs_strongest_primitive": (
                        value
                        - strongest_primitive
                    ),
                })

    write_csv(
        OUT / "results" / "broad_budget_60_70.csv",
        broad_rows,
        [
            "block",
            "budget_percent",
            "candidate",
            "candidate_value",
            "pH_value",
            "strongest_primitive_value",
            "delta_vs_pH",
            "delta_vs_strongest_primitive",
        ],
    )

    spec = {
        "stage": "EVVA_3 Stage 3B development ablation",
        "final_model_frozen": False,
        "new_seed_collection": False,
        "budgets": BUDGETS,
        "feature_sets": FEATURE_SETS,
        "shared_shallowgb_hyperparameters": {
            "learning_rate": 0.05,
            "max_iter": 100,
            "max_depth": 2,
            "min_samples_leaf": 40,
            "l2_regularization": 1.0,
            "random_state": RANDOM_SEED,
        },
        "ridge_alpha": 1.0,
        "heldout_unit": "entire 300-seed block",
        "training_rows_per_fold": 4500,
        "evaluation_rows_per_fold": 600,
        "tie_handling": "tie-aware exact-B expected value",
        "bootstrap": {
            "type": (
                "two-level block bootstrap plus "
                "within-block seed-cluster bootstrap"
            ),
            "repetitions": BOOTSTRAP_REPS,
        },
        "selection_warning": (
            "Stage 3B does not select or freeze a final model."
        ),
    }

    with (
        OUT / "manifests" / "stage3b_spec.json"
    ).open("w", encoding="utf-8") as handle:
        json.dump(
            spec,
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
        "candidate_models": CANDIDATES,
        "matched_capacity_shallowgb_ablations": True,
        "two_level_bootstrap_repetitions": BOOTSTRAP_REPS,
        "new_seed_collection": False,
        "final_model_frozen": False,
        "warning": (
            "Development evidence only; not untouched confirmation."
        ),
    }

    with (
        OUT / "reports" / "stage3b_summary.json"
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
echo "EVVA_3 STAGE 3B MATCHED ABLATION"
echo "===================================================="
echo "Output: $OUT"
echo "Two-level bootstrap repetitions: $BOOTSTRAP_REPS"
echo

python3 -m py_compile \
  "$OUT/code/aaai_evva3_stage3b_matched_ablation.py" \
  || die "Stage 3B Python failed py_compile."

python3 \
  "$OUT/code/aaai_evva3_stage3b_matched_ablation.py" \
  2>&1 | tee "$OUT/logs/stage3b.log" \
  || die "Stage 3B experiment failed."

{
  sha256sum "$V5M"
  sha256sum "$EVVA2H"
} > "$OUT/hashes/post_run_locked_sha256.txt"

POST_V5M_SHA="$(sha256sum "$V5M" | awk '{print $1}')"
POST_EVVA2H_SHA="$(sha256sum "$EVVA2H" | awk '{print $1}')"

[ "$POST_V5M_SHA" = "$EXPECTED_V5M_SHA" ] \
  || die "Locked v5m changed during Stage 3B."

[ "$POST_EVVA2H_SHA" = "$EXPECTED_EVVA2H_SHA" ] \
  || die "Frozen EVVA_2H changed during Stage 3B."

find "$OUT" \
  -type f \
  ! -name 'FINAL_SHA256SUMS.txt' \
  -print0 \
  | sort -z \
  | xargs -0 sha256sum \
  > "$OUT/FINAL_SHA256SUMS.txt"

{
  echo "# EVVA_3 Stage 3B completion"
  echo
  echo "Output: $OUT"
  echo
  echo "Development-only matched-capacity feature ablation."
  echo "No final model was selected."
  echo "No new seeds were collected."
  echo "Frozen methods were not modified."
} > "$OUT/reports/STAGE3B_COMPLETE.md"

echo
echo "===================================================="
echo "EVVA_3 STAGE 3B COMPLETE"
echo "===================================================="
echo "Output: $OUT"
echo

cat "$OUT/reports/stage3b_summary.json"

echo
echo "Aggregate ablation:"
column -s, -t \
  < "$OUT/results/aggregate_ablation_summary.csv"

echo
echo "Two-level bootstrap:"
column -s, -t \
  < "$OUT/results/two_level_block_seed_bootstrap.csv"

echo
echo "Cell summary:"
column -s, -t \
  < "$OUT/results/cell_summary.csv"

echo
echo "PASS: Stage 3B completed without new seeds or frozen-method changes."

#!/usr/bin/env bash

# EVVA_3 Stage 6C:
# Frozen-method ablation and robustness package.
#
# No new seeds.
# No method modification.
# No parameter selection.
# C1/C2 are used only for prespecified secondary analyses after
# the confirmatory decision was finalized.

die() {
  echo "ERROR: $*" >&2
  exit 1
}

WORKSPACE="$HOME/.openclaw/workspace/skills/openclaw_pilot_v4_large_exactB_20260707_EVVA_3_signal_repair_20260713"

V5M="code/aaai_v5m_signal_availability_gated_evva.py"
EXPECTED_V5M_SHA="924b6c893036f20ee9d60e90faf34c3beeb0f830af8e6d1c8ffd4dfee904906e"

[ -d "$WORKSPACE" ] \
  || die "Workspace not found."

cd "$WORKSPACE" \
  || die "Cannot enter workspace."

for pointer in \
  artifacts/aaai_evva3_stage4f_latest.txt \
  artifacts/aaai_evva3_stage5a_latest.txt \
  artifacts/aaai_evva3_stage5b_latest.txt \
  artifacts/aaai_evva3_stage6b_latest.txt
do
  [ -f "$pointer" ] \
    || die "Missing pointer: $pointer"
done

STAGE4F="$(cat artifacts/aaai_evva3_stage4f_latest.txt)"
STAGE5A="$(cat artifacts/aaai_evva3_stage5a_latest.txt)"
STAGE5B="$(cat artifacts/aaai_evva3_stage5b_latest.txt)"
STAGE6B="$(cat artifacts/aaai_evva3_stage6b_latest.txt)"

FINAL_METHOD="$STAGE4F/code/aaai_evva3_final_evva_sag.py"
PREREGISTRATION="$STAGE4F/manifests/C1_C2_PREREGISTRATION.json"

C1_RAW="$STAGE5A/c1_6500_6799/raw/full_agent_candidate_rows_6500_6799.csv"
C2_RAW="$STAGE5A/c2_6800_7099/raw/full_agent_candidate_rows_6800_7099.csv"

SEALED_HASHES="$STAGE5A/hashes/SEALED_RAW_SHA256.txt"
STAGE5B_HASHES="$STAGE5B/hashes/post_evaluation_sha256.txt"
CONFIRMATORY_DECISION="$STAGE5B/reports/confirmatory_decision.json"
REPLAY_SUMMARY="$STAGE6B/reports/deterministic_replay_summary.json"

for required in \
  "$V5M" \
  "$FINAL_METHOD" \
  "$PREREGISTRATION" \
  "$C1_RAW" \
  "$C2_RAW" \
  "$SEALED_HASHES" \
  "$STAGE5B_HASHES" \
  "$CONFIRMATORY_DECISION" \
  "$REPLAY_SUMMARY"
do
  [ -f "$required" ] \
    || die "Missing required input: $required"
done

[ "$(sha256sum "$V5M" | awk '{print $1}')" = "$EXPECTED_V5M_SHA" ] \
  || die "Locked v5m hash mismatch."

sha256sum -c "$SEALED_HASHES" \
  || die "Stage 5A sealed hashes failed."

sha256sum -c "$STAGE5B_HASHES" \
  || die "Stage 5B frozen hashes failed."

export EVVA3_STAGE6C_DECISION="$CONFIRMATORY_DECISION"
export EVVA3_STAGE6C_REPLAY="$REPLAY_SUMMARY"

python3 - <<'PY' \
  || die "Frozen evidence validation failed."
import json
import os
from pathlib import Path


with Path(
    os.environ["EVVA3_STAGE6C_DECISION"]
).open(
    encoding="utf-8"
) as handle:
    decision = json.load(handle)

with Path(
    os.environ["EVVA3_STAGE6C_REPLAY"]
).open(
    encoding="utf-8"
) as handle:
    replay = json.load(handle)

if decision.get("decision") != "PASS":
    raise SystemExit(
        "Stage 5B confirmatory decision is not PASS."
    )

if not decision.get(
    "all_preregistered_criteria_pass"
):
    raise SystemExit(
        "Preregistered criteria did not all pass."
    )

if decision.get(
    "method_modification_permitted_after_result"
):
    raise SystemExit(
        "Method modification is unexpectedly permitted."
    )

if replay.get("decision") != "PASS":
    raise SystemExit(
        "Stage 6B deterministic replay did not pass."
    )

if replay.get(
    "confirmation_seeds_used"
):
    raise SystemExit(
        "Stage 6B unexpectedly used confirmation seeds."
    )

print("FROZEN_EVIDENCE_VALIDATION=PASS")
PY

OUT="artifacts/aaai_evva3_stage6c_final_ablation_robustness_20260714"

if [ -f "$OUT/reports/stage6c_summary.json" ]; then
  echo "Stage 6C was already completed:"
  cat "$OUT/reports/stage6c_summary.json"
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
  || die "Cannot create Stage 6C directories."

echo "$OUT" \
  > artifacts/aaai_evva3_stage6c_latest.txt

BOOTSTRAP_REPS="${EVVA3_STAGE6C_BOOTSTRAP_REPS:-2000}"

export EVVA3_STAGE6C_OUT="$OUT"
export EVVA3_STAGE6C_V5M="$V5M"
export EVVA3_STAGE6C_FINAL="$FINAL_METHOD"
export EVVA3_STAGE6C_C1="$C1_RAW"
export EVVA3_STAGE6C_C2="$C2_RAW"
export EVVA3_STAGE6C_BOOTSTRAP_REPS="$BOOTSTRAP_REPS"

cp \
  "$CONFIRMATORY_DECISION" \
  "$OUT/evidence/confirmatory_decision_frozen.json"

cp \
  "$REPLAY_SUMMARY" \
  "$OUT/evidence/deterministic_replay_summary.json"

cp \
  "$PREREGISTRATION" \
  "$OUT/evidence/C1_C2_PREREGISTRATION.json"

{
  sha256sum "$V5M"
  sha256sum "$FINAL_METHOD"
  sha256sum "$C1_RAW"
  sha256sum "$C2_RAW"
  sha256sum "$CONFIRMATORY_DECISION"
  sha256sum "$REPLAY_SUMMARY"
} > "$OUT/hashes/pre_stage6c_sha256.txt"

cat > "$OUT/code/aaai_evva3_stage6c_ablation_robustness.py" <<'PY'
#!/usr/bin/env python3

"""Frozen EVVA-SAG ablation and robustness evaluation.

All analyses are secondary and occur after the confirmatory method,
criterion, and PASS/FAIL decision were frozen.

Primary ablations
-----------------

- Final-EVVA-SAG:
    0.10 percentile(pH) + 0.90 percentile(H)
- Locked-EVVA-SAG:
    original budget-dependent unavailable-signal fallback
- H-only:
    removes the pH component
- pH-only:
    removes the H component
- Raw-scale-BG:
    removes percentile normalization while preserving 0.10/0.90
- Primitive-envelope:
    per-budget maximum of H-only and pH-only

Robustness analyses
-------------------

- deterministic nested calibration subsets of 25, 50, and 100 seeds;
- seed-cluster bootstrap at every calibration size;
- per-case evaluation;
- score tie and resolution audit.
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


OUT = Path(
    os.environ["EVVA3_STAGE6C_OUT"]
)

V5M_PATH = Path(
    os.environ["EVVA3_STAGE6C_V5M"]
)

FINAL_PATH = Path(
    os.environ["EVVA3_STAGE6C_FINAL"]
)

C1_PATH = Path(
    os.environ["EVVA3_STAGE6C_C1"]
)

C2_PATH = Path(
    os.environ["EVVA3_STAGE6C_C2"]
)

BOOTSTRAP_REPS = int(
    os.environ.get(
        "EVVA3_STAGE6C_BOOTSTRAP_REPS",
        "2000",
    )
)

EXPECTED_V5M_SHA = (
    "924b6c893036f20ee9d60e90faf34c3beeb0f830af8e6d1c8ffd4dfee904906e"
)

RANDOM_SEED = 20260714
EPSILON = 1e-10

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

AUBC_COUNT = 11

CALIBRATION_SIZES = [
    25,
    50,
    100,
]

EXPECTED_CASES = [
    "dependency_sensitive",
    "corruption_prone",
    "dep_sensitive_held_out",
]

BLOCKS = [
    {
        "name": "C1",
        "path": C1_PATH,
        "calibration_min": 6500,
        "calibration_max": 6599,
        "evaluation_min": 6600,
        "evaluation_max": 6799,
    },
    {
        "name": "C2",
        "path": C2_PATH,
        "calibration_min": 6800,
        "calibration_max": 6899,
        "evaluation_min": 6900,
        "evaluation_max": 7099,
    },
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
    specification = (
        importlib.util.spec_from_file_location(
            name,
            path,
        )
    )

    if (
        specification is None
        or specification.loader is None
    ):
        raise RuntimeError(
            f"Cannot import {path}."
        )

    module = importlib.util.module_from_spec(
        specification
    )

    specification.loader.exec_module(
        module
    )

    return module


if sha256(V5M_PATH) != EXPECTED_V5M_SHA:
    raise RuntimeError(
        "Locked v5m hash mismatch."
    )


LOCKED = import_module(
    "evva3_stage6c_locked",
    V5M_PATH,
)

FINAL = import_module(
    "evva3_stage6c_final",
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


def canonicalize(
    rows: Sequence[Dict[str, str]],
) -> List[Dict[str, object]]:
    output = []

    for raw in rows:
        p = parse_float(
            raw.get("p_score")
        )

        H = parse_float(
            raw.get("harm_score")
        )

        pH = parse_float(
            raw.get("p_times_H_score")
        )

        gain = parse_float(
            raw.get("intervention_gain")
        )

        if any(
            value is None
            for value in [
                p,
                H,
                pH,
                gain,
            ]
        ):
            raise RuntimeError(
                "Missing required numerical value."
            )

        row: Dict[str, object] = dict(raw)

        row["_p"] = float(p)
        row["_H"] = float(H)
        row["_pH"] = float(pH)
        row["_gain"] = float(gain)
        row["_seed"] = parse_seed(
            raw.get("seed")
        )
        row["_case"] = str(
            raw.get(
                "case_type",
                "",
            )
        )

        output.append(row)

    return output


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


def selected_value(
    scores: np.ndarray,
    gains: np.ndarray,
    fraction: float,
) -> float:
    if len(scores) != len(gains):
        raise RuntimeError(
            "Score/gain length mismatch."
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

        required = (
            budget
            - selected_count
        )

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
            "Exact-B tie-aware selection failed."
        )

    return float(
        selected_sum / budget
    )


def curve(
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


def curve_budget_scores(
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


def aubc(
    values: Sequence[float],
) -> float:
    x = np.asarray(
        BUDGETS[:AUBC_COUNT],
        dtype=float,
    )

    y = np.asarray(
        values[:AUBC_COUNT],
        dtype=float,
    )

    return float(
        np.trapz(y, x)
        / (x[-1] - x[0])
    )


def percentile_scores(
    calibration_rows: Sequence[
        Dict[str, object]
    ],
    evaluation_rows: Sequence[
        Dict[str, object]
    ],
    pH_weight: float,
    H_weight: float,
) -> np.ndarray:
    pH_reference = sorted(
        float(row["_pH"])
        for row in calibration_rows
    )

    H_reference = sorted(
        float(row["_H"])
        for row in calibration_rows
    )

    return np.asarray([
        (
            pH_weight
            * float(
                LOCKED.percentile(
                    pH_reference,
                    float(row["_pH"]),
                )
            )
            + H_weight
            * float(
                LOCKED.percentile(
                    H_reference,
                    float(row["_H"]),
                )
            )
        )
        for row in evaluation_rows
    ], dtype=float)


def frozen_final_scores(
    calibration_rows: Sequence[
        Dict[str, object]
    ],
    evaluation_rows: Sequence[
        Dict[str, object]
    ],
) -> np.ndarray:
    scored = FINAL.apply_fixed_bg(
        calibration_rows,
        evaluation_rows,
        "_pH",
        "_H",
    )

    scores = np.asarray([
        float(
            row[
                "_EVVA3_FINAL_BG_score"
            ]
        )
        for row in scored
    ], dtype=float)

    manual = percentile_scores(
        calibration_rows,
        evaluation_rows,
        0.10,
        0.90,
    )

    if not np.allclose(
        scores,
        manual,
        rtol=0.0,
        atol=1e-12,
    ):
        raise RuntimeError(
            "Frozen final-score crosscheck failed."
        )

    return scores


def locked_scores(
    calibration_rows: Sequence[
        Dict[str, object]
    ],
    evaluation_rows: Sequence[
        Dict[str, object]
    ],
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
            "_pH",
            "_H",
            fraction,
        )

        budget = int(
            round(
                fraction * 100
            )
        )

        output[budget] = np.asarray([
            float(
                LOCKED.fnum(
                    row.get(
                        "_EVVA_BG_score"
                    )
                )
            )
            for row in temporary
        ], dtype=float)

    return output


def stable_seed_rank(
    block: str,
    seed: int,
) -> int:
    payload = (
        f"{block}|{seed}|"
        "EVVA3_STAGE6C_CALIBRATION_SUBSET"
    )

    return int(
        hashlib.sha256(
            payload.encode("utf-8")
        ).hexdigest(),
        16,
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


def tie_statistics(
    scores: np.ndarray,
) -> Dict[str, object]:
    counts = Counter(
        float(value)
        for value in scores
    )

    return {
        "rows": len(scores),
        "unique_scores": len(counts),
        "largest_tie": (
            max(counts.values())
            if counts
            else 0
        ),
        "rows_in_nontrivial_ties": sum(
            count
            for count in counts.values()
            if count > 1
        ),
        "nontrivial_tie_groups": sum(
            count > 1
            for count in counts.values()
        ),
        "score_variance": float(
            np.var(scores)
        ),
    }


def bootstrap_deltas(
    final_score: np.ndarray,
    locked_score_by_budget: Dict[
        int,
        np.ndarray,
    ],
    gains: np.ndarray,
    evaluation_rows: Sequence[
        Dict[str, object]
    ],
    repetitions: int,
    rng: np.random.Generator,
) -> List[float]:
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

    seeds = np.asarray(
        sorted(seed_indices),
        dtype=int,
    )

    output = []

    for _ in range(repetitions):
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

        sampled_gains = gains[
            indices
        ]

        final_curve = curve(
            final_score[indices],
            sampled_gains,
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
                    locked_score_by_budget[
                        budget
                    ][indices],
                    sampled_gains,
                    fraction,
                )
            )

        output.append(
            aubc(final_curve)
            - aubc(locked_curve)
        )

    return output


def load_block(
    specification: Dict[str, object],
) -> Dict[str, object]:
    _, raw_rows = read_csv(
        Path(
            specification["path"]
        )
    )

    rows = canonicalize(
        raw_rows
    )

    calibration_rows = [
        row
        for row in rows
        if (
            int(
                specification[
                    "calibration_min"
                ]
            )
            <= int(row["_seed"])
            <= int(
                specification[
                    "calibration_max"
                ]
            )
        )
    ]

    evaluation_rows = [
        row
        for row in rows
        if (
            int(
                specification[
                    "evaluation_min"
                ]
            )
            <= int(row["_seed"])
            <= int(
                specification[
                    "evaluation_max"
                ]
            )
        )
    ]

    if len(calibration_rows) != 300:
        raise RuntimeError(
            f"{specification['name']}: "
            "expected 300 calibration rows."
        )

    if len(evaluation_rows) != 600:
        raise RuntimeError(
            f"{specification['name']}: "
            "expected 600 evaluation rows."
        )

    cases = {
        str(row["_case"])
        for row in rows
    }

    if cases != set(EXPECTED_CASES):
        raise RuntimeError(
            f"{specification['name']}: "
            "unexpected case set."
        )

    return {
        "name": str(
            specification["name"]
        ),
        "path": Path(
            specification["path"]
        ),
        "calibration_rows": (
            calibration_rows
        ),
        "evaluation_rows": (
            evaluation_rows
        ),
    }


def main() -> None:
    blocks = [
        load_block(specification)
        for specification in BLOCKS
    ]

    ablation_rows = []
    aggregate_rows = []
    per_case_rows = []
    calibration_rows_output = []
    calibration_bootstrap_rows = []
    calibration_subset_rows = []
    tie_rows = []
    full_curve_rows = []

    bootstrap_values: Dict[
        Tuple[str, int],
        List[float],
    ] = {}

    rng = np.random.default_rng(
        RANDOM_SEED
    )

    for block in blocks:
        name = str(block["name"])

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

        final_score = frozen_final_scores(
            calibration_rows,
            evaluation_rows,
        )

        locked_score_by_budget = (
            locked_scores(
                calibration_rows,
                evaluation_rows,
            )
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

        curves = {
            "Final-EVVA-SAG": curve(
                final_score,
                gains,
            ),
            "Locked-EVVA-SAG": (
                curve_budget_scores(
                    locked_score_by_budget,
                    gains,
                )
            ),
            "H-only": curve(
                H_score,
                gains,
            ),
            "pH-only": curve(
                pH_score,
                gains,
            ),
            "Raw-scale-BG": curve(
                raw_scale_score,
                gains,
            ),
        }

        curves[
            "Primitive-envelope"
        ] = [
            max(h_value, ph_value)
            for h_value, ph_value in zip(
                curves["H-only"],
                curves["pH-only"],
            )
        ]

        final_aubc = aubc(
            curves["Final-EVVA-SAG"]
        )

        locked_aubc = aubc(
            curves["Locked-EVVA-SAG"]
        )

        for method, method_curve in (
            curves.items()
        ):
            method_aubc = aubc(
                method_curve
            )

            ablation_rows.append({
                "block": name,
                "method": method,
                "aubc_5_90": method_aubc,
                "delta_vs_final_evva_sag": (
                    method_aubc
                    - final_aubc
                ),
                "delta_vs_locked_evva_sag": (
                    method_aubc
                    - locked_aubc
                ),
            })

            for fraction, value in zip(
                BUDGETS,
                method_curve,
            ):
                full_curve_rows.append({
                    "block": name,
                    "method": method,
                    "budget_percent": int(
                        round(
                            fraction * 100
                        )
                    ),
                    "exact_B": exact_b(
                        len(
                            evaluation_rows
                        ),
                        fraction,
                    ),
                    "selected_mean_intervention_gain": value,
                })

        score_lookup = {
            "Final-EVVA-SAG": (
                final_score
            ),
            "H-only": H_score,
            "pH-only": pH_score,
            "Raw-scale-BG": (
                raw_scale_score
            ),
        }

        for method, scores in (
            score_lookup.items()
        ):
            statistics_row = (
                tie_statistics(scores)
            )

            tie_rows.append({
                "block": name,
                "method": method,
                **statistics_row,
            })

        # Per-case behavior uses pooled calibration references
        # and evaluates the frozen ranking within each case slice.
        for case_type in EXPECTED_CASES:
            indices = np.asarray([
                index
                for index, row in enumerate(
                    evaluation_rows
                )
                if row["_case"] == case_type
            ], dtype=int)

            if len(indices) != 200:
                raise RuntimeError(
                    f"{name}/{case_type}: "
                    "expected 200 evaluation rows."
                )

            case_gains = gains[
                indices
            ]

            case_curves = {
                "Final-EVVA-SAG": curve(
                    final_score[indices],
                    case_gains,
                ),
                "Locked-EVVA-SAG": (
                    curve_budget_scores(
                        {
                            budget: values[
                                indices
                            ]
                            for budget, values
                            in locked_score_by_budget.items()
                        },
                        case_gains,
                    )
                ),
                "H-only": curve(
                    H_score[indices],
                    case_gains,
                ),
                "pH-only": curve(
                    pH_score[indices],
                    case_gains,
                ),
                "Raw-scale-BG": curve(
                    raw_scale_score[
                        indices
                    ],
                    case_gains,
                ),
            }

            case_final_aubc = aubc(
                case_curves[
                    "Final-EVVA-SAG"
                ]
            )

            case_locked_aubc = aubc(
                case_curves[
                    "Locked-EVVA-SAG"
                ]
            )

            for method, method_curve in (
                case_curves.items()
            ):
                method_aubc = aubc(
                    method_curve
                )

                per_case_rows.append({
                    "block": name,
                    "case_type": case_type,
                    "method": method,
                    "rows": len(indices),
                    "aubc_5_90": (
                        method_aubc
                    ),
                    "delta_vs_final_evva_sag": (
                        method_aubc
                        - case_final_aubc
                    ),
                    "delta_vs_locked_evva_sag": (
                        method_aubc
                        - case_locked_aubc
                    ),
                })

        # Deterministic nested calibration subsets.
        calibration_seed_set = sorted({
            int(row["_seed"])
            for row in calibration_rows
        })

        ranked_seeds = sorted(
            calibration_seed_set,
            key=lambda seed: (
                stable_seed_rank(
                    name,
                    seed,
                ),
                seed,
            ),
        )

        for calibration_size in (
            CALIBRATION_SIZES
        ):
            selected_seeds = set(
                ranked_seeds[
                    :calibration_size
                ]
            )

            subset = [
                row
                for row in calibration_rows
                if int(
                    row["_seed"]
                ) in selected_seeds
            ]

            if len(subset) != (
                calibration_size * 3
            ):
                raise RuntimeError(
                    f"{name}: calibration "
                    f"subset {calibration_size} "
                    "has wrong row count."
                )

            for rank, seed in enumerate(
                ranked_seeds[
                    :calibration_size
                ],
                start=1,
            ):
                calibration_subset_rows.append({
                    "block": name,
                    "calibration_size_seeds": (
                        calibration_size
                    ),
                    "selection_rank": rank,
                    "seed": seed,
                })

            subset_final_score = (
                frozen_final_scores(
                    subset,
                    evaluation_rows,
                )
            )

            subset_locked_scores = (
                locked_scores(
                    subset,
                    evaluation_rows,
                )
            )

            subset_final_curve = curve(
                subset_final_score,
                gains,
            )

            subset_locked_curve = (
                curve_budget_scores(
                    subset_locked_scores,
                    gains,
                )
            )

            point_delta = (
                aubc(subset_final_curve)
                - aubc(subset_locked_curve)
            )

            calibration_rows_output.append({
                "block": name,
                "calibration_size_seeds": (
                    calibration_size
                ),
                "calibration_rows": len(
                    subset
                ),
                "evaluation_rows": len(
                    evaluation_rows
                ),
                "final_aubc_5_90": aubc(
                    subset_final_curve
                ),
                "locked_aubc_5_90": aubc(
                    subset_locked_curve
                ),
                "delta_aubc": point_delta,
                "final_score_unique": len(
                    np.unique(
                        subset_final_score
                    )
                ),
                "final_score_variance": (
                    float(
                        np.var(
                            subset_final_score
                        )
                    )
                ),
            })

            values = bootstrap_deltas(
                subset_final_score,
                subset_locked_scores,
                gains,
                evaluation_rows,
                BOOTSTRAP_REPS,
                rng,
            )

            bootstrap_values[
                (
                    name,
                    calibration_size,
                )
            ] = values

            calibration_bootstrap_rows.append({
                "analysis": name,
                "calibration_size_seeds": (
                    calibration_size
                ),
                "bootstrap_repetitions": (
                    BOOTSTRAP_REPS
                ),
                "point_delta_aubc": (
                    point_delta
                ),
                "bootstrap_mean_delta": (
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
                "probability_delta_ge_zero": (
                    sum(
                        value >= 0.0
                        for value in values
                    )
                    / len(values)
                ),
            })

    # Aggregate ablations across C1/C2.
    methods = sorted({
        row["method"]
        for row in ablation_rows
    })

    for method in methods:
        rows = [
            row
            for row in ablation_rows
            if row["method"] == method
        ]

        aggregate_rows.append({
            "method": method,
            "blocks": len(rows),
            "mean_aubc_5_90": (
                statistics.fmean(
                    float(
                        row[
                            "aubc_5_90"
                        ]
                    )
                    for row in rows
                )
            ),
            "mean_delta_vs_final_evva_sag": (
                statistics.fmean(
                    float(
                        row[
                            "delta_vs_final_evva_sag"
                        ]
                    )
                    for row in rows
                )
            ),
            "mean_delta_vs_locked_evva_sag": (
                statistics.fmean(
                    float(
                        row[
                            "delta_vs_locked_evva_sag"
                        ]
                    )
                    for row in rows
                )
            ),
            "minimum_block_delta_vs_locked_evva_sag": (
                min(
                    float(
                        row[
                            "delta_vs_locked_evva_sag"
                        ]
                    )
                    for row in rows
                )
            ),
            "positive_blocks_vs_locked_evva_sag": (
                sum(
                    float(
                        row[
                            "delta_vs_locked_evva_sag"
                        ]
                    ) > 0.0
                    for row in rows
                )
            ),
        })

    # Two-level combined bootstrap by calibration size.
    combined_rng = np.random.default_rng(
        RANDOM_SEED + 1
    )

    for calibration_size in (
        CALIBRATION_SIZES
    ):
        c1_values = bootstrap_values[
            ("C1", calibration_size)
        ]

        c2_values = bootstrap_values[
            ("C2", calibration_size)
        ]

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

        point_rows = [
            row
            for row in calibration_rows_output
            if row[
                "calibration_size_seeds"
            ] == calibration_size
        ]

        combined_point = (
            statistics.fmean(
                float(
                    row["delta_aubc"]
                )
                for row in point_rows
            )
        )

        calibration_bootstrap_rows.append({
            "analysis": (
                "Combined-two-level"
            ),
            "calibration_size_seeds": (
                calibration_size
            ),
            "bootstrap_repetitions": (
                BOOTSTRAP_REPS
            ),
            "point_delta_aubc": (
                combined_point
            ),
            "bootstrap_mean_delta": (
                statistics.fmean(
                    combined
                )
            ),
            "ci_2_5": quantile(
                combined,
                0.025,
            ),
            "ci_97_5": quantile(
                combined,
                0.975,
            ),
            "probability_delta_ge_zero": (
                sum(
                    value >= 0.0
                    for value in combined
                )
                / len(combined)
            ),
        })

    calibration_cell_deltas = [
        float(row["delta_aubc"])
        for row in calibration_rows_output
    ]

    case_final_rows = [
        row
        for row in per_case_rows
        if row["method"]
        == "Final-EVVA-SAG"
    ]

    summary = {
        "status": "complete",
        "stage": "EVVA_3 Stage 6C",
        "method": "Final-EVVA-SAG",
        "method_frozen": True,
        "method_modified": False,
        "new_seeds_collected": False,
        "parameter_selection_performed": False,
        "bootstrap_repetitions": (
            BOOTSTRAP_REPS
        ),
        "ablation_methods": methods,
        "calibration_sizes_seeds": (
            CALIBRATION_SIZES
        ),
        "calibration_robustness_cells": len(
            calibration_cell_deltas
        ),
        "positive_calibration_robustness_cells": sum(
            value > 0.0
            for value in calibration_cell_deltas
        ),
        "minimum_calibration_robustness_delta": min(
            calibration_cell_deltas
        ),
        "maximum_calibration_robustness_delta": max(
            calibration_cell_deltas
        ),
        "per_case_final_rows": len(
            case_final_rows
        ),
        "per_case_final_positive_vs_locked": sum(
            float(
                row[
                    "delta_vs_locked_evva_sag"
                ]
            ) > 0.0
            for row in case_final_rows
        ),
        "interpretation": (
            "Secondary robustness and ablation "
            "analyses only. Results cannot be used "
            "to alter the frozen method."
        ),
    }

    write_csv(
        OUT
        / "results"
        / "ablation_by_block.csv",
        ablation_rows,
        [
            "block",
            "method",
            "aubc_5_90",
            "delta_vs_final_evva_sag",
            "delta_vs_locked_evva_sag",
        ],
    )

    write_csv(
        OUT
        / "results"
        / "ablation_aggregate.csv",
        aggregate_rows,
        [
            "method",
            "blocks",
            "mean_aubc_5_90",
            "mean_delta_vs_final_evva_sag",
            "mean_delta_vs_locked_evva_sag",
            "minimum_block_delta_vs_locked_evva_sag",
            "positive_blocks_vs_locked_evva_sag",
        ],
    )

    write_csv(
        OUT
        / "results"
        / "per_case.csv",
        per_case_rows,
        [
            "block",
            "case_type",
            "method",
            "rows",
            "aubc_5_90",
            "delta_vs_final_evva_sag",
            "delta_vs_locked_evva_sag",
        ],
    )

    write_csv(
        OUT
        / "results"
        / "calibration_size.csv",
        calibration_rows_output,
        [
            "block",
            "calibration_size_seeds",
            "calibration_rows",
            "evaluation_rows",
            "final_aubc_5_90",
            "locked_aubc_5_90",
            "delta_aubc",
            "final_score_unique",
            "final_score_variance",
        ],
    )

    write_csv(
        OUT
        / "results"
        / "calibration_size_bootstrap.csv",
        calibration_bootstrap_rows,
        [
            "analysis",
            "calibration_size_seeds",
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
        / "manifests"
        / "calibration_seed_subsets.csv",
        calibration_subset_rows,
        [
            "block",
            "calibration_size_seeds",
            "selection_rank",
            "seed",
        ],
    )

    write_csv(
        OUT
        / "results"
        / "score_ties.csv",
        tie_rows,
        [
            "block",
            "method",
            "rows",
            "unique_scores",
            "largest_tie",
            "rows_in_nontrivial_ties",
            "nontrivial_tie_groups",
            "score_variance",
        ],
    )

    write_csv(
        OUT
        / "results"
        / "full_curves.csv",
        full_curve_rows,
        [
            "block",
            "method",
            "budget_percent",
            "exact_B",
            "selected_mean_intervention_gain",
        ],
    )

    with (
        OUT
        / "reports"
        / "stage6c_summary.json"
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

    specification = {
        "stage": "EVVA_3 Stage 6C",
        "status": "post-confirmatory secondary analysis",
        "method_selection": False,
        "method_modification": False,
        "ablation_definitions": {
            "Final-EVVA-SAG": (
                "0.10 percentile(pH) "
                "+ 0.90 percentile(H)"
            ),
            "Locked-EVVA-SAG": (
                "original budget-dependent "
                "unavailable-signal fallback"
            ),
            "H-only": (
                "remove pH component"
            ),
            "pH-only": (
                "remove H component"
            ),
            "Raw-scale-BG": (
                "remove percentile normalization "
                "while preserving frozen weights"
            ),
            "Primitive-envelope": (
                "per-budget maximum of H-only "
                "and pH-only; nondeployable diagnostic"
            ),
        },
        "calibration_subset_rule": (
            "nested deterministic SHA256 ranking "
            "of calibration seeds"
        ),
        "calibration_sizes_seeds": (
            CALIBRATION_SIZES
        ),
        "bootstrap_repetitions": (
            BOOTSTRAP_REPS
        ),
    }

    with (
        OUT
        / "manifests"
        / "stage6c_specification.json"
    ).open(
        "w",
        encoding="utf-8",
    ) as handle:
        json.dump(
            specification,
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
echo "EVVA_3 STAGE 6C FINAL ABLATION + ROBUSTNESS"
echo "===================================================="
echo "Output: $OUT"
echo "Bootstrap repetitions: $BOOTSTRAP_REPS"
echo

python3 -m py_compile \
  "$OUT/code/aaai_evva3_stage6c_ablation_robustness.py" \
  || die "Stage 6C evaluator failed py_compile."

python3 \
  "$OUT/code/aaai_evva3_stage6c_ablation_robustness.py" \
  2>&1 | tee "$OUT/logs/stage6c.log"

STATUS="${PIPESTATUS[0]}"

[ "$STATUS" -eq 0 ] \
  || die "Stage 6C evaluation failed."

for required in \
  "$OUT/reports/stage6c_summary.json" \
  "$OUT/results/ablation_by_block.csv" \
  "$OUT/results/ablation_aggregate.csv" \
  "$OUT/results/per_case.csv" \
  "$OUT/results/calibration_size.csv" \
  "$OUT/results/calibration_size_bootstrap.csv" \
  "$OUT/results/score_ties.csv" \
  "$OUT/results/full_curves.csv"
do
  [ -f "$required" ] \
    || die "Missing Stage 6C output: $required"
done

{
  sha256sum "$V5M"
  sha256sum "$FINAL_METHOD"
  sha256sum "$C1_RAW"
  sha256sum "$C2_RAW"
  sha256sum "$CONFIRMATORY_DECISION"
  sha256sum "$REPLAY_SUMMARY"
} > "$OUT/hashes/post_stage6c_sha256.txt"

cmp -s \
  "$OUT/hashes/pre_stage6c_sha256.txt" \
  "$OUT/hashes/post_stage6c_sha256.txt" \
  || die "A frozen input changed during Stage 6C."

cat > "$OUT/reports/STAGE6C_COMPLETE.md" <<'MD'
# EVVA_3 Stage 6C completion

The frozen Final-EVVA-SAG method was evaluated using component ablations,
normalization ablation, deterministic calibration-size sensitivity,
seed-cluster bootstrap, per-case analysis, and score-tie diagnostics.

These are post-confirmatory secondary analyses.

No new seed was collected. No method, weight, budget rule, comparator,
confirmation decision, or preregistered criterion was changed.
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
echo "EVVA_3 STAGE 6C COMPLETE"
echo "===================================================="
echo "Output: $OUT"
echo

echo "===== SUMMARY ====="
cat "$OUT/reports/stage6c_summary.json"

echo
echo "===== ABLATION AGGREGATE ====="
column -s, -t \
  < "$OUT/results/ablation_aggregate.csv"

echo
echo "===== CALIBRATION SIZE ====="
column -s, -t \
  < "$OUT/results/calibration_size.csv"

echo
echo "===== CALIBRATION BOOTSTRAP ====="
column -s, -t \
  < "$OUT/results/calibration_size_bootstrap.csv"

echo
echo "PASS: Stage 6C completed without changing frozen inputs."

#!/usr/bin/env bash

die() {
    echo
    echo "===================================================="
    echo "ERROR: $1"
    echo "The child script stopped. The interactive terminal remains open."
    echo "===================================================="
    exit 1
}

WORKSPACE="$HOME/.openclaw/workspace/skills/openclaw_pilot_v4_large_exactB_20260707_EVVA_2_explore_20260713"

ARTIFACT_ROOT="artifacts/aaai_evva2_exploratory_20260713"

RUN_ROOT="$ARTIFACT_ROOT/evva2h_final_confirmation_20260713"

METHOD="code/aaai_evva2h_severe_plateau_gate.py"

V5M="code/aaai_v5m_signal_availability_gated_evva.py"

EVVA2G="code/aaai_evva2g_calibration_compression_gate.py"

COLLECTOR="code/aaai_v4_full_agent_candidate_collector.py"

EXPECTED_V5M_HASH="924b6c893036f20ee9d60e90faf34c3beeb0f830af8e6d1c8ffd4dfee904906e"

EXPECTED_EVVA2G_HASH="5e8c7a94bd203bd9c323c3d53ff74e0bac3f4ad650d0edc8b0dde5253ccf3d8f"

cd "$WORKSPACE" ||
    die "Workspace was not found."

for REQUIRED in \
    "$V5M" \
    "$EVVA2G" \
    "$COLLECTOR"
do
    [[ -f "$REQUIRED" ]] ||
        die "Missing required file: $REQUIRED"
done

OBSERVED_V5M_HASH="$(
    sha256sum "$V5M" |
    awk '{print $1}'
)"

OBSERVED_EVVA2G_HASH="$(
    sha256sum "$EVVA2G" |
    awk '{print $1}'
)"

[[ "$OBSERVED_V5M_HASH" == "$EXPECTED_V5M_HASH" ]] ||
    die "Locked v5m hash mismatch."

[[ "$OBSERVED_EVVA2G_HASH" == "$EXPECTED_EVVA2G_HASH" ]] ||
    die "Frozen EVVA_2G hash mismatch."

mkdir -p \
    "$RUN_ROOT/manifests" \
    "$RUN_ROOT/logs" \
    "$RUN_ROOT/code_snapshot" ||
    die "Failed to create EVVA_2H directories."

TEMP_METHOD="$RUN_ROOT/manifests/aaai_evva2h_severe_plateau_gate.tmp.py"

cat > "$TEMP_METHOD" <<'PY'
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
PY

if [[ -e "$METHOD" ]]; then
    cmp -s \
        "$METHOD" \
        "$TEMP_METHOD" ||
        die "An existing EVVA_2H method differs from the frozen specification."
else
    mv \
        "$TEMP_METHOD" \
        "$METHOD" ||
        die "Failed to install the EVVA_2H method."
fi

rm -f "$TEMP_METHOD"

python3 -m py_compile \
    "$METHOD" \
    "$COLLECTOR" ||
    die "EVVA_2H or collector syntax validation failed."

echo "PASS: EVVA_2H syntax validation completed."

EVVA2H_HASH="$(
    sha256sum "$METHOD" |
    awk '{print $1}'
)"

echo "EVVA_2H hash: $EVVA2H_HASH"

PREREG_TEMP="$RUN_ROOT/manifests/evva2h_preregistration.tmp.md"

cat > "$PREREG_TEMP" <<EOF
# EVVA_2H Severe-Plateau Gate Preregistration

Date: 2026-07-13

## Frozen method

Method: EVVA_2H Severe-Plateau Gate

Method hash:

\`\`\`text
$EVVA2H_HASH
\`\`\`

Locked v5m hash:

\`\`\`text
$OBSERVED_V5M_HASH
\`\`\`

Frozen EVVA_2G development-method hash:

\`\`\`text
$OBSERVED_EVVA2G_HASH
\`\`\`

## Structural score

The structural refinement score is the equal-weight mean of
calibration percentile ranks for:

- rollback_difficulty
- persistent_state_risk
- log1p(downstream_dependency_count)

Only decision-time structural features are used.

## Frozen gate

Structural refinement is active only when all conditions hold:

1. The H boundary is a partial exact-B boundary.
2. H boundary size divided by calibration-pool size is at least 0.20.
3. H_struct boundary size divided by H boundary size is at most 0.25.
4. H_struct strictly reduces the H boundary.

Otherwise, the method returns the locked v5m fallback value.

The thresholds 0.20 and 0.25 are frozen before R4 and R5 collection.

## Confirmation blocks

### R4

- Collection seeds: 5900-6199
- Calibration seeds: 5900-5999
- Evaluation seeds: 6000-6199
- Expected rows: 900

### R5

- Collection seeds: 6200-6499
- Calibration seeds: 6200-6299
- Evaluation seeds: 6300-6499
- Expected rows: 900

## Primary evaluation

- Primary budget: large 40%
- Primary comparison: EVVA_2H minus locked v5m
- Bootstrap unit: evaluation seed cluster with all three cases
- Independent evaluations: R4 and R5
- Pooled evaluation: equal-block stratified R4-R5 bootstrap

## Success criteria

All of the following are required:

1. No new EVVA_2H loss relative to locked v5m in R4 or R5.
2. EVVA_2H has more strict wins than v5m in the pooled summary.
3. Pooled 40% point delta is positive.
4. Pooled P(delta >= 0) is at least 0.95.
5. Pooled 40% bootstrap 95% confidence-interval lower bound is positive.

R2 and R3 are development evidence and are not part of the R4-R5
primary confirmatory test.

No gate threshold, feature formula, budget set, or fallback rule may
be changed after R4 collection begins.
EOF

PREREG="$RUN_ROOT/manifests/evva2h_preregistration.md"

if [[ -e "$PREREG" ]]; then
    cmp -s \
        "$PREREG" \
        "$PREREG_TEMP" ||
        die "Existing EVVA_2H preregistration differs from the frozen specification."
else
    mv \
        "$PREREG_TEMP" \
        "$PREREG" ||
        die "Failed to install the preregistration."
fi

rm -f "$PREREG_TEMP"

snapshot_file() {
    SOURCE="$1"
    DESTINATION="$2"

    if [[ -e "$DESTINATION" ]]; then
        cmp -s \
            "$SOURCE" \
            "$DESTINATION" ||
            die "Code snapshot mismatch: $DESTINATION"
    else
        cp \
            "$SOURCE" \
            "$DESTINATION" ||
            die "Failed to create code snapshot: $DESTINATION"

        chmod a-w "$DESTINATION"
    fi
}

snapshot_file \
    "$METHOD" \
    "$RUN_ROOT/code_snapshot/aaai_evva2h_severe_plateau_gate.py"

snapshot_file \
    "$V5M" \
    "$RUN_ROOT/code_snapshot/aaai_v5m_signal_availability_gated_evva.py"

snapshot_file \
    "$EVVA2G" \
    "$RUN_ROOT/code_snapshot/aaai_evva2g_calibration_compression_gate.py"

snapshot_file \
    "$COLLECTOR" \
    "$RUN_ROOT/code_snapshot/aaai_v4_full_agent_candidate_collector.py"

sha256sum \
    "$METHOD" \
    "$V5M" \
    "$EVVA2G" \
    "$COLLECTOR" \
    "$PREREG" \
    > "$RUN_ROOT/manifests/pre_collection_SHA256SUMS.txt" ||
    die "Failed to record pre-collection hashes."

chmod a-w "$METHOD"

echo "PASS: EVVA_2H method and preregistration frozen."

python3 - \
    "$ARTIFACT_ROOT" \
    "$RUN_ROOT" \
    5900 \
    6499 \
    <<'PY_PREFLIGHT'
import csv
import sys
from pathlib import Path


artifact_root = Path(
    sys.argv[1]
).resolve()

run_root = Path(
    sys.argv[2]
).resolve()

seed_min = int(
    sys.argv[3]
)

seed_max = int(
    sys.argv[4]
)


conflicts = []


for path in artifact_root.rglob(
    "full_agent_candidate_rows*.csv"
):
    resolved = path.resolve()

    try:
        resolved.relative_to(
            run_root
        )

        continue
    except ValueError:
        pass

    try:
        with path.open(
            newline=""
        ) as handle:
            reader = csv.DictReader(
                handle
            )

            if (
                reader.fieldnames is None
                or "seed" not in reader.fieldnames
            ):
                continue

            overlap = set()

            for row in reader:
                try:
                    seed = int(
                        float(
                            row["seed"]
                        )
                    )
                except Exception:
                    continue

                if seed_min <= seed <= seed_max:
                    overlap.add(seed)

            if overlap:
                conflicts.append(
                    (
                        str(path),
                        min(overlap),
                        max(overlap),
                        len(overlap),
                    )
                )
    except Exception:
        continue


if conflicts:
    print(
        "ERROR: Proposed R4/R5 seeds already appear "
        "outside the EVVA_2H run root."
    )

    for path, first, last, count in conflicts:
        print(
            f"- {path}: {count} overlapping seeds "
            f"from {first} to {last}"
        )

    raise SystemExit(1)


print(
    "PASS: No prior full-agent rows use seeds 5900-6499."
)
PY_PREFLIGHT

PREFLIGHT_STATUS=$?

[[ $PREFLIGHT_STATUS -eq 0 ]] ||
    die "Untouched-seed preflight failed."

SPECS=(
    "r4 5900 6199 5900 5999 6000 6199"
    "r5 6200 6499 6200 6299 6300 6499"
)

for SPEC in "${SPECS[@]}"; do
    read -r \
        BLOCK \
        START \
        END \
        CAL_START \
        CAL_END \
        EVAL_START \
        EVAL_END \
        <<< "$SPEC"

    BLOCK_ROOT="$RUN_ROOT/${BLOCK}_${START}_${END}"

    RAW="$BLOCK_ROOT/raw/full_agent_candidate_rows_${START}_${END}.csv"

    mkdir -p \
        "$BLOCK_ROOT/raw" \
        "$BLOCK_ROOT/logs" \
        "$BLOCK_ROOT/collector_logs" \
        "$BLOCK_ROOT/manifests" ||
        die "Failed to create directories for ${BLOCK^^}."

    cat > "$BLOCK_ROOT/manifests/block_split_lock.md" <<EOF
# EVVA_2H ${BLOCK^^} Split Lock

- Collection seeds: ${START}-${END}
- Calibration seeds: ${CAL_START}-${CAL_END}
- Evaluation seeds: ${EVAL_START}-${EVAL_END}
- Cases: dependency_sensitive, corruption_prone, dep_sensitive_held_out
- Agent variant: openclaw_default
- Expected rows: 900
- Frozen method hash: ${EVVA2H_HASH}
EOF

    if [[ -e "$RAW" ]]; then
        chmod u+w "$RAW" 2>/dev/null || true
    fi

    echo
    echo "===================================================="
    echo "COLLECTING ${BLOCK^^}: ${START}-${END}"
    echo "===================================================="

    python3 "$COLLECTOR" \
        --cases \
            dependency_sensitive \
            corruption_prone \
            dep_sensitive_held_out \
        --seeds "${START}-${END}" \
        --agent-variants openclaw_default \
        --out "$RAW" \
        --log-dir "$BLOCK_ROOT/collector_logs" \
        | tee "$BLOCK_ROOT/logs/collection.log"

    COLLECT_STATUS=${PIPESTATUS[0]}

    [[ $COLLECT_STATUS -eq 0 ]] ||
        die "Collection failed for ${BLOCK^^}."

    python3 - \
        "$RAW" \
        "$START" \
        "$END" \
        "$CAL_START" \
        "$CAL_END" \
        "$EVAL_START" \
        "$EVAL_END" \
        <<'PY_AUDIT'
import csv
import math
import sys
from collections import Counter
from pathlib import Path


path = Path(
    sys.argv[1]
)

start = int(
    sys.argv[2]
)

end = int(
    sys.argv[3]
)

cal_start = int(
    sys.argv[4]
)

cal_end = int(
    sys.argv[5]
)

eval_start = int(
    sys.argv[6]
)

eval_end = int(
    sys.argv[7]
)


required_columns = {
    "experiment_id",
    "task_id",
    "episode_id",
    "case_type",
    "seed",
    "agent_variant",
    "candidate_id",
    "decision_point_id",
    "p_score",
    "harm_score",
    "p_times_H_score",
    "rollback_difficulty",
    "persistent_state_risk",
    "downstream_dependency_count",
    "intervention_gain",
}


with path.open(
    newline=""
) as handle:
    rows = list(
        csv.DictReader(handle)
    )


header = (
    set(rows[0])
    if rows
    else set()
)


seeds = sorted({
    int(
        float(
            row["seed"]
        )
    )
    for row in rows
})


cases = Counter(
    row["case_type"]
    for row in rows
)


calibration_rows = [
    row
    for row in rows
    if (
        cal_start
        <= int(
            float(
                row["seed"]
            )
        )
        <= cal_end
    )
]


evaluation_rows = [
    row
    for row in rows
    if (
        eval_start
        <= int(
            float(
                row["seed"]
            )
        )
        <= eval_end
    )
]


candidate_keys = [
    (
        row.get(
            "experiment_id",
            "",
        ),
        row.get(
            "task_id",
            "",
        ),
        row.get(
            "episode_id",
            "",
        ),
        row.get(
            "candidate_id",
            "",
        ),
        row.get(
            "decision_point_id",
            "",
        ),
    )
    for row in rows
]


expected_cases = {
    "dependency_sensitive",
    "corruption_prone",
    "dep_sensitive_held_out",
}


def finite_column(column):
    try:
        return all(
            math.isfinite(
                float(
                    row[column]
                )
            )
            for row in rows
        )
    except Exception:
        return False


checks = {
    "row_count_900": (
        len(rows) == 900
    ),
    "seed_count_300": (
        len(seeds) == 300
    ),
    "seed_range": (
        bool(seeds)
        and min(seeds) == start
        and max(seeds) == end
    ),
    "case_names": (
        set(cases)
        == expected_cases
    ),
    "each_case_300": all(
        cases[case] == 300
        for case in expected_cases
    ),
    "calibration_rows_300": (
        len(calibration_rows) == 300
    ),
    "evaluation_rows_600": (
        len(evaluation_rows) == 600
    ),
    "unique_candidate_keys": (
        len(candidate_keys)
        == len(
            set(candidate_keys)
        )
    ),
    "required_columns_present": (
        not (
            required_columns
            - header
        )
    ),
    "no_policy_column": (
        "policy" not in header
    ),
    "finite_rollback_difficulty": (
        finite_column(
            "rollback_difficulty"
        )
    ),
    "finite_persistent_state_risk": (
        finite_column(
            "persistent_state_risk"
        )
    ),
    "finite_dependency_count": (
        finite_column(
            "downstream_dependency_count"
        )
    ),
    "finite_intervention_gain": (
        finite_column(
            "intervention_gain"
        )
    ),
}


print(
    "===================================================="
)

print(
    "EVVA_2H COLLECTION AUDIT"
)

print(
    "===================================================="
)

print(
    f"File: {path}"
)

print(
    f"Rows: {len(rows)}"
)

print(
    f"Seeds: {len(seeds)}"
)

print(
    "Seed range: "
    + (
        f"{min(seeds)}-{max(seeds)}"
        if seeds
        else "none"
    )
)

print(
    f"Cases: {dict(sorted(cases.items()))}"
)

print(
    f"Calibration rows: {len(calibration_rows)}"
)

print(
    f"Evaluation rows: {len(evaluation_rows)}"
)

print()


for name, passed in checks.items():
    print(
        f"{'PASS' if passed else 'FAIL'}: {name}"
    )


overall = all(
    checks.values()
)


print()

print(
    "OVERALL: "
    + (
        "PASS"
        if overall
        else "FAIL"
    )
)


if not overall:
    raise SystemExit(1)
PY_AUDIT

    AUDIT_STATUS=$?

    [[ $AUDIT_STATUS -eq 0 ]] ||
        die "Collection audit failed for ${BLOCK^^}."

    sha256sum \
        "$RAW" \
        > "$BLOCK_ROOT/manifests/raw_SHA256SUMS.txt" ||
        die "Failed to record raw-data hash for ${BLOCK^^}."

    chmod a-w "$RAW"

    echo "PASS: ${BLOCK^^} untouched dataset is ready."
done

sha256sum -c \
    "$RUN_ROOT/manifests/pre_collection_SHA256SUMS.txt" ||
    die "A frozen source or preregistration file changed during collection."

echo
echo "===================================================="
echo "EVVA_2H R4/R5 COLLECTION COMPLETE"
echo "===================================================="

echo "EVVA_2H hash: $EVVA2H_HASH"
echo "PASS: R4 dataset ready."
echo "PASS: R5 dataset ready."
echo "PASS: Frozen v5m unchanged."
echo "PASS: Frozen EVVA_2G unchanged."
echo "PASS: EVVA_2H method unchanged."
echo "The interactive terminal remains open."

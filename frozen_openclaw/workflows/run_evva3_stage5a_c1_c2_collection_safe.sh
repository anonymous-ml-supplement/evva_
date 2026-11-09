#!/usr/bin/env bash

# EVVA_3 Stage 5A:
# Collect both untouched C1 and C2 blocks before evaluating either block.
#
# C1:
#   all seeds:         6500-6799
#   calibration seeds: 6500-6599
#   evaluation seeds:  6600-6799
#
# C2:
#   all seeds:         6800-7099
#   calibration seeds: 6800-6899
#   evaluation seeds:  6900-7099
#
# This stage performs structural integrity checks only.
# It does not calculate performance, curves, AUBC, or margins.

die() {
  echo "ERROR: $*" >&2
  exit 1
}

WORKSPACE="$HOME/.openclaw/workspace/skills/openclaw_pilot_v4_large_exactB_20260707_EVVA_3_signal_repair_20260713"

COLLECTOR="code/evva_v4_full_agent_candidate_collector.py"
V5M="code/evva_v5m_signal_availability_gated_evva.py"

EXPECTED_V5M_SHA="924b6c893036f20ee9d60e90faf34c3beeb0f830af8e6d1c8ffd4dfee904906e"

CASES=(
  dependency_sensitive
  corruption_prone
  dep_sensitive_held_out
)

AGENT_VARIANT="openclaw_default"

OUT="artifacts/evva3_stage5a_c1_c2_untouched_20260714"

C1_ROOT="$OUT/c1_6500_6799"
C2_ROOT="$OUT/c2_6800_7099"

C1_RAW="$C1_ROOT/raw/full_agent_candidate_rows_6500_6799.csv"
C2_RAW="$C2_ROOT/raw/full_agent_candidate_rows_6800_7099.csv"

[ -d "$WORKSPACE" ] \
  || die "Workspace not found: $WORKSPACE"

cd "$WORKSPACE" \
  || die "Cannot enter workspace."

[ -f "$COLLECTOR" ] \
  || die "Collector not found: $COLLECTOR"

[ -f "$V5M" ] \
  || die "Locked v5m not found."

ACTUAL_V5M_SHA="$(
  sha256sum "$V5M" |
  awk '{print $1}'
)"

[ "$ACTUAL_V5M_SHA" = "$EXPECTED_V5M_SHA" ] \
  || die "Locked v5m hash mismatch."

[ -f artifacts/evva3_stage4f_latest.txt ] \
  || die "Stage 4F freeze pointer is missing."

FREEZE_ROOT="$(
  cat artifacts/evva3_stage4f_latest.txt
)"

FINAL_METHOD="$FREEZE_ROOT/code/evva3_final_evva_sag.py"
PREREGISTRATION="$FREEZE_ROOT/manifests/C1_C2_PREREGISTRATION.json"
FREEZE_REPORT="$FREEZE_ROOT/reports/FINAL_METHOD_FREEZE.md"

[ -f "$FINAL_METHOD" ] \
  || die "Frozen final method is missing."

[ -f "$PREREGISTRATION" ] \
  || die "C1/C2 preregistration is missing."

[ -f "$FREEZE_REPORT" ] \
  || die "Final method freeze report is missing."

mkdir -p \
  "$OUT/code" \
  "$OUT/hashes" \
  "$OUT/logs" \
  "$OUT/manifests" \
  "$OUT/reports" \
  "$OUT/preflight" \
  "$C1_ROOT/raw" \
  "$C1_ROOT/collector_logs" \
  "$C2_ROOT/raw" \
  "$C2_ROOT/collector_logs" \
  || die "Cannot create Stage 5A directories."

echo "$OUT" \
  > artifacts/evva3_stage5a_latest.txt

python3 -m py_compile \
  "$COLLECTOR" \
  || die "Collector failed py_compile."

python3 -m py_compile \
  "$FINAL_METHOD" \
  || die "Frozen final method failed py_compile."

# Verify the frozen preregistration before collecting either block.
export EVVA3_STAGE5A_PREREGISTRATION="$PREREGISTRATION"

python3 - <<'PY' \
  || die "C1/C2 preregistration validation failed."
import json
import os
from pathlib import Path


path = Path(
    os.environ[
        "EVVA3_STAGE5A_PREREGISTRATION"
    ]
)

with path.open(
    encoding="utf-8"
) as handle:
    data = json.load(handle)

expected = [
    {
        "name": "C1",
        "all_seeds": "6500-6799",
        "calibration_seeds": "6500-6599",
        "evaluation_seeds": "6600-6799",
    },
    {
        "name": "C2",
        "all_seeds": "6800-7099",
        "calibration_seeds": "6800-6899",
        "evaluation_seeds": "6900-7099",
    },
]

actual = data.get(
    "confirmation_blocks"
)

if actual != expected:
    raise SystemExit(
        "Frozen confirmation ranges do not match "
        "the expected C1/C2 specification."
    )

method = data.get(
    "method",
    {}
)

if not method.get(
    "same_unavailable_ranking_at_all_budgets"
):
    raise SystemExit(
        "Frozen unified fallback rule is absent."
    )

print("PREREGISTRATION_VALIDATION=PASS")
PY

{
  sha256sum "$COLLECTOR"
  sha256sum "$V5M"
  sha256sum "$FINAL_METHOD"
  sha256sum "$PREREGISTRATION"
  sha256sum "$FREEZE_REPORT"
} > "$OUT/hashes/pre_collection_frozen_sha256.txt"

# Check that C1/C2 seeds do not already exist outside this resumable
# Stage 5A output directory.
export EVVA3_STAGE5A_OUT="$OUT"

python3 - <<'PY' \
  || die "Untouched-seed preflight failed."
import csv
import json
import os
from pathlib import Path


root = Path("artifacts")
stage5a = Path(
    os.environ["EVVA3_STAGE5A_OUT"]
).resolve()

overlaps = []

for path in root.rglob("*.csv"):
    try:
        resolved = path.resolve()
    except OSError:
        continue

    try:
        resolved.relative_to(stage5a)
        continue
    except ValueError:
        pass

    try:
        with path.open(
            newline="",
            encoding="utf-8-sig",
        ) as handle:
            reader = csv.DictReader(handle)

            if not reader.fieldnames:
                continue

            if "seed" not in reader.fieldnames:
                continue

            for row_number, row in enumerate(
                reader,
                start=2,
            ):
                try:
                    seed = int(
                        round(
                            float(
                                str(
                                    row.get(
                                        "seed",
                                        "",
                                    )
                                ).strip()
                            )
                        )
                    )
                except Exception:
                    continue

                if 6500 <= seed <= 7099:
                    overlaps.append({
                        "path": str(path),
                        "row_number": row_number,
                        "seed": seed,
                    })

                    if len(overlaps) >= 200:
                        break
    except Exception:
        continue

report_path = (
    Path(
        os.environ["EVVA3_STAGE5A_OUT"]
    )
    / "preflight"
    / "existing_c1_c2_seed_rows.json"
)

with report_path.open(
    "w",
    encoding="utf-8",
) as handle:
    json.dump(
        {
            "overlap_count": len(overlaps),
            "overlaps": overlaps,
        },
        handle,
        indent=2,
        sort_keys=True,
    )

if overlaps:
    raise SystemExit(
        "C1/C2 seed rows already exist outside "
        "the resumable Stage 5A directory."
    )

print("UNTOUCHED_SEED_PREFLIGHT=PASS")
PY

cat > "$OUT/manifests/COLLECTION_PLAN.json" <<'JSON'
{
  "stage": "EVVA_3 Stage 5A",
  "status": "collection_started",
  "evaluation_performed": false,
  "outcome_summary_performed": false,
  "collect_both_before_evaluation": true,
  "cases": [
    "dependency_sensitive",
    "corruption_prone",
    "dep_sensitive_held_out"
  ],
  "agent_variant": "openclaw_default",
  "blocks": [
    {
      "name": "C1",
      "all_seeds": "6500-6799",
      "calibration_seeds": "6500-6599",
      "evaluation_seeds": "6600-6799",
      "expected_rows": 900
    },
    {
      "name": "C2",
      "all_seeds": "6800-7099",
      "calibration_seeds": "6800-6899",
      "evaluation_seeds": "6900-7099",
      "expected_rows": 900
    }
  ]
}
JSON

echo
echo "===================================================="
echo "EVVA_3 STAGE 5A — COLLECTING C1"
echo "===================================================="
echo "Seeds: 6500-6799"
echo "Output: $C1_RAW"
echo

python3 "$COLLECTOR" \
  --cases "${CASES[@]}" \
  --seeds "6500-6799" \
  --agent-variants "$AGENT_VARIANT" \
  --out "$C1_RAW" \
  --log-dir "$C1_ROOT/collector_logs" \
  2>&1 | tee "$OUT/logs/c1_collector_console.log"

C1_STATUS="${PIPESTATUS[0]}"

[ "$C1_STATUS" -eq 0 ] \
  || die "C1 collector failed with status $C1_STATUS."

[ -f "$C1_RAW" ] \
  || die "C1 raw CSV was not created."

echo
echo "===================================================="
echo "EVVA_3 STAGE 5A — COLLECTING C2"
echo "===================================================="
echo "Seeds: 6800-7099"
echo "Output: $C2_RAW"
echo

python3 "$COLLECTOR" \
  --cases "${CASES[@]}" \
  --seeds "6800-7099" \
  --agent-variants "$AGENT_VARIANT" \
  --out "$C2_RAW" \
  --log-dir "$C2_ROOT/collector_logs" \
  2>&1 | tee "$OUT/logs/c2_collector_console.log"

C2_STATUS="${PIPESTATUS[0]}"

[ "$C2_STATUS" -eq 0 ] \
  || die "C2 collector failed with status $C2_STATUS."

[ -f "$C2_RAW" ] \
  || die "C2 raw CSV was not created."

# Structural audit only. Do not calculate gain distributions or
# confirmation performance.
export EVVA3_STAGE5A_C1_RAW="$C1_RAW"
export EVVA3_STAGE5A_C2_RAW="$C2_RAW"

cat > "$OUT/code/evva3_stage5a_collection_integrity.py" <<'PY'
#!/usr/bin/env python3

"""Outcome-blind C1/C2 collection-integrity audit.

This audit checks:

- exact seed ranges;
- 300 unique seeds per block;
- three formal cases per seed;
- 900 rows per block;
- one openclaw_default row per seed/case;
- no duplicates;
- required schema and nonblank fields;
- C1/C2 seed separation;
- trace provenance availability.

It deliberately does not calculate gain means, curves, AUBC,
oracle regret, method margins, or winner counts.
"""

import csv
import hashlib
import json
import os
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Sequence, Tuple


OUT = Path(
    os.environ["EVVA3_STAGE5A_OUT"]
)

BLOCKS = [
    {
        "name": "C1",
        "path": Path(
            os.environ["EVVA3_STAGE5A_C1_RAW"]
        ),
        "seed_min": 6500,
        "seed_max": 6799,
        "calibration_min": 6500,
        "calibration_max": 6599,
        "evaluation_min": 6600,
        "evaluation_max": 6799,
    },
    {
        "name": "C2",
        "path": Path(
            os.environ["EVVA3_STAGE5A_C2_RAW"]
        ),
        "seed_min": 6800,
        "seed_max": 7099,
        "calibration_min": 6800,
        "calibration_max": 6899,
        "evaluation_min": 6900,
        "evaluation_max": 7099,
    },
]

EXPECTED_CASES = {
    "dependency_sensitive",
    "corruption_prone",
    "dep_sensitive_held_out",
}

REQUIRED_COLUMNS = [
    "experiment_id",
    "case_type",
    "seed",
    "agent_variant",
    "candidate_id",
    "p_score",
    "harm_score",
    "p_times_H_score",
    "rollback_difficulty",
    "persistent_state_risk",
    "downstream_dependency_count",
    "branch_harm_exact",
    "reward_wrong_continuation",
    "reward_corrected_continuation",
    "intervention_gain",
    "verification_cost",
    "trace_path",
    "notes",
]

REQUIRED_NONBLANK = [
    "case_type",
    "seed",
    "agent_variant",
    "candidate_id",
    "p_score",
    "harm_score",
    "p_times_H_score",
    "rollback_difficulty",
    "persistent_state_risk",
    "downstream_dependency_count",
    "branch_harm_exact",
    "reward_wrong_continuation",
    "reward_corrected_continuation",
    "intervention_gain",
    "verification_cost",
    "trace_path",
    "notes",
]


def sha256(path: Path) -> str:
    digest = hashlib.sha256()

    with path.open("rb") as handle:
        for chunk in iter(
            lambda: handle.read(
                1024 * 1024
            ),
            b"",
        ):
            digest.update(chunk)

    return digest.hexdigest()


def read_rows(
    path: Path,
) -> Tuple[List[str], List[Dict[str, str]]]:
    with path.open(
        newline="",
        encoding="utf-8-sig",
    ) as handle:
        reader = csv.DictReader(handle)

        return (
            list(reader.fieldnames or []),
            list(reader),
        )


def seed_value(
    row: Dict[str, str],
) -> int:
    return int(
        round(
            float(
                str(
                    row.get(
                        "seed",
                        "",
                    )
                ).strip()
            )
        )
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


def audit_block(
    specification: Dict[str, object],
) -> Tuple[
    Dict[str, object],
    List[Dict[str, object]],
    set,
]:
    name = str(
        specification["name"]
    )

    path = Path(
        specification["path"]
    )

    fields, rows = read_rows(path)

    missing_columns = [
        column
        for column in REQUIRED_COLUMNS
        if column not in fields
    ]

    seeds = [
        seed_value(row)
        for row in rows
    ]

    seed_set = set(seeds)
    seed_counts = Counter(seeds)

    case_counts = Counter(
        str(
            row.get(
                "case_type",
                "",
            )
        )
        for row in rows
    )

    agent_counts = Counter(
        str(
            row.get(
                "agent_variant",
                "",
            )
        )
        for row in rows
    )

    per_seed_cases = defaultdict(set)

    for row in rows:
        per_seed_cases[
            seed_value(row)
        ].add(
            str(
                row.get(
                    "case_type",
                    "",
                )
            )
        )

    duplicate_keys = Counter(
        (
            seed_value(row),
            str(
                row.get(
                    "case_type",
                    "",
                )
            ),
            str(
                row.get(
                    "agent_variant",
                    "",
                )
            ),
            str(
                row.get(
                    "candidate_id",
                    "",
                )
            ),
        )
        for row in rows
    )

    duplicate_count = sum(
        count - 1
        for count in duplicate_keys.values()
        if count > 1
    )

    nonblank_failures = {
        column: sum(
            not str(
                row.get(
                    column,
                    "",
                )
            ).strip()
            for row in rows
        )
        for column in REQUIRED_NONBLANK
    }

    trace_missing = 0
    notes_json_failures = 0
    notes_branch_policy_failures = 0

    for row in rows:
        trace_text = str(
            row.get(
                "trace_path",
                "",
            )
        ).strip()

        trace_path = Path(
            trace_text
        )

        if (
            trace_text
            and not trace_path.is_absolute()
        ):
            trace_path = (
                Path.cwd()
                / trace_path
            )

        if (
            not trace_text
            or not trace_path.exists()
        ):
            trace_missing += 1

        try:
            notes = json.loads(
                str(
                    row.get(
                        "notes",
                        "",
                    )
                )
            )
        except Exception:
            notes_json_failures += 1
            continue

        policies = notes.get(
            "branch_probe_policies"
        )

        if policies != [
            "no_verify",
            "always_verify",
        ]:
            notes_branch_policy_failures += 1

    expected_seed_min = int(
        specification["seed_min"]
    )

    expected_seed_max = int(
        specification["seed_max"]
    )

    expected_seeds = set(
        range(
            expected_seed_min,
            expected_seed_max + 1,
        )
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

    calibration_rows = sum(
        calibration_min
        <= seed
        <= calibration_max
        for seed in seeds
    )

    evaluation_rows = sum(
        evaluation_min
        <= seed
        <= evaluation_max
        for seed in seeds
    )

    checks = {
        "raw_file_exists": path.is_file(),
        "row_count_900": len(rows) == 900,
        "unique_seed_count_300": (
            len(seed_set) == 300
        ),
        "exact_seed_range": (
            seed_set == expected_seeds
        ),
        "three_rows_per_seed": (
            bool(seed_counts)
            and min(
                seed_counts.values()
            ) == 3
            and max(
                seed_counts.values()
            ) == 3
        ),
        "expected_cases_only": (
            set(case_counts)
            == EXPECTED_CASES
        ),
        "each_case_300_rows": all(
            case_counts.get(
                case,
                0,
            ) == 300
            for case in EXPECTED_CASES
        ),
        "each_seed_has_all_cases": all(
            per_seed_cases.get(
                seed,
                set(),
            )
            == EXPECTED_CASES
            for seed in expected_seeds
        ),
        "openclaw_default_only": (
            agent_counts
            == Counter({
                "openclaw_default": 900
            })
        ),
        "no_duplicate_candidate_keys": (
            duplicate_count == 0
        ),
        "required_columns_present": (
            not missing_columns
        ),
        "required_fields_nonblank": all(
            value == 0
            for value
            in nonblank_failures.values()
        ),
        "calibration_rows_300": (
            calibration_rows == 300
        ),
        "evaluation_rows_600": (
            evaluation_rows == 600
        ),
        "trace_paths_exist": (
            trace_missing == 0
        ),
        "notes_json_valid": (
            notes_json_failures == 0
        ),
        "paired_branch_policy_recorded": (
            notes_branch_policy_failures
            == 0
        ),
    }

    detail_rows = []

    for check, passed in checks.items():
        detail_rows.append({
            "block": name,
            "check": check,
            "passed": passed,
        })

    report = {
        "block": name,
        "path": str(path),
        "sha256": sha256(path),
        "rows": len(rows),
        "unique_seeds": len(seed_set),
        "seed_min": (
            min(seed_set)
            if seed_set
            else None
        ),
        "seed_max": (
            max(seed_set)
            if seed_set
            else None
        ),
        "calibration_rows": calibration_rows,
        "evaluation_rows": evaluation_rows,
        "case_counts": dict(
            sorted(
                case_counts.items()
            )
        ),
        "agent_variant_counts": dict(
            sorted(
                agent_counts.items()
            )
        ),
        "missing_columns": missing_columns,
        "required_nonblank_failure_counts": (
            nonblank_failures
        ),
        "duplicate_candidate_keys": (
            duplicate_count
        ),
        "missing_trace_paths": trace_missing,
        "notes_json_failures": (
            notes_json_failures
        ),
        "notes_branch_policy_failures": (
            notes_branch_policy_failures
        ),
        "checks": checks,
        "all_checks_pass": all(
            checks.values()
        ),
    }

    return report, detail_rows, seed_set


def main() -> None:
    reports = []
    detail_rows = []
    seed_sets = {}

    for block in BLOCKS:
        report, details, seeds = (
            audit_block(block)
        )

        reports.append(report)
        detail_rows.extend(details)
        seed_sets[
            str(block["name"])
        ] = seeds

    c1_c2_overlap = sorted(
        seed_sets["C1"]
        & seed_sets["C2"]
    )

    overall = {
        "status": "complete",
        "timestamp_utc": datetime.now(
            timezone.utc
        ).isoformat(),
        "evaluation_performed": False,
        "outcome_summary_performed": False,
        "blocks": reports,
        "c1_c2_seed_overlap_count": len(
            c1_c2_overlap
        ),
        "c1_c2_seed_overlap": (
            c1_c2_overlap
        ),
        "all_integrity_checks_pass": (
            not c1_c2_overlap
            and all(
                report[
                    "all_checks_pass"
                ]
                for report in reports
            )
        ),
    }

    with (
        OUT
        / "reports"
        / "collection_integrity.json"
    ).open(
        "w",
        encoding="utf-8",
    ) as handle:
        json.dump(
            overall,
            handle,
            indent=2,
            sort_keys=True,
        )

    write_csv(
        OUT
        / "reports"
        / "collection_integrity_checks.csv",
        detail_rows,
        [
            "block",
            "check",
            "passed",
        ],
    )

    manifest_rows = [
        {
            "block": report["block"],
            "path": report["path"],
            "sha256": report["sha256"],
            "rows": report["rows"],
            "unique_seeds": (
                report["unique_seeds"]
            ),
            "seed_min": report["seed_min"],
            "seed_max": report["seed_max"],
            "calibration_rows": (
                report[
                    "calibration_rows"
                ]
            ),
            "evaluation_rows": (
                report[
                    "evaluation_rows"
                ]
            ),
        }
        for report in reports
    ]

    write_csv(
        OUT
        / "manifests"
        / "raw_collection_manifest.csv",
        manifest_rows,
        [
            "block",
            "path",
            "sha256",
            "rows",
            "unique_seeds",
            "seed_min",
            "seed_max",
            "calibration_rows",
            "evaluation_rows",
        ],
    )

    print(
        json.dumps(
            overall,
            indent=2,
            sort_keys=True,
        )
    )

    if not overall[
        "all_integrity_checks_pass"
    ]:
        raise SystemExit(
            "C1/C2 collection integrity failed."
        )


if __name__ == "__main__":
    main()
PY

python3 -m py_compile \
  "$OUT/code/evva3_stage5a_collection_integrity.py" \
  || die "Stage 5A integrity audit failed py_compile."

python3 \
  "$OUT/code/evva3_stage5a_collection_integrity.py" \
  2>&1 | tee "$OUT/logs/collection_integrity.log"

AUDIT_STATUS="${PIPESTATUS[0]}"

[ "$AUDIT_STATUS" -eq 0 ] \
  || die "C1/C2 collection integrity audit failed."

{
  sha256sum "$C1_RAW"
  sha256sum "$C2_RAW"
  sha256sum "$COLLECTOR"
  sha256sum "$V5M"
  sha256sum "$FINAL_METHOD"
  sha256sum "$PREREGISTRATION"
} > "$OUT/hashes/SEALED_RAW_SHA256.txt"

python3 - <<'PY'
import json
import os
from pathlib import Path


out = Path(
    os.environ["EVVA3_STAGE5A_OUT"]
)

plan_path = (
    out
    / "manifests"
    / "COLLECTION_PLAN.json"
)

with plan_path.open(
    encoding="utf-8",
) as handle:
    plan = json.load(handle)

plan["status"] = (
    "both_blocks_collected_and_sealed"
)

plan["evaluation_performed"] = False
plan["outcome_summary_performed"] = False

with plan_path.open(
    "w",
    encoding="utf-8",
) as handle:
    json.dump(
        plan,
        handle,
        indent=2,
        sort_keys=True,
    )
PY

cat > "$OUT/reports/STAGE5A_COMPLETE.md" <<'MD'
# EVVA_3 Stage 5A completion

Both untouched confirmation blocks were collected before either block was
evaluated.

## C1

- all seeds: 6500-6799
- calibration seeds: 6500-6599
- evaluation seeds: 6600-6799
- expected rows: 900

## C2

- all seeds: 6800-7099
- calibration seeds: 6800-6899
- evaluation seeds: 6900-7099
- expected rows: 900

Only outcome-blind structural integrity checks were performed.

No method comparison, curve, AUBC, regret, margin, winner count, or
confirmation decision was calculated during Stage 5A.

The two raw CSVs are now sealed for Stage 5B evaluation.
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
echo "EVVA_3 STAGE 5A C1/C2 COLLECTION COMPLETE"
echo "===================================================="
echo "Output: $OUT"
echo

cat "$OUT/reports/collection_integrity.json"

echo
echo "Raw collection manifest:"
column -s, -t \
  < "$OUT/manifests/raw_collection_manifest.csv"

echo
echo "Sealed raw hashes:"
cat "$OUT/hashes/SEALED_RAW_SHA256.txt"

echo
echo "PASS: C1 and C2 were collected and sealed before evaluation."

#!/usr/bin/env bash

# EVVA_3 Stage 6A:
# Paired-branch fidelity and provenance audit.
#
# This stage does not modify or compare methods.
# It audits the data-generation protocol underlying intervention_gain.

die() {
  echo "ERROR: $*" >&2
  exit 1
}

WORKSPACE="$HOME/.openclaw/workspace/skills/openclaw_pilot_v4_large_exactB_20260707_EVVA_3_signal_repair_20260713"

[ -d "$WORKSPACE" ] \
  || die "Workspace not found."

cd "$WORKSPACE" \
  || die "Cannot enter workspace."

[ -f artifacts/aaai_evva3_stage5a_latest.txt ] \
  || die "Stage 5A pointer missing."

[ -f artifacts/aaai_evva3_stage5b_latest.txt ] \
  || die "Stage 5B pointer missing."

STAGE5A="$(
  cat artifacts/aaai_evva3_stage5a_latest.txt
)"

STAGE5B="$(
  cat artifacts/aaai_evva3_stage5b_latest.txt
)"

C1_RAW="$STAGE5A/c1_6500_6799/raw/full_agent_candidate_rows_6500_6799.csv"
C2_RAW="$STAGE5A/c2_6800_7099/raw/full_agent_candidate_rows_6800_7099.csv"

C1_LOG_ROOT="$STAGE5A/c1_6500_6799/collector_logs"
C2_LOG_ROOT="$STAGE5A/c2_6800_7099/collector_logs"

SEALED_HASHES="$STAGE5A/hashes/SEALED_RAW_SHA256.txt"
CONFIRMATORY_DECISION="$STAGE5B/reports/confirmatory_decision.json"

for required in \
  "$C1_RAW" \
  "$C2_RAW" \
  "$SEALED_HASHES" \
  "$CONFIRMATORY_DECISION"
do
  [ -f "$required" ] \
    || die "Missing required input: $required"
done

sha256sum -c "$SEALED_HASHES" \
  || die "Sealed Stage 5A hashes failed."

export EVVA3_STAGE6A_DECISION="$CONFIRMATORY_DECISION"

python3 - <<'PY' \
  || die "Stage 5B decision validation failed."
import json
import os
from pathlib import Path

path = Path(
    os.environ["EVVA3_STAGE6A_DECISION"]
)

with path.open(
    encoding="utf-8"
) as handle:
    decision = json.load(handle)

if decision.get("decision") != "PASS":
    raise SystemExit(
        "Stage 5B confirmatory decision is not PASS."
    )

if not decision.get(
    "method_remains_frozen"
):
    raise SystemExit(
        "Frozen-method status is absent."
    )

if decision.get(
    "method_modification_permitted_after_result"
):
    raise SystemExit(
        "Method modification is unexpectedly permitted."
    )

print("CONFIRMATORY_FREEZE_VALIDATION=PASS")
PY

OUT="artifacts/aaai_evva3_stage6a_branch_fidelity_20260714"

mkdir -p \
  "$OUT/code" \
  "$OUT/hashes" \
  "$OUT/logs" \
  "$OUT/manifests" \
  "$OUT/results" \
  "$OUT/reports" \
  || die "Cannot create Stage 6A directories."

echo "$OUT" \
  > artifacts/aaai_evva3_stage6a_latest.txt

export EVVA3_STAGE6A_OUT="$OUT"
export EVVA3_STAGE6A_C1_RAW="$C1_RAW"
export EVVA3_STAGE6A_C2_RAW="$C2_RAW"
export EVVA3_STAGE6A_C1_LOG_ROOT="$C1_LOG_ROOT"
export EVVA3_STAGE6A_C2_LOG_ROOT="$C2_LOG_ROOT"

{
  sha256sum "$C1_RAW"
  sha256sum "$C2_RAW"
  sha256sum "$CONFIRMATORY_DECISION"
} > "$OUT/hashes/pre_audit_sha256.txt"

cat > "$OUT/code/aaai_evva3_stage6a_branch_fidelity.py" <<'PY'
#!/usr/bin/env python3

"""Paired-branch fidelity and provenance audit.

Hard checks
-----------

1. Corrected reward minus wrong-continuation reward equals intervention gain.
2. branch_harm_exact equals intervention gain.
3. Each candidate has no_verify and always_verify branch artifacts.
4. Summary CSV files are parseable and nonempty.
5. Standard-output logs exist and are nonempty.
6. Standard-error logs exist and are empty.
7. Log-directory identity agrees with case, seed, and agent.
8. notes is valid JSON and records the paired branch policies.
9. trace_path exists.

Metadata coverage
-----------------

The audit also inventories keys related to initial state, snapshots,
randomness, RNG seeds, replay, and state isolation. Absence of such metadata
is reported honestly and is not silently treated as proof of isolation.
"""

import csv
import hashlib
import json
import math
import os
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple


OUT = Path(
    os.environ["EVVA3_STAGE6A_OUT"]
)

BLOCKS = [
    {
        "name": "C1",
        "raw": Path(
            os.environ[
                "EVVA3_STAGE6A_C1_RAW"
            ]
        ),
        "log_root": Path(
            os.environ[
                "EVVA3_STAGE6A_C1_LOG_ROOT"
            ]
        ),
    },
    {
        "name": "C2",
        "raw": Path(
            os.environ[
                "EVVA3_STAGE6A_C2_RAW"
            ]
        ),
        "log_root": Path(
            os.environ[
                "EVVA3_STAGE6A_C2_LOG_ROOT"
            ]
        ),
    },
]

TOLERANCE = 1e-9

REQUIRED_BRANCH_FILES = [
    "no_verify_summary.csv",
    "always_verify_summary.csv",
    "no_verify.stdout.log",
    "always_verify.stdout.log",
    "no_verify.stderr.log",
    "always_verify.stderr.log",
]

METADATA_KEYWORDS = [
    "seed",
    "random",
    "rng",
    "state",
    "snapshot",
    "initial",
    "reset",
    "isolation",
    "replay",
    "checkpoint",
    "environment",
    "branch",
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


def flatten_json(
    value: Any,
    prefix: str = "",
) -> Dict[str, str]:
    output: Dict[str, str] = {}

    if isinstance(value, dict):
        for key, item in value.items():
            child = (
                f"{prefix}.{key}"
                if prefix
                else str(key)
            )

            output.update(
                flatten_json(
                    item,
                    child,
                )
            )

        return output

    if isinstance(value, list):
        output[prefix] = json.dumps(
            value,
            sort_keys=True,
        )

        for index, item in enumerate(value):
            child = f"{prefix}[{index}]"

            output.update(
                flatten_json(
                    item,
                    child,
                )
            )

        return output

    output[prefix] = str(value)

    return output


def summary_schema(
    path: Path,
) -> Tuple[
    List[str],
    int,
    Optional[Dict[str, str]],
]:
    fields, rows = read_csv(path)

    first = (
        rows[0]
        if rows
        else None
    )

    return fields, len(rows), first


def identity_checks(
    first_row: Optional[Dict[str, str]],
    expected_seed: int,
    expected_case: str,
    expected_agent: str,
    expected_branch: str,
) -> Dict[str, object]:
    if first_row is None:
        return {
            "identity_fields_found": 0,
            "identity_fields_matched": 0,
            "identity_mismatch": False,
        }

    checks = []

    candidates = {
        "seed": (
            str(expected_seed),
            [
                "seed",
                "random_seed",
                "run_seed",
            ],
        ),
        "case": (
            expected_case,
            [
                "case",
                "case_type",
                "scenario",
            ],
        ),
        "agent": (
            expected_agent,
            [
                "agent",
                "agent_variant",
                "variant",
            ],
        ),
        "branch": (
            expected_branch,
            [
                "branch",
                "policy",
                "branch_policy",
                "verification_policy",
            ],
        ),
    }

    for _, (
        expected,
        field_names,
    ) in candidates.items():
        for field in field_names:
            if field not in first_row:
                continue

            actual = str(
                first_row.get(
                    field,
                    "",
                )
            ).strip()

            if not actual:
                continue

            checks.append(
                actual == expected
            )

            break

    return {
        "identity_fields_found": len(checks),
        "identity_fields_matched": sum(checks),
        "identity_mismatch": (
            bool(checks)
            and not all(checks)
        ),
    }


def main() -> None:
    issue_rows = []
    row_check_rows = []
    schema_rows = []
    metadata_rows = []

    overall_counts = Counter()
    block_reports = []

    metadata_key_counts = Counter()
    metadata_row_coverage = Counter()

    branch_directory_owners = defaultdict(list)

    for block in BLOCKS:
        block_name = str(
            block["name"]
        )

        raw_path = Path(
            block["raw"]
        )

        log_root = Path(
            block["log_root"]
        )

        fields, rows = read_csv(
            raw_path
        )

        block_counts = Counter()

        for row_index, row in enumerate(
            rows,
            start=2,
        ):
            seed = parse_seed(
                row.get("seed")
            )

            case_type = str(
                row.get(
                    "case_type",
                    "",
                )
            ).strip()

            agent = str(
                row.get(
                    "agent_variant",
                    "",
                )
            ).strip()

            candidate_id = str(
                row.get(
                    "candidate_id",
                    "",
                )
            ).strip()

            owner = (
                block_name,
                seed,
                case_type,
                agent,
                candidate_id,
            )

            branch_dir = (
                log_root
                / f"case={case_type}"
                / f"seed={seed}"
                / f"agent={agent}"
            )

            branch_directory_owners[
                str(branch_dir)
            ].append(owner)

            wrong_reward = parse_float(
                row.get(
                    "reward_wrong_continuation"
                )
            )

            corrected_reward = parse_float(
                row.get(
                    "reward_corrected_continuation"
                )
            )

            gain = parse_float(
                row.get(
                    "intervention_gain"
                )
            )

            branch_harm = parse_float(
                row.get(
                    "branch_harm_exact"
                )
            )

            verification_cost = parse_float(
                row.get(
                    "verification_cost"
                )
            )

            arithmetic_available = all(
                value is not None
                for value in [
                    wrong_reward,
                    corrected_reward,
                    gain,
                ]
            )

            reward_identity_pass = (
                arithmetic_available
                and abs(
                    (
                        corrected_reward
                        - wrong_reward
                    )
                    - gain
                )
                <= TOLERANCE
            )

            harm_identity_pass = (
                branch_harm is not None
                and gain is not None
                and abs(
                    branch_harm
                    - gain
                )
                <= TOLERANCE
            )

            nonnegative_cost_pass = (
                verification_cost is not None
                and verification_cost >= 0.0
            )

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

            trace_exists = (
                bool(trace_text)
                and trace_path.exists()
            )

            notes_text = str(
                row.get(
                    "notes",
                    "",
                )
            ).strip()

            notes_valid = False
            policies_pass = False
            flattened = {}

            try:
                notes = json.loads(
                    notes_text
                )

                notes_valid = True

                policies_pass = (
                    notes.get(
                        "branch_probe_policies"
                    )
                    == [
                        "no_verify",
                        "always_verify",
                    ]
                )

                flattened = flatten_json(
                    notes
                )
            except Exception:
                notes = None

            matched_metadata_categories = set()

            for key, value in flattened.items():
                lower_key = key.lower()

                for keyword in METADATA_KEYWORDS:
                    if keyword in lower_key:
                        metadata_key_counts[
                            key
                        ] += 1

                        matched_metadata_categories.add(
                            keyword
                        )

                        metadata_rows.append({
                            "block": block_name,
                            "seed": seed,
                            "case_type": case_type,
                            "candidate_id": candidate_id,
                            "metadata_key": key,
                            "metadata_value": value,
                            "keyword_category": keyword,
                        })

            for keyword in matched_metadata_categories:
                metadata_row_coverage[
                    keyword
                ] += 1

            file_status = {}

            for filename in REQUIRED_BRANCH_FILES:
                path = branch_dir / filename

                file_status[
                    f"{filename}_exists"
                ] = path.is_file()

                if path.is_file():
                    file_status[
                        f"{filename}_size"
                    ] = path.stat().st_size
                else:
                    file_status[
                        f"{filename}_size"
                    ] = None

            summary_pass = True
            identity_mismatch = False

            for branch in [
                "no_verify",
                "always_verify",
            ]:
                summary_path = (
                    branch_dir
                    / f"{branch}_summary.csv"
                )

                if not summary_path.is_file():
                    summary_pass = False
                    continue

                try:
                    (
                        summary_fields,
                        summary_rows_count,
                        first_summary_row,
                    ) = summary_schema(
                        summary_path
                    )
                except Exception as error:
                    summary_pass = False

                    issue_rows.append({
                        "block": block_name,
                        "seed": seed,
                        "case_type": case_type,
                        "agent_variant": agent,
                        "candidate_id": candidate_id,
                        "issue": (
                            "summary_parse_failure"
                        ),
                        "detail": (
                            f"{summary_path}: {error}"
                        ),
                    })

                    continue

                identities = identity_checks(
                    first_summary_row,
                    seed,
                    case_type,
                    agent,
                    branch,
                )

                if identities[
                    "identity_mismatch"
                ]:
                    identity_mismatch = True

                schema_rows.append({
                    "block": block_name,
                    "branch": branch,
                    "summary_path": str(
                        summary_path
                    ),
                    "summary_rows": (
                        summary_rows_count
                    ),
                    "summary_columns": (
                        len(summary_fields)
                    ),
                    "field_names": "|".join(
                        summary_fields
                    ),
                    "identity_fields_found": (
                        identities[
                            "identity_fields_found"
                        ]
                    ),
                    "identity_fields_matched": (
                        identities[
                            "identity_fields_matched"
                        ]
                    ),
                    "identity_mismatch": (
                        identities[
                            "identity_mismatch"
                        ]
                    ),
                })

                if summary_rows_count < 1:
                    summary_pass = False

            stdout_nonempty = all(
                (
                    branch_dir
                    / f"{branch}.stdout.log"
                ).is_file()
                and (
                    branch_dir
                    / f"{branch}.stdout.log"
                ).stat().st_size > 0
                for branch in [
                    "no_verify",
                    "always_verify",
                ]
            )

            stderr_empty = all(
                (
                    branch_dir
                    / f"{branch}.stderr.log"
                ).is_file()
                and (
                    branch_dir
                    / f"{branch}.stderr.log"
                ).stat().st_size == 0
                for branch in [
                    "no_verify",
                    "always_verify",
                ]
            )

            all_branch_files_exist = all(
                bool(
                    file_status[
                        f"{filename}_exists"
                    ]
                )
                for filename
                in REQUIRED_BRANCH_FILES
            )

            checks = {
                "reward_identity_pass": (
                    reward_identity_pass
                ),
                "harm_identity_pass": (
                    harm_identity_pass
                ),
                "verification_cost_nonnegative": (
                    nonnegative_cost_pass
                ),
                "trace_exists": trace_exists,
                "notes_json_valid": notes_valid,
                "paired_policies_recorded": (
                    policies_pass
                ),
                "branch_directory_exists": (
                    branch_dir.is_dir()
                ),
                "all_branch_files_exist": (
                    all_branch_files_exist
                ),
                "summary_files_parseable_nonempty": (
                    summary_pass
                ),
                "summary_identity_no_mismatch": (
                    not identity_mismatch
                ),
                "stdout_logs_nonempty": (
                    stdout_nonempty
                ),
                "stderr_logs_empty": (
                    stderr_empty
                ),
            }

            all_hard_checks_pass = all(
                checks.values()
            )

            row_check = {
                "block": block_name,
                "raw_row_number": row_index,
                "seed": seed,
                "case_type": case_type,
                "agent_variant": agent,
                "candidate_id": candidate_id,
                **checks,
                "all_hard_checks_pass": (
                    all_hard_checks_pass
                ),
            }

            row_check_rows.append(
                row_check
            )

            block_counts[
                "rows"
            ] += 1

            overall_counts[
                "rows"
            ] += 1

            for check_name, passed in checks.items():
                if passed:
                    block_counts[
                        f"{check_name}_pass"
                    ] += 1

                    overall_counts[
                        f"{check_name}_pass"
                    ] += 1
                else:
                    issue_rows.append({
                        "block": block_name,
                        "seed": seed,
                        "case_type": case_type,
                        "agent_variant": agent,
                        "candidate_id": candidate_id,
                        "issue": check_name,
                        "detail": str(
                            branch_dir
                        ),
                    })

            if all_hard_checks_pass:
                block_counts[
                    "all_hard_checks_pass"
                ] += 1

                overall_counts[
                    "all_hard_checks_pass"
                ] += 1

        block_reports.append({
            "block": block_name,
            "raw_path": str(
                raw_path
            ),
            "raw_sha256": sha256(
                raw_path
            ),
            "rows": block_counts[
                "rows"
            ],
            "rows_passing_all_hard_checks": (
                block_counts[
                    "all_hard_checks_pass"
                ]
            ),
            "all_rows_pass": (
                block_counts[
                    "rows"
                ]
                == block_counts[
                    "all_hard_checks_pass"
                ]
            ),
        })

    duplicate_branch_directories = {
        directory: owners
        for directory, owners
        in branch_directory_owners.items()
        if len(owners) > 1
    }

    total_rows = overall_counts[
        "rows"
    ]

    metadata_coverage = {
        keyword: {
            "rows_with_metadata": (
                metadata_row_coverage[
                    keyword
                ]
            ),
            "total_rows": total_rows,
            "coverage_fraction": (
                metadata_row_coverage[
                    keyword
                ]
                / total_rows
                if total_rows
                else 0.0
            ),
        }
        for keyword in METADATA_KEYWORDS
    }

    hard_checks_pass = (
        total_rows == 1800
        and overall_counts[
            "all_hard_checks_pass"
        ] == total_rows
        and not duplicate_branch_directories
        and all(
            report["all_rows_pass"]
            for report in block_reports
        )
    )

    state_related_coverage = max(
        metadata_coverage[
            keyword
        ]["coverage_fraction"]
        for keyword in [
            "state",
            "snapshot",
            "initial",
            "reset",
            "isolation",
            "checkpoint",
        ]
    )

    randomness_related_coverage = max(
        metadata_coverage[
            keyword
        ]["coverage_fraction"]
        for keyword in [
            "seed",
            "random",
            "rng",
            "replay",
        ]
    )

    summary = {
        "status": "complete",
        "decision": (
            "PASS"
            if hard_checks_pass
            else "FAIL"
        ),
        "total_rows": total_rows,
        "rows_passing_all_hard_checks": (
            overall_counts[
                "all_hard_checks_pass"
            ]
        ),
        "duplicate_branch_directory_count": (
            len(
                duplicate_branch_directories
            )
        ),
        "block_reports": block_reports,
        "hard_provenance_checks_pass": (
            hard_checks_pass
        ),
        "state_isolation_metadata_coverage": (
            state_related_coverage
        ),
        "randomness_control_metadata_coverage": (
            randomness_related_coverage
        ),
        "metadata_coverage": metadata_coverage,
        "interpretation": (
            "Hard provenance PASS verifies arithmetic identities, "
            "paired artifacts, parseability, branch-policy records, "
            "trace existence, and clean stderr. Metadata coverage "
            "describes how directly state isolation and randomness "
            "control can be demonstrated from saved records."
        ),
        "method_modified": False,
        "confirmation_decision_modified": False,
    }

    with (
        OUT
        / "reports"
        / "branch_fidelity_summary.json"
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

    write_csv(
        OUT
        / "results"
        / "row_checks.csv",
        row_check_rows,
        [
            "block",
            "raw_row_number",
            "seed",
            "case_type",
            "agent_variant",
            "candidate_id",
            "reward_identity_pass",
            "harm_identity_pass",
            "verification_cost_nonnegative",
            "trace_exists",
            "notes_json_valid",
            "paired_policies_recorded",
            "branch_directory_exists",
            "all_branch_files_exist",
            "summary_files_parseable_nonempty",
            "summary_identity_no_mismatch",
            "stdout_logs_nonempty",
            "stderr_logs_empty",
            "all_hard_checks_pass",
        ],
    )

    write_csv(
        OUT
        / "results"
        / "issues.csv",
        issue_rows,
        [
            "block",
            "seed",
            "case_type",
            "agent_variant",
            "candidate_id",
            "issue",
            "detail",
        ],
    )

    write_csv(
        OUT
        / "results"
        / "summary_schema_inventory.csv",
        schema_rows,
        [
            "block",
            "branch",
            "summary_path",
            "summary_rows",
            "summary_columns",
            "field_names",
            "identity_fields_found",
            "identity_fields_matched",
            "identity_mismatch",
        ],
    )

    write_csv(
        OUT
        / "results"
        / "notes_metadata_inventory.csv",
        metadata_rows,
        [
            "block",
            "seed",
            "case_type",
            "candidate_id",
            "metadata_key",
            "metadata_value",
            "keyword_category",
        ],
    )

    duplicate_rows = []

    for directory, owners in (
        duplicate_branch_directories.items()
    ):
        duplicate_rows.append({
            "branch_directory": directory,
            "owner_count": len(owners),
            "owners_json": json.dumps(
                owners,
                sort_keys=True,
            ),
        })

    write_csv(
        OUT
        / "results"
        / "duplicate_branch_directories.csv",
        duplicate_rows,
        [
            "branch_directory",
            "owner_count",
            "owners_json",
        ],
    )

    print(
        json.dumps(
            summary,
            indent=2,
            sort_keys=True,
        )
    )

    if not hard_checks_pass:
        raise SystemExit(
            "Branch fidelity hard checks failed."
        )


if __name__ == "__main__":
    main()
PY

python3 -m py_compile \
  "$OUT/code/aaai_evva3_stage6a_branch_fidelity.py" \
  || die "Stage 6A failed py_compile."

python3 \
  "$OUT/code/aaai_evva3_stage6a_branch_fidelity.py" \
  2>&1 | tee "$OUT/logs/stage6a_branch_fidelity.log"

STATUS="${PIPESTATUS[0]}"

[ "$STATUS" -eq 0 ] \
  || die "Stage 6A audit failed."

for required in \
  "$OUT/reports/branch_fidelity_summary.json" \
  "$OUT/results/row_checks.csv" \
  "$OUT/results/issues.csv" \
  "$OUT/results/summary_schema_inventory.csv" \
  "$OUT/results/notes_metadata_inventory.csv"
do
  [ -f "$required" ] \
    || die "Missing Stage 6A output: $required"
done

{
  sha256sum "$C1_RAW"
  sha256sum "$C2_RAW"
  sha256sum "$CONFIRMATORY_DECISION"
} > "$OUT/hashes/post_audit_sha256.txt"

cmp -s \
  "$OUT/hashes/pre_audit_sha256.txt" \
  "$OUT/hashes/post_audit_sha256.txt" \
  || die "A frozen input changed during Stage 6A."

cat > "$OUT/reports/STAGE6A_COMPLETE.md" <<'MD'
# EVVA_3 Stage 6A completion

The paired-branch data-generation artifacts were audited after the
confirmatory method and decision were frozen.

The audit did not modify the method, confirmation data, or confirmatory
decision.

Hard checks cover arithmetic consistency, paired branch artifacts, summary
parseability, trace provenance, policy records, stdout availability, and clean
stderr.

State-isolation and randomness-control metadata coverage are reported
separately and are not overstated as causal proof.
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
echo "EVVA_3 STAGE 6A BRANCH FIDELITY COMPLETE"
echo "===================================================="
echo "Output: $OUT"
echo

cat "$OUT/reports/branch_fidelity_summary.json"

echo
echo "Issue count:"
python3 - "$OUT/results/issues.csv" <<'PY'
import csv
import sys

with open(
    sys.argv[1],
    newline="",
    encoding="utf-8",
) as handle:
    print(
        sum(
            1
            for _ in csv.DictReader(handle)
        )
    )
PY

echo
echo "PASS: Stage 6A completed without modifying frozen inputs."

#!/usr/bin/env bash

# EVVA_3 Stage 6B:
# Deterministic replay and branch-order invariance audit.
#
# Development seeds only.
# C1/C2 are not rerun or modified.
# The final method and confirmatory decision remain frozen.

die() {
  echo "ERROR: $*" >&2
  exit 1
}

WORKSPACE="$HOME/.openclaw/workspace/skills/openclaw_pilot_v4_large_exactB_20260707_EVVA_3_signal_repair_20260713"

COLLECTOR="code/evva_v4_full_agent_candidate_collector.py"

CASES=(
  dependency_sensitive
  corruption_prone
  dep_sensitive_held_out
)

# Two seeds from each of the six development blocks.
SEEDS="4200,4201,5000,5001,5300,5301,5600,5601,5900,5901,6200,6201"

AGENT_VARIANT="openclaw_default"

[ -d "$WORKSPACE" ] \
  || die "Workspace not found."

cd "$WORKSPACE" \
  || die "Cannot enter workspace."

[ -f "$COLLECTOR" ] \
  || die "Collector not found."

[ -f artifacts/evva3_stage5a_latest.txt ] \
  || die "Stage 5A pointer missing."

[ -f artifacts/evva3_stage5b_latest.txt ] \
  || die "Stage 5B pointer missing."

[ -f artifacts/evva3_stage6a_latest.txt ] \
  || die "Stage 6A pointer missing."

STAGE5A="$(
  cat artifacts/evva3_stage5a_latest.txt
)"

STAGE5B="$(
  cat artifacts/evva3_stage5b_latest.txt
)"

STAGE6A="$(
  cat artifacts/evva3_stage6a_latest.txt
)"

SEALED_HASHES="$STAGE5A/hashes/SEALED_RAW_SHA256.txt"
STAGE5B_HASHES="$STAGE5B/hashes/post_evaluation_sha256.txt"
STAGE5B_DECISION="$STAGE5B/reports/confirmatory_decision.json"
STAGE6A_SUMMARY="$STAGE6A/reports/branch_fidelity_summary.json"

for required in \
  "$SEALED_HASHES" \
  "$STAGE5B_HASHES" \
  "$STAGE5B_DECISION" \
  "$STAGE6A_SUMMARY"
do
  [ -f "$required" ] \
    || die "Missing frozen evidence: $required"
done

sha256sum -c "$SEALED_HASHES" \
  || die "Stage 5A sealed hashes failed."

sha256sum -c "$STAGE5B_HASHES" \
  || die "Stage 5B frozen hashes failed."

export EVVA3_STAGE6B_DECISION="$STAGE5B_DECISION"
export EVVA3_STAGE6B_STAGE6A="$STAGE6A_SUMMARY"

python3 - <<'PY' \
  || die "Frozen decision validation failed."
import json
import os
from pathlib import Path


decision_path = Path(
    os.environ["EVVA3_STAGE6B_DECISION"]
)

stage6a_path = Path(
    os.environ["EVVA3_STAGE6B_STAGE6A"]
)

with decision_path.open(
    encoding="utf-8"
) as handle:
    decision = json.load(handle)

with stage6a_path.open(
    encoding="utf-8"
) as handle:
    stage6a = json.load(handle)

if decision.get("decision") != "PASS":
    raise SystemExit(
        "Stage 5B confirmatory decision is not PASS."
    )

if not decision.get(
    "method_remains_frozen"
):
    raise SystemExit(
        "Method freeze status is absent."
    )

if not stage6a.get(
    "hard_provenance_checks_pass"
):
    raise SystemExit(
        "Stage 6A hard provenance did not pass."
    )

if stage6a.get(
    "total_rows"
) != 1800:
    raise SystemExit(
        "Unexpected Stage 6A row count."
    )

print("FROZEN_EVIDENCE_VALIDATION=PASS")
PY

RUNNER="$(
python3 - <<'PY'
import importlib.util
from pathlib import Path

path = Path(
    "code/evva_v4_full_agent_candidate_collector.py"
)

spec = importlib.util.spec_from_file_location(
    "evva3_stage6b_collector",
    path,
)

if spec is None or spec.loader is None:
    raise SystemExit(
        "Cannot import collector."
    )

module = importlib.util.module_from_spec(
    spec
)

spec.loader.exec_module(module)

print(module.find_runner())
PY
)"

[ -n "$RUNNER" ] \
  || die "Collector runner could not be resolved."

[ -f "$RUNNER" ] \
  || die "Resolved runner does not exist: $RUNNER"

OUT="artifacts/evva3_stage6b_deterministic_replay_20260714"

FORWARD1="$OUT/forward_1"
FORWARD2="$OUT/forward_2"
REVERSE1="$OUT/reverse_1"

mkdir -p \
  "$OUT/code" \
  "$OUT/hashes" \
  "$OUT/logs" \
  "$OUT/manifests" \
  "$OUT/results" \
  "$OUT/reports" \
  "$FORWARD1/logs" \
  "$FORWARD2/logs" \
  "$REVERSE1/logs" \
  || die "Cannot create Stage 6B directories."

echo "$OUT" \
  > artifacts/evva3_stage6b_latest.txt

python3 -m py_compile "$COLLECTOR" \
  || die "Collector failed py_compile."

export EVVA3_STAGE6B_COLLECTOR="$COLLECTOR"
export EVVA3_STAGE6B_REVERSE_COLLECTOR="$OUT/code/evva_v4_full_agent_candidate_collector_reverse_order.py"

python3 - <<'PY' \
  || die "Could not create reverse-order audit collector."
import os
import re
from pathlib import Path


source_path = Path(
    os.environ["EVVA3_STAGE6B_COLLECTOR"]
)

output_path = Path(
    os.environ[
        "EVVA3_STAGE6B_REVERSE_COLLECTOR"
    ]
)

text = source_path.read_text(
    encoding="utf-8"
)

pattern = re.compile(
    r'(?P<indent>[ \t]+)'
    r'no_v = run_branch'
    r'\(runner, case_type, seed, agent_variant, '
    r'"no_verify", trace_dir, notes\)\n'
    r'(?P=indent)'
    r'yes_v = run_branch'
    r'\(runner, case_type, seed, agent_variant, '
    r'"always_verify", trace_dir, notes\)'
)

match = pattern.search(text)

if match is None:
    raise SystemExit(
        "Expected paired branch calls were not found."
    )

if len(pattern.findall(text)) != 1:
    raise SystemExit(
        "Expected exactly one paired branch call site."
    )

indent = match.group("indent")

replacement = (
    f'{indent}yes_v = run_branch'
    f'(runner, case_type, seed, agent_variant, '
    f'"always_verify", trace_dir, notes)\n'
    f'{indent}no_v = run_branch'
    f'(runner, case_type, seed, agent_variant, '
    f'"no_verify", trace_dir, notes)'
)

patched = pattern.sub(
    replacement,
    text,
    count=1,
)

header = (
    "# AUDIT-ONLY COPY.\n"
    "# Branch execution order is reversed to test "
    "process/order invariance.\n"
    "# This file is not a method implementation.\n\n"
)

output_path.write_text(
    header + patched,
    encoding="utf-8",
)

print(output_path)
PY

python3 -m py_compile \
  "$OUT/code/evva_v4_full_agent_candidate_collector_reverse_order.py" \
  || die "Reverse-order collector failed py_compile."

{
  sha256sum "$COLLECTOR"
  sha256sum "$RUNNER"
  sha256sum "$STAGE5B_DECISION"
  sha256sum "$STAGE6A_SUMMARY"
  sha256sum "$STAGE5A/c1_6500_6799/raw/full_agent_candidate_rows_6500_6799.csv"
  sha256sum "$STAGE5A/c2_6800_7099/raw/full_agent_candidate_rows_6800_7099.csv"
} > "$OUT/hashes/pre_replay_frozen_sha256.txt"

cat > "$OUT/manifests/replay_plan.json" <<JSON
{
  "stage": "EVVA_3 Stage 6B",
  "purpose": "deterministic replay and branch-order invariance",
  "development_seeds_only": true,
  "confirmation_seeds_used": false,
  "seeds": [
    4200,
    4201,
    5000,
    5001,
    5300,
    5301,
    5600,
    5601,
    5900,
    5901,
    6200,
    6201
  ],
  "cases": [
    "dependency_sensitive",
    "corruption_prone",
    "dep_sensitive_held_out"
  ],
  "expected_rows_per_replay": 36,
  "replays": [
    {
      "name": "forward_1",
      "branch_order": [
        "no_verify",
        "always_verify"
      ]
    },
    {
      "name": "forward_2",
      "branch_order": [
        "no_verify",
        "always_verify"
      ]
    },
    {
      "name": "reverse_1",
      "branch_order": [
        "always_verify",
        "no_verify"
      ]
    }
  ],
  "method_modified": false,
  "confirmatory_decision_modified": false,
  "audit_collector_copy_only": true,
  "resolved_runner": "$RUNNER"
}
JSON

run_collection() {
  local label="$1"
  local collector="$2"
  local root="$3"

  local raw="$root/full_agent_candidate_rows.csv"
  local logs="$root/logs"

  mkdir -p "$logs"

  echo
  echo "===================================================="
  echo "STAGE 6B REPLAY: $label"
  echo "===================================================="
  echo "Collector: $collector"
  echo "Output: $raw"
  echo

  python3 "$collector" \
    --cases "${CASES[@]}" \
    --seeds "$SEEDS" \
    --agent-variants "$AGENT_VARIANT" \
    --out "$raw" \
    --log-dir "$logs" \
    --force \
    --no-resume \
    2>&1 | tee "$OUT/logs/${label}_console.log"

  local status="${PIPESTATUS[0]}"

  [ "$status" -eq 0 ] \
    || die "$label failed with status $status."

  [ -f "$raw" ] \
    || die "$label raw CSV missing."
}

run_collection \
  "forward_1" \
  "$COLLECTOR" \
  "$FORWARD1"

run_collection \
  "forward_2" \
  "$COLLECTOR" \
  "$FORWARD2"

run_collection \
  "reverse_1" \
  "$OUT/code/evva_v4_full_agent_candidate_collector_reverse_order.py" \
  "$REVERSE1"

export EVVA3_STAGE6B_OUT="$OUT"
export EVVA3_STAGE6B_FORWARD1="$FORWARD1"
export EVVA3_STAGE6B_FORWARD2="$FORWARD2"
export EVVA3_STAGE6B_REVERSE1="$REVERSE1"
export EVVA3_STAGE6B_RUNNER="$RUNNER"

cat > "$OUT/code/evva3_stage6b_replay_audit.py" <<'PY'
#!/usr/bin/env python3

"""Deterministic replay and branch-order invariance audit.

Three independent collections are compared:

- forward_1: no_verify, then always_verify
- forward_2: no_verify, then always_verify
- reverse_1: always_verify, then no_verify

The comparison excludes only path/profiling metadata whose values must
change because each replay has a separate artifact root.

All candidate-level scientific fields and normalized branch summaries
must otherwise be exactly reproducible.
"""

import csv
import hashlib
import json
import os
import re
from collections import Counter
from pathlib import Path
from typing import Dict, List, Sequence, Tuple


OUT = Path(
    os.environ["EVVA3_STAGE6B_OUT"]
)

RUNNER = Path(
    os.environ["EVVA3_STAGE6B_RUNNER"]
)

RUNS = {
    "forward_1": Path(
        os.environ["EVVA3_STAGE6B_FORWARD1"]
    ),
    "forward_2": Path(
        os.environ["EVVA3_STAGE6B_FORWARD2"]
    ),
    "reverse_1": Path(
        os.environ["EVVA3_STAGE6B_REVERSE1"]
    ),
}

EXPECTED_SEEDS = {
    4200,
    4201,
    5000,
    5001,
    5300,
    5301,
    5600,
    5601,
    5900,
    5901,
    6200,
    6201,
}

EXPECTED_CASES = {
    "dependency_sensitive",
    "corruption_prone",
    "dep_sensitive_held_out",
}

EXPECTED_ROWS = 36

RAW_EXCLUDED_COLUMNS = {
    "trace_path",
    "notes",
}

VOLATILE_FIELD_TOKENS = {
    "timestamp",
    "datetime",
    "date",
    "duration",
    "elapsed",
    "wall",
    "runtime",
    "path",
    "directory",
    "dir",
    "log",
    "stdout",
    "stderr",
    "output",
    "created",
    "updated",
    "pid",
    "hostname",
    "host",
    "cwd",
    "command",
    "cmd",
    "argv",
}

IDENTITY_ALIAS_GROUPS = {
    "seed": [
        "seed",
        "random_seed",
        "run_seed",
    ],
    "case": [
        "case",
        "case_type",
        "scenario",
    ],
    "agent": [
        "agent",
        "agent_variant",
        "variant",
    ],
    "candidate": [
        "candidate_id",
        "decision_point_id",
        "step_id",
    ],
    "requested_action": [
        "requested_action",
        "proposed_action",
        "action",
    ],
    "p_score": [
        "p_score",
        "error_probability",
        "failure_probability",
        "p_t",
    ],
    "harm_score": [
        "structural_harm_score",
        "estimated_harm_score",
        "H_score",
        "H_t",
        "pre_harm_score",
        "pre_intervention_harm_score",
        "harm_proxy",
        "risk_harm_proxy",
        "harm_score",
    ],
    "rollback": [
        "rollback_difficulty",
    ],
    "persistent": [
        "persistent_state_risk",
    ],
    "dependency": [
        "downstream_dependency_count",
        "dependency_count",
    ],
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()

    with path.open("rb") as handle:
        for chunk in iter(
            lambda: handle.read(1024 * 1024),
            b"",
        ):
            digest.update(chunk)

    return digest.hexdigest()


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


def key_for(
    row: Dict[str, str],
) -> Tuple[str, str, str, str]:
    return (
        str(row.get("case_type", "")),
        str(row.get("seed", "")),
        str(row.get("agent_variant", "")),
        str(row.get("candidate_id", "")),
    )


def stable_raw_row(
    row: Dict[str, str],
) -> Dict[str, str]:
    return {
        key: value
        for key, value in row.items()
        if key not in RAW_EXCLUDED_COLUMNS
    }


def notes_policy_pass(
    row: Dict[str, str],
) -> bool:
    try:
        notes = json.loads(
            str(row.get("notes", ""))
        )
    except Exception:
        return False

    return (
        notes.get("branch_probe_policies")
        == [
            "no_verify",
            "always_verify",
        ]
    )


def is_volatile_field(
    field: str,
) -> bool:
    lower = field.lower()

    return any(
        token in lower
        for token in VOLATILE_FIELD_TOKENS
    )


def normalized_summary(
    fields: Sequence[str],
    row: Dict[str, str],
) -> Dict[str, str]:
    return {
        field: str(
            row.get(field, "")
        )
        for field in fields
        if not is_volatile_field(field)
    }


def last_summary_row(
    path: Path,
) -> Tuple[List[str], Dict[str, str]]:
    fields, rows = read_csv(path)

    if not rows:
        raise RuntimeError(
            f"Empty summary: {path}"
        )

    return fields, rows[-1]


def find_alias_value(
    row: Dict[str, str],
    aliases: Sequence[str],
):
    for alias in aliases:
        if alias not in row:
            continue

        value = str(
            row.get(alias, "")
        ).strip()

        if value:
            return alias, value

    return None, None


def load_run(
    name: str,
    root: Path,
):
    raw_path = (
        root
        / "full_agent_candidate_rows.csv"
    )

    fields, rows = read_csv(raw_path)

    if len(rows) != EXPECTED_ROWS:
        raise RuntimeError(
            f"{name}: expected {EXPECTED_ROWS} rows, "
            f"found {len(rows)}."
        )

    keys = [
        key_for(row)
        for row in rows
    ]

    if len(set(keys)) != EXPECTED_ROWS:
        raise RuntimeError(
            f"{name}: duplicate candidate keys."
        )

    seeds = {
        int(round(float(row["seed"])))
        for row in rows
    }

    cases = {
        row["case_type"]
        for row in rows
    }

    if seeds != EXPECTED_SEEDS:
        raise RuntimeError(
            f"{name}: seed set mismatch."
        )

    if cases != EXPECTED_CASES:
        raise RuntimeError(
            f"{name}: case set mismatch."
        )

    if not all(
        notes_policy_pass(row)
        for row in rows
    ):
        raise RuntimeError(
            f"{name}: notes policy validation failed."
        )

    lookup = {
        key_for(row): row
        for row in rows
    }

    return {
        "name": name,
        "root": root,
        "raw_path": raw_path,
        "raw_sha256": sha256(raw_path),
        "fields": fields,
        "rows": rows,
        "lookup": lookup,
        "keys": set(lookup),
    }


def compare_runs(
    reference,
    candidate,
):
    pair_name = (
        f"{reference['name']}"
        f"_vs_{candidate['name']}"
    )

    raw_mismatches = []
    summary_mismatches = []
    summary_schema_mismatches = []
    stdout_hash_matches = 0
    stdout_files = 0
    stderr_nonempty = []
    normalized_field_counts = []

    if reference["keys"] != candidate["keys"]:
        raise RuntimeError(
            f"{pair_name}: candidate-key mismatch."
        )

    for key in sorted(
        reference["keys"]
    ):
        reference_row = reference[
            "lookup"
        ][key]

        candidate_row = candidate[
            "lookup"
        ][key]

        if stable_raw_row(
            reference_row
        ) != stable_raw_row(
            candidate_row
        ):
            differing = sorted(
                field
                for field in stable_raw_row(
                    reference_row
                )
                if stable_raw_row(
                    reference_row
                ).get(field)
                != stable_raw_row(
                    candidate_row
                ).get(field)
            )

            raw_mismatches.append({
                "comparison": pair_name,
                "case_type": key[0],
                "seed": key[1],
                "agent_variant": key[2],
                "candidate_id": key[3],
                "differing_fields": "|".join(
                    differing
                ),
            })

        for branch in [
            "no_verify",
            "always_verify",
        ]:
            case_type, seed, agent, _ = key

            relative = (
                Path(
                    f"case={case_type}"
                )
                / f"seed={seed}"
                / f"agent={agent}"
            )

            reference_summary = (
                reference["root"]
                / "logs"
                / relative
                / f"{branch}_summary.csv"
            )

            candidate_summary = (
                candidate["root"]
                / "logs"
                / relative
                / f"{branch}_summary.csv"
            )

            (
                reference_fields,
                reference_summary_row,
            ) = last_summary_row(
                reference_summary
            )

            (
                candidate_fields,
                candidate_summary_row,
            ) = last_summary_row(
                candidate_summary
            )

            if reference_fields != candidate_fields:
                summary_schema_mismatches.append({
                    "comparison": pair_name,
                    "case_type": case_type,
                    "seed": seed,
                    "branch": branch,
                    "reference_fields": "|".join(
                        reference_fields
                    ),
                    "candidate_fields": "|".join(
                        candidate_fields
                    ),
                })

            reference_normalized = normalized_summary(
                reference_fields,
                reference_summary_row,
            )

            candidate_normalized = normalized_summary(
                candidate_fields,
                candidate_summary_row,
            )

            normalized_field_counts.append(
                len(
                    reference_normalized
                )
            )

            if (
                reference_normalized
                != candidate_normalized
            ):
                all_fields = sorted(
                    set(reference_normalized)
                    | set(candidate_normalized)
                )

                differing = [
                    field
                    for field in all_fields
                    if reference_normalized.get(
                        field
                    )
                    != candidate_normalized.get(
                        field
                    )
                ]

                summary_mismatches.append({
                    "comparison": pair_name,
                    "case_type": case_type,
                    "seed": seed,
                    "branch": branch,
                    "differing_fields": "|".join(
                        differing
                    ),
                })

            reference_stdout = (
                reference["root"]
                / "logs"
                / relative
                / f"{branch}.stdout.log"
            )

            candidate_stdout = (
                candidate["root"]
                / "logs"
                / relative
                / f"{branch}.stdout.log"
            )

            stdout_files += 1

            if (
                sha256(reference_stdout)
                == sha256(candidate_stdout)
            ):
                stdout_hash_matches += 1

            for name, stderr_path in [
                (
                    reference["name"],
                    reference["root"]
                    / "logs"
                    / relative
                    / f"{branch}.stderr.log",
                ),
                (
                    candidate["name"],
                    candidate["root"]
                    / "logs"
                    / relative
                    / f"{branch}.stderr.log",
                ),
            ]:
                if stderr_path.stat().st_size != 0:
                    stderr_nonempty.append({
                        "run": name,
                        "case_type": case_type,
                        "seed": seed,
                        "branch": branch,
                        "stderr_path": str(
                            stderr_path
                        ),
                        "size_bytes": (
                            stderr_path.stat().st_size
                        ),
                    })

    return {
        "comparison": pair_name,
        "raw_mismatches": raw_mismatches,
        "summary_mismatches": (
            summary_mismatches
        ),
        "summary_schema_mismatches": (
            summary_schema_mismatches
        ),
        "stdout_hash_matches": (
            stdout_hash_matches
        ),
        "stdout_files": stdout_files,
        "stderr_nonempty": stderr_nonempty,
        "minimum_normalized_summary_fields": (
            min(normalized_field_counts)
            if normalized_field_counts
            else 0
        ),
    }


def within_run_branch_identity(
    run,
):
    rows = []
    mismatch_count = 0
    compared_fields = 0

    for key in sorted(run["keys"]):
        case_type, seed, agent, candidate = key

        relative = (
            Path(
                f"case={case_type}"
            )
            / f"seed={seed}"
            / f"agent={agent}"
        )

        no_fields, no_row = last_summary_row(
            run["root"]
            / "logs"
            / relative
            / "no_verify_summary.csv"
        )

        yes_fields, yes_row = last_summary_row(
            run["root"]
            / "logs"
            / relative
            / "always_verify_summary.csv"
        )

        for concept, aliases in (
            IDENTITY_ALIAS_GROUPS.items()
        ):
            no_field, no_value = find_alias_value(
                no_row,
                aliases,
            )

            yes_field, yes_value = find_alias_value(
                yes_row,
                aliases,
            )

            if (
                no_value is None
                or yes_value is None
            ):
                continue

            compared_fields += 1

            matched = (
                no_value == yes_value
            )

            if not matched:
                mismatch_count += 1

            rows.append({
                "run": run["name"],
                "case_type": case_type,
                "seed": seed,
                "agent_variant": agent,
                "candidate_id": candidate,
                "concept": concept,
                "no_verify_field": no_field,
                "always_verify_field": yes_field,
                "no_verify_value": no_value,
                "always_verify_value": yes_value,
                "matched": matched,
            })

    return {
        "rows": rows,
        "compared_identity_fields": (
            compared_fields
        ),
        "identity_mismatch_count": (
            mismatch_count
        ),
    }


def source_audit():
    collector_path = Path(
        "code/evva_v4_full_agent_candidate_collector.py"
    )

    text = collector_path.read_text(
        encoding="utf-8"
    )

    no_call = (
        'run_branch(runner, case_type, seed, '
        'agent_variant, "no_verify", '
        'trace_dir, notes)'
    )

    yes_call = (
        'run_branch(runner, case_type, seed, '
        'agent_variant, "always_verify", '
        'trace_dir, notes)'
    )

    runner_text = RUNNER.read_text(
        encoding="utf-8",
        errors="replace",
    )

    keyword_patterns = {
        "python_random_seed": (
            r"\brandom\.seed\s*\("
        ),
        "numpy_random_seed": (
            r"\b(?:np|numpy)\.random\.seed\s*\("
        ),
        "numpy_default_rng": (
            r"\bdefault_rng\s*\("
        ),
        "torch_manual_seed": (
            r"\btorch\.manual_seed\s*\("
        ),
        "seed_cli_reference": (
            r"(?:--seed|\bseed\b)"
        ),
        "state_reset_reference": (
            r"(?:reset|snapshot|checkpoint|"
            r"initial_state|restore)"
        ),
    }

    runner_keyword_audit = {
        name: bool(
            re.search(
                pattern,
                runner_text,
                flags=re.IGNORECASE,
            )
        )
        for name, pattern
        in keyword_patterns.items()
    }

    return {
        "collector_path": str(
            collector_path
        ),
        "collector_sha256": sha256(
            collector_path
        ),
        "runner_path": str(
            RUNNER
        ),
        "runner_sha256": sha256(
            RUNNER
        ),
        "collector_has_no_verify_call": (
            no_call in text
        ),
        "collector_has_always_verify_call": (
            yes_call in text
        ),
        "collector_uses_subprocess_run": (
            "subprocess.run(" in text
        ),
        "same_seed_variable_used_for_both_branches": (
            no_call in text
            and yes_call in text
        ),
        "runner_keyword_audit": (
            runner_keyword_audit
        ),
    }


def main() -> None:
    loaded = {
        name: load_run(
            name,
            root,
        )
        for name, root in RUNS.items()
    }

    comparisons = [
        compare_runs(
            loaded["forward_1"],
            loaded["forward_2"],
        ),
        compare_runs(
            loaded["forward_1"],
            loaded["reverse_1"],
        ),
    ]

    identity_results = [
        within_run_branch_identity(
            loaded[name]
        )
        for name in [
            "forward_1",
            "forward_2",
            "reverse_1",
        ]
    ]

    raw_mismatches = [
        row
        for comparison in comparisons
        for row in comparison[
            "raw_mismatches"
        ]
    ]

    summary_mismatches = [
        row
        for comparison in comparisons
        for row in comparison[
            "summary_mismatches"
        ]
    ]

    schema_mismatches = [
        row
        for comparison in comparisons
        for row in comparison[
            "summary_schema_mismatches"
        ]
    ]

    stderr_nonempty = [
        row
        for comparison in comparisons
        for row in comparison[
            "stderr_nonempty"
        ]
    ]

    identity_rows = [
        row
        for result in identity_results
        for row in result["rows"]
    ]

    identity_mismatches = [
        row
        for row in identity_rows
        if not row["matched"]
    ]

    source = source_audit()

    all_run_rows_correct = all(
        len(run["rows"]) == EXPECTED_ROWS
        for run in loaded.values()
    )

    minimum_normalized_fields = min(
        comparison[
            "minimum_normalized_summary_fields"
        ]
        for comparison in comparisons
    )

    hard_pass = all([
        all_run_rows_correct,
        not raw_mismatches,
        not summary_mismatches,
        not schema_mismatches,
        not stderr_nonempty,
        not identity_mismatches,
        minimum_normalized_fields > 0,
        source[
            "collector_has_no_verify_call"
        ],
        source[
            "collector_has_always_verify_call"
        ],
        source[
            "collector_uses_subprocess_run"
        ],
        source[
            "same_seed_variable_used_for_both_branches"
        ],
    ])

    comparison_reports = []

    for comparison in comparisons:
        comparison_reports.append({
            "comparison": comparison[
                "comparison"
            ],
            "raw_mismatch_count": len(
                comparison[
                    "raw_mismatches"
                ]
            ),
            "normalized_summary_mismatch_count": len(
                comparison[
                    "summary_mismatches"
                ]
            ),
            "summary_schema_mismatch_count": len(
                comparison[
                    "summary_schema_mismatches"
                ]
            ),
            "stdout_exact_hash_match_count": (
                comparison[
                    "stdout_hash_matches"
                ]
            ),
            "stdout_file_count": (
                comparison[
                    "stdout_files"
                ]
            ),
            "stderr_nonempty_count": len(
                comparison[
                    "stderr_nonempty"
                ]
            ),
            "minimum_normalized_summary_fields": (
                comparison[
                    "minimum_normalized_summary_fields"
                ]
            ),
        })

    summary = {
        "status": "complete",
        "decision": (
            "PASS"
            if hard_pass
            else "FAIL"
        ),
        "development_seeds_only": True,
        "confirmation_seeds_used": False,
        "runs": {
            name: {
                "rows": len(
                    run["rows"]
                ),
                "raw_path": str(
                    run["raw_path"]
                ),
                "raw_sha256": (
                    run["raw_sha256"]
                ),
            }
            for name, run
            in loaded.items()
        },
        "comparison_reports": (
            comparison_reports
        ),
        "raw_scientific_field_mismatch_count": len(
            raw_mismatches
        ),
        "normalized_branch_summary_mismatch_count": len(
            summary_mismatches
        ),
        "summary_schema_mismatch_count": len(
            schema_mismatches
        ),
        "stderr_nonempty_count": len(
            stderr_nonempty
        ),
        "within_pair_identity_fields_compared": sum(
            result[
                "compared_identity_fields"
            ]
            for result in identity_results
        ),
        "within_pair_identity_mismatch_count": len(
            identity_mismatches
        ),
        "source_audit": source,
        "interpretation": (
            "PASS means candidate-level scientific outputs "
            "and normalized branch summaries reproduced "
            "exactly across an independent rerun and after "
            "reversing branch execution order. Together with "
            "separate subprocess invocation using the same seed, "
            "this provides process-level evidence against "
            "cross-branch order contamination. It does not claim "
            "formal proof about external state not represented "
            "in the runner."
        ),
        "method_modified": False,
        "confirmation_decision_modified": False,
    }

    with (
        OUT
        / "reports"
        / "deterministic_replay_summary.json"
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

    with (
        OUT
        / "reports"
        / "runner_source_audit.json"
    ).open(
        "w",
        encoding="utf-8",
    ) as handle:
        json.dump(
            source,
            handle,
            indent=2,
            sort_keys=True,
        )

    write_csv(
        OUT
        / "results"
        / "raw_mismatches.csv",
        raw_mismatches,
        [
            "comparison",
            "case_type",
            "seed",
            "agent_variant",
            "candidate_id",
            "differing_fields",
        ],
    )

    write_csv(
        OUT
        / "results"
        / "summary_mismatches.csv",
        summary_mismatches,
        [
            "comparison",
            "case_type",
            "seed",
            "branch",
            "differing_fields",
        ],
    )

    write_csv(
        OUT
        / "results"
        / "summary_schema_mismatches.csv",
        schema_mismatches,
        [
            "comparison",
            "case_type",
            "seed",
            "branch",
            "reference_fields",
            "candidate_fields",
        ],
    )

    write_csv(
        OUT
        / "results"
        / "stderr_nonempty.csv",
        stderr_nonempty,
        [
            "run",
            "case_type",
            "seed",
            "branch",
            "stderr_path",
            "size_bytes",
        ],
    )

    write_csv(
        OUT
        / "results"
        / "within_pair_identity_checks.csv",
        identity_rows,
        [
            "run",
            "case_type",
            "seed",
            "agent_variant",
            "candidate_id",
            "concept",
            "no_verify_field",
            "always_verify_field",
            "no_verify_value",
            "always_verify_value",
            "matched",
        ],
    )

    write_csv(
        OUT
        / "results"
        / "comparison_summary.csv",
        comparison_reports,
        [
            "comparison",
            "raw_mismatch_count",
            "normalized_summary_mismatch_count",
            "summary_schema_mismatch_count",
            "stdout_exact_hash_match_count",
            "stdout_file_count",
            "stderr_nonempty_count",
            "minimum_normalized_summary_fields",
        ],
    )

    print(
        json.dumps(
            summary,
            indent=2,
            sort_keys=True,
        )
    )

    if not hard_pass:
        raise SystemExit(
            "Deterministic replay audit failed."
        )


if __name__ == "__main__":
    main()
PY

python3 -m py_compile \
  "$OUT/code/evva3_stage6b_replay_audit.py" \
  || die "Stage 6B audit failed py_compile."

python3 \
  "$OUT/code/evva3_stage6b_replay_audit.py" \
  2>&1 | tee "$OUT/logs/stage6b_replay_audit.log"

STATUS="${PIPESTATUS[0]}"

[ "$STATUS" -eq 0 ] \
  || die "Stage 6B replay audit failed."

for required in \
  "$OUT/reports/deterministic_replay_summary.json" \
  "$OUT/reports/runner_source_audit.json" \
  "$OUT/results/comparison_summary.csv" \
  "$OUT/results/raw_mismatches.csv" \
  "$OUT/results/summary_mismatches.csv" \
  "$OUT/results/within_pair_identity_checks.csv"
do
  [ -f "$required" ] \
    || die "Missing Stage 6B output: $required"
done

{
  sha256sum "$COLLECTOR"
  sha256sum "$RUNNER"
  sha256sum "$STAGE5B_DECISION"
  sha256sum "$STAGE6A_SUMMARY"
  sha256sum "$STAGE5A/c1_6500_6799/raw/full_agent_candidate_rows_6500_6799.csv"
  sha256sum "$STAGE5A/c2_6800_7099/raw/full_agent_candidate_rows_6800_7099.csv"
} > "$OUT/hashes/post_replay_frozen_sha256.txt"

cmp -s \
  "$OUT/hashes/pre_replay_frozen_sha256.txt" \
  "$OUT/hashes/post_replay_frozen_sha256.txt" \
  || die "A frozen input changed during Stage 6B."

cat > "$OUT/reports/STAGE6B_COMPLETE.md" <<'MD'
# EVVA_3 Stage 6B completion

The full-agent branch protocol was replayed three times on development seeds:

1. normal branch order;
2. independent normal-order replay;
3. reversed branch order.

Candidate-level scientific outputs and branch summaries were compared without
using C1/C2 or modifying the frozen method.

A PASS provides process-level deterministic replay and branch-order-invariance
evidence. It does not overstate this as formal proof about external state that
is not represented in the runner or saved artifacts.
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
echo "EVVA_3 STAGE 6B DETERMINISTIC REPLAY COMPLETE"
echo "===================================================="
echo "Output: $OUT"
echo

cat "$OUT/reports/deterministic_replay_summary.json"

echo
echo "Comparison summary:"
column -s, -t \
  < "$OUT/results/comparison_summary.csv"

echo
echo "PASS: Stage 6B completed without modifying frozen inputs."

#!/usr/bin/env bash

die() {
  echo "ERROR: $*" >&2
  exit 1
}

WORKSPACE="$HOME/.openclaw/workspace/skills/openclaw_pilot_v4_large_exactB_20260707_EVVA_3_signal_repair_20260713"

[ -d "$WORKSPACE" ] || die "Workspace not found."
cd "$WORKSPACE" || die "Cannot enter workspace."

RUN_ID="$(date +%Y%m%d_%H%M%S)"
OUT="artifacts/evva3_stage4a_factorization_audit_${RUN_ID}"

mkdir -p \
  "$OUT/code" \
  "$OUT/results" \
  "$OUT/reports" \
  "$OUT/hashes" \
  "$OUT/logs" \
  || die "Cannot create output directory."

echo "$OUT" > artifacts/evva3_stage4a_latest.txt

cat > "$OUT/code/evva3_stage4a_factorization_audit.py" <<'PY'
#!/usr/bin/env python3

import csv
import json
import math
import statistics
from collections import defaultdict
from pathlib import Path


DATASETS = [
    (
        "controlled",
        Path(
            "artifacts/evva_v5j_fair_controlled_prm_20260709/"
            "fair_controlled_train_eval_rows.csv"
        ),
    ),
    (
        "original_4200_4499",
        Path(
            "artifacts/v4_full_agent_20260707/large/"
            "full_agent_candidate_rows_large.csv"
        ),
    ),
    (
        "first_5000_5299",
        Path(
            "artifacts/evva2_exploratory_20260713/"
            "evva2g_confirmatory_5000_5299/raw/"
            "full_agent_candidate_rows_5000_5299.csv"
        ),
    ),
    (
        "r2_5300_5599",
        Path(
            "artifacts/evva2_exploratory_20260713/"
            "evva2g_replication_r2_5300_5599/raw/"
            "full_agent_candidate_rows_5300_5599.csv"
        ),
    ),
    (
        "r3_5600_5899",
        Path(
            "artifacts/evva2_exploratory_20260713/"
            "evva2g_replication_r3_5600_5899/raw/"
            "full_agent_candidate_rows_5600_5899.csv"
        ),
    ),
    (
        "r4_5900_6199",
        Path(
            "artifacts/evva2_exploratory_20260713/"
            "evva2h_final_confirmation_20260713/"
            "r4_5900_6199/raw/"
            "full_agent_candidate_rows_5900_6199.csv"
        ),
    ),
    (
        "r5_6200_6499",
        Path(
            "artifacts/evva2_exploratory_20260713/"
            "evva2h_final_confirmation_20260713/"
            "r5_6200_6499/raw/"
            "full_agent_candidate_rows_6200_6499.csv"
        ),
    ),
]

OUT = Path(
    __import__("os").environ["EVVA3_STAGE4A_OUT"]
)

EPSILON = 1e-9
TOLERANCE = 1e-8


def number(value):
    try:
        text = str(value).strip()

        if not text:
            return None

        result = float(text)

        if not math.isfinite(result):
            return None

        return result
    except Exception:
        return None


def quantile(values, probability):
    if not values:
        return None

    ordered = sorted(values)

    position = probability * (len(ordered) - 1)
    lower = int(math.floor(position))
    upper = int(math.ceil(position))

    if lower == upper:
        return ordered[lower]

    weight = position - lower

    return (
        ordered[lower] * (1.0 - weight)
        + ordered[upper] * weight
    )


def write_csv(path, rows, fields):
    path.parent.mkdir(parents=True, exist_ok=True)

    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=fields,
            extrasaction="ignore",
        )
        writer.writeheader()
        writer.writerows(rows)


def derive_avoidable_harm(row):
    direct = number(row.get("branch_harm_exact"))

    if direct is not None:
        return max(0.0, direct), "branch_harm_exact"

    wrong = number(
        row.get("reward_wrong_continuation")
    )
    corrected = number(
        row.get("reward_corrected_continuation")
    )

    if wrong is not None and corrected is not None:
        return (
            max(0.0, corrected - wrong),
            "corrected_minus_wrong",
        )

    return None, "unavailable"


def summarize_group(dataset, rows):
    gains = []
    harms = []
    ratios = []

    positive_harm = 0
    positive_gain = 0
    zero_gain_positive_harm = 0
    positive_gain_zero_harm = 0
    gain_exceeds_harm = 0
    negative_gain = 0
    near_full_recovery = 0
    partial_recovery = 0
    zero_recovery = 0

    source_counts = defaultdict(int)

    enriched = []

    for row in rows:
        gain = number(row.get("intervention_gain"))
        harm, source = derive_avoidable_harm(row)

        source_counts[source] += 1

        if gain is None or harm is None:
            continue

        gains.append(gain)
        harms.append(harm)

        if gain < -TOLERANCE:
            negative_gain += 1

        if gain > TOLERANCE:
            positive_gain += 1

        if harm > TOLERANCE:
            positive_harm += 1
            ratio = gain / harm
            ratios.append(ratio)

            if abs(gain) <= TOLERANCE:
                zero_gain_positive_harm += 1

            if gain > harm + TOLERANCE:
                gain_exceeds_harm += 1

            if ratio <= TOLERANCE:
                zero_recovery += 1
            elif ratio >= 1.0 - 1e-6:
                near_full_recovery += 1
            else:
                partial_recovery += 1
        else:
            ratio = None

            if gain > TOLERANCE:
                positive_gain_zero_harm += 1

        enriched.append({
            "dataset": dataset,
            "seed": row.get("seed", ""),
            "split": row.get("split", ""),
            "case_type": row.get("case_type", ""),
            "intervention_gain": gain,
            "avoidable_harm": harm,
            "recoverability_fraction": (
                ratio if ratio is not None else ""
            ),
            "harm_source": source,
            "p_score": (
                number(row.get("p_score"))
                if number(row.get("p_score")) is not None
                else number(row.get("score_p_only"))
            ),
            "harm_score": (
                number(row.get("harm_score"))
                if number(row.get("harm_score")) is not None
                else number(row.get("score_H_only"))
            ),
            "rollback_difficulty": number(
                row.get("rollback_difficulty")
            ),
            "persistent_state_risk": number(
                row.get("persistent_state_risk")
            ),
            "downstream_dependency_count": number(
                row.get("downstream_dependency_count")
            ),
        })

    summary = {
        "dataset": dataset,
        "raw_rows": len(rows),
        "usable_factorization_rows": len(gains),
        "harm_source_counts": dict(source_counts),
        "negative_gain_rows": negative_gain,
        "positive_gain_rows": positive_gain,
        "positive_harm_rows": positive_harm,
        "zero_gain_positive_harm_rows": (
            zero_gain_positive_harm
        ),
        "positive_gain_zero_harm_rows": (
            positive_gain_zero_harm
        ),
        "gain_exceeds_harm_rows": gain_exceeds_harm,
        "recoverability_rows": len(ratios),
        "recoverability_within_0_1_fraction": (
            sum(
                -TOLERANCE <= value <= 1.0 + TOLERANCE
                for value in ratios
            )
            / len(ratios)
            if ratios
            else None
        ),
        "recoverability_zero_fraction": (
            zero_recovery / len(ratios)
            if ratios
            else None
        ),
        "recoverability_partial_fraction": (
            partial_recovery / len(ratios)
            if ratios
            else None
        ),
        "recoverability_near_one_fraction": (
            near_full_recovery / len(ratios)
            if ratios
            else None
        ),
        "recoverability_q00": (
            min(ratios) if ratios else None
        ),
        "recoverability_q25": quantile(
            ratios,
            0.25,
        ),
        "recoverability_q50": quantile(
            ratios,
            0.50,
        ),
        "recoverability_q75": quantile(
            ratios,
            0.75,
        ),
        "recoverability_q100": (
            max(ratios) if ratios else None
        ),
        "mean_intervention_gain": (
            statistics.fmean(gains)
            if gains
            else None
        ),
        "mean_avoidable_harm": (
            statistics.fmean(harms)
            if harms
            else None
        ),
    }

    return summary, enriched


def feature_bins(enriched):
    output = []

    features = [
        "rollback_difficulty",
        "persistent_state_risk",
        "downstream_dependency_count",
    ]

    for feature in features:
        groups = defaultdict(list)

        for row in enriched:
            value = row.get(feature)
            harm = row.get("avoidable_harm")
            ratio = row.get("recoverability_fraction")
            gain = row.get("intervention_gain")

            if value is None or harm is None:
                continue

            groups[value].append((gain, harm, ratio))

        for value in sorted(groups):
            entries = groups[value]

            ratios = [
                ratio
                for _, harm, ratio in entries
                if harm > TOLERANCE
                and ratio != ""
                and ratio is not None
            ]

            output.append({
                "dataset": enriched[0]["dataset"],
                "feature": feature,
                "feature_value": value,
                "rows": len(entries),
                "positive_gain_fraction": (
                    sum(gain > TOLERANCE for gain, _, _ in entries)
                    / len(entries)
                ),
                "mean_intervention_gain": statistics.fmean(
                    gain for gain, _, _ in entries
                ),
                "mean_avoidable_harm": statistics.fmean(
                    harm for _, harm, _ in entries
                ),
                "mean_recoverability_fraction": (
                    statistics.fmean(ratios)
                    if ratios
                    else ""
                ),
                "median_recoverability_fraction": (
                    quantile(ratios, 0.50)
                    if ratios
                    else ""
                ),
            })

    return output


def main():
    summary_rows = []
    enriched_rows = []
    bin_rows = []
    missing_files = []

    for dataset, path in DATASETS:
        if not path.is_file():
            missing_files.append(str(path))
            continue

        with path.open(
            newline="",
            encoding="utf-8-sig",
        ) as handle:
            rows = list(csv.DictReader(handle))

        summary, enriched = summarize_group(
            dataset,
            rows,
        )

        summary_rows.append(summary)
        enriched_rows.extend(enriched)

        if enriched:
            bin_rows.extend(
                feature_bins(enriched)
            )

    write_csv(
        OUT / "results" / "factorization_summary.csv",
        summary_rows,
        [
            "dataset",
            "raw_rows",
            "usable_factorization_rows",
            "harm_source_counts",
            "negative_gain_rows",
            "positive_gain_rows",
            "positive_harm_rows",
            "zero_gain_positive_harm_rows",
            "positive_gain_zero_harm_rows",
            "gain_exceeds_harm_rows",
            "recoverability_rows",
            "recoverability_within_0_1_fraction",
            "recoverability_zero_fraction",
            "recoverability_partial_fraction",
            "recoverability_near_one_fraction",
            "recoverability_q00",
            "recoverability_q25",
            "recoverability_q50",
            "recoverability_q75",
            "recoverability_q100",
            "mean_intervention_gain",
            "mean_avoidable_harm",
        ],
    )

    write_csv(
        OUT / "results" / "row_level_factorization.csv",
        enriched_rows,
        [
            "dataset",
            "seed",
            "split",
            "case_type",
            "intervention_gain",
            "avoidable_harm",
            "recoverability_fraction",
            "harm_source",
            "p_score",
            "harm_score",
            "rollback_difficulty",
            "persistent_state_risk",
            "downstream_dependency_count",
        ],
    )

    write_csv(
        OUT / "results" / "structural_feature_bins.csv",
        bin_rows,
        [
            "dataset",
            "feature",
            "feature_value",
            "rows",
            "positive_gain_fraction",
            "mean_intervention_gain",
            "mean_avoidable_harm",
            "mean_recoverability_fraction",
            "median_recoverability_fraction",
        ],
    )

    report = {
        "status": "complete",
        "datasets_requested": len(DATASETS),
        "datasets_processed": len(summary_rows),
        "missing_files": missing_files,
        "new_seed_collection": False,
        "model_training": False,
        "purpose": (
            "Test whether intervention gain admits an "
            "avoidable-harm times recoverability factorization."
        ),
    }

    with (
        OUT / "reports" / "stage4a_summary.json"
    ).open("w", encoding="utf-8") as handle:
        json.dump(
            report,
            handle,
            indent=2,
            sort_keys=True,
        )

    print(json.dumps(report, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
PY

export EVVA3_STAGE4A_OUT="$OUT"

python3 -m py_compile \
  "$OUT/code/evva3_stage4a_factorization_audit.py" \
  || die "Stage 4A failed py_compile."

python3 \
  "$OUT/code/evva3_stage4a_factorization_audit.py" \
  2>&1 | tee "$OUT/logs/stage4a.log"

STATUS="${PIPESTATUS[0]}"

[ "$STATUS" -eq 0 ] \
  || die "Stage 4A failed with status $STATUS."

find "$OUT" \
  -type f \
  ! -name 'FINAL_SHA256SUMS.txt' \
  -print0 \
  | sort -z \
  | xargs -0 sha256sum \
  > "$OUT/FINAL_SHA256SUMS.txt"

echo
echo "===================================================="
echo "EVVA_3 STAGE 4A FACTORIZATION AUDIT COMPLETE"
echo "===================================================="
echo "Output: $OUT"

cat "$OUT/reports/stage4a_summary.json"

echo
echo "Factorization summary:"
column -s, -t \
  < "$OUT/results/factorization_summary.csv"

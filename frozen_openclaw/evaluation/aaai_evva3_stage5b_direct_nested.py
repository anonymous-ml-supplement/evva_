#!/usr/bin/env python3
"""Direct true-nested Stage 5B combined bootstrap correction.

For every outer sampled block occurrence:

1. Select C1 or C2 through block-level sampling with replacement.
2. Directly resample sealed evaluation seed clusters with replacement.
3. Keep all three case rows belonging to each sampled seed together.
4. Recompute the Final minus Locked AUBC statistic.
5. Average the two independently generated occurrence statistics.

This script does not sample from a precomputed inner-bootstrap pool.
"""

from __future__ import annotations

import csv
import hashlib
import importlib.util
import json
import math
import os
import shutil
import statistics
from pathlib import Path
from typing import Dict, List, Mapping, Sequence

import numpy as np


DIRECT_ROOT = Path(
    os.environ["EVVA3_DIRECT_ROOT"]
).resolve()

SOURCE_ROOT = Path(
    os.environ["EVVA3_SOURCE_ROOT"]
).resolve()

FULL_ROOT = (
    SOURCE_ROOT
    / "inputs"
    / "full_archive"
)

OUTPUT_ROOT = (
    DIRECT_ROOT
    / "outputs"
    / "stage5b_direct_nested"
)

REPORT_ROOT = DIRECT_ROOT / "reports"

MASTER_SEED = 20260714
BOOTSTRAP_REPETITIONS = 10000
EXPECTED_CASES = {
    "dependency_sensitive",
    "corruption_prone",
    "dep_sensitive_held_out",
}

C1_PATH = (
    FULL_ROOT
    / "artifacts"
    / "aaai_evva3_stage5a_c1_c2_untouched_20260714"
    / "c1_6500_6799"
    / "raw"
    / "full_agent_candidate_rows_6500_6799.csv"
)

C2_PATH = (
    FULL_ROOT
    / "artifacts"
    / "aaai_evva3_stage5a_c1_c2_untouched_20260714"
    / "c2_6800_7099"
    / "raw"
    / "full_agent_candidate_rows_6800_7099.csv"
)

V5M_PATH = (
    FULL_ROOT
    / "code"
    / "aaai_v5m_signal_availability_gated_evva.py"
)

FINAL_PATH = (
    FULL_ROOT
    / "artifacts"
    / "aaai_evva3_stage4f_final_method_freeze_20260714_154218"
    / "code"
    / "aaai_evva3_final_evva_sag.py"
)

PREREG_PATH = (
    FULL_ROOT
    / "artifacts"
    / "aaai_evva3_stage4f_final_method_freeze_20260714_154218"
    / "manifests"
    / "C1_C2_PREREGISTRATION.json"
)

ORIGINAL_STAGE5B_CODE = (
    FULL_ROOT
    / "artifacts"
    / "aaai_evva3_stage5b_c1_c2_confirmatory_20260714"
    / "code"
    / "aaai_evva3_stage5b_confirmatory_eval.py"
)

CLEAN_STAGE5B = (
    SOURCE_ROOT
    / "outputs"
    / "stage5b_corrected"
)

ORIGINAL_BOOTSTRAP = (
    FULL_ROOT
    / "artifacts"
    / "aaai_evva3_stage5b_c1_c2_confirmatory_20260714"
    / "results"
    / "bootstrap.csv"
)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()

    with path.open("rb") as handle:
        for chunk in iter(
            lambda: handle.read(1024 * 1024),
            b"",
        ):
            digest.update(chunk)

    return digest.hexdigest()


def load_module(name: str, path: Path):
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
            f"Cannot import module: {path}"
        )

    module = importlib.util.module_from_spec(
        specification
    )

    specification.loader.exec_module(
        module
    )

    return module


def read_csv(path: Path) -> List[Dict[str, str]]:
    with path.open(
        newline="",
        encoding="utf-8-sig",
    ) as handle:
        return list(
            csv.DictReader(handle)
        )


def write_csv(
    path: Path,
    rows: Sequence[Mapping[str, object]],
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


def write_json(
    path: Path,
    payload,
) -> None:
    path.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    path.write_text(
        json.dumps(
            payload,
            indent=2,
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )


def cluster_resample(
    state: Mapping[str, object],
    rng: np.random.Generator,
):
    seed_indices = state["seed_indices"]

    cluster_sizes = {
        len(indices)
        for indices in seed_indices.values()
    }

    if cluster_sizes != {3}:
        raise RuntimeError(
            "Each evaluation seed must contain "
            "exactly three case rows. "
            f"Observed cluster sizes: {cluster_sizes}"
        )

    seeds = np.asarray(
        sorted(seed_indices),
        dtype=int,
    )

    sampled_seeds = rng.choice(
        seeds,
        size=len(seeds),
        replace=True,
    )

    indices = np.asarray(
        [
            index
            for seed in sampled_seeds
            for index in seed_indices[
                int(seed)
            ]
        ],
        dtype=int,
    )

    if len(indices) != 3 * len(seeds):
        raise RuntimeError(
            "Seed-cluster resampling failed "
            "to preserve three rows per occurrence."
        )

    return sampled_seeds, indices


def delta_from_indices(
    module,
    state: Mapping[str, object],
    indices: np.ndarray,
) -> float:
    gains = state["gains"][indices]

    final_curve = module.curve_from_scores(
        state["scores"][
            "Final-EVVA-SAG"
        ][indices],
        gains,
    )

    locked_curve = []

    for fraction in module.BUDGETS:
        budget = int(
            round(
                fraction * 100
            )
        )

        locked_curve.append(
            module.selected_value(
                state[
                    "locked_budget_scores"
                ][budget][indices],
                gains,
                fraction,
            )
        )

    return float(
        module.aubc(final_curve)
        - module.aubc(locked_curve)
    )


def summarize(
    values: Sequence[float],
) -> Dict[str, float]:
    array = np.asarray(
        values,
        dtype=float,
    )

    return {
        "bootstrap_mean_delta": float(
            np.mean(array)
        ),
        "ci_2_5": float(
            np.quantile(
                array,
                0.025,
            )
        ),
        "ci_97_5": float(
            np.quantile(
                array,
                0.975,
            )
        ),
        "probability_delta_ge_zero": float(
            np.mean(
                array >= 0.0
            )
        ),
    }


def main() -> None:
    required = [
        C1_PATH,
        C2_PATH,
        V5M_PATH,
        FINAL_PATH,
        PREREG_PATH,
        ORIGINAL_STAGE5B_CODE,
        CLEAN_STAGE5B
        / "results"
        / "bootstrap.csv",
        CLEAN_STAGE5B
        / "reports"
        / "confirmatory_decision.json",
        ORIGINAL_BOOTSTRAP,
    ]

    for path in required:
        if not path.exists():
            raise FileNotFoundError(path)

    if sha256(C1_PATH) != (
        "eef3ddd81c955205a9df4e45a8e4062728e1e2c079da1e528c1326af7d67e59f"
    ):
        raise RuntimeError(
            "C1 raw SHA-256 mismatch."
        )

    if sha256(C2_PATH) != (
        "53da435349e5bd3f2205d4a499c57904f455363956b61f3705a5c16358dbf23d"
    ):
        raise RuntimeError(
            "C2 raw SHA-256 mismatch."
        )

    if sha256(V5M_PATH) != (
        "924b6c893036f20ee9d60e90faf34c3beeb0f830af8e6d1c8ffd4dfee904906e"
    ):
        raise RuntimeError(
            "Locked v5m SHA-256 mismatch."
        )

    if sha256(FINAL_PATH) != (
        "3a04b828762cd311e1ec27c1ffdb1f655172d5783503454bf042aa30ab0c042a"
    ):
        raise RuntimeError(
            "Final Stage 4F SHA-256 mismatch."
        )

    # The frozen Final module resolves Locked v5m through
    # code/aaai_v5m_signal_availability_gated_evva.py.
    os.chdir(FULL_ROOT)

    os.environ.update({
        "EVVA3_STAGE5B_OUT": str(
            DIRECT_ROOT
            / "scratch"
            / "stage5b_import"
        ),
        "EVVA3_STAGE5B_C1": str(
            C1_PATH
        ),
        "EVVA3_STAGE5B_C2": str(
            C2_PATH
        ),
        "EVVA3_STAGE5B_V5M": str(
            V5M_PATH
        ),
        "EVVA3_STAGE5B_FINAL": str(
            FINAL_PATH
        ),
        "EVVA3_STAGE5B_PREREG": str(
            PREREG_PATH
        ),
        "EVVA3_STAGE5B_BOOTSTRAP_REPS": str(
            BOOTSTRAP_REPETITIONS
        ),
    })

    module = load_module(
        "evva3_stage5b_direct_nested",
        ORIGINAL_STAGE5B_CODE,
    )

    blocks = [
        module.load_block(
            specification
        )
        for specification in module.BLOCKS
    ]

    states = {
        str(block["name"]): block
        for block in blocks
    }

    for name, state in states.items():
        observed_cases = {
            str(
                row.get(
                    "case_type",
                    "",
                )
            )
            for row in state[
                "evaluation_rows"
            ]
        }

        if observed_cases != EXPECTED_CASES:
            raise RuntimeError(
                f"{name}: unexpected case set "
                f"{observed_cases}"
            )

    clean_rows = read_csv(
        CLEAN_STAGE5B
        / "results"
        / "bootstrap.csv"
    )

    clean_lookup = {
        row["analysis"]: row
        for row in clean_rows
    }

    original_rows = read_csv(
        ORIGINAL_BOOTSTRAP
    )

    original_lookup = {
        row["analysis"]: row
        for row in original_rows
    }

    point_values = {}

    for block_name, state in states.items():
        full_indices = np.arange(
            len(
                state[
                    "evaluation_rows"
                ]
            ),
            dtype=int,
        )

        point_values[
            block_name
        ] = delta_from_indices(
            module,
            state,
            full_indices,
        )

        archived_point = float(
            original_lookup[
                block_name
            ]["point_delta_aubc"]
        )

        if not math.isclose(
            point_values[
                block_name
            ],
            archived_point,
            rel_tol=0.0,
            abs_tol=1e-12,
        ):
            raise RuntimeError(
                f"{block_name} point estimate changed."
            )

    combined_point = statistics.fmean([
        point_values["C1"],
        point_values["C2"],
    ])

    archived_combined_point = float(
        original_lookup[
            "Combined-two-level"
        ]["point_delta_aubc"]
    )

    if not math.isclose(
        combined_point,
        archived_combined_point,
        rel_tol=0.0,
        abs_tol=1e-12,
    ):
        raise RuntimeError(
            "Combined point estimate changed."
        )

    outer_rng = np.random.Generator(
        np.random.PCG64(
            np.random.SeedSequence(
                [
                    MASTER_SEED,
                    5,
                    0,
                ]
            )
        )
    )

    inner_rng = np.random.Generator(
        np.random.PCG64(
            np.random.SeedSequence(
                [
                    MASTER_SEED,
                    5,
                    1,
                ]
            )
        )
    )

    block_names = np.asarray(
        ["C1", "C2"],
        dtype=object,
    )

    corrected_values = []
    trace_rows = []

    repeated_block_draws = 0
    repeated_identical_seed_sequences = 0

    for replicate in range(
        BOOTSTRAP_REPETITIONS
    ):
        sampled_blocks = (
            outer_rng.choice(
                block_names,
                size=2,
                replace=True,
            )
        )

        occurrence_values = []
        occurrence_hashes = []

        for block_value in sampled_blocks:
            block_name = str(
                block_value
            )

            sampled_seeds, indices = (
                cluster_resample(
                    states[block_name],
                    inner_rng,
                )
            )

            occurrence_hashes.append(
                hashlib.sha256(
                    sampled_seeds
                    .astype(np.int64)
                    .tobytes()
                ).hexdigest()
            )

            occurrence_values.append(
                delta_from_indices(
                    module,
                    states[block_name],
                    indices,
                )
            )

        repeated_block = (
            str(sampled_blocks[0])
            == str(sampled_blocks[1])
        )

        identical_seed_sequence = (
            occurrence_hashes[0]
            == occurrence_hashes[1]
        )

        if repeated_block:
            repeated_block_draws += 1

            if identical_seed_sequence:
                repeated_identical_seed_sequences += 1

        combined_value = statistics.fmean(
            occurrence_values
        )

        corrected_values.append(
            combined_value
        )

        trace_rows.append({
            "replicate": replicate,
            "sampled_block_1": str(
                sampled_blocks[0]
            ),
            "sampled_block_2": str(
                sampled_blocks[1]
            ),
            "block_1_seed_sequence_sha256": (
                occurrence_hashes[0]
            ),
            "block_2_seed_sequence_sha256": (
                occurrence_hashes[1]
            ),
            "repeated_block": repeated_block,
            "identical_seed_sequence": (
                identical_seed_sequence
            ),
            "combined_delta_aubc": (
                combined_value
            ),
        })

    corrected = summarize(
        corrected_values
    )

    if OUTPUT_ROOT.exists():
        raise RuntimeError(
            "Refusing to overwrite existing "
            f"direct Stage 5B output: {OUTPUT_ROOT}"
        )

    shutil.copytree(
        CLEAN_STAGE5B,
        OUTPUT_ROOT,
    )

    corrected_rows = [
        row
        for row in clean_rows
        if row["analysis"]
        != "Combined-two-level"
    ]

    corrected_rows.append({
        "analysis": "Combined-two-level",
        "bootstrap_repetitions": (
            BOOTSTRAP_REPETITIONS
        ),
        "point_delta_aubc": (
            combined_point
        ),
        "bootstrap_mean_delta": (
            corrected[
                "bootstrap_mean_delta"
            ]
        ),
        "ci_2_5": corrected[
            "ci_2_5"
        ],
        "ci_97_5": corrected[
            "ci_97_5"
        ],
        "probability_delta_ge_zero": (
            corrected[
                "probability_delta_ge_zero"
            ]
        ),
    })

    write_csv(
        OUTPUT_ROOT
        / "results"
        / "bootstrap.csv",
        corrected_rows,
        list(clean_rows[0]),
    )

    decision_path = (
        OUTPUT_ROOT
        / "reports"
        / "confirmatory_decision.json"
    )

    decision = json.loads(
        decision_path.read_text(
            encoding="utf-8"
        )
    )

    decision[
        "combined_bootstrap_ci_2_5"
    ] = corrected["ci_2_5"]

    decision[
        "combined_bootstrap_ci_97_5"
    ] = corrected["ci_97_5"]

    decision[
        "combined_probability_delta_ge_zero"
    ] = corrected[
        "probability_delta_ge_zero"
    ]

    decision[
        "preregistered_criteria"
    ][
        "combined_bootstrap_ci_lower_above_zero"
    ] = corrected["ci_2_5"] > 0.0

    decision[
        "all_preregistered_criteria_pass"
    ] = all(
        decision[
            "preregistered_criteria"
        ].values()
    )

    decision["decision"] = (
        "PASS"
        if decision[
            "all_preregistered_criteria_pass"
        ]
        else "FAIL"
    )

    decision["uncertainty_estimator"] = (
        "Direct true nested block bootstrap "
        "with independent sealed raw seed-cluster "
        "resampling for every sampled block occurrence."
    )

    write_json(
        decision_path,
        decision,
    )

    write_csv(
        DIRECT_ROOT
        / "outputs"
        / "stage5b_direct_nested_draws.csv",
        trace_rows,
        list(trace_rows[0]),
    )

    summary = {
        "status": "PASS",
        "stage": "Priority-0 direct Stage 5B",
        "prng": (
            "NumPy Generator PCG64 "
            "through SeedSequence"
        ),
        "master_seed": MASTER_SEED,
        "bootstrap_repetitions": (
            BOOTSTRAP_REPETITIONS
        ),
        "block_resampling_rule": (
            "Sample two block occurrences "
            "with replacement from C1 and C2."
        ),
        "seed_cluster_resampling_rule": (
            "For every block occurrence, directly "
            "sample sealed evaluation seeds with "
            "replacement and retain all three case "
            "rows for every sampled seed occurrence."
        ),
        "combined_point_delta": (
            combined_point
        ),
        "superseded_original_ci": [
            float(
                original_lookup[
                    "Combined-two-level"
                ]["ci_2_5"]
            ),
            float(
                original_lookup[
                    "Combined-two-level"
                ]["ci_97_5"]
            ),
        ],
        "finite_pool_provisional_ci": [
            float(
                clean_lookup[
                    "Combined-two-level"
                ]["ci_2_5"]
            ),
            float(
                clean_lookup[
                    "Combined-two-level"
                ]["ci_97_5"]
            ),
        ],
        "direct_true_nested_ci": [
            corrected["ci_2_5"],
            corrected["ci_97_5"],
        ],
        "direct_probability_delta_ge_zero": (
            corrected[
                "probability_delta_ge_zero"
            ]
        ),
        "repeated_block_outer_draws": (
            repeated_block_draws
        ),
        "repeated_block_identical_seed_sequences": (
            repeated_identical_seed_sequences
        ),
        "point_estimates_unchanged": True,
        "individual_c1_c2_bootstraps_unchanged": True,
        "method_modified": False,
        "new_seeds_collected": False,
        "success_criterion_changed": False,
        "preregistered_combined_ci_pass": (
            corrected["ci_2_5"] > 0.0
        ),
        "decision": decision["decision"],
    }

    write_json(
        DIRECT_ROOT
        / "outputs"
        / "stage5b_direct_nested_summary.json",
        summary,
    )

    report = f"""# Direct true-nested Stage 5B correction

The previous clean rerun removed perfect repeated-replicate reuse by
independently sampling from a finite precomputed inner-bootstrap pool.

This stricter correction directly resamples sealed evaluation seed clusters
for every sampled block occurrence. It therefore follows the originally
specified true-nested control flow literally.

Combined point delta, unchanged:

`{combined_point:+.10f}`

Direct true-nested 95% percentile interval:

`[{corrected['ci_2_5']:+.10f}, {corrected['ci_97_5']:+.10f}]`

Probability delta greater than or equal to zero:

`{corrected['probability_delta_ge_zero']:.4f}`

Preregistered combined-CI decision:

`{decision['decision']}`
"""

    (
        REPORT_ROOT
        / "stage5b_direct_nested_report.md"
    ).write_text(
        report,
        encoding="utf-8",
    )

    print(
        json.dumps(
            summary,
            indent=2,
            sort_keys=True,
        )
    )

    print(
        "STAGE5B_DIRECT_TRUE_NESTED=PASS",
        flush=True,
    )


if __name__ == "__main__":
    main()

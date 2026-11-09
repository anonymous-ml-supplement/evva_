#!/usr/bin/env python3
"""Direct true-nested correction for EVVA_3 Stages 6C-6F.

For every outer sampled block occurrence, this implementation directly
resamples sealed evaluation seed clusters. All three cases belonging to
the same sampled seed remain together.

It does not sample from a precomputed inner-bootstrap pool.
"""

from __future__ import annotations

import csv
import importlib.util
import json
import os
import shutil
import statistics
from collections import defaultdict
from pathlib import Path
from typing import Mapping, Sequence

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

MASTER_SEED = 20260714

REPS_6C = int(
    os.environ.get(
        "EVVA3_DIRECT_6C_REPS",
        "2000",
    )
)

REPS_6D = int(
    os.environ.get(
        "EVVA3_DIRECT_6D_REPS",
        "5000",
    )
)

REPS_6E = int(
    os.environ.get(
        "EVVA3_DIRECT_6E_REPS",
        "5000",
    )
)

REPS_6F = int(
    os.environ.get(
        "EVVA3_DIRECT_6F_REPS",
        "5000",
    )
)


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

STAGE6C_CODE = (
    FULL_ROOT
    / "artifacts"
    / "aaai_evva3_stage6c_final_ablation_robustness_20260714"
    / "code"
    / "aaai_evva3_stage6c_ablation_robustness.py"
)

STAGE6D_CODE = (
    FULL_ROOT
    / "artifacts"
    / "aaai_evva3_stage6d_pairwise_case_analysis_20260714"
    / "code"
    / "aaai_evva3_stage6d_pairwise_case_analysis.py"
)

STAGE6E_CODE = (
    FULL_ROOT
    / "artifacts"
    / "aaai_evva3_stage6e_pooled_case_decomposition_20260714"
    / "code"
    / "aaai_evva3_stage6e_pooled_case_decomposition.py"
)

STAGE6F_CODE = (
    FULL_ROOT
    / "artifacts"
    / "aaai_evva3_stage6f_budget_selection_mechanism_20260714"
    / "code"
    / "aaai_evva3_stage6f_budget_selection_mechanism.py"
)


TEMPLATES = {
    "stage6c": (
        SOURCE_ROOT
        / "outputs"
        / "stage6c_corrected"
    ),
    "stage6d": (
        SOURCE_ROOT
        / "outputs"
        / "stage6d_corrected"
    ),
    "stage6e": (
        SOURCE_ROOT
        / "outputs"
        / "stage6e_corrected"
    ),
    "stage6f": (
        SOURCE_ROOT
        / "outputs"
        / "stage6f_corrected"
    ),
}

OUTPUTS = {
    stage: (
        DIRECT_ROOT
        / "outputs"
        / f"{stage}_direct_nested"
    )
    for stage in TEMPLATES
}


def require(path: Path) -> None:
    if not path.exists():
        raise FileNotFoundError(path)


for required in [
    C1_PATH,
    C2_PATH,
    V5M_PATH,
    FINAL_PATH,
    STAGE6C_CODE,
    STAGE6D_CODE,
    STAGE6E_CODE,
    STAGE6F_CODE,
    *TEMPLATES.values(),
]:
    require(required)


for output in OUTPUTS.values():
    if output.exists():
        raise RuntimeError(
            "Refusing to overwrite existing output: "
            f"{output}"
        )


DIRECT_ROOT.joinpath(
    "outputs"
).mkdir(
    parents=True,
    exist_ok=True,
)

DIRECT_ROOT.joinpath(
    "reports"
).mkdir(
    parents=True,
    exist_ok=True,
)


# The frozen Final module resolves Locked v5m relative to the archive root.
os.chdir(FULL_ROOT)


os.environ.update({
    "EVVA3_STAGE6C_OUT": str(
        DIRECT_ROOT
        / "scratch"
        / "import_stage6c"
    ),
    "EVVA3_STAGE6C_V5M": str(
        V5M_PATH
    ),
    "EVVA3_STAGE6C_FINAL": str(
        FINAL_PATH
    ),
    "EVVA3_STAGE6C_C1": str(
        C1_PATH
    ),
    "EVVA3_STAGE6C_C2": str(
        C2_PATH
    ),
    "EVVA3_STAGE6C_BOOTSTRAP_REPS": str(
        REPS_6C
    ),
    "EVVA3_STAGE6D_OUT": str(
        DIRECT_ROOT
        / "scratch"
        / "import_stage6d"
    ),
    "EVVA3_STAGE6D_STAGE6C_CODE": str(
        STAGE6C_CODE
    ),
    "EVVA3_STAGE6D_BOOTSTRAP_REPS": str(
        REPS_6D
    ),
    "EVVA3_STAGE6E_OUT": str(
        DIRECT_ROOT
        / "scratch"
        / "import_stage6e"
    ),
    "EVVA3_STAGE6E_STAGE6C_CODE": str(
        STAGE6C_CODE
    ),
    "EVVA3_STAGE6E_BOOTSTRAP_REPS": str(
        REPS_6E
    ),
    "EVVA3_STAGE6F_OUT": str(
        DIRECT_ROOT
        / "scratch"
        / "import_stage6f"
    ),
    "EVVA3_STAGE6F_STAGE6C_CODE": str(
        STAGE6C_CODE
    ),
    "EVVA3_STAGE6F_BOOTSTRAP_REPS": str(
        REPS_6F
    ),
})


def load_module(
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
            f"Cannot import {path}"
        )

    module = importlib.util.module_from_spec(
        specification
    )

    specification.loader.exec_module(
        module
    )

    return module


M = load_module(
    "priority0_direct_stage6c",
    STAGE6C_CODE,
)

D = load_module(
    "priority0_direct_stage6d",
    STAGE6D_CODE,
)

E = load_module(
    "priority0_direct_stage6e",
    STAGE6E_CODE,
)

F = load_module(
    "priority0_direct_stage6f",
    STAGE6F_CODE,
)


blocks = [
    M.load_block(
        specification
    )
    for specification in M.BLOCKS
]

blocks_by_name = {
    str(block["name"]): block
    for block in blocks
}


def read_csv(path: Path):
    with path.open(
        newline="",
        encoding="utf-8-sig",
    ) as handle:
        return list(
            csv.DictReader(handle)
        )


def write_csv(
    path: Path,
    rows: Sequence[
        Mapping[str, object]
    ],
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


def read_json(path: Path):
    return json.loads(
        path.read_text(
            encoding="utf-8"
        )
    )


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
            allow_nan=True,
        )
        + "\n",
        encoding="utf-8",
    )


def make_cluster_map(
    rows,
):
    mapping = defaultdict(list)

    for index, row in enumerate(rows):
        mapping[
            int(row["_seed"])
        ].append(index)

    cluster_sizes = {
        len(indices)
        for indices in mapping.values()
    }

    if cluster_sizes != {3}:
        raise RuntimeError(
            "Expected exactly three case rows "
            "for every evaluation seed. "
            f"Observed {cluster_sizes}"
        )

    return mapping


def direct_cluster_indices(
    mapping,
    rng: np.random.Generator,
):
    seeds = np.asarray(
        sorted(mapping),
        dtype=int,
    )

    sampled_seeds = rng.choice(
        seeds,
        size=len(seeds),
        replace=True,
    )

    return np.asarray(
        [
            index
            for seed in sampled_seeds
            for index in mapping[
                int(seed)
            ]
        ],
        dtype=int,
    )


def summarize(
    values,
):
    array = np.asarray(
        values,
        dtype=float,
    )

    finite = array[
        np.isfinite(array)
    ]

    if len(finite) == 0:
        return {
            "mean": float("nan"),
            "ci_2_5": float("nan"),
            "ci_97_5": float("nan"),
        }

    return {
        "mean": float(
            np.mean(finite)
        ),
        "ci_2_5": float(
            np.quantile(
                finite,
                0.025,
            )
        ),
        "ci_97_5": float(
            np.quantile(
                finite,
                0.975,
            )
        ),
    }


def probability_ge_zero(
    values,
) -> float:
    array = np.asarray(
        values,
        dtype=float,
    )

    finite = array[
        np.isfinite(array)
    ]

    return float(
        np.mean(
            finite >= 0.0
        )
    )


def make_rng_pair(
    stage_id: int,
    *extra: int,
):
    outer_rng = np.random.Generator(
        np.random.PCG64(
            np.random.SeedSequence(
                [
                    MASTER_SEED,
                    stage_id,
                    *extra,
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
                    stage_id,
                    *extra,
                    1,
                ]
            )
        )
    )

    return outer_rng, inner_rng


def combined_point(
    rows,
    key_name: str,
    key_value: str,
    point_field: str,
) -> float:
    values = [
        float(row[point_field])
        for row in rows
        if (
            row["analysis"]
            in {"C1", "C2"}
            and row[key_name]
            == key_value
        )
    ]

    if len(values) != 2:
        raise RuntimeError(
            "Expected C1 and C2 point rows for "
            f"{key_name}={key_value}; found {len(values)}"
        )

    return statistics.fmean(
        values
    )


for stage_name in OUTPUTS:
    shutil.copytree(
        TEMPLATES[stage_name],
        OUTPUTS[stage_name],
    )


# ---------------------------------------------------------------------
# Stage 6C
# ---------------------------------------------------------------------

states_6c = {}

for block_name, block in (
    blocks_by_name.items()
):
    calibration_rows = block[
        "calibration_rows"
    ]

    evaluation_rows = block[
        "evaluation_rows"
    ]

    gains = np.asarray(
        [
            float(row["_gain"])
            for row in evaluation_rows
        ],
        dtype=float,
    )

    ranked_seeds = sorted(
        {
            int(row["_seed"])
            for row in calibration_rows
        },
        key=lambda seed: (
            M.stable_seed_rank(
                block_name,
                seed,
            ),
            seed,
        ),
    )

    for calibration_size in (
        M.CALIBRATION_SIZES
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
                f"{block_name}/{calibration_size}: "
                "wrong calibration subset size."
            )

        states_6c[
            (
                block_name,
                calibration_size,
            )
        ] = {
            "gains": gains,
            "final_score": (
                M.frozen_final_scores(
                    subset,
                    evaluation_rows,
                )
            ),
            "locked_scores": (
                M.locked_scores(
                    subset,
                    evaluation_rows,
                )
            ),
            "clusters": (
                make_cluster_map(
                    evaluation_rows
                )
            ),
        }


stage6c_csv = (
    OUTPUTS["stage6c"]
    / "results"
    / "calibration_size_bootstrap.csv"
)

stage6c_rows = read_csv(
    stage6c_csv
)

direct_stage6c = {}


for calibration_size in (
    M.CALIBRATION_SIZES
):
    outer_rng, inner_rng = (
        make_rng_pair(
            6,
            calibration_size,
        )
    )

    combined_values = []

    for _ in range(
        REPS_6C
    ):
        sampled_blocks = (
            outer_rng.choice(
                np.asarray(
                    ["C1", "C2"],
                    dtype=object,
                ),
                size=2,
                replace=True,
            )
        )

        occurrence_values = []

        for sampled_block in (
            sampled_blocks
        ):
            state = states_6c[
                (
                    str(sampled_block),
                    calibration_size,
                )
            ]

            indices = (
                direct_cluster_indices(
                    state["clusters"],
                    inner_rng,
                )
            )

            gains = state[
                "gains"
            ][indices]

            final_aubc = M.aubc(
                M.curve(
                    state[
                        "final_score"
                    ][indices],
                    gains,
                )
            )

            locked_aubc = M.aubc(
                M.curve_budget_scores(
                    {
                        budget: scores[
                            indices
                        ]
                        for budget, scores
                        in state[
                            "locked_scores"
                        ].items()
                    },
                    gains,
                )
            )

            occurrence_values.append(
                final_aubc
                - locked_aubc
            )

        combined_values.append(
            float(
                np.mean(
                    occurrence_values
                )
            )
        )

    statistics_6c = summarize(
        combined_values
    )

    point = combined_point(
        stage6c_rows,
        "calibration_size_seeds",
        str(calibration_size),
        "point_delta_aubc",
    )

    direct_stage6c[
        str(calibration_size)
    ] = {
        "point_delta_aubc": point,
        "bootstrap_mean_delta": (
            statistics_6c["mean"]
        ),
        "ci_2_5": (
            statistics_6c["ci_2_5"]
        ),
        "ci_97_5": (
            statistics_6c[
                "ci_97_5"
            ]
        ),
        "probability_delta_ge_zero": (
            probability_ge_zero(
                combined_values
            )
        ),
    }

    for row in stage6c_rows:
        if (
            row["analysis"]
            == "Combined-two-level"
            and int(
                row[
                    "calibration_size_seeds"
                ]
            )
            == calibration_size
        ):
            row.update({
                "bootstrap_repetitions": (
                    REPS_6C
                ),
                **direct_stage6c[
                    str(calibration_size)
                ],
            })


write_csv(
    stage6c_csv,
    stage6c_rows,
    list(stage6c_rows[0]),
)

stage6c_summary_path = (
    OUTPUTS["stage6c"]
    / "reports"
    / "stage6c_summary.json"
)

stage6c_summary = read_json(
    stage6c_summary_path
)

stage6c_summary[
    "combined_direct_true_nested"
] = direct_stage6c

stage6c_summary[
    "combined_uncertainty_estimator"
] = (
    "Direct raw seed-cluster resampling "
    "for every sampled block occurrence."
)

write_json(
    stage6c_summary_path,
    stage6c_summary,
)


# ---------------------------------------------------------------------
# Stage 6D
# ---------------------------------------------------------------------

states_6d = {
    block_name: (
        D.make_block_state(
            block
        )
    )
    for block_name, block
    in blocks_by_name.items()
}

stage6d_csv = (
    OUTPUTS["stage6d"]
    / "results"
    / "pairwise_bootstrap.csv"
)

stage6d_rows = read_csv(
    stage6d_csv
)

direct_stage6d = {}


for comparator_index, comparator in enumerate(
    D.COMPARATORS
):
    outer_rng, inner_rng = (
        make_rng_pair(
            7,
            comparator_index,
        )
    )

    combined_values = []

    for _ in range(
        REPS_6D
    ):
        sampled_blocks = (
            outer_rng.choice(
                np.asarray(
                    ["C1", "C2"],
                    dtype=object,
                ),
                size=2,
                replace=True,
            )
        )

        occurrence_values = []

        for sampled_block in (
            sampled_blocks
        ):
            state = states_6d[
                str(sampled_block)
            ]

            indices = (
                direct_cluster_indices(
                    state[
                        "seed_indices"
                    ],
                    inner_rng,
                )
            )

            occurrence_values.append(
                D.point_delta(
                    state,
                    comparator,
                    indices,
                )
            )

        combined_values.append(
            float(
                np.mean(
                    occurrence_values
                )
            )
        )

    statistics_6d = summarize(
        combined_values
    )

    point = combined_point(
        stage6d_rows,
        "comparator",
        comparator,
        "point_delta_aubc",
    )

    direct_stage6d[
        comparator
    ] = {
        "point_delta_aubc": point,
        "bootstrap_mean_delta": (
            statistics_6d["mean"]
        ),
        "ci_2_5": (
            statistics_6d["ci_2_5"]
        ),
        "ci_97_5": (
            statistics_6d[
                "ci_97_5"
            ]
        ),
        "probability_delta_ge_zero": (
            probability_ge_zero(
                combined_values
            )
        ),
    }

    for row in stage6d_rows:
        if (
            row["analysis"]
            == "Combined-two-level"
            and row["comparator"]
            == comparator
        ):
            row.update({
                "bootstrap_repetitions": (
                    REPS_6D
                ),
                **direct_stage6d[
                    comparator
                ],
            })


write_csv(
    stage6d_csv,
    stage6d_rows,
    list(stage6d_rows[0]),
)

stage6d_summary_path = (
    OUTPUTS["stage6d"]
    / "reports"
    / "stage6d_summary.json"
)

stage6d_summary = read_json(
    stage6d_summary_path
)

stage6d_summary[
    "combined_direct_true_nested"
] = direct_stage6d

raw_scale = direct_stage6d[
    "Raw-scale-BG"
]

stage6d_summary[
    "final_vs_raw_scale"
] = {
    "point_delta_aubc": (
        raw_scale[
            "point_delta_aubc"
        ]
    ),
    "ci_2_5": (
        raw_scale["ci_2_5"]
    ),
    "ci_97_5": (
        raw_scale["ci_97_5"]
    ),
    "probability_delta_ge_zero": (
        raw_scale[
            "probability_delta_ge_zero"
        ]
    ),
}

stage6d_summary[
    "final_vs_H_only_ci_lower"
] = direct_stage6d[
    "H-only"
]["ci_2_5"]

stage6d_summary[
    "final_vs_pH_only_ci_lower"
] = direct_stage6d[
    "pH-only"
]["ci_2_5"]

stage6d_summary[
    "final_vs_primitive_envelope_ci_lower"
] = direct_stage6d[
    "Primitive-envelope"
]["ci_2_5"]

write_json(
    stage6d_summary_path,
    stage6d_summary,
)


# ---------------------------------------------------------------------
# Stage 6E
# ---------------------------------------------------------------------

states_6e = {
    block_name: (
        E.make_state(
            block
        )
    )
    for block_name, block
    in blocks_by_name.items()
}

case_types = (
    list(E.CASES)
    + ["__TOTAL__"]
)

values_6e = {
    case_type: []
    for case_type in case_types
}

outer_rng, inner_rng = (
    make_rng_pair(8)
)

maximum_additivity_error = 0.0


for _ in range(
    REPS_6E
):
    sampled_blocks = (
        outer_rng.choice(
            np.asarray(
                ["C1", "C2"],
                dtype=object,
            ),
            size=2,
            replace=True,
        )
    )

    occurrence_contributions = []

    for sampled_block in (
        sampled_blocks
    ):
        state = states_6e[
            str(sampled_block)
        ]

        indices = (
            direct_cluster_indices(
                state[
                    "seed_indices"
                ],
                inner_rng,
            )
        )

        _, contributions = (
            E.decomposition(
                state,
                indices,
            )
        )

        occurrence_contributions.append(
            contributions
        )

    combined = {
        case_type: float(
            np.mean([
                occurrence[
                    case_type
                ]
                for occurrence
                in occurrence_contributions
            ])
        )
        for case_type in case_types
    }

    additivity_error = abs(
        sum(
            combined[case_type]
            for case_type in E.CASES
        )
        - combined["__TOTAL__"]
    )

    maximum_additivity_error = max(
        maximum_additivity_error,
        additivity_error,
    )

    for case_type in case_types:
        values_6e[
            case_type
        ].append(
            combined[case_type]
        )


if maximum_additivity_error > 1e-9:
    raise RuntimeError(
        "Stage 6E direct nested "
        "additivity check failed: "
        f"{maximum_additivity_error}"
    )


stage6e_csv = (
    OUTPUTS["stage6e"]
    / "results"
    / "case_contribution_bootstrap.csv"
)

stage6e_rows = read_csv(
    stage6e_csv
)

direct_stage6e = {}


for case_type in case_types:
    statistics_6e = summarize(
        values_6e[case_type]
    )

    point_values = [
        float(
            row[
                "point_aubc_contribution"
            ]
        )
        for row in stage6e_rows
        if (
            row["analysis"]
            in {"C1", "C2"}
            and row["case_type"]
            == case_type
        )
    ]

    if len(point_values) != 2:
        raise RuntimeError(
            f"Stage 6E {case_type}: "
            "missing C1/C2 point rows."
        )

    point = statistics.fmean(
        point_values
    )

    direct_stage6e[
        case_type
    ] = {
        "point_aubc_contribution": (
            point
        ),
        "bootstrap_mean_contribution": (
            statistics_6e["mean"]
        ),
        "ci_2_5": (
            statistics_6e["ci_2_5"]
        ),
        "ci_97_5": (
            statistics_6e[
                "ci_97_5"
            ]
        ),
        "probability_contribution_ge_zero": (
            probability_ge_zero(
                values_6e[
                    case_type
                ]
            )
        ),
    }

    for row in stage6e_rows:
        if (
            row["analysis"]
            == "Combined-two-level"
            and row["case_type"]
            == case_type
        ):
            row.update({
                "bootstrap_repetitions": (
                    REPS_6E
                ),
                **direct_stage6e[
                    case_type
                ],
            })


write_csv(
    stage6e_csv,
    stage6e_rows,
    list(stage6e_rows[0]),
)

stage6e_summary_path = (
    OUTPUTS["stage6e"]
    / "reports"
    / "stage6e_summary.json"
)

stage6e_summary = read_json(
    stage6e_summary_path
)

stage6e_summary[
    "combined_direct_true_nested"
] = direct_stage6e

stage6e_summary[
    "direct_nested_max_additivity_error"
] = maximum_additivity_error

write_json(
    stage6e_summary_path,
    stage6e_summary,
)


# ---------------------------------------------------------------------
# Stage 6F
# ---------------------------------------------------------------------

states_6f = {
    block_name: (
        F.make_state(
            block
        )
    )
    for block_name, block
    in blocks_by_name.items()
}

mechanism_metrics = [
    "margin",
    "overlap_fraction",
    "switched_fraction",
    "score_spearman",
]

budget_percents = [
    int(
        round(
            fraction * 100
        )
    )
    for fraction in M.BUDGETS
]

values_6f = {
    budget: {
        metric: []
        for metric in mechanism_metrics
    }
    for budget in budget_percents
}

outer_rng, inner_rng = (
    make_rng_pair(9)
)


for _ in range(
    REPS_6F
):
    sampled_blocks = (
        outer_rng.choice(
            np.asarray(
                ["C1", "C2"],
                dtype=object,
            ),
            size=2,
            replace=True,
        )
    )

    occurrence_results = []

    for sampled_block in (
        sampled_blocks
    ):
        state = states_6f[
            str(sampled_block)
        ]

        indices = (
            direct_cluster_indices(
                state[
                    "seed_indices"
                ],
                inner_rng,
            )
        )

        occurrence_results.append({
            int(
                round(
                    fraction * 100
                )
            ): F.analyze_budget(
                state,
                indices,
                fraction,
            )
            for fraction in M.BUDGETS
        })

    for budget in budget_percents:
        for metric in mechanism_metrics:
            values_6f[
                budget
            ][metric].append(
                float(
                    np.mean([
                        occurrence[
                            budget
                        ][metric]
                        for occurrence
                        in occurrence_results
                    ])
                )
            )


stage6f_csv = (
    OUTPUTS["stage6f"]
    / "results"
    / "budget_mechanism_bootstrap.csv"
)

stage6f_rows = read_csv(
    stage6f_csv
)

direct_stage6f = {}


for budget in budget_percents:
    combined_row = next(
        row
        for row in stage6f_rows
        if (
            row["analysis"]
            == "Combined-two-level"
            and int(
                row["budget_percent"]
            )
            == budget
        )
    )

    metric_statistics = {
        metric: summarize(
            values_6f[
                budget
            ][metric]
        )
        for metric in mechanism_metrics
    }

    direct_stage6f[
        str(budget)
    ] = {
        "point_margin": float(
            combined_row[
                "point_margin"
            ]
        ),
        "bootstrap_mean_margin": (
            metric_statistics[
                "margin"
            ]["mean"]
        ),
        "margin_ci_2_5": (
            metric_statistics[
                "margin"
            ]["ci_2_5"]
        ),
        "margin_ci_97_5": (
            metric_statistics[
                "margin"
            ]["ci_97_5"]
        ),
        "probability_margin_ge_zero": (
            probability_ge_zero(
                values_6f[
                    budget
                ]["margin"]
            )
        ),
        "overlap_ci_2_5": (
            metric_statistics[
                "overlap_fraction"
            ]["ci_2_5"]
        ),
        "overlap_ci_97_5": (
            metric_statistics[
                "overlap_fraction"
            ]["ci_97_5"]
        ),
        "switched_ci_2_5": (
            metric_statistics[
                "switched_fraction"
            ]["ci_2_5"]
        ),
        "switched_ci_97_5": (
            metric_statistics[
                "switched_fraction"
            ]["ci_97_5"]
        ),
        "spearman_ci_2_5": (
            metric_statistics[
                "score_spearman"
            ]["ci_2_5"]
        ),
        "spearman_ci_97_5": (
            metric_statistics[
                "score_spearman"
            ]["ci_97_5"]
        ),
    }

    combined_row.update({
        "bootstrap_repetitions": (
            REPS_6F
        ),
        **direct_stage6f[
            str(budget)
        ],
    })


write_csv(
    stage6f_csv,
    stage6f_rows,
    list(stage6f_rows[0]),
)

stage6f_summary_path = (
    OUTPUTS["stage6f"]
    / "reports"
    / "stage6f_summary.json"
)

stage6f_summary = read_json(
    stage6f_summary_path
)

stage6f_summary[
    "combined_direct_true_nested"
] = direct_stage6f

for budget_text, record in (
    stage6f_summary.get(
        "focus_budget_mechanisms",
        {},
    ).items()
):
    direct = direct_stage6f[
        budget_text
    ]

    record[
        "margin_ci_2_5"
    ] = direct[
        "margin_ci_2_5"
    ]

    record[
        "margin_ci_97_5"
    ] = direct[
        "margin_ci_97_5"
    ]

    record[
        "probability_margin_ge_zero"
    ] = direct[
        "probability_margin_ge_zero"
    ]


write_json(
    stage6f_summary_path,
    stage6f_summary,
)


final_summary = {
    "status": "PASS",
    "method_modified": False,
    "new_seeds_collected": False,
    "success_criterion_changed": False,
    "uncertainty_estimator": (
        "Direct true nested block bootstrap "
        "with independent sealed raw seed-cluster "
        "resampling for every sampled block occurrence."
    ),
    "prng": (
        "NumPy Generator PCG64 "
        "through SeedSequence"
    ),
    "master_seed": MASTER_SEED,
    "stage6c_repetitions": REPS_6C,
    "stage6d_repetitions": REPS_6D,
    "stage6e_repetitions": REPS_6E,
    "stage6f_repetitions": REPS_6F,
    "stage6c": direct_stage6c,
    "stage6d": direct_stage6d,
    "stage6e": direct_stage6e,
    "stage6e_max_additivity_error": (
        maximum_additivity_error
    ),
    "stage6f": direct_stage6f,
}


write_json(
    DIRECT_ROOT
    / "outputs"
    / "stage6c_6f_direct_nested_summary.json",
    final_summary,
)


(
    DIRECT_ROOT
    / "reports"
    / "stage6c_6f_direct_nested_report.md"
).write_text(
    "# Priority-0 direct true-nested Stage 6C-6F\n\n"
    "All combined uncertainty distributions independently resample "
    "sealed raw seed clusters for every sampled block occurrence. "
    "Individual C1/C2 results and all point estimates remain unchanged.\n",
    encoding="utf-8",
)


print(
    json.dumps(
        {
            "status": "PASS",
            "stage6c_100": (
                direct_stage6c["100"]
            ),
            "stage6d_locked": (
                direct_stage6d[
                    "Locked-EVVA-SAG"
                ]
            ),
            "stage6e_total": (
                direct_stage6e[
                    "__TOTAL__"
                ]
            ),
            "stage6e_max_additivity_error": (
                maximum_additivity_error
            ),
            "stage6f_40": (
                direct_stage6f["40"]
            ),
        },
        indent=2,
        sort_keys=True,
    )
)

print(
    "STAGE6C_6F_DIRECT_TRUE_NESTED=PASS",
    flush=True,
)

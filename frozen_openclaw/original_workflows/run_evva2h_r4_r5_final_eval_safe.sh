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

RUN_ROOT="artifacts/aaai_evva2_exploratory_20260713/evva2h_final_confirmation_20260713"

EVALUATOR="code/aaai_evva2h_r4_r5_final_confirmatory_eval.py"

V5M="code/aaai_v5m_signal_availability_gated_evva.py"

EVVA2H="code/aaai_evva2h_severe_plateau_gate.py"

EXPECTED_V5M_HASH="924b6c893036f20ee9d60e90faf34c3beeb0f830af8e6d1c8ffd4dfee904906e"

EXPECTED_EVVA2H_HASH="21ccb27ded1838b86e7b37deae5c9bd069d58c2fe13d8ec90a54f7967205b28d"

cd "$WORKSPACE" ||
    die "Workspace was not found."

for REQUIRED in \
    "$V5M" \
    "$EVVA2H" \
    "$RUN_ROOT/r4_5900_6199/raw/full_agent_candidate_rows_5900_6199.csv" \
    "$RUN_ROOT/r5_6200_6499/raw/full_agent_candidate_rows_6200_6499.csv" \
    "$RUN_ROOT/manifests/pre_collection_SHA256SUMS.txt"
do
    [[ -f "$REQUIRED" ]] ||
        die "Missing required file: $REQUIRED"
done

OBSERVED_V5M_HASH="$(
    sha256sum "$V5M" |
    awk '{print $1}'
)"

OBSERVED_EVVA2H_HASH="$(
    sha256sum "$EVVA2H" |
    awk '{print $1}'
)"

[[ "$OBSERVED_V5M_HASH" == "$EXPECTED_V5M_HASH" ]] ||
    die "Locked v5m hash mismatch."

[[ "$OBSERVED_EVVA2H_HASH" == "$EXPECTED_EVVA2H_HASH" ]] ||
    die "Frozen EVVA_2H hash mismatch."

sha256sum -c \
    "$RUN_ROOT/manifests/pre_collection_SHA256SUMS.txt" ||
    die "A frozen method or preregistration file changed."

sha256sum -c \
    "$RUN_ROOT/r4_5900_6199/manifests/raw_SHA256SUMS.txt" ||
    die "R4 raw-data hash mismatch."

sha256sum -c \
    "$RUN_ROOT/r5_6200_6499/manifests/raw_SHA256SUMS.txt" ||
    die "R5 raw-data hash mismatch."

mkdir -p \
    "$RUN_ROOT/final_evaluation" \
    "$RUN_ROOT/logs" \
    "$RUN_ROOT/manifests" ||
    die "Failed to create final-evaluation directories."

cat > "$EVALUATOR" <<'PY'
#!/usr/bin/env python3

import csv
import hashlib
import importlib.util
import math
import random
from collections import defaultdict
from pathlib import Path


RUN_ROOT = Path(
    "artifacts/aaai_evva2_exploratory_20260713/"
    "evva2h_final_confirmation_20260713"
)

OUTPUT_ROOT = (
    RUN_ROOT
    / "final_evaluation"
)

V5M_SCRIPT = Path(
    "code/aaai_v5m_signal_availability_gated_evva.py"
)

EVVA2H_SCRIPT = Path(
    "code/aaai_evva2h_severe_plateau_gate.py"
)

EXPECTED_V5M_HASH = (
    "924b6c893036f20ee9d60e90faf34c3beeb0f830af8e6d1c8ffd4dfee904906e"
)

EXPECTED_EVVA2H_HASH = (
    "21ccb27ded1838b86e7b37deae5c9bd069d58c2fe13d8ec90a54f7967205b28d"
)

BOOTSTRAP_REPS = 10000

LABEL = "intervention_gain"

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

BROAD_BUDGETS = {
    0.40,
    0.50,
    0.60,
    0.70,
    0.75,
    0.80,
    0.90,
}

BLOCK_SPECS = [
    {
        "name": "R4",
        "raw": (
            RUN_ROOT
            / "r4_5900_6199"
            / "raw"
            / "full_agent_candidate_rows_5900_6199.csv"
        ),
        "cal_min": 5900,
        "cal_max": 5999,
        "eval_min": 6000,
        "eval_max": 6199,
        "bootstrap_seed": 32513,
    },
    {
        "name": "R5",
        "raw": (
            RUN_ROOT
            / "r5_6200_6499"
            / "raw"
            / "full_agent_candidate_rows_6200_6499.csv"
        ),
        "cal_min": 6200,
        "cal_max": 6299,
        "eval_min": 6300,
        "eval_max": 6499,
        "bootstrap_seed": 33513,
    },
]


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


def sha256_file(path):
    digest = hashlib.sha256()

    with path.open("rb") as handle:
        for block in iter(
            lambda: handle.read(
                1024 * 1024
            ),
            b"",
        ):
            digest.update(block)

    return digest.hexdigest()


def load_module(path, name):
    spec = importlib.util.spec_from_file_location(
        name,
        path,
    )

    if spec is None or spec.loader is None:
        raise SystemExit(
            f"ERROR: Could not load module: {path}"
        )

    module = importlib.util.module_from_spec(
        spec
    )

    spec.loader.exec_module(
        module
    )

    return module


def read_rows(path):
    if not path.is_file():
        raise SystemExit(
            f"ERROR: Missing required file: {path}"
        )

    with path.open(newline="") as handle:
        return list(
            csv.DictReader(handle)
        )


def exact_b(n_rows, fraction):
    return max(
        1,
        min(
            int(round(n_rows * fraction)),
            n_rows,
        ),
    )


def classify(margin):
    if margin > 0.00005:
        return "strict-win"

    if margin >= -0.00005:
        return "tie"

    return "loss"


def quantile(values, probability):
    ordered = sorted(values)

    if not ordered:
        return float("nan")

    position = (
        len(ordered) - 1
    ) * probability

    lower = int(
        math.floor(position)
    )

    upper = int(
        math.ceil(position)
    )

    if lower == upper:
        return ordered[lower]

    weight = position - lower

    return (
        ordered[lower] * (1.0 - weight)
        + ordered[upper] * weight
    )


def summarize(values):
    return {
        "mean": (
            sum(values)
            / len(values)
        ),
        "median": quantile(
            values,
            0.50,
        ),
        "ci_low": quantile(
            values,
            0.025,
        ),
        "ci_high": quantile(
            values,
            0.975,
        ),
        "p_nonnegative": (
            sum(
                value >= -1e-12
                for value in values
            )
            / len(values)
        ),
        "minimum": min(values),
        "maximum": max(values),
    }


def v5m_value(
    module,
    calibration_rows,
    evaluation_rows,
    columns,
    value_usable,
    fraction,
):
    if value_usable:
        quota = module.value_aware_schedule(
            fraction
        )

        score_columns = {
            "p": columns["p"],
            "H": columns["H"],
            "pH": columns["pH"],
            "V": columns["V"],
        }

        active = [
            (name, weight)
            for name, weight
            in quota.items()
            if weight > 1e-12
        ]

        if len(active) == 1:
            return module.scalar_tieaware(
                evaluation_rows,
                score_columns[
                    active[0][0]
                ],
                fraction,
            )

        return module.portfolio_value(
            evaluation_rows,
            score_columns,
            quota,
            fraction,
        )

    return module.bg_value(
        calibration_rows,
        evaluation_rows,
        columns["pH"],
        columns["H"],
        fraction,
    )


for required_path in [
    V5M_SCRIPT,
    EVVA2H_SCRIPT,
]:
    if not required_path.is_file():
        raise SystemExit(
            f"ERROR: Missing required file: {required_path}"
        )


v5m_hash = sha256_file(
    V5M_SCRIPT
)

evva2h_hash = sha256_file(
    EVVA2H_SCRIPT
)


if v5m_hash != EXPECTED_V5M_HASH:
    raise SystemExit(
        "ERROR: Locked v5m hash mismatch."
    )

if evva2h_hash != EXPECTED_EVVA2H_HASH:
    raise SystemExit(
        "ERROR: Frozen EVVA_2H hash mismatch."
    )


v5m = load_module(
    V5M_SCRIPT,
    "locked_v5m_r4_r5",
)

evva2h = load_module(
    EVVA2H_SCRIPT,
    "frozen_evva2h_r4_r5",
)


columns = {
    "p": "p_score",
    "H": "harm_score",
    "pH": "p_times_H_score",
    "V": "PRM_value_surrogate",
    "P": "PRM_task_surrogate",
    "L": "value_router_surrogate",
}


baseline_columns = {
    "Random": "_score_random",
    "p-only": columns["p"],
    "H-only": columns["H"],
    "PRM/process": columns["P"],
    "Reward/value": columns["V"],
    "Learned router": columns["L"],
}


blocks = []


for spec in BLOCK_SPECS:
    raw_rows = read_rows(
        spec["raw"]
    )

    if len(raw_rows) != 900:
        raise SystemExit(
            f"ERROR [{spec['name']}]: "
            f"expected 900 rows, found {len(raw_rows)}."
        )

    v5m.add_large_random(
        raw_rows
    )

    calibration_rows = [
        dict(row)
        for row in raw_rows
        if (
            spec["cal_min"]
            <= int(
                fnum(
                    row.get("seed")
                )
            )
            <= spec["cal_max"]
        )
    ]

    evaluation_rows = [
        dict(row)
        for row in raw_rows
        if (
            spec["eval_min"]
            <= int(
                fnum(
                    row.get("seed")
                )
            )
            <= spec["eval_max"]
        )
    ]

    if len(calibration_rows) != 300:
        raise SystemExit(
            f"ERROR [{spec['name']}]: "
            "expected 300 calibration rows."
        )

    if len(evaluation_rows) != 600:
        raise SystemExit(
            f"ERROR [{spec['name']}]: "
            "expected 600 evaluation rows."
        )

    evva2h.add_structural_score(
        calibration_rows,
        evaluation_rows,
    )

    value_usable = v5m.usable(
        calibration_rows,
        columns["V"],
    )

    rows_by_seed = defaultdict(
        list
    )

    for row in evaluation_rows:
        seed = int(
            fnum(
                row.get("seed")
            )
        )

        rows_by_seed[
            seed
        ].append(row)

    evaluation_seeds = sorted(
        rows_by_seed
    )

    if len(evaluation_seeds) != 200:
        raise SystemExit(
            f"ERROR [{spec['name']}]: "
            f"expected 200 evaluation seeds, "
            f"found {len(evaluation_seeds)}."
        )

    blocks.append({
        **spec,
        "calibration_rows": (
            calibration_rows
        ),
        "evaluation_rows": (
            evaluation_rows
        ),
        "rows_by_seed": (
            rows_by_seed
        ),
        "evaluation_seeds": (
            evaluation_seeds
        ),
        "value_usable": (
            value_usable
        ),
    })


point_rows = []

block_summaries = {}


for block in blocks:
    v5m_counts = {
        "strict-win": 0,
        "tie": 0,
        "loss": 0,
    }

    evva2h_counts = {
        "strict-win": 0,
        "tie": 0,
        "loss": 0,
    }

    inherited_losses = []

    new_losses = []

    recovered_losses = []

    active_budgets = []

    for fraction in BUDGETS:
        budget_name = (
            f"{int(round(100 * fraction))}%"
        )

        fallback_value = v5m_value(
            module=v5m,
            calibration_rows=block[
                "calibration_rows"
            ],
            evaluation_rows=block[
                "evaluation_rows"
            ],
            columns=columns,
            value_usable=block[
                "value_usable"
            ],
            fraction=fraction,
        )

        diagnostic = {
            "active": False,
            "H_boundary": "",
            "H_needed": "",
            "boundary_fraction": "",
            "H_struct_boundary": "",
            "compression_ratio": "",
            "severe_plateau": False,
            "strong_compression": False,
        }

        candidate_value = fallback_value

        if (
            not block["value_usable"]
            and fraction in BROAD_BUDGETS
        ):
            (
                candidate_value,
                diagnostic,
            ) = evva2h.candidate_value(
                calibration_rows=block[
                    "calibration_rows"
                ],
                evaluation_rows=block[
                    "evaluation_rows"
                ],
                fraction=fraction,
                fallback_value=fallback_value,
                label_column=LABEL,
            )

        if diagnostic["active"]:
            active_budgets.append(
                budget_name
            )

        best_name, best_value = (
            v5m.best_baseline(
                block[
                    "evaluation_rows"
                ],
                baseline_columns,
                fraction,
            )
        )

        v5m_margin = (
            fallback_value
            - best_value
        )

        candidate_margin = (
            candidate_value
            - best_value
        )

        v5m_status = classify(
            v5m_margin
        )

        candidate_status = classify(
            candidate_margin
        )

        v5m_counts[
            v5m_status
        ] += 1

        evva2h_counts[
            candidate_status
        ] += 1

        if (
            v5m_status == "loss"
            and candidate_status == "loss"
        ):
            inherited_losses.append(
                budget_name
            )

        if (
            v5m_status != "loss"
            and candidate_status == "loss"
        ):
            new_losses.append(
                budget_name
            )

        if (
            v5m_status == "loss"
            and candidate_status != "loss"
        ):
            recovered_losses.append(
                budget_name
            )

        point_rows.append({
            "block": block["name"],
            "budget": budget_name,
            "B": exact_b(
                len(
                    block[
                        "evaluation_rows"
                    ]
                ),
                fraction,
            ),
            "V_usable": str(
                block["value_usable"]
            ),
            "gate_active": str(
                diagnostic["active"]
            ),
            "H_boundary": (
                diagnostic["H_boundary"]
            ),
            "H_needed": (
                diagnostic["H_needed"]
            ),
            "boundary_fraction": (
                diagnostic[
                    "boundary_fraction"
                ]
            ),
            "H_struct_boundary": (
                diagnostic[
                    "H_struct_boundary"
                ]
            ),
            "compression_ratio": (
                diagnostic[
                    "compression_ratio"
                ]
            ),
            "severe_plateau": str(
                diagnostic[
                    "severe_plateau"
                ]
            ),
            "strong_compression": str(
                diagnostic[
                    "strong_compression"
                ]
            ),
            "v5m": (
                f"{fallback_value:.8f}"
            ),
            "evva2h": (
                f"{candidate_value:.8f}"
            ),
            "delta_vs_v5m": (
                f"{candidate_value - fallback_value:+.8f}"
            ),
            "best_baseline": (
                best_name
            ),
            "best_baseline_value": (
                f"{best_value:.8f}"
            ),
            "v5m_margin": (
                f"{v5m_margin:+.8f}"
            ),
            "evva2h_margin": (
                f"{candidate_margin:+.8f}"
            ),
            "v5m_status": (
                v5m_status
            ),
            "evva2h_status": (
                candidate_status
            ),
        })

    block_summaries[
        block["name"]
    ] = {
        "v5m": v5m_counts,
        "evva2h": evva2h_counts,
        "inherited_losses": (
            inherited_losses
        ),
        "new_losses": (
            new_losses
        ),
        "recovered_losses": (
            recovered_losses
        ),
        "active_budgets": (
            active_budgets
        ),
    }


bootstrap_deltas = {}


for block in blocks:
    generator = random.Random(
        block["bootstrap_seed"]
    )

    seeds = block[
        "evaluation_seeds"
    ]

    deltas = []

    for _ in range(
        BOOTSTRAP_REPS
    ):
        sampled_seeds = [
            seeds[
                generator.randrange(
                    len(seeds)
                )
            ]
            for _ in range(
                len(seeds)
            )
        ]

        sampled_rows = []

        for seed in sampled_seeds:
            sampled_rows.extend(
                dict(row)
                for row in block[
                    "rows_by_seed"
                ][seed]
            )

        fallback_value = v5m_value(
            module=v5m,
            calibration_rows=block[
                "calibration_rows"
            ],
            evaluation_rows=sampled_rows,
            columns=columns,
            value_usable=block[
                "value_usable"
            ],
            fraction=0.40,
        )

        candidate_value = fallback_value

        if not block["value_usable"]:
            (
                candidate_value,
                _,
            ) = evva2h.candidate_value(
                calibration_rows=block[
                    "calibration_rows"
                ],
                evaluation_rows=sampled_rows,
                fraction=0.40,
                fallback_value=fallback_value,
                label_column=LABEL,
            )

        deltas.append(
            candidate_value
            - fallback_value
        )

    bootstrap_deltas[
        block["name"]
    ] = deltas


r4_deltas = bootstrap_deltas[
    "R4"
]

r5_deltas = bootstrap_deltas[
    "R5"
]


pooled_deltas = [
    0.5 * (
        r4_delta
        + r5_delta
    )
    for r4_delta, r5_delta
    in zip(
        r4_deltas,
        r5_deltas,
    )
]


bootstrap_summaries = {
    "R4": summarize(
        r4_deltas
    ),
    "R5": summarize(
        r5_deltas
    ),
    "R4+R5 pooled stratified": summarize(
        pooled_deltas
    ),
}


def point_delta(
    block_name,
    budget_name,
):
    return next(
        float(
            row[
                "delta_vs_v5m"
            ]
        )
        for row in point_rows
        if (
            row["block"]
            == block_name
            and row["budget"]
            == budget_name
        )
    )


r4_point_40 = point_delta(
    "R4",
    "40%",
)

r5_point_40 = point_delta(
    "R5",
    "40%",
)

pooled_point_40 = (
    r4_point_40
    + r5_point_40
) / 2.0


aggregate_v5m_strict = sum(
    block_summaries[
        block_name
    ]["v5m"]["strict-win"]
    for block_name in [
        "R4",
        "R5",
    ]
)

aggregate_evva2h_strict = sum(
    block_summaries[
        block_name
    ]["evva2h"]["strict-win"]
    for block_name in [
        "R4",
        "R5",
    ]
)


new_loss_budgets = {
    block_name: block_summaries[
        block_name
    ]["new_losses"]
    for block_name in [
        "R4",
        "R5",
    ]
}


incremental_safety_pass = all(
    not losses
    for losses in new_loss_budgets.values()
)


strict_win_pass = (
    aggregate_evva2h_strict
    > aggregate_v5m_strict
)


pooled_summary = (
    bootstrap_summaries[
        "R4+R5 pooled stratified"
    ]
)


pooled_point_pass = (
    pooled_point_40 > 0.0
)

pooled_probability_pass = (
    pooled_summary[
        "p_nonnegative"
    ] >= 0.95
)

pooled_ci_pass = (
    pooled_summary[
        "ci_low"
    ] > 0.0
)


full_confirmatory_pass = all([
    incremental_safety_pass,
    strict_win_pass,
    pooled_point_pass,
    pooled_probability_pass,
    pooled_ci_pass,
])


OUTPUT_ROOT.mkdir(
    parents=True,
    exist_ok=True,
)


point_csv = (
    OUTPUT_ROOT
    / "evva2h_r4_r5_point_results.csv"
)

with point_csv.open(
    "w",
    newline="",
) as handle:
    writer = csv.DictWriter(
        handle,
        fieldnames=list(
            point_rows[0].keys()
        ),
    )

    writer.writeheader()

    writer.writerows(
        point_rows
    )


bootstrap_rows = []


for scope in [
    "R4",
    "R5",
    "R4+R5 pooled stratified",
]:
    summary = (
        bootstrap_summaries[
            scope
        ]
    )

    if scope == "R4":
        point = r4_point_40
    elif scope == "R5":
        point = r5_point_40
    else:
        point = pooled_point_40

    bootstrap_rows.append({
        "scope": scope,
        "budget": "40%",
        "point_delta": (
            f"{point:+.8f}"
        ),
        "bootstrap_reps": (
            BOOTSTRAP_REPS
        ),
        "bootstrap_mean": (
            f"{summary['mean']:+.8f}"
        ),
        "bootstrap_median": (
            f"{summary['median']:+.8f}"
        ),
        "ci_low": (
            f"{summary['ci_low']:+.8f}"
        ),
        "ci_high": (
            f"{summary['ci_high']:+.8f}"
        ),
        "p_nonnegative": (
            f"{summary['p_nonnegative']:.6f}"
        ),
        "minimum": (
            f"{summary['minimum']:+.8f}"
        ),
        "maximum": (
            f"{summary['maximum']:+.8f}"
        ),
    })


bootstrap_csv = (
    OUTPUT_ROOT
    / "evva2h_r4_r5_bootstrap_results.csv"
)

with bootstrap_csv.open(
    "w",
    newline="",
) as handle:
    writer = csv.DictWriter(
        handle,
        fieldnames=list(
            bootstrap_rows[0].keys()
        ),
    )

    writer.writeheader()

    writer.writerows(
        bootstrap_rows
    )


lines = [
    "# EVVA_2H R4-R5 Final Confirmatory Evaluation",
    "",
    "## Integrity",
    "",
    (
        f"- Locked v5m hash: "
        f"**PASS** (`{v5m_hash}`)"
    ),
    (
        f"- Frozen EVVA_2H hash: "
        f"**PASS** (`{evva2h_hash}`)"
    ),
    "- R4 and R5 are untouched confirmatory blocks.",
    "- Bootstrap unit: evaluation seed with all three cases.",
    "- Pooling: equal-block stratified average.",
    "",
    "## Independent summaries",
    "",
    (
        "| Block | v5m strict/tie/loss | "
        "EVVA_2H strict/tie/loss | "
        "Active budgets | New losses |"
    ),
    "|---|---:|---:|---|---|",
]


for block_name in [
    "R4",
    "R5",
]:
    summary = block_summaries[
        block_name
    ]

    v5m_counts = summary[
        "v5m"
    ]

    candidate_counts = summary[
        "evva2h"
    ]

    active_text = (
        ", ".join(
            summary[
                "active_budgets"
            ]
        )
        if summary[
            "active_budgets"
        ]
        else "none"
    )

    new_loss_text = (
        ", ".join(
            summary[
                "new_losses"
            ]
        )
        if summary[
            "new_losses"
        ]
        else "none"
    )

    lines.append(
        f"| {block_name} | "
        f'{v5m_counts["strict-win"]}/'
        f'{v5m_counts["tie"]}/'
        f'{v5m_counts["loss"]} | '
        f'{candidate_counts["strict-win"]}/'
        f'{candidate_counts["tie"]}/'
        f'{candidate_counts["loss"]} | '
        f"{active_text} | "
        f"{new_loss_text} |"
    )


lines.extend([
    "",
    "## Budget-level results",
    "",
    (
        "| Block | Budget | Gate | H boundary | "
        "Boundary fraction | Structural boundary | "
        "Compression | v5m | EVVA_2H | Delta | "
        "Best baseline | Margin | Status |"
    ),
    (
        "|---|---:|---|---:|---:|---:|---:|"
        "---:|---:|---:|---|---:|---|"
    ),
])


for row in point_rows:
    boundary_fraction = (
        f'{float(row["boundary_fraction"]):.6f}'
        if row["boundary_fraction"] != ""
        else ""
    )

    compression_ratio = (
        f'{float(row["compression_ratio"]):.6f}'
        if row["compression_ratio"] != ""
        else ""
    )

    lines.append(
        f'| {row["block"]} | '
        f'{row["budget"]} | '
        f'{row["gate_active"]} | '
        f'{row["H_boundary"]} | '
        f'{boundary_fraction} | '
        f'{row["H_struct_boundary"]} | '
        f'{compression_ratio} | '
        f'{float(row["v5m"]):.4f} | '
        f'{float(row["evva2h"]):.4f} | '
        f'{float(row["delta_vs_v5m"]):+.4f} | '
        f'{row["best_baseline"]} | '
        f'{float(row["evva2h_margin"]):+.4f} | '
        f'{row["evva2h_status"]} |'
    )


lines.extend([
    "",
    "## Primary 40% confirmatory bootstrap",
    "",
    (
        "| Scope | Point delta | Bootstrap mean | "
        "95% CI | P(delta>=0) | Range |"
    ),
    "|---|---:|---:|---:|---:|---:|",
])


for row in bootstrap_rows:
    lines.append(
        f'| {row["scope"]} | '
        f'{row["point_delta"]} | '
        f'{row["bootstrap_mean"]} | '
        f'[{row["ci_low"]}, '
        f'{row["ci_high"]}] | '
        f'{row["p_nonnegative"]} | '
        f'[{row["minimum"]}, '
        f'{row["maximum"]}] |'
    )


lines.extend([
    "",
    "## Preregistered criteria",
    "",
    (
        f"- No new loss in R4 or R5: "
        f"**{'PASS' if incremental_safety_pass else 'FAIL'}**"
    ),
    (
        f"- Aggregate strict wins increase "
        f"({aggregate_v5m_strict} to "
        f"{aggregate_evva2h_strict}): "
        f"**{'PASS' if strict_win_pass else 'FAIL'}**"
    ),
    (
        f"- Pooled 40% point delta positive "
        f"({pooled_point_40:+.8f}): "
        f"**{'PASS' if pooled_point_pass else 'FAIL'}**"
    ),
    (
        f"- Pooled P(delta>=0) >= 0.95 "
        f"({pooled_summary['p_nonnegative']:.6f}): "
        f"**{'PASS' if pooled_probability_pass else 'FAIL'}**"
    ),
    (
        f"- Pooled 95% CI lower bound positive "
        f"({pooled_summary['ci_low']:+.8f}): "
        f"**{'PASS' if pooled_ci_pass else 'FAIL'}**"
    ),
    "",
    "## Final decision",
    "",
])


if full_confirmatory_pass:
    lines.extend([
        (
            "**FULL CONFIRMATORY PASS:** frozen EVVA_2H "
            "satisfies every preregistered criterion on R4 and R5."
        ),
        "",
        (
            "EVVA_2H is eligible for direct comparison with locked "
            "v5m as the candidate main method."
        ),
    ])

elif (
    pooled_probability_pass
    and pooled_ci_pass
    and not incremental_safety_pass
):
    lines.extend([
        (
            "**PRIMARY EFFECT CONFIRMED BUT SAFETY FAILED:** "
            "the severe-plateau refinement improves the pooled "
            "40% result, but it introduces at least one new loss."
        ),
        "",
        (
            "Do not replace locked v5m. Retain the result only as "
            "bounded mechanism evidence."
        ),
    ])

elif incremental_safety_pass:
    lines.extend([
        (
            "**SAFETY PASS BUT PRIMARY CONFIRMATION FAILED:** "
            "EVVA_2H does not introduce a new loss, but the pooled "
            "40% evidence fails at least one primary criterion."
        ),
        "",
        (
            "Retain locked v5m as the main method."
        ),
    ])

else:
    lines.extend([
        (
            "**FINAL CONFIRMATORY FAIL:** EVVA_2H fails both "
            "method-level safety and at least one primary criterion."
        ),
        "",
        (
            "Stop EVVA_2 development and retain locked v5m."
        ),
    ])


report_path = (
    OUTPUT_ROOT
    / "evva2h_r4_r5_final_confirmatory_report.md"
)

report_path.write_text(
    "\n".join(lines) + "\n"
)


manifest_path = (
    OUTPUT_ROOT
    / "evva2h_r4_r5_final_confirmatory_manifest.txt"
)

manifest_path.write_text(
    "\n".join([
        f"v5m_sha256={v5m_hash}",
        f"evva2h_sha256={evva2h_hash}",
        f"bootstrap_reps={BOOTSTRAP_REPS}",
        "bootstrap_unit=evaluation_seed_cluster",
        "pooling=equal_block_stratified_average",
        f"r4_point_40={r4_point_40:+.8f}",
        f"r5_point_40={r5_point_40:+.8f}",
        f"pooled_point_40={pooled_point_40:+.8f}",
        (
            "pooled_bootstrap_mean="
            f"{pooled_summary['mean']:+.8f}"
        ),
        (
            "pooled_bootstrap_ci="
            f"[{pooled_summary['ci_low']:+.8f},"
            f"{pooled_summary['ci_high']:+.8f}]"
        ),
        (
            "pooled_p_nonnegative="
            f"{pooled_summary['p_nonnegative']:.6f}"
        ),
        (
            "aggregate_v5m_strict="
            f"{aggregate_v5m_strict}"
        ),
        (
            "aggregate_evva2h_strict="
            f"{aggregate_evva2h_strict}"
        ),
        (
            "r4_new_losses="
            + ",".join(
                new_loss_budgets["R4"]
            )
        ),
        (
            "r5_new_losses="
            + ",".join(
                new_loss_budgets["R5"]
            )
        ),
        (
            "incremental_safety_pass="
            f"{incremental_safety_pass}"
        ),
        f"strict_win_pass={strict_win_pass}",
        f"pooled_point_pass={pooled_point_pass}",
        (
            "pooled_probability_pass="
            f"{pooled_probability_pass}"
        ),
        f"pooled_ci_pass={pooled_ci_pass}",
        (
            "full_confirmatory_pass="
            f"{full_confirmatory_pass}"
        ),
    ]) + "\n"
)


print(
    report_path.read_text()
)

print(
    f"Point CSV: {point_csv}"
)

print(
    f"Bootstrap CSV: {bootstrap_csv}"
)

print(
    f"Report: {report_path}"
)

print(
    f"Manifest: {manifest_path}"
)
PY

python3 -m py_compile \
    "$EVALUATOR" ||
    die "EVVA_2H final evaluator syntax validation failed."

echo "PASS: EVVA_2H final evaluator syntax validated."

sha256sum \
    "$EVALUATOR" \
    "$V5M" \
    "$EVVA2H" \
    > "$RUN_ROOT/manifests/final_evaluator_pre_run.sha256" ||
    die "Failed to record final-evaluator hashes."

echo
echo "===================================================="
echo "RUNNING EVVA_2H R4/R5 FINAL CONFIRMATORY EVALUATION"
echo "===================================================="

python3 "$EVALUATOR" \
    | tee "$RUN_ROOT/logs/final_confirmatory_evaluation.log"

RUN_STATUS=${PIPESTATUS[0]}

[[ $RUN_STATUS -eq 0 ]] ||
    die "EVVA_2H final confirmatory evaluation failed."

sha256sum -c \
    "$RUN_ROOT/manifests/final_evaluator_pre_run.sha256" ||
    die "A frozen evaluator or method changed during evaluation."

sha256sum -c \
    "$RUN_ROOT/manifests/pre_collection_SHA256SUMS.txt" ||
    die "A frozen source or preregistration file changed."

sha256sum -c \
    "$RUN_ROOT/r4_5900_6199/manifests/raw_SHA256SUMS.txt" ||
    die "R4 raw data changed."

sha256sum -c \
    "$RUN_ROOT/r5_6200_6499/manifests/raw_SHA256SUMS.txt" ||
    die "R5 raw data changed."

echo
echo "===================================================="
echo "EVVA_2H FINAL EVALUATION COMPLETE"
echo "===================================================="

echo "v5m hash:"
sha256sum "$V5M"

echo "EVVA_2H hash:"
sha256sum "$EVVA2H"

echo "PASS: Frozen EVVA_2H R4/R5 evaluation completed."
echo "The interactive terminal remains open."

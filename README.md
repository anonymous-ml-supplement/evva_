# EVVA — Exact-Budget Verification Value Allocation

**Anonymous reviewer code and artifact release.** This package contains the supplied EVVA controlled, frozen, prospective-partial, and live Web materials. Public paths and titles use neutral EVVA naming throughout. Historical venue-style prefixes have been removed from filenames, text and source references, without changing study outcomes or method-level selection logic.

## Quick checks

From the extracted release directory:

```bash
bash scripts/reproduce_available_tables.sh
python3 scripts/check_controlled_aubc_from_rows.py
python3 scripts/check_web_binding_paths.py
python3 scripts/check_frozen_source_hashes.py
```

The code checks use existing bundled data only. `run_table1.py` recalculates Table 3's budget cells but prints the AUBC column and final delta from previously recorded constants. The independent cross-check separately recalculates all eight AUBC means from 200 included rows at all 12 budgets and tests a disclosed absolute legacy-reporting tolerance of `0.0002` (not rounding equivalence). The Web analyzer calculates available curves, bootstrap means and intervals, while three positive-probability fields come from stored `recorded_positive` constants; see the paper-to-code mapping.

## Release contents

- `controlled_openclaw/code/`, `data/`, `results/`: Table 3 controlled comparison, 200-row input and analysis.
- `controlled_openclaw/supplementary_code/`: supporting controlled/OpenClaw prototype, collector and development code. Certain workflows depend on source data not present in the package.
- `frozen_openclaw/source/`, `evaluation/`, `results/`, `protocol/`: EVVA value-unavailable structural branch, Switch ablation, analysis code, supplied corrected result tables, and frozen protocol notes.
- `frozen_openclaw/workflows/`: supporting collection/audit shell workflows. The original raw C1/C2 candidate rows and some external infrastructure are absent; these are not turnkey replay scripts.
- `live_web_agent/analysis/`, `data/`: Web captured-value analysis on the supplied 30 decisions and previously recorded execution observations; no model requests needed for table analysis.
- `live_web_agent/execution/`: the bundled browser runtime and binding lineage. The original runtime is **not** fully self-contained, and live replay is **not tested**.
- `scripts/`: local table, independent AUBC, Web binding, and source-integrity checks.
- `paper_tables/`: controlled and Web tables.
- `docs/PAPER_TO_CODE_MAPPING.csv`: item-by-item experiment mapping and reproducibility boundaries; `docs/PACKAGE_INVENTORY_EXCLUSIONS.csv`: source selection inventory.
- `docs/FINAL_VALIDATION.md`, `docs/RELEASE_CLEANUP_REPORT.md`: current lightweight validation and the public naming adjustments.

## Algorithm and evidence boundaries

The manuscript's full EVVA algorithm specifies a calibration-only value-rankability gate (Eq. 7). The supplied historical `frozen_openclaw/source/evva3_final_evva_sag.py` evaluator instead calls `LOCKED.usable(evaluation, value_column)` on evaluation rows. It therefore **does not generally implement** the calibration-only gate on arbitrary value-available data. In C1/C2 the value signal is unavailable and only the fixed structural branch was confirmed; this distinction does not alter that structural-branch scope. The source has received only neutral identifier/path changes, not a scientific gate correction.

Table 3 is development-selected and in-sample. C1/C2 confirmation datasets are not included, so the available frozen results/analyses are **partial reproduction only**. A1/A2 value-available stress tests and B1/B2 trained router evidence are partial/not rerunnable from these files. The Web setting is retrospective, uses post-execution trajectory information for its exploratory configuration, and was not a frozen confirmation. No new experimental results were computed for this release cleanup.

## Web runtime path notes

Runtime binding JSON `candidate_pair` is relative to the binding JSON parent. The `candidate_state_pickle` reference uses the `source_stream/04k_stream` base, alternatively located as `runtime_root/constructor/candidates/<candidate_id>/candidate_state.pkl` using the runner's constructor root. Run `python3 scripts/check_web_binding_paths.py` for a **read-only** location and checksum crosswalk covering all 180 bindings. It never unpickles data and does not demonstrate browser replay success.

## Anonymization and verification

The neutralization pass updated historical filename prefixes, matching source string references, internal configuration symbol names and human-facing documentation. This changes the present file hashes, so **original frozen-source hashes are not claimed to survive**. `scripts/check_frozen_source_hashes.py` now verifies the *current release's* two key source files, while `SHA256SUMS.txt` covers the current payload. Reproducible controlled/Web analyses were checked both before and after renaming. The old release's historical checksum assertions are not used as current validation evidence. No author/institution names, personal URLs or credentials should be supplied to reviewers; see `docs/ANONYMIZATION_AUDIT.md` for the bounded scan.

Historical auxiliary workflows may still rely on external data/dependencies and are not represented as self-contained runs. Do not execute untrusted pickle data. No paper or manuscript references were edited, and no experiment/data collection, model invocation, or online services were used during this package cleanup.

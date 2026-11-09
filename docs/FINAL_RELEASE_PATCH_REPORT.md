# EVVA — final targeted release patch report

## Scope and outcome

This report documents the prior v2-to-FINAL repair. The subsequent venue-neutral relabeling adds one documentation note, updates released explanatory text and display names, and refreshes the release checksum manifest without changing original computation files. Counts below describe the prior repair stage.


The **sole editable release baseline** is `EVVA reviewer-release v2 ZIP` (713 entries). The separate independent audit specifies four packaging/documentation issues. The final archive retains all original code, data, results, runtime bindings and manuscript numbers. Only documentation, source-neutral audit scripts, generated audit CSVs and the release-level checksum manifest change.

No new experimental observations, model inference, training, Web replay, raw record recovery, scientific algorithm changes, or manuscript changes were performed.

## F1 — Table 3 AUBC provenance and independent cross-check

- Preserved `controlled_openclaw/code/run_table1.py` and `evva_controlled.py` byte-for-byte, including original `PAPER_AUBC` constants and its literal `+0.7559` margin.
- `check_table1.py` **recomputes 12 per-budget selected-gain cells** per method from the 200 bundled candidates and checks against the packaged reference table; it does **not independently compute the manuscript-printed AUBC column**.
- Added `scripts/check_controlled_aubc_from_rows.py` and `docs/CONTROLLED_AUBC_RECALC_CHECK.csv`. The audit reads the frozen 200-row CSV and calls the existing released `scalar_cutoff_value`, `portfolio_value` and `envelope_schedule` functions on every one of the 12 budgets; computes each **unrounded** 12-point arithmetic mean independently of the printed table; then extracts `PAPER_AUBC` using AST for *comparison only*, without running the legacy generator.
- **8/8 method checks PASS**, maximum absolute difference `0.000133581349` (p-only). Absolute tolerance `0.0002` is a bounded **legacy reporting/display tolerance**, chosen to cover the observed source-vs-paper fourth-decimal differences. It is intentionally wider than pure four-decimal rounding (`0.00005`), so it **does not certify equality under ordinary rounding** and must not be treated as statistical uncertainty. A future substantive difference above `0.0002` is flagged `REVIEW`, never silently rewritten.

## F2 — Frozen helper / paper gate scope

- Preserved SHA-256-identical frozen EVVA and locked Switch source. No Python implementation was rewritten.
- Original `frozen_openclaw/source/aaai_evva3_final_evva_sag.py` calls `LOCKED.usable(evaluation, value_column)` on **evaluation** rows. Manuscript Algorithm 1 / Eq. (7) specifies rankability using **calibration** rows. Consequently the historical hash-locked helper is **not** a universal end-to-end realization of the paper's calibration-only gate for arbitrary value-available inputs. It is documented exactly as originally implemented.
- Published C1/C2 value-side scores are unavailable, so both are tests of the **structural** branch, which is unaffected by this gate-placement difference. Exact raw C1/C2 rows are unavailable in this archive. No invented corrected gate was introduced.
- Original historical comparator's mixed-portfolio vacancy-fill order is also preserved rather than silently changed to the paper's presentation.

## F3 — Original Web binding path relocation

- Left all 180 runtime binding JSONs, 180 candidate-pair JSONs, 30 pickles, and the original runner unchanged.
- Added `scripts/check_web_binding_paths.py` and `docs/WEB_RUNTIME_BINDING_PATH_CHECK.csv`. For each binding: `candidate_pair` resolves relative to binding-JSON **parent**; `candidate_state_pickle` does *not*. Its stored relative string correctly resolves from the parent `source_stream/04k_stream/`, or equivalently the runner's `runtime_root/constructor/candidates/<candidate_id>/candidate_state.pkl` location.
- **180/180 candidate pairs and 180/180 state paths exist**, with **180/180 SHA-256 matches for each type**. **0/180 state strings resolve using the JSON-parent base**; the latter is the documented ambiguity, not evidence of runtime failure. The validator never unpickles, imports the runner or performs Web tasks; replay status is `NOT RUN`.

## F4 — Anonymization/path-documentation consistency

- The earlier v2 statement that some nonfrozen historical workflows had author-home paths replaced conflicted with its own reported `0` source modifications and `0` path substitutions. A read-only byte comparison of the **58 v2 original `.py` and `.sh` files**, excluding release wrapper scripts, to the two provided draft-source archives found **58/58 exact basename+SHA-256 matches**. No such in-source replacement is supported. The documentation now reports **no historical code path redaction performed**, rather than claiming nonexistent edits.
- Updated root and component README files, `docs/ANONYMIZATION_AUDIT.md`, and duplicate documentation in `release_reports/` to consistently describe the original versus release-authored boundary. All original source/data remain untouched.
- Static scans cover text-like files, JSON, shell/Python scripts, pickles (limited byte-string patterns), filenames, and final ZIP metadata. No personal name, institution, email, concrete personal home path, personal repository reference, private key header or common credential-assignment pattern was detected in scanned release content. This is not a proof against arbitrary unrecognized secrets embedded in binary artifacts.

## Extra mapping clarification

The supplied `live_web_agent/analysis/run_paper_tables.py` computes bootstrap samples, means and intervals, but prints three bootstrap positive-probability fields from the original `recorded_positive` constants. The Table 30 mapping now attributes these specific fields as recorded values; the code, method, and numbers remain unchanged.

## Exact v2 → FINAL file inventory delta

**Changed files (11; includes the refreshed release-level checksum manifest):**

- `README.md`
- `SHA256SUMS.txt`
- `controlled_openclaw/README.md`
- `docs/ANONYMIZATION_AUDIT.md`
- `docs/FINAL_VALIDATION.md`
- `docs/PAPER_TO_CODE_MAPPING.csv`
- `frozen_openclaw/README.md`
- `live_web_agent/README.md`
- `release_reports/EVVA_Anonymization_Audit.md`
- `release_reports/EVVA_Final_Validation.md`
- `release_reports/EVVA_Paper_to_Code_Mapping.csv`

**Added files (5):**

- `docs/CONTROLLED_AUBC_RECALC_CHECK.csv`
- `docs/FINAL_RELEASE_PATCH_REPORT.md`
- `docs/WEB_RUNTIME_BINDING_PATH_CHECK.csv`
- `scripts/check_controlled_aubc_from_rows.py`
- `scripts/check_web_binding_paths.py`

**Removed files (0):** none.

The package has **718 files**, versus **713 files** in v2. All 702 other baseline members remain SHA-256 identical to v2 (`713 - 11 = 702`). All original bundled implementations, data, pickles, source-defined results, and protocol materials remain unchanged. Only documentation, new audit materials and `SHA256SUMS.txt` differ.

## Publication and reproducibility boundaries

- **PASS:** table-generator checks on supplied rows, eight method AUBC numerical cross-checks, local binding path/hash checks, syntax, original frozen hashes and release ZIP/manifest integrity.
- **PARTIAL (supplied artifacts only):** C1/C2 frozen confirmation source plus supplied results; A1/A2 stress tests and B1/B2 trained-router partial implementation; 180 live Web execution lineage outputs.
- **NOT RUN/NOT INCLUDED:** full external OpenClaw collection, raw missing C1/C2/A1/A2/B1/B2 data-based reruns, full live Web browser/Docker replay and model-dependent tests.

The internal historical source filenames are draft development labels, not evidence of previous AAAI or WSDM submissions. This is the final limited packaging repair; no new research activity was performed.

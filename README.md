# EVVA: Exact-Budget Verification Value Allocation for Tool-Using Agents

Anonymous EVVA code and artifact release. This package is organized around the **final manuscript**, not the titles or numbering of earlier working drafts. Historical filename prefixes are internal development labels; they do not signify prior conference submissions.

## Quick verification (no model credentials required)

Run from the ZIP's extracted top-level directory:

```bash
bash scripts/reproduce_available_tables.sh
python3 scripts/check_frozen_source_hashes.py
```

The first command runs the *existing* controlled and live table checks over bundled rows, without collecting new observations. **Controlled Table 3 budget cells are recomputed, but its legacy `AUBC` column is printed from manuscript-restated `PAPER_AUBC` constants** (including the final `+0.7559` delta). The new independent check below separately computes unrounded AUBC means from all 12 budget allocations, compares them against those constants, and records signed differences and a documented 2e-4 display/legacy tolerance. It does not alter the legacy script, table, or source results. The frozen source check verifies the **original, unchanged** two method files identified by SHA-256 in Appendix A. Python 3 is needed; neither Docker nor model credentials are needed for these checks.

```bash
python3 scripts/check_controlled_aubc_from_rows.py
python3 scripts/check_web_binding_paths.py
```

These scripts work from any current working directory because they resolve package paths relative to their own source files. Their CSV results are in `docs/CONTROLLED_AUBC_RECALC_CHECK.csv` and `docs/WEB_RUNTIME_BINDING_PATH_CHECK.csv`. The Web path checker is **read-only**: it never unpickles a candidate or attempts live execution.

## Directory guide

- `controlled_openclaw/code/`, `data/`, `results/`: 200-candidate controlled comparison, Table 3 and Appendix C (previously labeled Table 1 in an internal draft). `code/check_table1.py` checks the **recomputed budget cells against a supplied table reference**; the legacy AUBC fields are restated, not independently computed by that checker. `scripts/check_controlled_aubc_from_rows.py` independently cross-checks the 12-point means. `original_source/` contains additional original OpenClaw collector, environment, baseline and development implementations, without the old raw training pools.
- `frozen_openclaw/source/`: the **hash-identical** frozen EVVA structural-branch source and its locked comparator (`source/code/...`). Appendix A's original source hashes are retained. The frozen method reads the companion file via a relative `code/` path, so import it from `frozen_openclaw/source/` as its working directory.
- `frozen_openclaw/evaluation/`, `protocol/`, `results/`: original confirmation/bootstrap and post-confirmation analysis implementations, freeze metadata, and available corrected statistical artifacts. The C1/C2 candidate-level paired data are **not in either input ZIP**, so this is **not** a self-contained re-execution of Tables 4–5 or Figure 1.
- `frozen_openclaw/original_workflows/`: original source-carrying shell workflows for collection, LOBO development, validation, sensitivity and provenance audits. These use historical, unbundled datasets and infrastructure; they are **provenance/partial reproduction only**. Do not run these scripts as turnkey commands.
- `live_web_agent/analysis/`, `data/frozen/`, `results/`: frozen 30-decision Web data and original computation for Table 6 and Tables 28–30, including lambda sweep, bootstrap and permutation diagnostics. Existing analysis output files still use earlier table numbers.
- `live_web_agent/data/execution_lineage/`, `execution/`: preserved 180 accepted branch output records and original candidate-pair/binding/state/runner materials. The binding `candidate_pair` relative path uses the binding-JSON parent; its `candidate_state_pickle` reference instead resolves from `source_stream/04k_stream/`, or the equivalent runner `runtime_root/constructor/candidates/<candidate_id>/candidate_state.pkl` path. The original binding JSON is untouched; see `live_web_agent/README.md` and the read-only Web path crosswalk CSV. Docker, WebArena-compatible services, model-provider access, and originally installed AgentLab/BrowserGym dependencies are not bundled. Full live replay has **not** been tested in this release; runtime configuration imports modules that the provided archives did not fully supply.
- `paper_tables/`: easily located source-identical, renamed copies of the Table 3 and Table 6 result TSVs.
- `docs/PAPER_TO_CODE_MAPPING.csv`: manuscript item-by-item availability, runnable status and exact paths. `docs/PACKAGE_INVENTORY_EXCLUSIONS.csv` and external reports record inclusion decisions.

## Paper-specific interpretation

- Table 3 is development evidence. The value-aware schedule is **in-sample**, not a prospective confirmation.
- Tables 4–5 and Figure 1 concern the frozen, **value-unavailable** (structural) branch on disjoint C1/C2 blocks. The supplied corrected statistical tables are authoritative but do not replace the missing raw candidate-level data.
- The Section 8.1 prospective A1/A2 value-aware tests and Section 8.2 B1/B2 supervised-router comparison are **not independently reconstructible** from these archives. No replacement runs, invented results, or synthetic data were added.
- Table 6 is a separate **exploratory retrospective Web configuration**, where `WebEVVA` includes recorded trajectory information and the weight was selected on the same pool. It is not the frozen OpenClaw EVVA policy.
- Live results report **captured positive value**; controlled results report **mean selected reward gain**. They use different units.
- The Web bootstrap script computes sample-based bootstrap means/intervals but prints the three Table 30 positive-probability fields from its pre-existing `recorded_positive` constants; those probability fields are **recorded-source values**, not independently recomputed by this entrypoint.

## Verification and original code boundaries

Existing source code and computational parameters are unchanged. The 58 shipped pre-existing `.py`/`.sh` implementation/workflow files (excluding release-check wrappers) match source bytes in the original provided code archives by filename and SHA-256; **no historical source path substitutions or placeholder edits were observed** in the v2 release. The earlier wording that source-workflow paths had been replaced was unsupported and has been corrected. The release-specific README, inventories, and instructions are separately authored descriptions, not modified original implementations. Historical workflows may depend on external directory layouts or data and are **not turnkey executables**, irrespective of whether a path is present. Old package checksums/manifests were omitted and replaced with the release-level `SHA256SUMS.txt`, which is distinct from the two manuscript-cited frozen source hashes.

The original frozen source's `evaluate()` helper calls `LOCKED.usable(evaluation, value_column)`, testing the **evaluation** rows. The manuscript's Algorithm 1 / Eq. (7) instead specifies a **calibration-only** rankability gate. Thus the hash-locked historical helper is **not a general implementation of the manuscript's full gate for arbitrary value-available inputs**. In published C1/C2, the value signal is blank/unavailable, so the structural branch was exercised and this gate-location distinction does not alter that evaluated structural comparison. The correctly scoped gate is specified in manuscript Eq. (7); the package does not supply a hash-preserving corrected full-policy implementation. The frozen helper was **not silently edited**. The locked historical comparator also has its own portfolio vacancy-fill order; do not substitute it for the separately released Table 3 controlled evaluator. See `docs/ANONYMIZATION_AUDIT.md` and `docs/FINAL_VALIDATION.md`.

## Scope and dependencies

`controlled_openclaw/environment/requirements.txt` and `live_web_agent/environment/` preserve the supplied environment notes; the frozen OpenClaw analysis is Python-based, with certain computations requiring NumPy. Data collection and full browser replay may require external code, container images, benchmark services and credentials that are not included. API keys and local `.env` secrets are intentionally absent. All reports describe **what was actually included**; no source outside the two provided archives was fetched.

## Neutral release naming

The package name, documentation headings and copied table filenames are venue-neutral. Original research source files and historical module imports were not renamed or rewritten. See `docs/VENUE_NEUTRAL_RELEASE_NOTE.md`.

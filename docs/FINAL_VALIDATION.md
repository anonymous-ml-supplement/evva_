# EVVA — final release validation

## Summary

**PASS for local packaging and supported artifact checks; PARTIAL for experiments whose raw inputs are absent; NOT RUN for live browser replay.** All results below are based on the supplied v2 baseline. No new training, data collection, model calls, or full Web replay were performed.

## Commands executed in the extracted package

| Command / check | Actual result | Interpretation |
|---|---|---|
| ZIP structural preflight of v2 | **PASS**; 713 entries; unique safe relative paths; `ZipFile.testzip()` returned `None` | No ZIP path traversal or corruption in v2 |
| `python3` AST parse of all `*.py` | **PASS: 44/44** | 42 original plus 2 added audit scripts; *syntax only* |
| `bash -n` all `*.sh` | **PASS: 19/19** | Shell syntax only; no workflow execution |
| `bash scripts/reproduce_available_tables.sh` | **PASS**; controlled `EVALUATION_ROWS=200`, `ROWS=9`; live `CANDIDATES=30`, `EXECUTION_INSTANCES=90`, `RANDOM_SEEDS=0-9`, `BOOTSTRAP=10000`, `SWITCH=1000`, `PAPER_TABLE_CHECK=PASS` | Existing code recomputed controlled budget cells and Web analysis from included rows; controlled AUBCs and last delta remain source-restated; Web three positive-probabilities remain source-restated |
| `python3 scripts/check_frozen_source_hashes.py` | **PASS: 2/2** | Frozen EVVA SHA-256 `3a04b828762cd311e1ec27c1ffdb1f655172d5783503454bf042aa30ab0c042a`; comparator `924b6c893036f20ee9d60e90faf34c3beeb0f830af8e6d1c8ffd4dfee904906e` |
| `python3 scripts/check_controlled_aubc_from_rows.py` | **PASS: 8/8** methods; 200 rows, 12 budgets; max absolute difference `0.000133581349` within documented `0.0002` | Unrounded means independently computed from rows with existing functions, compared to legacy printed `PAPER_AUBC` literals; not a manuscript rewrite |
| `python3 scripts/check_web_binding_paths.py` | **PASS: 180/180 pairs and 180/180 state files found; 180/180 recorded SHA-256 matches for each; 0/180 state strings work from binding JSON parent** | Uses correct `04k_stream`/runner constructor base; no pickle load or Web runtime replay |
| Read-only source byte provenance comparison | **PASS: 58/58 original Python/shell files** match supplied development archives by filename+SHA-256 | Corrects earlier unsupported v2 statement about source path replacements |
| Original v2/final file comparison | **PASS: 713 → 718**, 11 modified baseline documents/manifest, 5 new audit files, 0 removed; 702 baseline files byte-identical | No changes to original algorithms, datasets, source results or bindings |
| `sha256sum --status -c SHA256SUMS.txt` | **PASS** (regenerated manifest, all included member files except checksum manifest itself) | Release-level integrity distinct from original frozen-source hashes |
| Prior final ZIP `ZipFile.testzip()` and safe-member scan | **PASS: 718 entries**; no duplicate/absolute/traversal names; fixed neutral DOS timestamps and no archive comment | File archive integrity and neutral package metadata |
| Anonymization scan of release payload | **PASS under scoped patterns**; 0 matches in text/JSON/Python/shell/CSV and small pickle byte-string patterns; neutral ZIP member names/metadata | Pattern scan is bounded, not a formal absence-of-secrets proof |

All table calculations and source hashes were checked before final archive generation. The final archive was then reopened, CRC-verified, and compared byte-for-byte against the assembled release tree.

## Distinctions reviewers should keep

**Controlled Table 3:** `run_table1.py` recomputes its **12 budget cells** per method; its AUBC column is **printed directly from `PAPER_AUBC` constants**. The independent check `docs/CONTROLLED_AUBC_RECALC_CHECK.csv` computes the unrounded AUBCs using existing selection functions. Its tolerance (`2e-4`) accommodates small **legacy-reporting differences that can exceed strict 4-decimal rounding**. Nothing in the original table or source has been modified.

**Live Web:** the existing analyzer computes the available Web curves, lambda sweep, permutation/bootstrap analyses from bundled data, while **three positive-probability numbers** are still reported from the historical `recorded_positive` mapping. The 180 binding-path validator confirms only file existence and original SHA-256, **not successful replay**.

**Frozen confirmation C1/C2:** the original two hashed source files, original confirmation/ablation evaluators, corrected summary artifacts, and freeze metadata are retained. Original paired raw candidate/calibration rows are not supplied. The evaluation-row gate in the historical helper differs from the paper's calibration-only gate when value is available; it is not a universal full-policy gate implementation. C1/C2 use the structural branch with unavailable value scores.

**Prospective A1/A2 and supervised-router B1/B2:** original partial materials are present but full data-based replay is **NOT INCLUDED**. External OpenClaw and full browser/Docker execution are **NOT RUN**. The manuscript and its source-defined numbers were untouched.

## Privacy and validation limits

Static scans sought concrete personal home paths, author names, institutional names, personal GitHub accounts, emails, common secret-variable assignments, and private key headers in text and in limited pickle byte strings. No matches were found. They do not constitute a binary-forensics guarantee. The final ZIP uses uniformly neutral timestamps and normal file attributes. Historical draft prefixes in immutable source filenames do **not** signify prior conference submissions.

The SHA-256 of the **ZIP container itself** is reported alongside the downloadable artifact in the external `FINAL_RELEASE_VALIDATION.md` (a self-contained archive cannot embed its own ZIP hash without changing that hash). The internal integrity manifest covers each payload file.

## Venue-neutral ZIP verification

The earlier table and frozen-source checks above were run on the byte-identical computational payload. The venue-neutral package has **719 entries** (one new documentation note) and the same original code/data/results as the prior final release. The renamed container was checked independently for safe ZIP paths, member integrity, member checksums, and original-source hashes.

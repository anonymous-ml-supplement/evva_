# EVVA — anonymous public release validation

**Status: PASS for packaging and existing lightweight reproduction checks; PARTIAL for missing datasets; NOT RUN for full browser/agent replay.**

The repair is a publishing/label cleanup, not a scientific redevelopment. Original draft-venue markers and an auxiliary code-folder label were removed from public names and payload text. Earlier historical byte-for-byte SHA statements no longer apply: the two key source files are now verified against **this package's own hashes**.

## Commands executed on the relabeled extracted package

| Validation | Observed result |
|---|---|
| Python `ast.parse` all source | PASS — 44/44 files |
| `bash -n` all shell scripts | PASS — 19/19 files |
| `bash scripts/reproduce_available_tables.sh` | PASS — controlled 200-row budget-cell check and Web 30-decision / 90 analysis-instance check; Web output confirms 10 random seeds, 10,000 bootstrap draws and 1,000 switch draws |
| `python3 scripts/check_controlled_aubc_from_rows.py` | PASS — 8 methods, 200 candidates, 12 budgets, maximum delta 0.000133581349 within explicitly documented 0.0002 tolerance |
| `python3 scripts/check_web_binding_paths.py` | PASS — 180/180 candidate pairs found, 180/180 state pickle files found; read-only check; live replay NOT RUN |
| `python3 scripts/check_frozen_source_hashes.py` | PASS — 2/2 **current release** key source hashes, not the pre-relabeled source checksums |
| Existing released data, result, protocol, lineage, and paper table bytes | PASS — 630/630 files identical between previous reviewer ZIP and relabeled ZIP workspace |
| Public naming byte scan | PASS — 0 residual matches for the old venue/directory tokens across names and file bytes, including small binary pickle files |
| Personal directory/institution marker scan | PASS — 0 matches for the searched author-home strings, user handles and institution patterns; this is a scoped pattern check |
| Email pattern scan | 0 matched strings (see limitations; public references are not automatically leaks) |
| Credential-assignment regex | 0 possible matches (pattern scan only) |

**Important result provenance:** the controlled Table 3 script independently computes budget cells, but uses manuscript-recorded `PAPER_AUBC` constants and the final displayed delta; the separate AUBC checker recomputes 12-point means. The Web analyzer computes available numerical analyses but prints three positive-probability values from historical `recorded_positive` constants. Neither is represented as newly generated experimental evidence.

**Partial/not run:** C1/C2 candidate-level confirmation datasets and complete A1/A2 / B1/B2 replay inputs are unavailable in the source ZIP. Historical auxiliary workflows rely on unbundled research data. Full live WebArena/AgentLab browser replay was not performed; a renamed but unbundled runtime config module is still a dependency. No claim of turnkey full Web execution is made.

**Source behavior:** only venue-style labels, module/path strings and explanatory documentation were neutralized; no selection, metrics, training, numerical data or inference routines were intentionally changed. All runnable checks above succeeded after this change. A previous source's gate uses evaluation-row rankability, whereas paper Eq. 7 defines a calibration-only gate; the confirmation scope is the value-unavailable structural branch. No general gate correction was fabricated.

## Privacy-scan limits

This report records bounded static scans, not proof that every arbitrary binary or dependency is free of identifying data. The bundled pickle state files were never unpickled. No third-party services or experiments were invoked for cleanup.

## Archive integrity

The final ZIP contains a complete `SHA256SUMS.txt` generated over all its other members. Independent final ZIP structural, CRC and manifest checks are recorded in the external release-cleanup report and verified immediately after creating the archive.

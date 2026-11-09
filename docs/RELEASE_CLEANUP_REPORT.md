# EVVA anonymous reviewer release — final cleanup

This release uses neutral package naming **everywhere**, not only in the ZIP filename. Changes are limited to filename/path identifiers, their matching references in source and shell scripts, packaging documentation, and regenerated release-local checksums. This cleanup did not add experiments, new model calls, raw evidence or alter reported scientific results.

## Changes

- Neutralized 24 formerly venue-prefixed implementation script filenames; relocated supporting code to `controlled_openclaw/supplementary_code/` and workflow scripts to `frozen_openclaw/workflows/`.
- Updated matching imports, path lookups, code comments and string labels so the renamed existing modules remain consistent with their local callers. Unavailable external artifacts remain unavailable.
- Rewrote public README, mapping paths, release audit and validation language to remove superseded historical-hash claims.
- Regenerated current-release key-source SHA check and all-member `SHA256SUMS.txt` so checks validate the current ZIP rather than the pre-relabeled build.
- Re-ran existing local table and Web checks after the edits. Those checks are lightweight reproduction/analysis only, not a claim that full frozen confirmation or browser runtime was rerun.

## Current preservation and validation

The numerical candidate/result/lineage payload remains unchanged. No new experiments, API calls, data collection, training, or manuscript edits occurred. See `docs/FINAL_VALIDATION.md`.

## Inventory changes

- Filename changes: 47 (including folder relocation and method script identifiers).
- Existing files with relabeled textual contents: 44; additional documentation/checksum replacements made where needed.
- Existing result/data/lineage/protocol/table files preserved exactly: 630/630.
- Python scripts: 44; shell scripts: 19.

## Current public source entrypoints

- `frozen_openclaw/source/evva3_final_evva_sag.py`
- `frozen_openclaw/source/code/evva_v5m_signal_availability_gated_evva.py`
- `scripts/check_frozen_source_hashes.py` (release-local hashes)
- `scripts/check_controlled_aubc_from_rows.py`
- `scripts/check_web_binding_paths.py`

Names and code references were updated together; this is not a scientific correction of the known calibration-vs-evaluation rankability-gate distinction. Missing external datasets/runtime modules remain out of scope.

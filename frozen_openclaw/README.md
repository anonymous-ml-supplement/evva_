# Frozen OpenClaw confirmation and appendix analyses

`source/aaai_evva3_final_evva_sag.py` is the paper-cited *unchanged* frozen EVVA source. Its import of `code/aaai_v5m_signal_availability_gated_evva.py` resolves when run from `source/`. Both SHA-256 hashes match Appendix A. The locked source is a historical Switch comparator, not a separate proposed method.

**Gate scope:** the frozen helper `evaluate()` calls `LOCKED.usable(evaluation, value_column)` on evaluation rows, but manuscript Algorithm 1 / Eq. (7) states a **calibration-only** rankability condition. Consequently this file is **not a universal realization of the paper's entire algorithm for arbitrary value-available input**. On C1/C2 the value-side column is blank/unavailable and the structural branch is evaluated, so the difference does not change that C1/C2 branch result. For the published gate definition refer to Eq. (7); no corrected general gate implementation was fabricated. Both original hashed files remain byte-identical.


`evaluation/` contains original C1/C2 evaluators and corrected two-level bootstrap source; `results/` contains supplied corrected summary CSVs and reports. **Paired C1/C2 candidate rows and large development source data were excluded from the original inputs**, so full evaluation re-execution cannot honestly be claimed. The original shell workflow scripts in `original_workflows/` have dependencies on unavailable source data and historical environment directory layouts. They remain unchanged from their bundled source bytes; no author-home-path placeholder edits were identified. They are provenance only, not turnkey replay scripts.

The prospective A1/A2 and held-out supervised router B1/B2 experiments do not have self-contained row data or their final complete evaluation implementations in these archives. They are listed as partial/not supplied in the mapping rather than filled by synthetic substitutes.

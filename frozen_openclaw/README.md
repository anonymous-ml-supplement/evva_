# EVVA Frozen OpenClaw Components

`source/evva3_final_evva_sag.py` and `source/code/evva_v5m_signal_availability_gated_evva.py` contain the historical EVVA structural allocation and Switch comparator components. Their filenames, corresponding import/path references, and related textual labels have been neutralized for anonymous distribution; therefore their current file hashes differ from the unpublished working-file hashes. Scientific algorithm choices, dataset splits, and recorded result tables were not redesigned.

**Important gate scope:** historical `evaluate()` uses `LOCKED.usable(evaluation, value_column)` on evaluation rows. The paper's Eq. 7 defines the rankability gate on calibration data. This historical helper must not be represented as a general implementation of the entire value-available paper algorithm. The C1/C2 frozen confirmation concerns the value-unavailable structural branch.

`evaluation/` provides existing confirmation/bootstrap and follow-up analysis; `results/` provides the included summaries; `protocol/` records the freeze context. C1/C2 paired raw rows are absent, so full data-based reruns are not supported. `workflows/` contains historical shell scripts with unbundled external dataset/infrastructure paths. They are examples/partial source and have not been executed end-to-end from this package.

Run `python3 scripts/check_frozen_source_hashes.py` at the release root to check the two **current packaged file** hashes. Run the main lightweight table scripts from the root README.

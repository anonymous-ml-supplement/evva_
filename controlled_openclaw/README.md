# Controlled OpenClaw evaluation

`code/run_table1.py` recalculates the full 12-budget controlled Table 3 cells using the bundled 200 candidate rows. Its displayed `PAPER_AUBC` entries and final reported delta remain recorded literals. `scripts/check_controlled_aubc_from_rows.py` independently recalculates AUBC means from all included rows and compares to those literals using a documented display/legacy tolerance.

`code/check_table1.py` checks the supplied table reference. `supplementary_code/` includes auxiliary earlier development, collector, and baseline scripts with neutralized local filenames/path labels; some require source data absent from the package. They are provided as partial evidence, not as validated standalone runs.

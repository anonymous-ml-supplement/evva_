# Package inventory and exclusions

The inventory includes **every file from the two input ZIPs**, including those excluded and those renamed. The release is scoped to the final manuscript; earlier draft/conference labels were internal code names and are not presented as prior submissions.

- Original input files inventoried: **1189** (531 controlled/older; 658 Web/older).
- Source files incorporated: **696**; source files excluded: **493**.
- Nonfrozen files with author-path substitution: **0**. The two frozen, manuscript-cited source files remain byte-identical.
- Top-level source groups: controlled_openclaw=31, frozen_openclaw=36, live_web_agent=626, paper_tables=2, scripts=1.
- Excluded categories: Python bytecode (`.pyc`), duplicated historical branches, superseded/irrelevant experiments, internal logs/manifests, obsolete manuscript PDF, development-only administrative material and reports with unnecessary private filesystem paths.
- The **180 raw accepted Web branch output records**, **180 pair JSONs**, **180 runtime bindings**, **30 candidate source/state records**, **30 candidate state pickles**, controlled 200 rows, and available final corrected statistics remain where present.

The complete, row-by-row inventory is `PACKAGE_INVENTORY_EXCLUSIONS.csv` (columns: source archive, original relative path, size, decision, release path, reason). Released replacement README and checker files do not have a source-archive counterpart, because they are packaging/documentation only.

Note: internal draft-venue tokens embedded in *excluded original paths* are normalized for display in the public inventory. The released computational files and the attached original archives were not altered by this metadata-only cleanup.

# Anonymous release — provenance, anonymization and path integrity audit

This report concerns the release files, not excluded manuscript drafts or raw source archives. Claims are limited to the inspections described here; **a static privacy scan cannot prove absence of every possible identifier in arbitrary binary files**.

## Exact source/redaction boundary (correcting v2 documentation)

- **No historical implementation source was patched for this targeted final repair.** The v2 package's 58 pre-existing `.py` / `.sh` source and workflow files (excluding new/release-check scripts) were compared by filename and SHA-256 against the two originally supplied code archives: **58/58 match source bytes**. In particular, the two manuscript-cited frozen files match Appendix A: `3a04b828762cd311e1ec27c1ffdb1f655172d5783503454bf042aa30ab0c042a` (EVVA) and `924b6c893036f20ee9d60e90faf34c3beeb0f830af8e6d1c8ffd4dfee904906e` (locked comparator).
- The previous v2 sentence claiming “some nonfrozen source-workflow paths were replaced by neutral placeholders” was unsupported: the original v2 reports counted **0 historical source modifications and 0 path/host substitutions**, and the byte comparison found no such source edits. **This release corrects the prose rather than modifying code.** Release-authored README, mapping, and inventories are distinct from original code and were written for packaging.
- Original historical workflow paths may still depend on unavailable host infrastructure and datasets. No portability guarantee is implied by retaining these code files. They are explicitly provenance/partial material, not validated replay commands.
- Original runtime binding JSON, candidate pair JSON, runner code, 30 small pickles, supplied frozen candidate data and result tables remain byte-identical to v2. The 180 bindings' `candidate_pair` path is binding-JSON-parent relative; the pickle relative string requires the `04k_stream/` base, matching the runner's `runtime_root/constructor/candidates/<id>/candidate_state.pkl`. No JSON paths were silently rewritten. See `docs/WEB_RUNTIME_BINDING_PATH_CHECK.csv`.
- The two original frozen-source hashes above are independent of the **release-level** `SHA256SUMS.txt`, which is regenerated only to account for intentional documentation/check-script additions and changes.

## Research-alignment cautions preserved

- The hash-locked evaluator calls `LOCKED.usable(evaluation, value_column)`, evaluating rankability on **evaluation rows**. Paper Eq. (7) defines a **calibration-only** rankability gate. This original helper is not a universal full-policy implementation for arbitrary value-available inputs, and it was not edited. C1/C2 have unavailable value columns and specifically test the structural branch.
- The historical locked comparator's mixed-portfolio fill order and the controlled table evaluator's fill order can differ; the manuscript's stated order was not silently imposed on original hashed source.
- Controlled Table 3 per-budget cells are recomputed by the legacy table script, while the legacy AUBC column and final AUBC delta are printed from manuscript-restated literals. An independent, read-only unrounded AUBC comparison is supplied separately.
- The Web bootstrap code computes sample draws, means and intervals but restates three positive-probability fields from pre-existing `recorded_positive` constants; these are not independently recomputed probabilities.
- Missing C1/C2, A1/A2 and B1/B2 raw records, and live environment dependencies, were not invented or fetched. Full Web replay was not run.

## Anonymization scan scope

The final packaging scan checks text-like, JSON, shell, Python, CSV and archive metadata for personal identifiers, educational affiliations, nonanonymous repositories, emails, concrete user-home paths and common credential assignments, plus selected string patterns in binary pickle bytes. It preserves legitimate third-party scholarly references and public dependency names. The detailed scan evidence, classifications and bounded limitations are recorded in `docs/FINAL_VALIDATION.md`. No credential or environment-secret files were intentionally added.

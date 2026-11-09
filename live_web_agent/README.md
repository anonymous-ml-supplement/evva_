# Live Web-agent: Paper Table 6 and Appendix G Web analyses

Run `python3 analysis/check_paper_tables.py` from this directory. The unchanged analysis reconstructs available live table products from `data/frozen/` (30 decisions; 90 execution-level score rows). Original analysis filenames use an earlier draft's Table 2 / Table 3 / Table S4–S8 scheme; see the paper-to-code mapping CSV for manuscript Tables 6 and 28–30.

The 180 branch-execution records, 180 candidate pair JSONs, 180 runtime bindings, and 30 candidate-state pickles are preserved under `data/execution_lineage` and `execution/runtime_root`. Full live replay would additionally require an external configured environment, original Docker images and credentials. Supplied runtime override imports optional `generic_agent` and an unchanged historical configuration module not shipped in the archives; **full live replay is not validated**.

The Web EVVA value score contains post-execution trajectory information and uses an in-pool lambda=2: descriptive, retrospective, not deployment-verified. The sampled Random baseline uses ten permutations; the bootstrap script embeds recorded probability summaries while recomputing other values. Treat these distinctions as part of the analysis provenance.

## Runtime-binding path relocation (read-only guidance)

`execution/runtime_root/source_stream/04k_stream/runtime_bindings/*.runtime_binding.json` contains two **different relative path bases**:

- `candidate_pair` is relative to the **binding JSON's parent**, `.../04k_stream/runtime_bindings/`. The bundled JSONs resolve under `.../04k_stream/candidate_pairs/`.
- `candidate_state_pickle` is **not** relative to the binding JSON's parent. Its `../../constructor/candidates/<id>/candidate_state.pkl` string resolves from `.../source_stream/04k_stream/` (one directory above `runtime_bindings/`). The original runner independently constructs `CONSTRUCTOR / 'candidates' / cid / 'candidate_state.pkl'`, where `CONSTRUCTOR` is the extracted `execution/runtime_root/constructor/` directory.

To locate a pickle independently of the shell's current working directory, anchor paths to the **absolute extracted release root** (or use `Path(__file__).resolve().parents[1]` inside a script stored under `scripts/`):

```python
from pathlib import Path
release_root = Path('/absolute/path/to/extracted/EVVA_release')
constructor = release_root / 'live_web_agent/execution/runtime_root/constructor'
cid = 'W13PRIMARY005'  # example identifier read from a binding JSON
state_path = constructor / 'candidates' / cid / 'candidate_state.pkl'
assert state_path.is_file()  # existence check only; DO NOT unpickle
```

Run `python3 /absolute/path/to/extracted/EVVA_release/scripts/check_web_binding_paths.py` from any directory to generate the 180-row `docs/WEB_RUNTIME_BINDING_PATH_CHECK.csv`. The script checks files and original SHA-256 fields without unpickling or browser execution. **Path found is not evidence of successful live Web replay**. The binding JSONs and original runner are preserved unmodified.

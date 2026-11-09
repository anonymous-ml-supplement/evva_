# Priority-0 corrected final numbers

## Stage 5B primary confirmation

C1 Final minus Locked AUBC:

`+0.1782120738`

C1 individual seed-cluster 95% CI:

`[+0.0450548198, +0.3094117617]`

C2 Final minus Locked AUBC:

`+0.2922645116`

C2 individual seed-cluster 95% CI:

`[+0.1282479728, +0.4518590750]`

Combined point delta:

`+0.2352382927`

Corrected direct true-nested 95% CI:

`[+0.1122966639, +0.3690636747]`

Corrected probability delta greater than or equal to zero:

`0.9999`

Preregistered combined-CI criterion:

`PASS`

## Statistical estimator

- NumPy Generator PCG64 through SeedSequence.
- Master seed: 20260714.
- Two block occurrences sampled with replacement from C1 and C2.
- Every block occurrence independently resamples sealed evaluation seed clusters.
- All three cases belonging to the same sampled seed remain together.
- Percentile 95% interval using the 0.025 and 0.975 quantiles.

## Integrity

- Point estimates unchanged.
- Individual C1/C2 bootstrap intervals unchanged.
- Frozen method unchanged.
- No new seeds collected.
- Success criterion unchanged.
- Repeated block occurrences with identical seed sequences: 0.

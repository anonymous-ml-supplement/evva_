# Reproducibility report

## Fixed configuration

- PRNG: NumPy Generator PCG64 through SeedSequence.
- Master seed: 20260714.
- Stage 5B replicates: 10000.
- Stage 6C replicates: 2000.
- Stage 6D replicates: 5000.
- Stage 6E replicates: 5000.
- Stage 6F replicates: 5000.
- Block sample: two occurrences with replacement from C1 and C2.
- Seed-cluster sample: independent direct resampling for every occurrence.
- Grouping: evaluation seed, with all three case rows retained together.
- Interval: percentile 95% interval using 0.025 and 0.975 quantiles.

## Frozen identities

- Locked v5m:
  `924b6c893036f20ee9d60e90faf34c3beeb0f830af8e6d1c8ffd4dfee904906e`
- Final Stage 4F:
  `3a04b828762cd311e1ec27c1ffdb1f655172d5783503454bf042aa30ab0c042a`
- C1 raw:
  `eef3ddd81c955205a9df4e45a8e4062728e1e2c079da1e528c1326af7d67e59f`
- C2 raw:
  `53da435349e5bd3f2205d4a499c57904f455363956b61f3705a5c16358dbf23d`

## Validation

- Point estimates unchanged.
- Individual C1/C2 intervals unchanged.
- Stage 6E maximum direct additivity error:
  `2.747801985947262e-15`.
- Method modified: false.
- New seeds collected: false.
- Success criterion changed: false.
- New figures generated: false.

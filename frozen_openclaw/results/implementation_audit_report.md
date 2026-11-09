# Priority-0 implementation audit report

## Finding

Repeated-block replicate reuse was confirmed in the original Stage 5B,
Stage 6C, Stage 6D, Stage 6E, and Stage 6F combined bootstrap control
flow.

The superseded implementation generated one within-block draw for C1 and
one for C2, then reused that value when the outer block bootstrap selected
the same block twice.

## Corrected implementation

The correction directly resamples sealed evaluation seed clusters for every
sampled block occurrence. A repeated outer draw such as `[C1, C1]` therefore
uses two independent C1 seed-cluster resamples.

The three cases from each sampled seed are always kept together.

## Stage 5B direct audit

- Bootstrap repetitions: 10000
- Repeated-block outer draws: 4965
- Repeated-block identical seed sequences:
  0
- Combined point delta: +0.2352382927
- Corrected CI:
  [+0.1122966639,
   +0.3690636747]
- Corrected probability: 0.9999
- Decision: PASS

No frozen method, raw data, budget, metric, comparator, or success
criterion was changed.

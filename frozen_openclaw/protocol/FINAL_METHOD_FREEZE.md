# EVVA_3 final method freeze

## Frozen method

The final method remains EVVA-SAG.

When the Reward/value signal is usable, EVVA-SAG preserves the exact
hash-locked value-aware schedule.

When Reward/value is unavailable, EVVA-SAG uses one fixed ranking at every
budget:

\[
0.10\,\operatorname{Pct}(pH)
+
0.90\,\operatorname{Pct}(H).
\]

The prior pure-H fallback above 30% is removed.

## Why this candidate was selected

The fixed BG anchor was the only development candidate that improved over the
original locked EVVA-SAG in all six large blocks while also improving over the
primitive envelope in all six blocks.

It introduces no learned model, no budget-specific repair, and no change to the
controlled value-available regime.

## Rejected candidates

- Direct ShallowGB intervention-value prediction
- Ridge residual repair
- Isotonic plateau repair
- Pareto-dominance repair
- Recoverability factorization

These remain development diagnostics and are not part of the final method.

## Freeze status

The method is frozen before C1 and C2.

C1 and C2 must not be used to modify the method.

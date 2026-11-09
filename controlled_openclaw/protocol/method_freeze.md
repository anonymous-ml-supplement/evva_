# Controlled OpenClaw evaluation specification

This package reconstructs the controlled exact-budget comparison reported in Table 1 of the paper.

The reported controlled EVVA row is a retrospective achievable-envelope reference, not an additional independently validated deployable allocation signal. The frozen per-budget schedule is:

- 5%, 10%: H
- 20%, 30%, 40%: pH
- 50%: 20% H + 80% v
- 60%, 70%: v
- 75%: 10% pH + 10% H + 80% v
- 80%: 20% pH + 80% v
- 90%: 80% pH + 20% v
- 100%: all candidates

All methods use the same locked pool of 200 evaluation candidates and the same exact budget. Component scores are pre-intervention. The schedule was retrospectively identified on this evaluation pool and is frozen only to reproduce the achievable-envelope result.

Scalar rows use fractional cutoff expectation only when a score tie crosses the exact-budget boundary. Mixed portfolios use exact quotas, deterministic component order, de-duplication, and the frozen tie-break keys released with the evaluation rows. At 75%, component order is pH, H, then v. Fill order after overlap is pH, v, H, then p.

Realized intervention gain is used only for evaluation. PRM/process, Reward/value, and Learned routing are frozen nondegenerate candidate-level surrogate score families, not end-to-end reproductions of external systems.

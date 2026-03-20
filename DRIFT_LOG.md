# Drift Log

## Metadata
- Last audit: 2026-03-19
- Runs since audit: 4

## Unresolved Observations
- [2026-03-20 | "Implement Milestone 17: Tech Stack Detection Engine"] `detect.sh` `_find_source_files()`: the `git ls-files` path is not depth-bounded (finds files at any depth), while the non-git fallback uses `find -maxdepth 2`. Same inconsistency noted in cycle 1 — not a current blocker but detection results will differ between git and non-git repos with the same structure. Worth aligning when the crawler (M18) is built.
- [2026-03-20 | "Implement Milestone 16: Outer Orchestration Loop (Milestone-to-Completion)"] `lib/metrics.sh:~395` — predates M16, still ~95 lines over ceiling. `summarize_metrics` and its helper sub-functions remain the natural extraction target.
- [2026-03-20 | "Implement Milestone 16: Outer Orchestration Loop (Milestone-to-Completion)"] `orchestrate.sh:162` — `acceptance_pass=false` when `SKIP_FINAL_CHECKS=true` on a pipeline exit 0 is a dead branch (a null run should produce non-zero exit before reaching this check). A one-line comment explaining the invariant would prevent future confusion.
- [2026-03-19 | "architect audit"] **Obs 4** — Pre-assessed as no structural problem; confirmed. Out of scope for remediation. **Obs 5** — Pre-assessed as below remediation threshold; confirmed. Out of scope for remediation. No speculative issues were introduced. Audit is bounded to the two reported observations.

## Resolved

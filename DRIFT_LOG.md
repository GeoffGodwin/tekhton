# Drift Log

## Metadata
- Last audit: 2026-03-20
- Runs since audit: 1

## Unresolved Observations
- [2026-03-20 | "Fix Milestone 17 TESTER_REPORT bugs — see TESTER_REPORT.md ## Bugs Found"] `lib/metrics_dashboard.sh:162` and `lib/metrics_dashboard.sh:186` — `val`/`est`/`actual` variables are set via `grep ... || true`, which can produce empty strings; `$(( sum + val ))` with an empty `val` is a bash arithmetic syntax error. This latent bug was pre-existing in `metrics.sh` before extraction — not a regression introduced here.
- [2026-03-20 | "Fix Milestone 17 TESTER_REPORT bugs — see TESTER_REPORT.md ## Bugs Found"] `lib/metrics.sh`, `lib/metrics_calibration.sh`, `lib/metrics_dashboard.sh` — all three metrics library files are missing `set -euo pipefail`. All other sourced lib files include it. Worth a single cleanup commit to standardize the family.

## Resolved
- [RESOLVED 2026-03-20] `detect.sh` `_find_source_files()`: the `git ls-files` path is not depth-bounded (finds files at any depth), while the non-git fallback uses `find -maxdepth 2`. Same inconsistency noted in cycle 1 — not a current blocker but detection results will differ between git and non-git repos with the same structure. Worth aligning when the crawler (M18) is built.
- [RESOLVED 2026-03-20] `lib/metrics.sh:~395` — predates M16, still ~95 lines over ceiling. `summarize_metrics` and its helper sub-functions remain the natural extraction target.
- [RESOLVED 2026-03-20] `orchestrate.sh:162` — `acceptance_pass=false` when `SKIP_FINAL_CHECKS=true` on a pipeline exit 0 is a dead branch (a null run should produce non-zero exit before reaching this check). A one-line comment explaining the invariant would prevent future confusion.
- [RESOLVED 2026-03-20] **Obs 4** — Pre-assessed as no structural problem; confirmed. Out of scope for remediation. **Obs 5** — Pre-assessed as below remediation threshold; confirmed. Out of scope for remediation. No speculative issues were introduced. Audit is bounded to the two reported observations.

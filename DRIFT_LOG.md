# Drift Log

## Metadata
- Last audit: 2026-04-01
- Runs since audit: 2

## Unresolved Observations
- [2026-04-01 | "Address all 3 open non-blocking notes in NON_BLOCKING_LOG.md. Fix each item and note what you changed."] `lib/progress.sh:192-209` — `_get_timing_breakdown` injects stage names directly as JSON keys without escaping. Stage names are controlled pipeline constants so this is safe in practice, but a stage name containing `"` or `` would produce invalid JSON. Pre-existing concern not introduced by this change.
nd then 45"] `_try_preflight_fix()` (`lib/orchestrate_helpers.sh:87,134`) counts failure lines via `grep -ciE '(FAIL|ERROR|error|failure)'` for the regression detection heuristic. The pattern matches lowercase "error" and "failure" literally, which can produce false-positive counts in test frameworks that print "0 errors" or "no failures found" in passing output. The core fix logic uses exit codes (correct), so this only affects the regression abort heuristic — not a correctness issue, but worth noting for future calibration.
nd then 45"] Regression abort threshold is `initial_fail_count + 2` (`orchestrate_helpers.sh:135`). The magic constant `2` is undocumented. A comment explaining why +2 (allow slight variance in noisy grep counts) would improve maintainability.
(none)

## Resolved

# Drift Log

## Metadata
- Last audit: 2026-04-01
- Runs since audit: 1

## Unresolved Observations
(none)

## Resolved
- [RESOLVED 2026-04-01] `_try_preflight_fix()` (`lib/orchestrate_helpers.sh:87,134`) grep false-positive counts — explanatory comment added at lines 86–89 documenting that grep pattern may over-count but is accepted because the heuristic uses exit codes for correctness.
- [RESOLVED 2026-04-01] Regression abort threshold `+2` (`orchestrate_helpers.sh:135`) — explanatory comment added at lines 139–142 documenting that the +2 accommodates measurement noise in grep counts across runs.
- [RESOLVED 2026-04-01] `lib/progress.sh:192-209` — `_get_timing_breakdown` injects stage names directly as JSON keys without escaping. Stage names are controlled pipeline constants so this is safe in practice, but a stage name containing `"` or `` would produce invalid JSON. Pre-existing concern not introduced by this change.

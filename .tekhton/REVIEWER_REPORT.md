## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- **(Prior Blocker 2 — FIXED ✓)** Both `_run_fix_nonblockers_loop` (tekhton.sh:2682–2684) and `_run_fix_drift_loop` (tekhton.sh:2772–2774) now call `out_reset_pass` at the top of each iteration, guarded by `declare -f`. Terminal "No remaining work" event emitted on loop exit (lines 2693–2695, 2783–2785). Pass-boundary "Starting pass N" event for passes ≥2 is correctly placed after `tui_start` re-arm in both loops (lines 2742–2748, 2832–2838). Blocker resolved.
- **(Prior Blocker 3 — FIXED ✓)** `tools/tui_hold.py` now partitions `recent_events` into `runtime_events` and `summary_events` at lines 53–54. Runtime events render in the existing `[bold]Event log:[/bold]` block with timestamps; summary events render in a new `[bold]Run summary:[/bold]` block after Action Items with timestamps suppressed. Blocker resolved.
- **(Prior Blocker 4 — FIXED ✓)** Pre-flight is now a first-class lifecycle owner: `tui_stage_begin "preflight"` is called at tekhton.sh:2884 before `run_preflight_checks`, success path closes with status `"pass"` (line 2888), failure path closes with `"FAILED"` (line 2892) before `exit 1`. Blocker resolved.
- `_policy_field` at `lib/pipeline_order.sh:285` has no call sites — all consumers use inline `${_pol#*|}` parameter expansion in `tui_ops.sh`. Dead code; remove in a future cleanup pass.
- `lib/pipeline_order.sh` is 338 lines — 38 over the 300-line soft ceiling. Consider splitting M110 policy/metrics/plan functions into `lib/pipeline_order_policy.sh`.
- `tekhton.sh:2530–2535` contains an inline metrics-key alias map (`review → reviewer`, `test_verify → tester`, `test_write → tester_write`) that duplicates `get_stage_metrics_key` in `pipeline_order.sh`. Future cleanup should replace the inline case with a `get_stage_metrics_key` call.

## Coverage Gaps
- Unit tests for `get_stage_policy` — correct record shape for every stage in the §2 table; unknown stage falls back to `op` record (milestone §10 marks this mandatory).
- Unit tests for `get_stage_metrics_key` — all alias pairs from §6; idempotent on canonical keys.
- Unit tests for `get_run_stage_plan` for each run mode variant: bare task, `SKIP_SECURITY=true`, `DOCS_AGENT_ENABLED=true`, `--milestone`, `--fix nb`, `--fix drift` (architect promoted), `--start-at review`.
- Integration test suite `tests/test_tui_stage_wiring.sh` (new file) per milestone §10 — scout→coder zero-gap, two-cycle rework distinct lifecycle ids, architect promotion, multi-pass reset, hold→no-work terminal exit.
- Lifecycle-id monotonicity test: repeated `tui_stage_begin "rework"` allocates `rework#1`, `rework#2`, never reuses a completed id.

## Drift Observations
- `get_stage_policy` internally calls `get_stage_metrics_key` via a subshell at `pipeline_order.sh:265`. Both are pure functions; subshell is correct but adds fork overhead on every policy lookup. Low-priority until policy lookups move into high-frequency paths.

## ACP Verdicts
None

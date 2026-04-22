## Planned Tests
- [x] `tests/test_tui_stage_wiring.sh` — verify M110 lifecycle invariants, transition atomicity, stale-id guard, runtime vs summary event typing, out_reset_pass, intake-not-at-end regression (M110-1 through M110-13)
- [x] `tests/test_pipeline_order_policy.sh` — verify get_stage_policy record shape for all §2 stages, get_stage_metrics_key alias normalization, get_run_stage_plan for all run modes
- [x] `tests/test_pipeline_order_m110.sh` — verify get_run_stage_plan FORCE_AUDIT, drift thresholds, INTAKE disabled, fix-drift+SKIP_SECURITY, and start-at scenarios

## Test Run Results
Passed: 422  Failed: 0

## Bugs Found
None

## Files Modified
- [x] `tests/test_tui_stage_wiring.sh`
- [x] `tests/test_pipeline_order_policy.sh`
- [x] `tests/test_pipeline_order_m110.sh`

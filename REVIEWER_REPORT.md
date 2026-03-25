# Reviewer Report — Milestone 27: Configurable Pipeline Order (TDD Support) — Cycle 2

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- Stage header display regression (standard mode): scout occupies position 1 in the dynamic order array, so the coder stage now shows "Stage 2 / 5 — Coder" instead of the prior "Stage 1 / 4 — Coder". Scout is never displayed as a standalone stage (the loop `continue`s), so users see stage numbers that skip 1 and count 5 total where only 4 are visible. The defaults `_stage_pos=1` and `_stage_count=4` in `run_stage_coder()` are always bypassed because tekhton.sh sets both globals before calling the function.
- `TESTER_WRITE_FAILING_MAX_TURNS` default of 10 is likely too low. The test-write agent must read its role file, read SCOUT_REPORT.md, identify test patterns, write test files, run the test suite to confirm they load, and produce TESTER_PREFLIGHT.md. 10 turns is tight for a non-trivial project. Consider raising the default to 15 or 20.
- `_run_tester_write_failing()` has no UPSTREAM error check. The full `run_stage_tester()` explicitly handles `AGENT_ERROR_CATEGORY=UPSTREAM` with `write_pipeline_state`. The write-failing path silently swallows API errors via the null-run fallback — API failures during TDD pre-flight leave no trace in the state file.
- `CODER_TDD_TURN_MULTIPLIER` has no upper-bound clamp. The `_clamp_config_value` machinery only matches integers (`^[0-9]+$`), so floats are never clamped. A large value (e.g., `100.0`) would multiply the already-capped base turn budget by 100×, bypassing `CODER_MAX_TURNS_CAP`. Low risk (admin-only config), but worth noting for completeness.

## Coverage Gaps
- `lib/pipeline_order.sh` has no unit test coverage. All five public functions (`validate_pipeline_order`, `get_pipeline_order`, `get_stage_count`, `get_stage_position`, `should_run_stage`) are exercised only at runtime. The position-comparison resume logic in `should_run_stage` — especially the `start_at=test` → `test_verify` mapping and position comparisons across both order arrays — is subtle and would benefit from explicit test assertions.

## ACP Verdicts
- None (no Architecture Change Proposals declared in CODER_SUMMARY.md)

## Drift Observations
- `validate_pipeline_order()` in `pipeline_order.sh` and the inline `case` block in `config.sh` both validate `PIPELINE_ORDER` against the same allowlist (`standard|test_first|auto`). Duplicated validation — if a new order value is added, both must be updated. The `config.sh` validation runs first and normalizes the value before `pipeline_order.sh` is sourced, so the library's `validate_pipeline_order()` function is only reachable if called directly. One of the two could be removed or one deferred to the other.
- `PIPELINE_ORDER_STANDARD` includes "scout" to produce a 5-element array, but scout emits no standalone stage header and is handled internally by `run_stage_coder()`. The array conflates two roles: position-based resume mapping (needs scout for accurate positions) and visible stage count display (should exclude scout). This tension will complicate future stage additions.

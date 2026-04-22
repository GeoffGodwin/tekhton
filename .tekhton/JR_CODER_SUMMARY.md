# Junior Coder Summary — Architect Remediation

## What Was Fixed

- **SF-1 (CLAUDE.md)**: Updated `tui_ops.sh` comment on line 170 to note that `run_op` uses the M113 substage API as of M115. This clarifies the coupling between `tui_ops.sh` and `tui_ops_substage.sh`.

- **SF-2 (ARCHITECTURE.md)**: Inserted missing `lib/tui_ops.sh` entry in Layer 3 library list between `tui_helpers.sh` and `tui_ops_substage.sh` (around line 177). Documents the public API (`tui_update_stage()`, `tui_finish_stage()`, `tui_update_agent()`, `tui_append_event()`) and clarifies that `run_op()` wraps long-running commands via the M113 substage API.

- **SF-3 (tools/tests/test_tui_render_timings.py)**: Added `hasattr` guards for Rich's private `._cells` attribute at two test sites:
  - Lines 400-410 in `test_substage_blanks_turns_column()`: Guard the `turns_column._cells` access with a check; skip the direct-inspection assertion if unavailable.
  - Lines 437-450 in `test_parent_timer_continues_across_substage_boundary()`: Guard the `time_column._cells` access with a check; skip the direct-inspection assertion if unavailable.
  - In both cases, the string-level assertions that check for the presence/absence of time/turn text remain as the primary validation; the direct-inspection assertions are now defensive fallbacks.

## Files Modified

- `CLAUDE.md`
- `ARCHITECTURE.md`
- `tools/tests/test_tui_render_timings.py`

All changes are bounded, mechanical fixes addressing staleness and test resilience as specified in the architect plan.

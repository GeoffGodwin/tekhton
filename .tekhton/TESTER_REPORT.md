## Planned Tests
- [x] `tests/test_orchestrate_recovery.sh` — M130 routing decisions: T1-T11 + T2b/T8b/T8c (25 assertions, existing)
- [x] `tests/test_ui_gate_force_noninteractive.sh` — Priority 0 hook in _ui_detect_framework (new)
- [x] `tests/test_m131_coverage_gaps.sh` — M131 gate escalation (PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED→CI=1 without hardened arg) and CY-2 pass case (mochawesome + --exit → no warn)

## Test Run Results
Passed: 50  Failed: 0

Full suite (bash tests/run_tests.sh): 463 shell / 247 Python — all pass.

## Bugs Found
None

## Files Modified
- [x] `tests/test_ui_gate_force_noninteractive.sh`
- [x] `tests/test_m131_coverage_gaps.sh`

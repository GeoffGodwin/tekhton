## Planned Tests
- [x] `tests/test_build_gate_timeouts.sh` — build gate per-phase timeout and overall gate timeout
- [x] `tests/test_ui_server_hardening.sh` — curl probe timeout and process group kill fallback

## Test Run Results
Passed: 185  Failed: 1

Note: The 1 failure (`test_coder_stage_split_wiring.sh`) is pre-existing and unrelated to M30.
Both new test files pass. Both correctly fail against pre-M30 code (confirmed via git stash).

## Bugs Found
None

## Files Modified
- [x] `tests/test_build_gate_timeouts.sh`
- [x] `tests/test_ui_server_hardening.sh`

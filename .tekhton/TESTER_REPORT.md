## Planned Tests
- [x] `tests/test_m127_buildfix_routing.sh` — _bf_read_raw_errors fallback path and noncode_dominant terminal behavior (exit 1 + write_pipeline_state env_failure)
- [x] `tests/test_build_fix_loop.sh` — T9d-ext: assert write_pipeline_state(coder, build_failure) and exit 1 on BUILD_FIX_ENABLED=false

## Test Run Results
Passed: 458  Failed: 0

## Bugs Found
None

## Files Modified
- [x] `tests/test_m127_buildfix_routing.sh`
- [x] `tests/test_build_fix_loop.sh`

## Planned Tests
- [x] `tests/test_plan_config_loader.sh` — Verify existing 6/6 pass (empty self-heal, custom preservation, no-conf default, _assert_design_file_usable ×3)
- [x] `tests/test_plan_empty_slate.sh` — Verify existing 8/8 pass (--init canonical default, round-trip write, self-heal round-trip)
- [x] `tests/test_validate_config.sh` — Add M121 coverage: 6a warning (pipeline.conf DESIGN_FILE=""), 6b warning (trailing slash), no-false-positive on valid/unset, both are warnings-only (exit 0)

## Test Run Results
Passed: 38  Failed: 0

## Bugs Found
None

## Files Modified
- [x] `tests/test_plan_config_loader.sh`
- [x] `tests/test_plan_empty_slate.sh`
- [x] `tests/test_validate_config.sh`

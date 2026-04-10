## Planned Tests
- [x] `tests/test_init_report_greenfield_suppression.sh` — Verify greenfield (file_count=0) suppresses false-positive warnings (8 tests)
- [x] `tests/test_init_report_architecture_config.sh` — Verify ARCHITECTURE_FILE config path is checked (8 tests)

## Test Run Results
Passed: 328  Failed: 0

## Bugs Found
None

## Files Modified
- [x] `tests/test_init_report_greenfield_suppression.sh`
- [x] `tests/test_init_report_architecture_config.sh`

## Coverage Summary

### Test File 1: test_init_report_greenfield_suppression.sh
Validates that false-positive warnings are suppressed on greenfield (file_count=0) projects:
- emit_init_summary() suppresses ARCHITECTURE_FILE warning on greenfield
- emit_init_summary() suppresses test command warning on greenfield
- emit_init_summary() shows expected warnings on brownfield (file_count > 0)
- _report_attention_items() respects file_count parameter
- emit_init_report_file() generates INIT_REPORT.md with correct suppression

### Test File 2: test_init_report_architecture_config.sh
Validates that ARCHITECTURE_FILE config is properly checked:
- Default hardcoded ARCHITECTURE.md path is checked first
- Custom ARCHITECTURE_FILE path from pipeline.conf is checked second
- Quote stripping works for both single and double quotes
- Missing files trigger expected warnings
- Config path checking works across all report-generation functions

### Full Test Suite Results
All 328 shell tests pass (312 existing + 16 new).
Python tests: PASSED

All task requirements verified:
- ✅ ARCHITECTURE_FILE check reads pipeline.conf configuration
- ✅ Greenfield warning suppression on file_count=0
- ✅ Brownfield warning display on file_count > 0
- ✅ file_count parameter threaded to _report_attention_items
- ✅ Same fix applied to INIT_REPORT.md writer function

## Audit Rework
- [x] Fixed: INTEGRITY finding in tests/test_init_report_architecture_config.sh:259 — replaced unconditional `pass` with proper assertions that check actual output. Test 8 now verifies both emit_init_summary and _report_attention_items paths emit "ARCHITECTURE_FILE not detected" warning when ARCHITECTURE_FILE is empty and file_count > 0.
- [x] Fixed: EXERCISE finding — added `source "${TEKHTON_HOME}/lib/init_config.sh"` to both test files so that `_best_command` (called by emit_init_summary) is available in test environment, matching runtime conditions.
- [x] Fixed: COVERAGE finding — added second test assertion in test_empty_architecture_file_config to call `_report_attention_items` with empty ARCHITECTURE_FILE and verify the warning appears in that code path as well.

All 328 shell tests pass (312 existing + 16 new). No test weakening or implementation changes.

## Planned Tests
- [x] `tests/test_detect_claude_md_fallback.sh` — Verify detect_languages() reads tech stack from CLAUDE.md when file-based detection is empty
- [x] `tests/test_health_greenfield_baseline.sh` — Verify health scoring for greenfield projects and pre-code callout in report
- [x] `tests/test_dep_ratio_boundary.sh` — Verify dependency ratio scoring is continuous at boundary (ratio=50 scores 25)

## Test Run Results
Passed: 333 (shell) + 76 (Python)  Failed: 0

## Bugs Found
None

## Files Modified
- [x] `tests/test_detect_claude_md_fallback.sh`
- [x] `tests/test_health_greenfield_baseline.sh`
- [x] `tests/test_dep_ratio_boundary.sh` — Fixed to extract dep_ratio sub-score from JSON details, added 6 boundary test cases covering all tiers

## Timing
- Test executions: 1
- Approximate total test execution time: ~45s
- Test files written: 1 (fixed/completed)

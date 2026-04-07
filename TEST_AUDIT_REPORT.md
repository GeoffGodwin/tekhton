## Test Audit Report

### Audit Summary
Tests audited: 2 files, 14 test functions
Verdict: CONCERNS

---

### Findings

#### EXERCISE: test_review_inloop_recalibration.sh never calls implementation code
- File: tests/test_review_inloop_recalibration.sh:1-299
- Issue: All 8 tests re-implement the bump algorithm inline (arithmetic directly in the test script) rather than sourcing `stages/review.sh` or calling any function from it. The bump logic lives inside `run_stage_review()` as an embedded block (lines 120–138), not a callable helper, so the tests replicate the exact same bash arithmetic and assert against their own copy. A bug in the production code — wrong variable name, wrong multiplier, wrong threshold — would leave all 8 tests green while the implementation remains broken. This provides false assurance for bug fix #2.
- Severity: HIGH
- Action: Extract the bump block from `run_stage_review()` into a named helper function (e.g., `_recalibrate_reviewer_turns()`) in `stages/review.sh` or a shared lib file. The test can then source the file and call the real function. Until then, bug fix #2 has no mechanical test coverage against the actual implementation — only against the test's own copy of the algorithm.

#### COVERAGE: Test 1 and Test 5 in test_review_inloop_recalibration.sh are identical
- File: tests/test_review_inloop_recalibration.sh:32-52 (Test 1) and tests/test_review_inloop_recalibration.sh:144-168 (Test 5)
- Issue: Both tests use exactly the same setup — `ADJUSTED_REVIEWER_TURNS=20`, `LAST_AGENT_TURNS=17`, `REVIEWER_MAX_TURNS_CAP=30` — and assert the same result (25). Test 1 is labelled "Usage >= 85% triggers bump" and Test 5 is labelled "Exact 85% threshold triggers bump." Since 17/20 = 85% exactly, these are the same scenario. The duplicate wastes a test slot that could verify a distinct boundary.
- Severity: LOW
- Action: Remove one of the two duplicates and replace it with a distinct scenario not already covered — for example, the guard condition where `_rev_limit` is 0 (no-op expected), or usage at 86% with a non-round denominator to confirm integer truncation behaviour.

#### COVERAGE: test_metrics_calibration_overshoot.sh does not test all-cap-hit fallback
- File: tests/test_metrics_calibration_overshoot.sh:64-86
- Issue: No test covers the scenario where every record qualifies as a cap-hit and is skipped, leaving `count < min_runs` and forcing the function to return the original recommendation unchanged. A project whose reviewer consistently saturates its turn limit would produce exactly this metrics file, and calibration would silently never apply. The existing Test 2 covers 80% usage (below threshold, all included), not the all-excluded case.
- Severity: LOW
- Action: Add a test where all 5 records have `actual <= adjusted` with usage >= 85% (e.g., est=10, actual=9, adjusted=10 for all 5 records). After filtering, `count=0 < min_runs=5`, so `calibrate_turn_estimate 25 reviewer` should return 25 unchanged.

---

### Notes

**test_metrics_calibration_overshoot.sh passes all exercise and honesty checks.**
All 6 test functions source `lib/metrics.sh` and `lib/metrics_calibration.sh` and call `calibrate_turn_estimate()` directly against real temp-file fixtures. Expected values (14, 8, 10, 20, 25, 10) are derived step-by-step from the implementation's own arithmetic and documented inline — no hard-coded magic numbers. Edge cases covered: pure overshoots, pure sub-85% usage, mixed cap-hit/overshoot exclusion, extreme overshoot clamped to 2.0x multiplier, insufficient data fallback, and disabled calibration short-circuit.

**CODER_SUMMARY.md is absent.** The REVIEWER_REPORT confirms it was not produced by the coder agent. The "Implementation Files Changed: none" in the audit context is a consequence — scope alignment was performed against git status instead (`lib/metrics_calibration.sh` and `stages/review.sh` both show as modified). Both test files align with the current state of those implementation files; no orphaned imports or stale references were found.

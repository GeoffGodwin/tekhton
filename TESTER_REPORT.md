## Planned Tests
- [x] `tests/test_m43_test_aware.sh` — verify extraction, baseline summary, and template conditional coverage for M43

## Test Run Results
Passed: 16  Failed: 0

## Bugs Found
None

## Files Modified
- [x] `tests/test_m43_test_aware.sh`

## Audit Rework
- [x] Fixed: INTEGRITY — `tests/test_notes_acceptance.sh:229` else branch called `pass()` unconditionally;
  changed to `fail "run_note_acceptance should set warn_no_test for BUG (got: ...)"` so the
  condition is load-bearing and any deviation from expected behaviour is caught.
- [x] Fixed: INTEGRITY — `tests/test_human_workflow.sh:233-237` special-characters test discarded
  the real exit code with `|| true` then asserted `echo 'ok'` (always 0). Replaced with
  `set +e; claim_single_note "$note"; _special_rc=$?; set -e`, a crash-detection guard
  (`rc > 1` → FAIL), and an `assert_contains` check that HUMAN_NOTES.md is not corrupted.
- [x] Fixed: SCOPE — `tests/test_finalize_run.sh:830` assertion 15.6 (`resolve_human_notes NOT
  called on failure`) tested a function removed in M42. The assertion was vacuously true for
  all inputs. Replaced with a comment that explains the removal and maps intent to Suite 8b
  (cases 8b.4 and 8b.7 cover the equivalent live guards).
- [x] Fixed: WEAKENING — Added a comment block above Suite 8b in `test_finalize_run.sh` that
  enumerates the four former assertions retired in M42, states the behavioral reason each no
  longer applies, and maps each to the specific Suite 8b case that now covers the equivalent
  guarantee (net: −4 former, +8 Suite 8b, broader surface covered).
- [ ] Deferred: EXERCISE — `tests/test_human_workflow.sh:634-688` Section 10 flag-validation
  tests inline-reimplement `tekhton.sh` argument-parsing logic rather than calling real code.
  Acknowledged by comment at lines 634–638. Full fix requires extracting flag validation into
  a sourceable `lib/flags.sh` function — that is an implementation change outside test scope.

## Post-Rework Test Run
Shell: Passed: 226  Failed: 0
Python: 76 passed, 1 skipped

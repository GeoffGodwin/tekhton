# Coder Summary

## Status: COMPLETE

## What Was Implemented
M121 — Planning Path Write-Failure Hardening + Empty-Slate Test Coverage.

- **Goal 1 — Fail-loud DESIGN_FILE guard.** Added `_assert_design_file_usable()`
  helper to `lib/plan.sh` (after `load_plan_config` block, before the
  planning-config defaults). Returns 1 with a clear `error()` message when
  `DESIGN_FILE` is empty or ends in `/`, returns 0 otherwise. Invoked at the
  top of all six plan-mode / replan-mode consumers:
  - `run_plan_interview` in `stages/plan_interview.sh`
  - `run_plan_generate` in `stages/plan_generate.sh`
  - `check_design_completeness` in `lib/plan_completeness.sh`
  - `run_plan_completeness_loop` in `lib/plan_completeness.sh`
  - `run_replan` in `lib/replan_brownfield.sh`
  - `_apply_brownfield_delta` in `lib/replan_brownfield.sh`

  Per the milestone design, `lib/plan_state.sh` was intentionally left
  unchanged (cosmetic label rendering tolerates empty values).

- **Goal 2 — Verified write in `run_plan_interview`.** Replaced the
  unchecked `printf ... > "$design_file"` at `stages/plan_interview.sh:194`
  with (a) a failing-redirect check (`if ! printf ... > "$file" 2>/dev/null`)
  that emits a specific error and returns 1, plus (b) a post-write
  `[[ ! -s "$design_file" ]]` zero-byte assertion for defence in depth.
  Both paths close fd 3 before returning.

- **Goal 3 — Config validator shape checks.** Added checks 6a and 6b to
  `lib/validate_config.sh` immediately before the existing existence check.
  - 6a warns when `pipeline.conf` contains a literal `DESIGN_FILE=""` (empty
    string). Detected by grepping the raw file, since `config_defaults.sh`
    self-heals the in-memory value before validation runs. Wording is
    brownfield-safe (informational, points out the runtime self-heal).
  - 6b warns when `DESIGN_FILE` ends in `/`. Uses the in-memory value
    (survives `config_defaults.sh` because `:=` does not override non-empty
    values). Actionable wording (fix instructions).
  Both are warnings only — `validate_config()` still returns 0 on warnings,
  preserving brownfield safety for users on legacy `pipeline.conf` files.

- **Goal 4 — Integration test (NEW).** `tests/test_plan_empty_slate.sh`.
  Three sub-tests:
  1. Fresh `--init` emits canonical `DESIGN_FILE=".tekhton/DESIGN.md"`.
  2. `run_plan_interview` with a stubbed batch call produces a non-empty
     `.tekhton/DESIGN.md` on disk with the stubbed content.
  3. Negative case: a pipeline.conf-equivalent `DESIGN_FILE=""` still
     round-trips cleanly because M120 + M121 self-heal empty values. The
     assertion does not fire and the write succeeds at the canonical path.

- **Goal 5 — Unit test (NEW).** `tests/test_plan_config_loader.sh`.
  Six sub-tests exercising: (1) empty-string self-heal, (2) custom
  DESIGN_FILE preservation, (3) no-pipeline.conf default path, (4)
  `_assert_design_file_usable` returns 1 on empty, (5) returns 1 on
  trailing slash, (6) returns 0 on canonical value.

- **Goal 6 — Test registration.** `tests/run_tests.sh` uses a glob
  (`for test_file in "${TESTS_DIR}"/test_*.sh`) to auto-discover all
  `test_*.sh` files; no explicit registration row is needed or used. Both
  new files are picked up by the runner automatically.

## Files Modified
- `lib/plan.sh` — Added `_assert_design_file_usable()` helper.
- `stages/plan_interview.sh` — Added assertion + verified-write at the
  write path.
- `stages/plan_generate.sh` — Added assertion at entry.
- `lib/plan_completeness.sh` — Added assertion at two entry points.
- `lib/replan_brownfield.sh` — Added assertion at two entry points.
- `lib/validate_config.sh` — Added checks 6a (empty string) and 6b
  (trailing slash).
- `tests/test_plan_config_loader.sh` (NEW) — Unit test.
- `tests/test_plan_empty_slate.sh` (NEW) — Integration test.

## Docs Updated
None — no public-surface changes in this task. M121 is pure defence-in-depth
hardening: no new config keys, no new CLI flags, no schema changes, and no
new exported helpers that callers outside `lib/plan*.sh` would reference.
The only user-visible change is two new validator warnings and two new
error messages that fire only on degenerate configs — both surface through
existing output channels (`validate_config` and `error()` respectively) and
require no doc entry.

## Verification
- `shellcheck -S warning` clean on all modified files and both new tests
  (only info-level SC1091 for sourced files and SC2153 for
  exported-elsewhere variables, both expected for this codebase).
- Both new tests pass standalone:
  - `test_plan_config_loader.sh`: 6/6 pass.
  - `test_plan_empty_slate.sh`: 8/8 pass (including the negative
    self-heal round-trip case).
- Hand-test confirms failing-write path returns exit code 1 (write to a
  chmod 555 directory path).
- Full `bash tests/run_tests.sh`: 439/439 shell tests pass, 188/188
  Python tests pass. No regressions vs the pre-change state; the 8
  pre-existing failures documented in the baseline did not recur in
  this environment.

## Human Notes Status
No human notes listed in this task.

## Observed Issues (out of scope)
- `lib/replan_brownfield.sh` is 347 lines (2 above the pre-M121 baseline of
  345). It already exceeded the 300-line ceiling before M121 and splitting
  it out would be a refactor unrelated to the M121 design. Flagging for
  future cleanup rather than expanding scope here.

# Coder Summary

## Status: COMPLETE

## What Was Implemented

M112 — Pre-Run Dedup Coverage Hardening.

### Goal 1 — Cover highest-value missed test paths
Added `test_dedup_can_skip` / `test_dedup_record_pass` guards to three previously
uncached TEST_CMD invocations, following the pattern used by existing call sites
(milestone_acceptance, gates_completion, orchestrate_loop, orchestrate_preflight,
hooks_final_checks):

1. `run_prerun_clean_sweep()` — initial pre-coder test check
   (`stages/coder_prerun.sh`). When dedup can skip, logs a `test_dedup_skip`
   event and treats the cached pass as success so the coder starts from a
   clean state without re-running TEST_CMD. Records pass on exit 0.
2. `_run_prerun_fix_agent()` — post-attempt shell verification
   (`stages/coder_prerun.sh`). Same skip/record treatment: if nothing
   observable changed, the fix's effect is already captured.
3. `_run_tester_inline_fix()` — retest loop after each fix attempt
   (`stages/tester_fix.sh`). Same pattern; emits skip events to `$LOG_FILE`.

All new sites emit `test_dedup_skip` through the existing `emit_event` pathway
so dashboards and the causal log continue to observe dedup activity. All new
sites honor `TEST_DEDUP_ENABLED=false` via the central policy in
`lib/test_dedup.sh` — no parallel skip mechanism was introduced.

### Goal 2 — Strengthen fingerprint identity (HEAD inclusion)

`_test_dedup_fingerprint()` now hashes `git rev-parse HEAD` alongside
`git status --porcelain` and `cmd:${TEST_CMD}`. A clean working tree at a
different commit therefore never matches a prior pass fingerprint, preventing
false skips across commits. Fallback behavior for non-git directories is
unchanged (always returns "must run").

### Goal 3 — Baseline / acceptance behavior preserved

No change to baseline capture, comparison, or acceptance semantics. Pass
fingerprints are still only recorded on exit 0. Failed-state fingerprints are
never cached. Existing dedup-enabled gates continue to behave unchanged (tests
confirm).

### Goal 4 — Policy centralization

No new config keys, no new skip mechanism. Reused `lib/test_dedup.sh` as the
single policy source. `test_dedup_reset` is still called once at orchestration
loop entry (`lib/orchestrate.sh`), which is sufficient for the new call sites.

## Root Cause (bugs only)
N/A — this is a feature milestone (coverage expansion + fingerprint
strengthening), not a bug fix.

## Files Modified

| File | Change |
|------|--------|
| `lib/test_dedup.sh` | `_test_dedup_fingerprint` now includes `git rev-parse HEAD` in the hashed input. Doc comment updated. |
| `stages/coder_prerun.sh` | `run_prerun_clean_sweep` gains a can_skip guard on the initial pre-coder check and a record_pass call on exit 0. `_run_prerun_fix_agent` gains the same guard/record pair around the shell verification after each fix attempt. |
| `stages/tester_fix.sh` | `_run_tester_inline_fix` retest loop gains a can_skip guard and record_pass on exit 0. |
| `tests/test_dedup.sh` | New Suites 4.5 and 4.6: HEAD-identity invalidation across commits and `record_pass` no-op when `TEST_DEDUP_ENABLED=false`. |
| `tests/test_dedup_callsites.sh` | Suite 4 extended to check the two new call sites (`stages/coder_prerun.sh`, `stages/tester_fix.sh`). New Suite 4.8 asserts coder_prerun has ≥2 can_skip and ≥2 record_pass calls (both initial and fix-loop paths). |

## Human Notes Status
No human notes were injected in this run.

## Docs Updated
None — no public-surface changes. Only internal logic (fingerprint composition
and internal call-site additions). The pre-existing `TEST_DEDUP_ENABLED`
config key is already documented in CLAUDE.md and its contract is unchanged.

## Verification
- `shellcheck tekhton.sh lib/*.sh stages/*.sh` — clean on all modified files
  (one pre-existing SC1091 info-level note in `lib/pipeline_order.sh`, unrelated
  to this milestone).
- `bash tests/run_tests.sh` — 422 shell tests passed, 0 failed; 177 Python
  tests passed. All M105 tests still green; M112 additions green.
- All modified files are under 300 lines (largest: 245).

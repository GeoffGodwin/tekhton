# Milestone 63: Test Baseline Hygiene & Completion Gate Hardening
<!-- milestone-meta
id: "63"
status: "done"
-->

## Overview

Tekhton is designed to leave the repo in a pristine state — all tests passing,
no build errors. However, the test baseline system has gaps that allow runs to
complete with failing tests or misclassify new failures as "pre-existing":

1. **Stale baselines on resume:** `capture_test_baseline()` skips re-capture if
   `TEST_BASELINE.json` exists for the current milestone, even across separate
   runs. A baseline from Run A persists into Run B.
2. **Completion gate doesn't run tests:** `run_completion_gate()` only checks
   whether `CODER_SUMMARY.md` says "COMPLETE" — it never executes `TEST_CMD`.
3. **Tester blind to baseline:** The tester prompt has no `TEST_BASELINE_SUMMARY`
   context, so it cannot distinguish pre-existing failures from new ones when
   deciding whether to trigger `TESTER_FIX_ENABLED` auto-fix.
4. **Stuck detection can auto-pass:** When `TEST_BASELINE_PASS_ON_STUCK=true`,
   identical failures across 2+ attempts are auto-passed, even if the failures
   are genuine regressions from the current run (baseline was clean).

This milestone hardens the test integrity guarantees so Tekhton never silently
passes a run with failing tests.

Depends on M56 for stable pipeline baseline.

## Scope

### 1. Fresh Baseline Per Run

**File:** `lib/test_baseline.sh`

**Problem:** `_should_capture_test_baseline()` at line 171-177 only checks
`! has_test_baseline` — i.e., whether a baseline file exists for the current
milestone. It cannot distinguish "resume within same run" from "new run."

**Fix:** Add a `run_id` field to `TEST_BASELINE.json`. Use `TIMESTAMP` (set
once at `tekhton.sh` startup, globally exported) as the run identifier.

Modify `_should_capture_test_baseline()`:
1. If no baseline file exists → capture (current behavior)
2. If baseline exists, read its `run_id` field
3. If `run_id` matches current `TIMESTAMP` → skip (same-run resume)
4. If `run_id` differs → re-capture (new run with stale baseline)

Modify baseline JSON emission at lines 115-130 to include:
```json
{
  "run_id": "${TIMESTAMP}",
  "timestamp": "...",
  "milestone": "...",
  "exit_code": 0,
  "output_hash": "...",
  "failure_hash": "...",
  "failure_count": 0
}
```

### 2. Inject TEST_BASELINE_SUMMARY into Tester

**Files:** `stages/tester.sh`, `prompts/tester.prompt.md`

**Problem:** `stages/coder.sh:346-361` builds and exports `TEST_BASELINE_SUMMARY`
but the tester stage never reads or injects it.

**Fix:** In `stages/tester.sh`, before calling `render_prompt`, build
`TEST_BASELINE_SUMMARY` using the same pattern as coder.sh:

```bash
export TEST_BASELINE_SUMMARY=""
if [[ "${TEST_BASELINE_ENABLED:-false}" == "true" ]] && has_test_baseline; then
    local _bl_status
    _bl_status=$(get_baseline_status)
    if [[ "$_bl_status" == "pre_existing_failures" ]]; then
        TEST_BASELINE_SUMMARY="Pre-existing test failures detected before your changes.
$(get_baseline_failure_summary)"
    fi
fi
```

Add conditional block to `prompts/tester.prompt.md`:
```markdown
{{IF:TEST_BASELINE_SUMMARY}}
## Pre-Change Test Baseline
{{TEST_BASELINE_SUMMARY}}
Do NOT treat pre-existing failures as regressions from your test work.
Focus on testing NEW functionality only.
{{ENDIF:TEST_BASELINE_SUMMARY}}
```

Context cost: ~200 tokens. Negligible.

### 3. Completion Gate Test Enforcement

**File:** `lib/gates_completion.sh`

**Problem:** `run_completion_gate()` at lines 52-84 only checks
`CODER_SUMMARY.md` for "COMPLETE" status. It never executes `TEST_CMD`.

**Note:** The pre-finalization test gate in `orchestrate.sh:244-300` already
runs `TEST_CMD`, but it runs AFTER acceptance checking, not as a formal
completion gate. These serve different purposes:
- Pre-finalization gate: catches regressions before final commit
- Completion gate: prevents "SUCCESS" status when tests fail

**Fix:** Add test enforcement to `run_completion_gate()`:
1. After the existing CODER_SUMMARY check passes, if `TEST_CMD` is configured
   and `COMPLETION_GATE_TEST_ENABLED=true`:
   - Run `TEST_CMD`
   - If exit code 0 → pass
   - If exit code non-zero → compare against baseline using
     `compare_test_with_baseline()` (already in test_baseline.sh:181-233)
   - If all failures are pre-existing → pass (with logged note)
   - If new failures exist → fail the gate

Add config key `COMPLETION_GATE_TEST_ENABLED` to `lib/config_defaults.sh`:
```bash
: "${COMPLETION_GATE_TEST_ENABLED:=true}"
```

Place it near the existing `TEST_BASELINE_*` keys (around line 332).

### 4. Tighten Stuck Detection

**File:** `lib/test_baseline.sh`

**Problem:** `_check_acceptance_stuck()` at line 295 returns 0 (auto-pass)
when `TEST_BASELINE_PASS_ON_STUCK=true` **without checking whether the
baseline was clean**. If baseline had zero failures (exit_code=0), all
current failures are definitionally new regressions — auto-passing is wrong.

**Fix:** Before the auto-pass return at line 295, add a baseline state check:

```bash
if [[ "${TEST_BASELINE_PASS_ON_STUCK:-false}" = "true" ]]; then
    # Never auto-pass if baseline was clean — all failures are new
    local _bl_exit
    _bl_exit=$(get_baseline_exit_code)
    if [[ "$_bl_exit" == "0" ]]; then
        warn "Stuck detected but baseline was clean — all failures are new regressions. NOT auto-passing."
        emit_causal_event "stuck_test_detected" "clean_baseline" \
            "Stuck on identical failures but baseline had zero failures — auto-pass blocked"
        return 1
    fi
    warn "TEST_BASELINE_PASS_ON_STUCK=true — treating acceptance as PASSED."
    return 0
fi
```

Also update the causal event emission at lines 287-293 to use event type
`stuck_test_detected` (more specific than the current generic event).

### 5. Baseline Cleanup

**File:** `lib/test_baseline.sh`

Add `cleanup_stale_baselines()`:
- Called during finalization (add hook in `lib/finalize.sh`)
- Removes TEST_BASELINE.json files with `run_id` not matching current `TIMESTAMP`
- Keeps only the current run's baseline (for potential resume)
- Logs cleanup action to causal log

Implementation: Baseline files are per-milestone (stored relative to
`.claude/` or milestone dir). Walk the baseline storage location, check
each file's `run_id`, remove if stale.

### 6. Tester Fix Baseline Check

**File:** `stages/tester.sh`

**Problem:** The `TESTER_FIX_ENABLED` flow at lines 226-248 spawns a fix
run for ANY test failure, including pre-existing ones.

**Fix:** Before spawning the fix agent (line 247), check baseline:
```bash
if [[ "${TEST_BASELINE_ENABLED:-false}" == "true" ]] && has_test_baseline; then
    local _comparison
    _comparison=$(compare_test_with_baseline "$_failure_output" "$_test_exit")
    if [[ "$_comparison" == "pre_existing" ]]; then
        log "All test failures are pre-existing — skipping tester fix."
        # Continue to normal completion, not fix
        continue  # or break, depending on control flow
    fi
fi
```

## Migration Impact

| Key | Default | Notes |
|-----|---------|-------|
| `COMPLETION_GATE_TEST_ENABLED` | `true` | Set to `false` to restore prior behavior (no test enforcement at completion) |

Existing `TEST_BASELINE_ENABLED`, `TEST_BASELINE_PASS_ON_STUCK`, and
`TEST_BASELINE_STUCK_THRESHOLD` settings continue to work unchanged.

The `run_id` field added to `TEST_BASELINE.json` is backward-compatible:
if a baseline file from a prior version lacks `run_id`, treat it as stale
(re-capture).

## Acceptance Criteria

- Fresh baseline captured at start of each new run (not reused across runs)
- Resume within the same run reuses baseline (no unnecessary re-capture)
- Tester prompt includes `TEST_BASELINE_SUMMARY` when available
- Completion gate runs `TEST_CMD` and fails on non-zero exit (minus baseline)
- Stuck detection never auto-passes when baseline was clean (exit_code=0)
- Stale baseline files cleaned up during finalization
- Tester fix flow checks baseline before spawning fix agent
- All existing tests pass
- No run can report SUCCESS with genuinely failing tests

Tests:
- New run re-captures baseline even when `TEST_BASELINE.json` exists (different TIMESTAMP)
- Resume within same run skips re-capture (same TIMESTAMP in run_id field)
- Baseline file missing `run_id` field treated as stale (backward compat)
- Tester prompt renders baseline block when summary is non-empty
- Tester prompt omits baseline block when summary is empty
- Completion gate catches test failures that acceptance gate missed
- Completion gate passes when all failures are pre-existing (baseline comparison)
- Stuck detection with clean baseline (exit_code=0) never auto-passes
- Stuck detection with dirty baseline auto-passes when PASS_ON_STUCK=true
- Stale baseline cleanup removes old files, keeps current
- Tester fix skips when all failures are pre-existing

Watch For:
- The completion gate test run adds wall-clock time to every successful run.
  This is acceptable because it's the only way to guarantee test integrity.
  If `TEST_CMD` is slow, users can disable with `COMPLETION_GATE_TEST_ENABLED=false`.
- Baseline re-capture means running `TEST_CMD` once more at run start. For
  projects with slow test suites, this adds startup cost. The trade-off is
  correctness — a stale baseline is worse than a 30-second test run.
- The `get_baseline_exit_code` function must handle missing or malformed
  baseline JSON defensively (return empty string, not crash).
- The pre-finalization test gate in `orchestrate.sh:244-300` is a SEPARATE
  mechanism from the completion gate. Do NOT remove or merge them — they serve
  different purposes at different points in the pipeline.

Seeds Forward:
- Clean baseline guarantees make stuck detection more trustworthy
- Completion gate data feeds into run memory for cross-run quality tracking
- Baseline-aware tester fix is a prerequisite for M64 (Surgical Fix Mode)

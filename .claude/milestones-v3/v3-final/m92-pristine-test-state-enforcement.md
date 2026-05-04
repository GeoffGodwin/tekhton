# Milestone 92: Pristine Test State Enforcement
<!-- milestone-meta
id: "92"
status: "done"
-->

## Overview

Today `TEST_BASELINE_PASS_ON_PREEXISTING=true` is the default. When a test suite
has pre-existing failures, the pipeline silently accepts them everywhere —
acceptance gate, completion gate, pre-finalization gate — and calls the run
"done." This means a codebase can accumulate broken tests indefinitely: each
run masks the same failure set, rework never gets triggered, and the user sees
green even though the suite is broken.

This milestone flips the model:

1. **Pre-coder clean sweep**: before the coder agent runs, if the test suite is
   failing, run a targeted fix agent to restore a clean baseline. Coder work
   starts from passing tests.
2. **Strict post-run gate**: after coder work completes, all tests must pass.
   `pre_existing` is no longer treated as an acceptable outcome.
3. **`TEST_BASELINE_PASS_ON_PREEXISTING` defaults to `false`**: projects that
   genuinely cannot fix some tests can opt back in, but it is no longer the
   default silent workaround.

## Design Decisions

### 1. Pre-run fix, not pre-run block

When tests fail before the coder runs, the pipeline spawns a `PRE_RUN_FIX`
agent (reusing the existing `_try_preflight_fix` mechanism, or a near-identical
one) to repair them. If the fix succeeds, the coder runs on a clean state. If
the fix fails, the pipeline does NOT abort — it warns loudly, captures the
unfixed state as the new baseline, and proceeds. "Can't fix everything" is
acknowledged; "silently accepting broken tests as done" is not.

This preserves progress on large legacy projects where some tests may be
genuinely difficult to fix. The difference: the user sees a warning, not a
silent green.

### 2. `TEST_BASELINE_PASS_ON_PREEXISTING=false` is the new default

The three sites that check this flag are:
- `lib/milestone_acceptance.sh` — milestone acceptance gate
- `lib/orchestrate.sh` — pre-finalization test gate
- `lib/gates_completion.sh` — completion gate

All three currently auto-pass when `compare_test_with_baseline` returns
`pre_existing`. With the new default, `pre_existing` routes to the same path
as `new_failures`: the coder gets routed back to fix tests.

### 3. Baseline is only used to identify *new* regressions

The baseline still serves its original purpose: identifying whether a failure
was introduced by this run or was there before. The change is in what happens
when the comparison returns `pre_existing` — it now means "these need fixing,"
not "these are fine."

### 4. Escape hatch remains

`TEST_BASELINE_PASS_ON_PREEXISTING=true` in `pipeline.conf` restores the prior
behavior for projects that explicitly opt in. The config validation adds a
comment warning that this masks failing tests.

### 5. Pre-run fix is gated by config and cost

```bash
: "${PRE_RUN_CLEAN_ENABLED:=true}"      # spawn fix agent if tests fail pre-coder
: "${PRE_RUN_FIX_MAX_TURNS:=20}"        # turn budget for pre-run fix agent
: "${PRE_RUN_FIX_MAX_ATTEMPTS:=1}"      # max fix attempts before proceeding anyway
```

If `PRE_RUN_CLEAN_ENABLED=false`, the pre-run check is skipped entirely.

## Scope Summary

| Area | Count | Notes |
|------|-------|-------|
| Shell files modified | 4 | `lib/orchestrate.sh`, `lib/milestone_acceptance.sh`, `lib/gates_completion.sh`, `lib/config_defaults.sh` |
| Shell files modified | 1 | `stages/coder.sh` — pre-coder clean sweep |
| Shell tests modified | 1 | `tests/test_orchestrate.sh` — update expectations |
| Shell tests added | 1 | `tests/test_pristine_state_enforcement.sh` |

## Implementation Plan

### Step 1 — lib/config_defaults.sh: change default + add new keys

```bash
: "${TEST_BASELINE_PASS_ON_PREEXISTING:=false}"   # CHANGED from true
: "${PRE_RUN_CLEAN_ENABLED:=true}"
: "${PRE_RUN_FIX_MAX_TURNS:=20}"
: "${PRE_RUN_FIX_MAX_ATTEMPTS:=1}"
```

### Step 2 — lib/milestone_acceptance.sh + lib/gates_completion.sh + lib/orchestrate.sh

In each of the three `pre_existing` auto-pass blocks, replace the current
`PASS_ON_PREEXISTING` check with a direct check:

```bash
# OLD:
if [[ "${TEST_BASELINE_PASS_ON_PREEXISTING:-true}" = "true" ]]; then
    log "... pre-existing failures accepted."
fi

# NEW:
if [[ "${TEST_BASELINE_PASS_ON_PREEXISTING:-false}" = "true" ]]; then
    log "... pre-existing failures accepted (PASS_ON_PREEXISTING=true)."
else
    warn "Tests FAILED — pre-existing failures with PASS_ON_PREEXISTING=false."
    warn "All tests must pass. Set TEST_BASELINE_PASS_ON_PREEXISTING=true to opt out."
    # route to fix / rework (same path as new_failures)
fi
```

### Step 3 — stages/coder.sh: pre-coder clean sweep

At the top of the coder stage (before running the coder agent), check test
state when `PRE_RUN_CLEAN_ENABLED=true`:

```bash
if [[ "${PRE_RUN_CLEAN_ENABLED:-true}" = "true" ]] && [[ -n "${TEST_CMD:-}" ]]; then
    _prerun_exit=0
    _prerun_output=$(bash -c "${TEST_CMD}" 2>&1) || _prerun_exit=$?
    if [[ "$_prerun_exit" -ne 0 ]]; then
        warn "[coder] Tests failing before coder runs — attempting pre-run fix."
        if ! _run_prerun_fix_agent "$_prerun_output" "$_prerun_exit"; then
            warn "[coder] Pre-run fix incomplete. Coder will work from a non-pristine state."
            warn "[coder] Set PRE_RUN_CLEAN_ENABLED=false to skip this check."
        fi
    fi
fi
```

`_run_prerun_fix_agent()` reuses the `build_fix.prompt.md` / jr-coder role, same
as `_try_preflight_fix`, with `PRE_RUN_FIX_MAX_TURNS` budget.

### Step 4 — Update capture_test_baseline

When `PRE_RUN_CLEAN_ENABLED=true`, `capture_test_baseline` should be called
*after* the pre-run fix (if one ran), so the baseline reflects the achieved
clean state, not the dirty pre-fix state.

### Step 5 — Shell tests

`tests/test_pristine_state_enforcement.sh`:
- `test_preexisting_does_not_autopass` — `PASS_ON_PREEXISTING=false`, `pre_existing` result → acceptance fails
- `test_preexisting_autopasses_when_opted_in` — `PASS_ON_PREEXISTING=true` → still passes
- `test_prerun_fix_skipped_when_disabled` — `PRE_RUN_CLEAN_ENABLED=false` → fix agent not spawned
- `test_baseline_captured_after_fix` — verify baseline is captured post-fix, not pre-fix

## Files Touched

### Modified
- `lib/config_defaults.sh` — change default + add PRE_RUN_* keys
- `lib/milestone_acceptance.sh` — remove auto-pass on `pre_existing`
- `lib/gates_completion.sh` — remove auto-pass on `pre_existing`
- `lib/orchestrate.sh` — remove auto-pass on `pre_existing` in pre-finalization gate
- `stages/coder.sh` — pre-coder clean sweep before agent invocation

### Added
- `tests/test_pristine_state_enforcement.sh`

## Acceptance Criteria

- [ ] `TEST_BASELINE_PASS_ON_PREEXISTING` defaults to `false` in `config_defaults.sh`
- [ ] With the default, a run where post-coder tests match the failing baseline does NOT auto-pass acceptance
- [ ] With `TEST_BASELINE_PASS_ON_PREEXISTING=true`, the old behavior is preserved
- [ ] When pre-coder tests fail and `PRE_RUN_CLEAN_ENABLED=true`, a fix agent is spawned
- [ ] When the pre-run fix agent fails, a warning is emitted and the coder proceeds anyway (no hard abort)
- [ ] When `PRE_RUN_CLEAN_ENABLED=false`, no pre-run check is performed
- [ ] `bash tests/test_pristine_state_enforcement.sh` passes
- [ ] `shellcheck lib/milestone_acceptance.sh lib/gates_completion.sh lib/orchestrate.sh stages/coder.sh` zero warnings
- [ ] Existing `tests/test_orchestrate.sh` passes (updated expectations)

## Watch For

- Projects with intentionally failing tests (e.g., skipped integration tests)
  will immediately start seeing spurious fix attempts. The `PRE_RUN_CLEAN_ENABLED=false`
  escape hatch must be clearly documented in `docs/configuration.md`.
- The pre-run fix adds an agent call cost to every run where tests start dirty.
  `PRE_RUN_FIX_MAX_TURNS=20` keeps this cheap; the default should reflect that
  most pre-run fixes are small (a stale fixture, a path change).
- Baseline capture timing: currently `capture_test_baseline` runs at the start
  of `run_complete_loop`. With the pre-run fix, it should run *after* the fix
  to avoid capturing a baseline that is immediately dirtier than the post-fix
  state.

## Seeds Forward

- M94 surfaces the pre-run fix outcome in the recovery guidance: "Tests were
  failing before the coder ran. A fix agent was spawned but could not restore
  a clean state. Manual intervention may be required."
- Future: track "persistent pre-existing failures" across runs in run memory —
  if the same tests fail for 5 consecutive pre-run checks and can never be fixed,
  flag them as candidates for removal or permanent `PRE_RUN_CLEAN_ENABLED=false`.

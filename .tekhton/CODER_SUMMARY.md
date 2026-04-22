# Coder Summary — M118 Preflight / Intake Success-Line Timing Fix

## Status: COMPLETE

## What Was Implemented

**Goal.** Eliminate the "stage said success before its pill turned green"
window for the preflight and intake pre-stages. After M118, the pill flips
green BEFORE the corresponding green confirmation line appears in Recent
Events, so the TUI never shows a contradictory state where the log claims a
stage finished while its pill is still yellow.

**Mechanical change for both stages.** The `success "..."` call moves out of
the stage function and into the caller in `tekhton.sh`, emitted *after*
`tui_stage_end`. The library/stage function communicates "should emit on the
PASS path" to the caller via a single global; the caller emits and unsets it.

**Preflight (lib/preflight.sh + tekhton.sh).**
- `run_preflight_checks` no longer calls `success "$summary"` on the all-pass
  path. Instead it stores the summary in `_PREFLIGHT_SUMMARY`.
- The warn-only and fail paths are untouched — they still emit `warn` /
  `error` from inside the function as before (per milestone scope: "only the
  PASS path is reordered").
- After `tui_stage_end "preflight" ... "pass"`, tekhton.sh emits
  `success "$_PREFLIGHT_SUMMARY"` and unsets the global. The unset is
  important for `--complete` mode so a stale summary cannot leak into a later
  pipeline iteration (the warn/fail paths leave the global unset).

**Intake (stages/intake.sh + tekhton.sh).**
- The PASS branch of the verdict `case` no longer calls
  `success "Intake: task is clear. Proceeding."`. Instead it sets
  `_INTAKE_PASS_EMIT="true"`.
- Other verdict branches (TWEAKED, SPLIT_RECOMMENDED, NEEDS_CLARITY) are
  untouched — they emit their own diagnostics through their handler chains
  at appropriate times.
- After `tui_stage_end "intake" ...` in tekhton.sh, the caller checks
  `_INTAKE_PASS_EMIT` and on `true` emits the success line and unsets it.

**Why a dedicated flag for intake instead of checking `INTAKE_VERDICT`.**
Three early-exit paths at the top of `run_stage_intake` set
`INTAKE_VERDICT="PASS"` without actually running intake:
- `INTAKE_AGENT_ENABLED != true` — explicitly disabled
- `HUMAN_MODE == true` — notes are pre-triaged, intake is skipped silently
- The cached `INTAKE_CACHED == true` PASS branch — no banner, no log
- Empty content — function returns 0 silently

Pre-M118 these were all silent. Checking the verdict in the caller would
start emitting the success line in those paths, regressing behavior.
A dedicated flag set only on the actual PASS branch preserves the original
silence on those paths.

## Root Cause (bugs only)

Both `success` calls fired from *inside* the stage function, before control
returned to `tekhton.sh` where `tui_stage_end` performs the pill flip. The
TUI sidecar polls `tui_status.json` ~2x/s and updates Recent Events from the
ring buffer at the same cadence — so an event written milliseconds before
the pill state update lands in the events panel one tick *before* the pill
visibly flips. The fix is purely an ordering swap; no new state machinery
or polling logic is needed.

## Files Modified

- `lib/preflight.sh` — Replaced `success "$summary"` on the all-pass path
  with `_PREFLIGHT_SUMMARY="$summary"`. Warn and fail paths untouched.
- `stages/intake.sh` — Replaced `success "Intake: task is clear. Proceeding."`
  on the PASS verdict branch with `export _INTAKE_PASS_EMIT="true"`.
- `tekhton.sh` — Two new emit-and-unset blocks: one after the preflight
  `tui_stage_end` (consumes `_PREFLIGHT_SUMMARY`), one after the intake
  `tui_stage_end` (consumes `_INTAKE_PASS_EMIT`).

## Human Notes Status

N/A — no human notes were attached to this task.

## Architecture Decisions

- **Two single-purpose globals, not one shared transport.** The preflight
  and intake handoffs travel through separate globals (`_PREFLIGHT_SUMMARY`
  and `_INTAKE_PASS_EMIT`) because their semantics differ: preflight needs
  to ferry a dynamically-built summary string; intake's success message is
  a fixed string and only needs a boolean "should emit" signal. Sharing a
  single global would conflate a string-payload role with a flag role and
  invite future bugs.
- **Caller-side emit, not library-side defer queue.** The "queue success
  calls and flush them after stage_end" approach (option 3 in the milestone
  design) was rejected as overkill. Two two-line emit blocks in the caller
  cost less complexity than a queue and are fully visible at the call site.
- **Unset after use.** Both globals are unset after emit so they cannot leak
  into the next iteration in `--complete` mode. The warn/fail paths in
  preflight intentionally leave `_PREFLIGHT_SUMMARY` unset, so the caller's
  `[[ -n "${_PREFLIGHT_SUMMARY:-}" ]]` guard correctly skips emission on
  those paths.

## Test Results

- Shell tests: **431 passed, 0 failed** (full suite, unchanged from baseline).
- Python tests: **188 passed**.
- Shellcheck (warning severity and above): no new findings on `lib/preflight.sh`,
  `stages/intake.sh`, or `tekhton.sh`. Pre-existing SC2034 warnings on
  unrelated tekhton.sh global variables remain.

## Acceptance Criteria Verification

- ✓ Preflight pill flips green BEFORE "preflight: ..." line appears — by
  construction: `tui_stage_end` runs first, then `success` is called.
- ✓ Intake pill flips green BEFORE "Intake: task is clear. Proceeding." —
  same construction.
- ✓ Preflight summary content identical: same `summary` string, same
  formatting, same `success()` rendering function.
- ✓ Intake PASS message identical: same literal string, same `success()`
  rendering function.
- ✓ Non-PASS intake paths behave identically: code paths for TWEAKED,
  SPLIT_RECOMMENDED, NEEDS_CLARITY are untouched.
- ✓ Failing preflight: failure path emits `error` lines from inside the
  function as before (untouched).
- ✓ `_PREFLIGHT_SUMMARY` and `_INTAKE_PASS_EMIT` are unset after use.
  Warn/fail paths leave them unset so guards skip emission.
- ✓ Shellcheck clean on `lib/preflight.sh`, `stages/intake.sh`, `tekhton.sh`.
- ✓ All existing preflight and intake tests continue to pass with no edits.

## Docs Updated

None — no public-surface changes. `_PREFLIGHT_SUMMARY` and `_INTAKE_PASS_EMIT`
are internal handoff globals between stage functions and their direct caller
(tekhton.sh's `_run_pipeline_stages` and the top-level preflight call site).
They are not config keys, CLI flags, public functions, or template variables.
The user-visible behavior — the success line text and styling — is unchanged.

## Observed Issues (out of scope)

- `stages/intake.sh` is now 358 lines (was 351 pre-M118; 300-line soft
  ceiling). My net contribution is +7 lines (one removed `success` call,
  eight added lines of which seven are explanatory comment). The file was
  already over the ceiling before M118 — splitting it would touch every
  call site of `run_stage_intake` and `run_intake_create` and is a separate
  cleanup milestone. Same situation applies to `tekhton.sh` (2998 lines,
  already over by an order of magnitude — entry-point file).
- `lib/intake_verdict_handlers.sh:171` (NEEDS_CLARITY `exit 1` in
  COMPLETE_MODE) is called out in the M118 design as a known unclosed-
  lifecycle issue and explicitly out of scope; M113's auto-close-and-warn
  rule covers the TUI side on exit.

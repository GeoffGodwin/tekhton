# M118 - Preflight / Intake Success-Line Timing Fix

<!-- milestone-meta
id: "118"
status: "pending"
-->

## Overview

Original Bug #1 from the timing-display investigation: during the preflight
and intake pre-stages, the green `success "..."` confirmation line appears in
Recent Events *before* the corresponding stage pill flips from yellow to
green. The pill eventually catches up, but for a perceptible window the TUI
shows "intake succeeded" in the log while the pill still says intake is
running — a contradiction the user must reconcile.

Root cause is ordering. Both preflight and intake emit their success log from
*inside* the stage function, before control returns to the caller in
`tekhton.sh` where `tui_stage_end` fires and the pill flips. The fix is
mechanical: ensure pill-flip happens before the success line emits.

M118 is independent of the M113–M117 substage work. It was carried along so
the full timing-display problem is solved in one initiative rather than left
as a straggler.

## Design

### Goal 1 — Reorder preflight success emission

`lib/preflight.sh:189` emits `success "$summary"` inside `run_preflight_checks`
before returning. The caller wraps the invocation:

```bash
# tekhton.sh:2876-2887 (paraphrased)
tui_stage_begin "preflight"
run_preflight_checks   # internally emits success before returning
tui_stage_end "preflight" "PASS"
```

Options evaluated:

1. **Move the `success` call from `run_preflight_checks` to the caller** —
   return the summary string and log it after `tui_stage_end`. Straightforward
   but changes the library's public contract.

2. **Capture the summary inside `run_preflight_checks` without emitting, let
   the caller emit** — deletes the in-function `success`, returns summary on
   stdout or via a global. Same contract change as option 1.

3. **Have the library defer its `success` call through a queue** — overkill.

**Selected: option 1, scoped narrowly.** `run_preflight_checks` returns the
summary via a global (`_PREFLIGHT_SUMMARY`) that the caller consumes; the
`success` emission moves to `tekhton.sh` after `tui_stage_end`. The library
function itself gains no argument, no new parameter — just drops one line
and sets one variable.

### Goal 2 — Reorder intake success emission

`stages/intake.sh:198` emits `success "Intake: task is clear. Proceeding."`
inside the PASS branch, before returning. The caller in `tekhton.sh:2272-2306`
wraps with `tui_stage_begin "intake"` / `tui_stage_end "intake"`.

Apply the same transformation: the PASS verdict returns successfully without
emitting the success line; the caller emits it after `tui_stage_end "intake"
"PASS"`. The hard-coded message string moves to the caller as well.

### Goal 3 — Preserve behavior on non-PASS paths

Intake has multiple verdict paths (PASS, REJECT, NEEDS_CLARITY). Only the PASS
path emits the above success line. The other paths emit their own diagnostics
at appropriate times; M118 does not touch those. Specifically,
`lib/intake_verdict_handlers.sh:171` (COMPLETE_MODE `exit 1` in
NEEDS_CLARITY) is called out as a known unclosed-lifecycle issue and is
**out of scope** here — if that path fires, the pipeline terminates
immediately and TUI coherence is moot. The M113 auto-close-and-warn rule
handles any partial state on exit.

### Goal 4 — Don't add new state

No new globals beyond the single `_PREFLIGHT_SUMMARY` transport variable. No
new config flags. No changes to how `success` formats output.

## Files Modified

| File | Change |
|------|--------|
| `lib/preflight.sh` | Stop emitting `success` inside `run_preflight_checks`; export summary via `_PREFLIGHT_SUMMARY` global |
| `tekhton.sh` | After `tui_stage_end "preflight" "PASS"`, emit `success "$_PREFLIGHT_SUMMARY"`; unset global |
| `stages/intake.sh` | Stop emitting the PASS success line inside `run_stage_intake` |
| `tekhton.sh` | After `tui_stage_end "intake" "PASS"`, emit `success "Intake: task is clear. Proceeding."` |

## Acceptance Criteria

- [ ] During a successful preflight, the preflight pill flips from yellow
      (running) to green (complete) BEFORE the green "preflight: ..." line
      appears in Recent Events. Verified by ordering of
      `stages_complete` update vs. events ring-buffer update in sequential
      `tui_status.json` snapshots.
- [ ] During a successful intake (PASS verdict), the intake pill flips green
      BEFORE "Intake: task is clear. Proceeding." appears in Recent Events.
- [ ] The preflight summary message content is identical to pre-M118 (same
      format, same information).
- [ ] The intake PASS success line content is identical to pre-M118.
- [ ] Non-PASS intake paths (REJECT, NEEDS_CLARITY) behave identically to
      pre-M118: same event emissions, same exit paths, same verdict routing.
- [ ] A failing preflight (`run_preflight_checks` returns non-zero) still
      emits its failure diagnostics at the current time; only the PASS path
      is reordered.
- [ ] `_PREFLIGHT_SUMMARY` is cleared after use; no stale summary leaks into
      later runs (for `--complete` mode).
- [ ] Shellcheck clean for `lib/preflight.sh`, `stages/intake.sh`,
      `tekhton.sh`.
- [ ] Existing preflight and intake tests continue to pass with no edits.

## Non-Goals

- Fixing the unclosed-lifecycle issue at
  `lib/intake_verdict_handlers.sh:171` (separate follow-up; M113's
  auto-close-and-warn covers the TUI side on exit).
- Reordering success emissions for other pipeline stages (coder, review,
  tester, security, docs, wrap-up). Those already behave correctly because
  their success lines come from agent output channels, not in-function
  `success` calls before the stage end.
- Changing the visual styling of pill-flip or success lines.
- Removing or renaming `_PREFLIGHT_SUMMARY`.

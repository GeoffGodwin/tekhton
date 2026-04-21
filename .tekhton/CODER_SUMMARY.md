## Status: COMPLETE

## Summary
M110 senior-coder rework cycle: addressed three Complex Blockers from
`.tekhton/REVIEWER_REPORT.md` covering multi-pass per-pass state reset,
hold-view runtime-vs-summary event separation, and pre-flight stage
lifecycle wiring.

## Files Modified (rework cycle)

### `tekhton.sh`

1. **Blocker 2 — multi-pass reset (§9).** `_run_fix_nonblockers_loop` and
   `_run_fix_drift_loop` now:
   - Call `out_reset_pass` at the top of each iteration (before remaining-work
     check) so `_OUT_CTX[action_items]` and the current-stage/current-model
     carry-over are cleared before the new pass accumulates state.
   - Emit a `tui_append_event "info" "Starting pass ${N}" "runtime"` boundary
     event for passes ≥2, placed after the sidecar re-arm so the event
     lands in the fresh sidecar's status file.
   - Emit a terminal `tui_append_event "info" "No remaining work — exiting"
     "runtime"` event when the loop breaks on zero remaining work, providing
     the explicit loop-exit marker required by §9.
   - All three wrapped in `declare -f` guards so non-TUI runs (no sidecar)
     remain no-ops.

2. **Blocker 4 — preflight lifecycle (§2, §3 pre-stage ordering).**
   `run_preflight_checks` at line 2886 is now wrapped in explicit
   `tui_stage_begin "preflight"` / `tui_stage_end "preflight"` calls matching
   the intake wiring pattern. The failure branch calls
   `tui_stage_end "preflight" "" "" "" "FAILED"` before `exit 1`, so the pill
   and timings row are correctly closed on pre-flight rejection rather than
   stranded at `pending`. This makes pre-flight a first-class pre-stage
   lifecycle owner, satisfying the acceptance criterion "Pre-flight and Intake
   are represented as distinct stages in lifecycle state".

### `tools/tui_hold.py`

3. **Blocker 3 — summary vs runtime event split (§8).** The event-log rendering
   loop in `_hold_on_complete` now partitions `recent_events` into two lists
   by the `type` field (default `runtime` for backward compatibility with
   pre-M110 status payloads):
   - `runtime_events` render in the existing `[bold]Event log:[/bold]` block
     with timestamps (unchanged behavior).
   - `summary_events` render in a new `[bold]Run summary:[/bold]` block
     positioned after Action Items. Timestamps are suppressed because
     summary events are run-facts (Task, Started, Verdict, Log, Version,
     breakdown), not chronological moments.
   - This satisfies the acceptance criterion "Completion recap fields
     (Task, Started, Verdict, Log, Version, breakdown) do not appear as
     late chronological runtime events in the hold event log."

## Architecture Change Proposals

None — all changes sit inside the existing M110 design (§2 pre-stage policy,
§8 event-type routing, §9 multi-pass state reset). No new protocol surface
introduced.

## Verification

- `bash -n tekhton.sh` — syntax OK.
- `shellcheck -S warning tekhton.sh` — no new warnings introduced (existing
  SC2034 notes unrelated to this rework).
- `python3 -m py_compile tools/tui_hold.py` — OK.
- `python3 -c "import tui_hold"` (with `tools/` on path) — imports cleanly.

## Remaining Work

None for the rework cycle. Simple Blockers were empty. Non-blocking notes
(dead `_policy_field`, `pipeline_order.sh` line count, duplicate inline
metrics-key map in `tekhton.sh:2530`) are explicitly out of scope per rework
instructions — left for a later cleanup pass.

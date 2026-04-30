# Coder Summary
## Status: COMPLETE
## What Was Implemented

Defensive observability fix for the TUI sidecar's silent-death failure mode in
`tekhton --human --complete`. The companion BUG (per-iteration reset calls
missing from `_run_human_complete_loop`) was already addressed in the prior
turn — those calls remain in place. This run completes the POLISH item:
sampled liveness probe so a dead sidecar is detected and reported instead
of silently no-op'ing while the user sees mixed CLI output.

Changes:

1. **`lib/tui_liveness.sh` (NEW, 72 lines).** Hosts `_tui_write_status` (moved
   verbatim from `lib/tui.sh`) and the new `_tui_check_sidecar_liveness`
   sampled probe. Co-locating them makes the writer's invariants and the
   probe that protects them visible in one file.
2. **`lib/tui.sh`.** Sources `lib/tui_liveness.sh` and removes the moved
   `_tui_write_status` body. Net file shrinks from 301 → 279 lines (back
   under the 300-line ceiling).
3. **`tekhton.sh:2630-2644`.** Per-iteration `out_reset_pass` +
   `tui_reset_for_next_milestone` calls in `_run_human_complete_loop`
   (companion BUG fix; was applied in the prior turn).

The probe runs `kill -0 "$_TUI_PID"` once every `_TUI_LIVENESS_INTERVAL=20`
status-file writes (fewer than 20 status writes between notes ≈ no probe
in the hot path). On detected death it flips `_TUI_ACTIVE=false`, clears
`_TUI_PID`, removes the pidfile, and emits a single
`warn "TUI sidecar exited (pid X; likely watchdog timeout); continuing
in CLI mode"`. Subsequent `tui_*` calls then correctly no-op via the
existing `[[ "$_TUI_ACTIVE" == "true" ]]` guards in
`lib/tui_ops.sh` / `lib/tui.sh`, so the user sees a clean transition
to CLI mode rather than a confusing mix.

## Root Cause (bugs only)

The fix in `_run_human_complete_loop` removes the watchdog firing
preconditions (idle status + nonzero turns + stale mtime) by zeroing
`_TUI_AGENT_TURNS_USED` and refreshing the status-file mtime via
`tui_reset_for_next_milestone` at the top of every iteration — matching
the pattern `_run_auto_advance_chain` already uses
(`lib/orchestrate_helpers.sh:64-65`) and that `_run_fix_nonblockers_loop`
uses (`tekhton.sh:2726-2727`).

The liveness probe is the defensive backstop: even if some other future
quiet-window pattern reintroduces the watchdog firing condition, or the
sidecar crashes for an unrelated reason, the parent shell now detects
the death and surfaces it as a `warn` line rather than silently writing
to a status file nobody is reading.

## Files Modified

- `tekhton.sh` — `_run_human_complete_loop` per-iteration resets (BUG fix)
- `lib/tui.sh` — sources `tui_liveness.sh`; `_tui_write_status` body removed
- `lib/tui_liveness.sh` (NEW) — atomic writer + sampled liveness probe

## Docs Updated

None — no public-surface changes. The new `lib/tui_liveness.sh` is purely
internal (sourced by `lib/tui.sh`); no new config keys, CLI flags, or
exported function signatures. Internal architecture mention belongs in
`ARCHITECTURE.md` but is intentionally deferred — this is a one-liner
update to the Layer-3 library list under the existing `lib/tui.sh`
entry, and the file already documents itself in its header comment.

## Human Notes Status

- COMPLETED: [POLISH] When the TUI sidecar self-terminates mid-run (most commonly via the watchdog in `tools/tui.py:170-198`, but also possible if the Python process crashes for any other reason), the parent bash process is not notified — `_TUI_ACTIVE=true` stays set, `_TUI_PID` becomes stale, and subsequent `tui_*` calls in `lib/tui.sh` / `lib/tui_ops.sh` succeed silently while writing to a status file that nobody reads. The user sees the shell's regular `log` / banner output reappear on the terminal (because `rich.live` released the alternate-screen) with no indication of what happened or why TUI mode "turned off". Add a lightweight liveness check so this failure mode is observable: in `_tui_write_status` (or via a small wrapper invoked from the public API in `lib/tui_ops.sh`), once every N writes (e.g. N=20) or every K seconds (tracked via a `_TUI_LAST_LIVENESS_CHECK` global) run `kill -0 "${_TUI_PID:-0}" 2>/dev/null`; if it fails, set `_TUI_ACTIVE=false`, unset `_TUI_PID`, remove the pidfile, and emit a single `warn` line such as `"TUI sidecar exited (likely watchdog timeout); continuing in CLI mode"`. Avoid checking on every write to keep overhead negligible — the status-file write path is hot. Once `_TUI_ACTIVE=false` is set, all downstream `tui_*` calls correctly no-op and any code that conditionally suppresses CLI output when TUI is on will start emitting normally, so the user sees a clean transition rather than a confusing mix. Verify by manually killing the sidecar process during a long run (`pkill -f tools/tui.py` while a stage is running) and confirming the warn line appears and the rest of the run displays normal CLI output. Note: this is a defensive observability fix; it does not by itself prevent the sidecar from dying — the companion `[BUG]` entry above addresses the underlying watchdog-firing trigger in `--human --complete`.

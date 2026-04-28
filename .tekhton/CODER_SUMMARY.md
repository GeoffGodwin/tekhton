# Coder Summary
## Status: COMPLETE

## What Was Implemented
Added a regression test (`tests/test_tui_stop_silent_fds.sh`) that asserts
`tui_stop()` emits zero bytes on fd 1 and fd 2 across every reachable path:
no pidfile / no `_TUI_PID`, stale dead pidfile, orphan with `_TUI_ACTIVE=false`
+ live pid, and the normal `_TUI_ACTIVE=true` teardown. The test stubs
`tput`/`stty` with markers (`TPUT_LEAK:` / `STTY_LEAK:`) so any future
re-introduction of the old safety-net path inside `tui_stop` will be
detectable on the captured stream — verified by temporarily reinstating
the buggy lines, which made all 5 cases fail.

The runtime fix that this test guards is already in place from prior commits:
- `lib/tui.sh:223-230` — `_tui_restore_terminal()` extracted; owns the three
  `tput rmcup`, `tput cnorm`, `stty icrnl` lines that previously lived inside
  `tui_stop`.
- `lib/tui.sh:203-221` — `tui_stop()` no longer touches the terminal.
- `tekhton.sh:147-156` — EXIT trap calls `tui_stop` and then
  `_tui_restore_terminal` separately, so terminal restoration only runs at
  the real interactive exit point (never from a child shell sourcing `lib/tui.sh`).
- `tests/test_tui_stop_orphan_recovery.sh:30-31` — `tput`/`stty` no-op stubs
  added before sourcing `lib/tui.sh` (defense-in-depth against future
  regressions).
- `tests/test_tui_orphan_lifecycle_integration.sh:28-29,112` — same stubs +
  `</dev/null` on the spawned `tools/tui.py` subprocess so it cannot grab the
  parent's `/dev/tty` and render a competing alt-screen.

## Root Cause (bugs only)
Commit 5876c91 ("TUI sidecar orphaned after build-gate-failure exit") added
three terminal-restore lines (`tput rmcup`, `tput cnorm`, `stty icrnl`)
inside `tui_stop` and two new tests that call `tui_stop` directly. When
those tests run inside `tests/run_tests.sh` while a parent tekhton pipeline
is rendering a `rich.live` alt-screen, the escape sequences write straight
to the shared `/dev/tty`, switching the parent terminal out of alt-screen
mode every time the test fires `tui_stop`. The user-visible symptom is the
"TUI keeps exiting" flicker during the coder-stage build-gate's
"Running completion tests" substage — the alt-screen drops, exposing
`print_run_summary` output and other stdout writes from the running
pipeline, then `rich.live` repaints on the next tick. The fix isolates the
terminal-restore lines to a separate `_tui_restore_terminal()` invoked only
from `tekhton.sh`'s EXIT trap (a context that only fires once, at real
process exit), and stubs `tput`/`stty` in the two tests as defense-in-depth.

## Files Modified
- `tests/test_tui_stop_silent_fds.sh` (NEW) — regression test asserting
  `tui_stop()` is byte-silent on fd 1 / fd 2 across all reachable paths
  and never invokes `tput`/`stty`.

(The runtime files — `lib/tui.sh`, `tekhton.sh`,
`tests/test_tui_stop_orphan_recovery.sh`,
`tests/test_tui_orphan_lifecycle_integration.sh` — were already modified on
this branch by prior commits per the Scout Report's "Implementation Status";
this run only adds the regression test that locks the fix in place.)

## Docs Updated
None — no public-surface changes in this task. The fix is internal to the
TUI sidecar lifecycle; no CLI flags, config keys, exported functions, or
prompt variables were added or renamed.

## Human Notes Status
No human notes injected.

## Summary
This change set fixes an alt-screen flicker bug by extracting `_tui_restore_terminal()` from `tui_stop()` and confining terminal-restore escape sequences to `tekhton.sh`'s EXIT trap. Four existing files were modified (`lib/tui.sh`, `tekhton.sh`, and two test files) and one new regression test was added (`tests/test_tui_stop_silent_fds.sh`). No authentication, cryptography, user input handling, or network communication is involved. The changes are narrowly scoped to TUI sidecar process lifecycle management.

## Findings

- [LOW] [category:A01] [tests/test_tui_orphan_lifecycle_integration.sh:202] fixable:yes — The second `tools/tui.py` spawn (watchdog bonus test, lines 196–202) is missing `</dev/null` on stdin. The first spawn at line 112 correctly uses `</dev/null >/dev/null 2>&1 &`, preventing the child from acquiring the parent's controlling terminal as stdin. The second spawn uses only `>/dev/null 2>&1 &`, leaving stdin connected. When this test runs inside a live pipeline sharing a TTY with an active TUI sidecar, the spawned `tui.py` could open the controlling terminal for input, partially undoing the fix for the very scenario this test validates. Fix: add `</dev/null` before `>/dev/null 2>&1 &` to match line 112.
- [LOW] [category:A01] [lib/tui.sh:206-216] fixable:yes — `tui_stop` reads the PID file's raw content into `target_pid` and passes it directly to `kill` without integer validation. A pidfile containing `-1` or `0` would cause `kill -0 -1` to return true (signal any sendable process) and `kill -1` to SIGHUP all processes owned by the current user (POSIX semantics). The same pattern is present in `_tui_kill_stale` (lines 137–148). Exploitation requires write access to `$PROJECT_DIR/.claude/tui_sidecar.pid`, so the threat is low-severity in practice. Fix: validate with `[[ "$target_pid" =~ ^[1-9][0-9]*$ ]]` before passing to `kill`.

## Verdict
FINDINGS_PRESENT

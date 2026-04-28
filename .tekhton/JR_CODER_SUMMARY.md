# JR Coder Summary

## What Was Fixed

- **tests/test_tui_orphan_lifecycle_integration.sh:202** — Added missing `</dev/null` redirection to the watchdog test spawn. The second `tools/tui.py` spawn (lines 196–202) now includes `</dev/null` before `>/dev/null 2>&1 &`, matching the pattern from the first spawn at line 112. This prevents the test-spawned tui.py process from acquiring the parent shell's controlling TTY, which was causing the TUI sidecar to leak terminal escape sequences.

## Files Modified

- `tests/test_tui_orphan_lifecycle_integration.sh` — Added `</dev/null` to line 202

## Verification

- ✓ Syntax check: `bash -n` passed
- ✓ Shellcheck: passed with no warnings

## Status: COMPLETE (rework pass)

## Summary
Addressed both Complex Blockers from REVIEWER_REPORT.md:

1. **PID routing bug** in `lib/agent_spinner.sh` / `lib/agent.sh`. The previous
   space-separated `echo "$spinner_pid $tui_updater_pid"` collapsed the leading
   empty field on the TUI path, causing `read -r _spinner_pid _tui_updater_pid`
   to assign the PID into `_spinner_pid` and leave `_tui_updater_pid` empty.
   `_stop_agent_spinner` then took the non-TUI branch and wrote `\r\033[K` to
   `/dev/tty`, corrupting the TUI alternate screen — the exact scenario M106
   was designed to prevent (AC-13/AC-15). Fix: switch the separator to `:` —
   `_start_agent_spinner` now uses `printf '%s:%s\n'` and `agent.sh` parses
   with `IFS=: read -r`. Empty leading field is preserved, PIDs route correctly.
   Updated the function header comment in `agent_spinner.sh` to document the
   contract and warn against whitespace separators.

2. **Broken Python assertions** in `tools/tests/test_tui.py`. The two M106
   `_build_active_bar` tests called `str(bar)` on a Rich `Table`, which returns
   the object repr instead of rendered content — both assertions would always
   fail. Added a `_render()` helper that mirrors the pattern used by
   `test_build_layout_full`: render the renderable into a `StringIO`-backed
   `Console(force_terminal=False, width=120)` and assert against the resulting
   string. Both tests now read from real rendered output.

## Files Modified (rework)
- `lib/agent_spinner.sh` — separator changed to `:`, header comment updated
- `lib/agent.sh` — `IFS=: read -r ...` for PID parsing
- `tools/tests/test_tui.py` — added `_render()` helper; both M106 tests use it

## Architecture Change Proposals
None this pass.

## Remaining Work
None for the Complex Blockers. Non-blocking notes (CLAUDE.md layout entries
for new files; latent label-mismatch risk in `pipeline_order.sh`) and the
M106 bash-side coverage gaps remain for follow-up — they were called out as
Non-Blocking and Coverage Gaps, not blockers.

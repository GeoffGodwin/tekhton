# Coder Summary
## Status: COMPLETE

## What Was Implemented
- Fixed the BUG where `tekhton --report` printed literal `\033[...]` strings on
  the Outcome / Coder / Security / Reviewer / Tester lines instead of colorized
  text. Took the proposed Option 1 fix (lowest-blast-radius): `_out_color` in
  `lib/output_format.sh` now uses `printf '%b'` instead of `printf '%s'`, so it
  always emits real ESC bytes regardless of how the caller prints them. Other
  helpers (`out_banner`, `out_section`, `out_kv`, `out_progress`,
  `out_action_item`) keep working because `%b`-formatted real ESC bytes pass
  through `echo -e` and `printf '%b'` unchanged.
- Added the POLISH human note: the TUI top status bar now shows the project
  directory next to the Pass count. `_tui_json_build_status` in
  `lib/tui_helpers.sh` emits a new `project_dir` field
  (`basename "$PROJECT_DIR"`); `tools/tui_render.py` `_build_context` appends
  `· /<project_dir>` after `Pass N/M`.
- Updated `tests/test_output_format.sh` test 2 to assert that `_out_color`
  output contains an actual ESC byte (0x1b) and is free of the literal
  `\033` substring.
- Updated `tests/test_report.sh` Test Suite 9 to compare `_report_colorize`
  against the interpreted-form colors (`printf '%b'`).
- Added Test Suite 10 in `tests/test_report.sh` — regression for the bug:
  fixtures all stages, runs `print_run_report`, `grep -F`s the output for
  literal `\033[` and `\e[`, both must be zero matches.

## Root Cause (bugs only)
Color constants in `lib/common.sh` are stored as single-quoted literal strings
(e.g. `RED='\033[0;31m'`), which means the variable holds a 7-character backslash
sequence — not actual ESC bytes. `_out_color` previously called
`printf '%s'`, which copies the literal characters verbatim. Reports rendered
through `out_msg "  Outcome:   ${color}${val}${nc}"` were then printed via
`out_msg`'s `printf '%s\n'`, which also doesn't interpret escape sequences, so
the literal `\033[...]` characters reached the terminal unchanged. The other
formatters (`out_banner`, `out_kv`, `out_progress`, `out_action_item`) avoided
the bug because they used `echo -e` or `printf '%b...'` which interpret the
sequences. Fixing at `_out_color` interprets the escapes once at the boundary
where color is resolved, so every consumer — `%s`, `%b`, or `echo -e` — sees
real ESC bytes and renders correctly.

## Files Modified
- `lib/output_format.sh` — `_out_color` switched from `printf '%s'` to
  `printf '%b'`; comment updated to explain why.
- `lib/tui_helpers.sh` — `_tui_json_build_status` computes
  `basename "$PROJECT_DIR"` and emits a new `project_dir` field in the status
  JSON.
- `tools/tui_render.py` — `_build_context` reads the new `project_dir` field
  and renders `· /<project_dir>` after `Pass N/M`.
- `tests/test_output_format.sh` — updated test 2 (`_out_color` passthrough)
  to assert interpreted ESC bytes plus absence of literal `\033`.
- `tests/test_report.sh` — Test Suite 9 now compares against `printf '%b'`
  expansions of the color vars. New Test Suite 10 grep-asserts the rendered
  report output is free of literal `\033[` / `\e[` substrings (regression
  guard for the original bug).

## Docs Updated
None — no public-surface changes in this task. The TUI status JSON gains a
`project_dir` field, but the schema is internal to the sidecar and not
documented as a stable contract; renderer change is purely visual.

## Human Notes Status
- COMPLETED: [POLISH] The top status bar of Tekhton currently lists the mode (milestone, nb, drift), the pass number (1/5) and the Task. What it doesn't show is the current directory it's working in (project). Let's add the immediate directory name it's being run from next to the Pass count so that we go from the form "fix-nb  ·  Pass 1/5" to the form "fix-nb  ·  Pass 1/5  ·  /name-of-folder"

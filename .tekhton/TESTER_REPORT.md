## Planned Tests
- [x] `tools/tests/test_tui.py` — Add Python test for project_dir field in _build_context
- [x] `tests/test_output_format.sh` — Verify ANSI escape sequence fix (70 tests)
- [x] `tests/test_report.sh` — Verify Test Suite 9 and 10 (regression for ANSI bug)

## Test Run Results
- Python (tui): Passed: 78  Failed: 0
- Python (full suite): Passed: 250  Failed: 0
- Shell (full suite): Passed: 475  Failed: 0

## Coverage Verification
- ✓ New `project_dir` field in JSON (Bash: `_tui_json_build_status`)
- ✓ Rendering of `project_dir` in TUI context when set
- ✓ Omission of `project_dir` when empty or absent
- ✓ ANSI escape sequences rendered as real ESC bytes (no literal `\033` in output)
- ✓ Color code interpretation via `printf '%b'` in `_out_color`

## Bugs Found
None

## Files Modified
- [x] `tools/tests/test_tui.py`

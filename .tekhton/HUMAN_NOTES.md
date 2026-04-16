# Human Notes
<!-- notes-format: v2 -->
<!-- IDs are auto-managed by Tekhton. Do not remove note: comments. -->

Add your observations below as unchecked items. The pipeline will inject
unchecked items into the next coder run and archive them when done.

Use `- [ ]` for new notes. Use `- [x]` to mark items you want to defer/skip.

Prefix each note with a priority tag so the pipeline can scope runs correctly:
- `[BUG]` — something is broken, needs fixing before new features
- `[FEAT]` — new mechanic or system, architectural work
- `[POLISH]` — visual/UX improvement, no logic changes

## Features

## Bugs

- [x] [BUG] `tests/run_tests.sh` `run_test()` runs each failing test **twice** — exit code from Run 1 (silent) determines PASS/FAIL, but the debug output shown is from an independent Run 2 (re-run). If `set -euo pipefail` aborts Run 1 early (e.g. SIGPIPE from `head -20` inside a `$()` capture, or a bare `grep` with no match), Run 2 starts clean and can produce all-PASS output, yielding a false "FAIL ... Passed: N  Failed: 0" in the log. Fix: capture output and exit code in one run — `output=$(bash "$test_file" < /dev/null 2>&1); rc=$?` — then branch on `$rc` and print `$output` only when non-zero. Remove the second `bash "$test_file"` invocation entirely. File: `tests/run_tests.sh`, function `run_test()`.

## Polish

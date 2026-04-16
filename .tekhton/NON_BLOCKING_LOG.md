# Non-Blocking Notes Log

Accumulated reviewer notes that were not blocking but should be addressed.
Items are auto-collected from `## Non-Blocking Notes` in REVIEWER_REPORT.md.
The coder is prompted to address these when the count exceeds the threshold.

## Open
- [x] [2026-04-16 | "[BUG] `tests/run_tests.sh` `run_test()` runs each failing test **twice** — exit code from Run 1 (silent) determines PASS/FAIL, but the debug output shown is from an independent Run 2 (re-run). If `set -euo pipefail` aborts Run 1 early (e.g. SIGPIPE from `head -20` inside a `$()` capture, or a bare `grep` with no match), Run 2 starts clean and can produce all-PASS output, yielding a false "FAIL ... Passed: N  Failed: 0" in the log. Fix: capture output and exit code in one run — `output=$(bash "$test_file" < /dev/null 2>&1); rc=$?` — then branch on `$rc` and print `$output` only when non-zero. Remove the second `bash "$test_file"` invocation entirely. File: `tests/run_tests.sh`, function `run_test()`."] `tests/test_run_tests_single_invocation.sh:47` — The `awk` range pattern `'/^run_test() {/,/^}/'` terminates at the first line starting with `}` in the file after the opening. Currently correct because all interior `}` (closing `if` blocks) are indented, but if a future edit adds a `}` at column 0 inside the function body the extraction would silently truncate. Consider anchoring more tightly (e.g. matching the specific closing `^}$` or extracting via a function-aware tool) if the function grows more complex.
- [ ] [2026-04-16 | "M89"] The three new config keys (`TEST_AUDIT_ROLLING_ENABLED`, `TEST_AUDIT_ROLLING_SAMPLE_K`, `TEST_AUDIT_HISTORY_MAX_RECORDS`) are not documented in the Template Variables table in `CLAUDE.md`. Other `TEST_AUDIT_*` keys are also absent from that table, so this continues an existing gap rather than introducing a new regression. Worth a future pass to add all `TEST_AUDIT_*` keys.

## Resolved

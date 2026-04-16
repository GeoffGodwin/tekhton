# Reviewer Report

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- `tests/test_run_tests_single_invocation.sh:47` — The `awk` range pattern `'/^run_test\(\) \{/,/^}/'` terminates at the first line starting with `}` in the file after the opening. Currently correct because all interior `}` (closing `if` blocks) are indented, but if a future edit adds a `}` at column 0 inside the function body the extraction would silently truncate. Consider anchoring more tightly (e.g. matching the specific closing `^}$` or extracting via a function-aware tool) if the function grows more complex.

## Coverage Gaps
- None

## Drift Observations
- None

---

### Review Notes

The fix is correct and minimal. The two-invocation pattern is gone; `output=$(bash "$test_file" < /dev/null 2>&1) || rc=$?` captures both the output and exit code in a single run and the `|| rc=$?` prevents the runner's own `set -e` from aborting on a failing test. `< /dev/null` avoids stdin inheritance. `printf '%s\n' "$output"` is safer than `echo` for arbitrary captured content.

The regression test is well-constructed: the stateful fixture (counter file, exits 1 on run 1 / 0 on run 2) directly exercises the double-invocation failure mode, the counter check asserts exactly one invocation, and the passing-fixture sanity check verifies the happy path is unaffected. The coder verified the test fails on the pre-fix code — a strong signal it exercises the right behaviour.

Both files: `set -euo pipefail` present, under 300 lines, variables quoted, no hardcoded values.

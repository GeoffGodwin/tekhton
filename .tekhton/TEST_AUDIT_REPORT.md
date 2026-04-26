## Test Audit Report

### Audit Summary
Tests audited: 2 files, ~70 test assertions across 16 suites (T1–T8 schema tests + Suites 1–16 finalize tests)
Verdict: PASS

### Findings

#### NAMING: Stale hook-count in test_finalize_run.sh header comment
- File: tests/test_finalize_run.sh:8
- Issue: The file header says "Hook registration order (20 hooks in deterministic sequence)" but Suite 1 now asserts 26 hooks (correct). The comment was not updated when M129 added `_hook_failure_context_reset`. Does not affect test correctness — all 26 name/index assertions match finalize.sh exactly.
- Severity: LOW
- Action: Update the comment to read "(26 hooks in deterministic sequence)".

#### COVERAGE: No behavioral test for `_hook_failure_context_reset`
- File: tests/test_finalize_run.sh (Suite 1 only covers position)
- Issue: M129 introduced `_hook_failure_context_reset` (finalize_aux.sh:48–54). This hook has a non-trivial exit-code guard — it is a no-op when exit_code != 0 and calls `reset_failure_cause_context` only on success. Suite 1 asserts the hook is at index 25 in the registry, but no suite directly invokes the hook and checks its guards. Compare: all other success-only hooks added in prior milestones received dedicated guard suites (7, 9, 10, 11, 12, 16). The underlying `reset_failure_cause_context` is well-tested by T7 in test_failure_context_schema.sh, so the gap is only in the hook wrapper behavior.
- Severity: MEDIUM
- Action: Add a Suite 16b that exercises `_hook_failure_context_reset` directly. Set all eight PRIMARY_*/SECONDARY_* vars via `set_primary_cause`/`set_secondary_cause` (functions available after sourcing failure_context.sh, which is already loaded transitively through finalize_aux.sh via finalize.sh), then: (a) call `_hook_failure_context_reset 1` and assert the vars remain populated, (b) call `_hook_failure_context_reset 0` and assert all eight vars are empty.

#### COVERAGE: No test for consecutive_count increment on classification repeat
- File: tests/test_failure_context_schema.sh (T1 only tests first write)
- Issue: `write_last_failure_context` in diagnose_output.sh:226–234 reads the prior `LAST_FAILURE_CONTEXT.json` and increments `consecutive_count` when the classification matches, resets to 1 otherwise. T1 only covers the initial write (no prior file → count=1). The increment path and the reset-on-different-classification path are unexercised.
- Severity: LOW
- Action: Extend T1 or add a T1b: after the existing T1 write, call `write_last_failure_context` again with the same classification and assert `consecutive_count` is 2; then call with a different classification and assert it resets to 1.

#### SCOPE: STALE-SYM entries are bash builtins — no action needed
- File: tests/test_finalize_run.sh (all STALE-SYM entries)
- Issue: The shell-based orphan detector flagged `cat`, `cd`, `dirname`, `echo`, `exit`, `grep`, `mkdir`, `mktemp`, `pwd`, `return`, `rm`, `set`, `source`, `touch`, `trap` as missing from source definitions. All are POSIX external utilities or bash builtins. The detector cannot distinguish these from user-defined functions.
- Severity: LOW (false positive — no action required)
- Action: None.

### Rubric Notes

**Assertion Honesty — CLEAR.** All assertions in test_failure_context_schema.sh derive from real function calls (set_primary_cause → write_last_failure_context → file output; _read_diagnostic_context → _DIAG_* vars; _rule_max_turns → DIAG_SUGGESTIONS array). No hard-coded sentinel values that bypass implementation logic were found. The `_write_v2_fixture` hand-writes a JSON file that is byte-compatible with what `write_last_failure_context` produces, deliberately so — the fixture is a stable contract anchor for downstream m130/m132/m133 parser tests. T3's pretty-print canary tests `grep -n '"primary_cause": {$'` against the actual emitted file, not a stub. All 26 hook-position assertions in test_finalize_run.sh Suite 1 were verified against the `register_finalize_hook` call sequence in finalize.sh:218–243; all match.

**Test Weakening — CLEAR.** The only modification to test_finalize_run.sh was adding one count assertion (25→26), adding one name assertion for `_hook_failure_context_reset` at index 25, and shifting four pre-existing index assertions by one. No assertions were removed, no expected values were broadened, no edge-case tests were deleted.

**Implementation Exercise — CLEAR.** Both test files source real implementation code. test_failure_context_schema.sh sources `lib/failure_context.sh` and `lib/diagnose.sh` (which transitively sources diagnose_rules.sh, diagnose_helpers.sh, diagnose_output.sh, diagnose_output_extra.sh). The real `_diag_parse_cause_block`, `_rule_max_turns`, `write_last_failure_context`, and `format_failure_cause_summary` all execute through live implementation paths. test_finalize_run.sh sources `lib/finalize.sh` (which sources all extension hook files) and exercises real hook guards — mocks are limited to side-effectful external calls (git, agent invocations, dashboard writes).

**Scope Alignment — CLEAR.** All function and variable references in both test files resolve to current symbols in the M129 implementation. `_hook_failure_context_reset` is defined in finalize_aux.sh:48–54 and registered in finalize.sh:243. The eight `PRIMARY_ERROR_*`/`SECONDARY_ERROR_*` variables tested in T7 are exactly the eight vars declared and exported by failure_context.sh:26–37. `_DIAG_PRIMARY_*`/`_DIAG_SECONDARY_*`/`_DIAG_SCHEMA_VERSION` tested in T4–T5 are declared in diagnose.sh:64–72.

**Test Isolation — CLEAR.** Both test files create a `mktemp -d` temp directory and route all file I/O through `PROJECT_DIR="$TMPDIR"`. test_failure_context_schema.sh writes `LAST_FAILURE_CONTEXT.json` to `$TMPDIR/.claude/` and mocks `is_dashboard_enabled`, `_write_js_file`, and `_to_js_timestamp` to prevent any project-dir writes. test_finalize_run.sh runs `cd "$TMPDIR"` so relative paths (HUMAN_NOTES_FILE, TEKHTON_DIR) resolve inside the temp dir. All files written in Suites 8/8b are written to and read from `$TMPDIR`-relative paths. Both files register `trap 'rm -rf "$TMPDIR"' EXIT`.

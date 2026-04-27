## Test Audit Report

### Audit Summary
Tests audited: 2 files, 26 test functions (test_diagnose_rules_resilience.sh)
+ 20 test suites (test_diagnose.sh, Suites 1–20)
Verdict: PASS

### Findings

#### COVERAGE: _rule_ui_gate_interactive_reporter source-4 path (RUN_SUMMARY correlation) has no test
- File: tests/test_diagnose_rules_resilience.sh (no covering scenario)
- Issue: `_rule_ui_gate_interactive_reporter` has four detection sources; T1 covers
  source 1 (v2 primary signal), T2 covers source 3 (raw log), but source 4
  (RUN_SUMMARY.json `causal_context.primary_signal + recovery_routing.route_taken =
  retry_ui_gate_env`) has no test. The implementation path (lines 66–74 of
  diagnose_rules_resilience.sh) is reachable when neither source 1/2/3 fires but
  a recovered run left a RUN_SUMMARY. A regression in the JSON field names or
  awk extraction would pass silently.
- Severity: LOW
- Action: Add a T2b scenario that creates only a RUN_SUMMARY.json with
  `"primary_signal": "ui_timeout_interactive_report"` and
  `"route_taken": "retry_ui_gate_env"` (no failure_ctx, no raw_errors), calls
  `classify_failure_diag`, and asserts `UI_GATE_INTERACTIVE_REPORTER` with
  `medium` confidence.

#### COVERAGE: _rule_preflight_interactive_config only tests source 1 of three detection sources
- File: tests/test_diagnose_rules_resilience.sh:289 (T7)
- Issue: T7 covers source 1 (RUN_SUMMARY.json `preflight_ui` section). Sources 2
  and 3 are untested: source 2 is the PREFLIGHT_REPORT.md heading sentinel
  (`UI Config (Playwright) — html reporter` + fail entry); source 3 is
  LAST_FAILURE_CONTEXT.json with `classification = PREFLIGHT_INTERACTIVE_CONFIG`
  or `primary_cause.signal = ui_interactive_config_preflight`. If the m131-frozen
  PREFLIGHT_REPORT.md heading string drifts or source 3's JSON field names change,
  no test would catch it.
- Severity: LOW
- Action: Add a T7b scenario writing only PREFLIGHT_REPORT.md with the frozen
  heading and a "FAIL" line (no RUN_SUMMARY), and assert
  `PREFLIGHT_INTERACTIVE_CONFIG`. Add a T7c scenario writing only
  LAST_FAILURE_CONTEXT.json with
  `"classification": "PREFLIGHT_INTERACTIVE_CONFIG"`, and assert the same outcome.

#### ISOLATION: _reset_fixture in resilience test leaves several _DIAG_* variables uncleared
- File: tests/test_diagnose_rules_resilience.sh:93
- Issue: `_reset_fixture` explicitly clears `_DIAG_PRIMARY_*`, `_DIAG_SECONDARY_*`,
  and `_DIAG_SCHEMA_VERSION`, but does not clear `_DIAG_CAUSAL_EVENTS`,
  `_DIAG_CAUSE_CHAIN`, `_DIAG_CAUSE_CHAIN_SHORT`, `_DIAG_TERMINAL_EVENT`,
  `_DIAG_REVIEW_CYCLES`, or `_DIAG_RECURRING_COUNT`. If `_read_diagnostic_context`
  only writes these variables when their source files exist (rather than
  unconditionally resetting them), stale values from a prior test scenario could
  affect a later one. Currently no test in this file populates those variables
  (no causal log is created anywhere in the file), so no test failure results in
  practice. The risk is latent: adding a new scenario that creates a causal log
  without adding the corresponding resets could cause hidden ordering dependence.
- Severity: LOW
- Action: Add the missing resets to `_reset_fixture`:
  `_DIAG_CAUSAL_EVENTS=""; _DIAG_CAUSE_CHAIN=""; _DIAG_CAUSE_CHAIN_SHORT="";`
  `_DIAG_TERMINAL_EVENT=""; _DIAG_REVIEW_CYCLES=0; _DIAG_RECURRING_COUNT=0`

### Notes
- **Assertion honesty (all scenarios):** Every assert_eq and assert_contains value
  is derived from strings that appear verbatim in the implementation (verified
  against lib/diagnose_rules_resilience.sh, lib/diagnose_rules_extra.sh, and
  lib/diagnose_rules.sh). No hard-coded magic values or tautologies detected.
- **test_diagnose.sh Suites 2–20:** None were weakened. The only edits were to
  Suite 1 (rule-count 14→18 and position assertions for indices 0–4, 17). All
  updated index assertions match the literal DIAGNOSE_RULES array in
  diagnose_rules.sh. Suite 13's `BUILD_FAILURE > STUCK_LOOP` priority assertion
  remains correct under the new registry (positions 3 vs 9).
- **T9 direct-call design:** T9 calls `_rule_max_turns` directly instead of
  `classify_failure_diag` to test the env-root upgrade path in isolation, explicitly
  noting that `_rule_ui_gate_interactive_reporter` would win in the full run. This is
  intentional and honest — the comment at line 339 documents the rationale.
- **STALE-SYM warnings:** All 17 flagged symbols (`cat`, `cd`, `dirname`, `echo`,
  `grep`, `mkdir`, `mktemp`, `printf`, `pwd`, `return`, `rm`, `sed`, `set`,
  `source`, `touch`, `trap`, `true`) are POSIX shell builtins and utilities, not
  source-file-defined functions. They are false positives from the symbol-level
  orphan detector and require no action.
- **T5 stale-report guard:** This is the only negative-path test for
  `_rule_build_fix_exhausted`. It directly exercises the `has_artifacts` guard that
  prevents stale BUILD_FIX_REPORT from producing false positives on clean runs.
  The assertion `r=1` (does not match) is verified against the implementation's
  early-return at `[[ "$has_artifacts" = true ]] || return 1`.

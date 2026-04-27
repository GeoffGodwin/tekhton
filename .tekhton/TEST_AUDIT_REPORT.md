## Test Audit Report

### Audit Summary
Tests audited: 5 files, 39 test functions
(Primary: test_orchestrate_recovery.sh, test_ui_gate_force_noninteractive.sh;
Freshness sample: test_intake_report_edge_cases.sh, test_intake_report_json_escape.sh, test_intake_report_rendering.sh)
Verdict: PASS

### Findings

#### COVERAGE: T2b.2 assertion is tautologically true
- File: tests/test_orchestrate_recovery.sh:167
- Issue: `assert_eq "T2b.2 _ORCH_ENV_GATE_RETRIED untouched" "0" "${_ORCH_ENV_GATE_RETRIED}"` cannot detect a bug. `_reset_test_state` sets the guard to 0, then `_classify_failure` runs in a subshell via `out=$(_classify_failure)`. Subshells structurally cannot mutate parent shell variables, so `_ORCH_ENV_GATE_RETRIED` will always read 0 regardless of what `_classify_failure` does internally. The assertion documents an architectural invariant (guards are written by the dispatcher in the parent shell, never by `_classify_failure` itself) rather than testing behavior that could actually fail. T2b.1 — the routing decision — is the meaningful assertion and is solid.
- Severity: LOW
- Action: Either remove the assertion and add a prose comment explaining the invariant, or replace it with a test that verifies the dispatcher in `orchestrate_loop.sh` does NOT write `_ORCH_ENV_GATE_RETRIED` in the opt-out branch. No implementation changes needed.

### No other findings.

---

### Per-file Detail

#### tests/test_orchestrate_recovery.sh (25 assertions, T1–T11 + T2b/T8b/T8c)

**Assertion Honesty — CLEAR.** All routing assertions call the real `_classify_failure` with meaningful fixture state and verify the returned action string against documented implementation branches. `_load_failure_cause_context` calls (T1.2/T1.3, T9.2–T9.4, T10.2–T10.4) use direct (non-subshell) invocation so Lifetime A state mutations are visible in the parent shell. No hard-coded values bypass implementation logic.

**Edge Case Coverage — STRONG.** v1 schema compatibility (T9), missing context file (T10), explicit opt-out via `_CONF_KEYS_SET` (T2b), kill-switch `BUILD_FIX_CLASSIFICATION_REQUIRED=false` (T8c), `unknown_only` classification (T8b), `mixed_uncertain` first-vs-second attempt (T7/T8), negative cause_summary suppression (T11.3). Ratio of error-path to happy-path tests is approximately 1:1.

**Implementation Exercise — CLEAR.** Tests source the real `orchestrate_recovery.sh`, which transitively sources `orchestrate_recovery_causal.sh` and `orchestrate_recovery_print.sh`. Only `warn`/`log`/`error` are stubbed — appropriate since logging is not under test. All routing decisions and loader behaviors execute through live code paths.

**Test Weakening — N/A.** New file; no prior version exists.

**Test Naming — CLEAR.** All names encode scenario and expected outcome (e.g., `T2b.1 explicit opt-out routes save_exit`, `T8c.1 kill switch forces retry_coder_build`). No opaque identifiers.

**Scope Alignment — CLEAR.** All referenced functions (`_classify_failure`, `_load_failure_cause_context`, `_reset_orch_recovery_state`, `_causal_env_retry_allowed`, `_print_recovery_block`) exist in the current M130 implementation at the locations the coder summary specifies. The subshell-isolation comment in the test header (lines 126–129) accurately describes the architecture. No orphaned or stale references.

**Test Isolation — CLEAR.** All fixture JSON files are written to `$TMPDIR` via `_write_v2_env_primary`, `_write_v1_legacy`, and `_make_build_errors_present`. `ORCH_CONTEXT_FILE_OVERRIDE` redirects the loader to fixtures rather than `$PROJECT_DIR`. `_reset_test_state` fully resets all module-level vars before each case. No mutable project state is read.

---

#### tests/test_ui_gate_force_noninteractive.sh (8 assertions, P0-T1–P0-T6)

**Assertion Honesty — CLEAR.** All assertions call the real `_ui_detect_framework` and `_ui_deterministic_env_list`. P0-T6 correctly passes `hardened=1` to exercise the conditional `CI=1` emission path, then asserts both `PLAYWRIGHT_HTML_OPEN=never` (unconditional for playwright) and `CI=1` (hardened-only). The two asserted values appear in the implementation at `gates_ui_helpers.sh:64` and `gates_ui_helpers.sh:66` exactly.

**Edge Case Coverage — GOOD.** Three Priority 0 activation cases (plain, with `UI_FRAMEWORK` override, with empty `PROJECT_DIR` preventing file detection), two negative cases (unset variable, value=0), one env-list integration case.

**Implementation Exercise — CLEAR.** Sources real `gates_ui_helpers.sh`. No mocking. `_clear_detection_vars` resets env state only, leaving the implementation untouched.

**Test Weakening — N/A.** New file.

**Test Naming — CLEAR.** All names encode priority level, trigger condition, and expected outcome.

**Scope Alignment — CLEAR.** `_ui_detect_framework` Priority 0 hook is at `lib/gates_ui_helpers.sh:25–28` exactly as tested. `_ui_deterministic_env_list` is at `lib/gates_ui_helpers.sh:57–73`. No stale references.

**Test Isolation — CLEAR.** `PROJECT_DIR="$TMPDIR"` (empty temp dir) prevents file-based playwright detection from triggering. `_clear_detection_vars` resets all detection inputs between test cases. No mutable project state is read.

---

#### Freshness Samples (test_intake_report_edge_cases.sh, test_intake_report_json_escape.sh, test_intake_report_rendering.sh)

**Scope Alignment check — CLEAR.** All three files source `lib/dashboard_parsers.sh` and test `_parse_intake_report`. M130 changed `lib/orchestrate_recovery*.sh` and `lib/gates_ui_helpers.sh` — no overlap with these test files. No orphaned, stale, or misaligned references to M130-changed code detected. Freshness samples remain valid.

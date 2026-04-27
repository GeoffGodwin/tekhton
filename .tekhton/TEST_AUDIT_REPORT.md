## Test Audit Report

### Audit Summary
Tests audited: 3 files, 50 test assertions
- `tests/test_orchestrate_recovery.sh` — 25 assertions (T1–T11, T2b, T8b, T8c); pre-existing, executed as regression check
- `tests/test_ui_gate_force_noninteractive.sh` — 8 assertions (P0-T1 through P0-T6)
- `tests/test_m131_coverage_gaps.sh` — 17 assertions (GAP-1.1–1.6, GAP-2.1–2.3)

Verdict: PASS

---

### Findings

#### SCOPE: test_orchestrate_recovery.sh misclassified as "modified this run"
- File: `tests/test_orchestrate_recovery.sh`
- Issue: The audit context lists this file as "modified this run." However, it does not appear in the git status diff captured before this audit, and the TESTER_REPORT itself correctly marks it "(existing)." The tester executed it as a regression verification run, not as a new authorship. The 25 assertions from this pre-existing file make up half of the reported "50 passed" count. The tests themselves are valid and passing; the misclassification is in the audit metadata.
- Severity: LOW
- Action: No changes to the test file needed. The audit pipeline metadata template should distinguish "Regression Checks (executed)" from "New/Modified Tests (authored)" to prevent misattribution.

#### COVERAGE: Primary M131 test file (test_preflight_ui_config.sh) absent from audit scope
- File: `tests/test_preflight_ui_config.sh` (not listed in audit context)
- Issue: The CODER_SUMMARY reports 46 assertions across T1–T10 in `tests/test_preflight_ui_config.sh` as the primary test artifact for M131. This file appears as new (`??`) in git status. It was not included in the tester's audit context and therefore received no independent integrity review — neither by the tester agent nor by this audit. The audit covered gap-fill tests but not the main test file, leaving the largest test artifact unverified by an independent party.
- Severity: MEDIUM
- Action: `tests/test_preflight_ui_config.sh` should be added to the audit context for a follow-up review pass. Audit integrity requires that the primary implementation test file be reviewed by a party independent of the coder who wrote it.

#### COVERAGE: P0-T6 tests pre-M131 hardened path, not M131 escalation
- File: `tests/test_ui_gate_force_noninteractive.sh:92`
- Issue: P0-T6 calls `_ui_deterministic_env_list 1` (explicit `hardened=1` argument) and asserts `CI=1`. This exercises a code path that predates M131 (`gates_ui_helpers.sh:71–73`). The M131-specific escalation — `PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED=1` causing `CI=1` without passing `hardened=1` (lines 65–67) — is not tested in this file. The TESTER_REPORT describes P0-T6 as covering the M131 interaction, which is inaccurate.
- Severity: LOW
- Action: No change required; GAP-1.1 and GAP-1.2 in `test_m131_coverage_gaps.sh` directly exercise the new escalation path. The gap is covered elsewhere. Update the P0-T6 inline comment to clarify it is a regression guard for the pre-M131 hardened path.

#### NAMING: GAP-2.2 uses indirect boolean assertion instead of exact count
- File: `tests/test_m131_coverage_gaps.sh:211`
- Issue: `assert_eq "GAP-2.2 _PF_WARN>=1 ..." "1" "$([[ $_PF_WARN -ge 1 ]] && echo 1 || echo 0)"` collapses the real counter into a boolean via a subshell conditional. The description honestly declares `>=1` semantics, but the assertion would silently pass if `_PF_WARN` were 2 or higher due to an unexpected secondary warning. In this test scenario, only CY-2 can fire (CY-1 requires `video: true`, which is absent from the fixture), so `_PF_WARN` should be exactly 1.
- Severity: LOW
- Action: Replace with `assert_eq "GAP-2.2 _PF_WARN=1" "1" "$_PF_WARN"` for precise, direct failure reporting.

---

### Per-file Detail

#### tests/test_orchestrate_recovery.sh (25 assertions, T1–T11 + T2b/T8b/T8c)

**Assertion Honesty — CLEAR.** All routing assertions call the real `_classify_failure` with meaningful fixture state and verify the returned action string against documented implementation branches in `orchestrate_recovery.sh:121–240`. `_load_failure_cause_context` calls (T1.2/T1.3, T9.2–T9.4, T10.2–T10.4) use direct (non-subshell) invocation so state mutations are visible in the parent shell. No hard-coded values that bypass implementation logic.

**Edge Case Coverage — STRONG.** v1 schema compatibility (T9), missing context file (T10), explicit pipeline.conf opt-out via `_CONF_KEYS_SET` (T2b), kill-switch `BUILD_FIX_CLASSIFICATION_REQUIRED=false` (T8c), `unknown_only` classification (T8b), `mixed_uncertain` first-vs-second attempt (T7/T8), negative cause_summary suppression (T11.3). Error-path to happy-path ratio is approximately 1:1.

**Implementation Exercise — CLEAR.** Tests source the real `orchestrate_recovery.sh`, which transitively sources `orchestrate_recovery_causal.sh` and `orchestrate_recovery_print.sh`. Only `warn`/`log`/`error` are stubbed — appropriate since logging is not under test.

**Test Weakening — N/A.** Pre-existing file with no modifications this run.

**Test Naming — CLEAR.** All names encode scenario and expected outcome (e.g., `T2b.1 explicit opt-out routes save_exit`, `T8c.1 kill switch forces retry_coder_build`).

**Scope Alignment — CLEAR.** All referenced functions and state variables exist in the current implementation. The subshell-isolation comment at lines 126–129 accurately describes the architecture (guards written by dispatcher, not by `_classify_failure`). Assertions for T1.2/T1.3 and T9.2–T9.4 correctly call `_load_failure_cause_context` directly to bypass the subshell isolation. No stale references.

**Test Isolation — CLEAR.** All fixture JSON files are written to `$TMPDIR` via fixture writers. `ORCH_CONTEXT_FILE_OVERRIDE` redirects the loader to fixtures rather than `$PROJECT_DIR`. `_reset_test_state` fully resets all module-level vars before each case. No mutable project state is read.

---

#### tests/test_ui_gate_force_noninteractive.sh (8 assertions, P0-T1–P0-T6)

**Assertion Honesty — CLEAR.** All assertions call the real `_ui_detect_framework` and `_ui_deterministic_env_list` with no mocking. The asserted strings (`playwright`, `none`, `PLAYWRIGHT_HTML_OPEN=never`, `CI=1`) match the literal echo outputs in `gates_ui_helpers.sh:26`, `51`, `71`, `73`.

**Edge Case Coverage — GOOD.** Three Priority 0 activation cases (plain, UI_FRAMEWORK override, empty PROJECT_DIR preventing file detection), two non-activation cases (unset variable, value=0 opt-out), one env-list integration case (hardened path).

**Implementation Exercise — CLEAR.** Sources real `gates_ui_helpers.sh`. No mocking. `_clear_detection_vars` resets env state only, leaving the implementation untouched.

**Test Weakening — N/A.** No prior assertions removed or broadened.

**Test Naming — CLEAR.** Names encode priority level, trigger condition, and expected outcome.

**Scope Alignment — CLEAR.** `_ui_detect_framework` Priority 0 hook tested at its actual location (`gates_ui_helpers.sh:25–28`). `_ui_deterministic_env_list` at `gates_ui_helpers.sh:60–80`. No stale references.

**Test Isolation — CLEAR.** `PROJECT_DIR="$TMPDIR"` (empty temp dir) prevents file-based playwright detection. `_clear_detection_vars` resets all detection inputs between test cases. No mutable project state is read.

---

#### tests/test_m131_coverage_gaps.sh (17 assertions, GAP-1.1–1.6, GAP-2.1–2.3)

**Assertion Honesty — CLEAR.** GAP-1.x assertions verify env var strings emitted by `_ui_deterministic_env_list` against the implementation at `gates_ui_helpers.sh:65–79`. GAP-2.x assertions verify `_PF_PASS`, `_PF_WARN`, `_PF_FAIL` counter values against the `_pf_record` call structure in `preflight_checks_ui.sh:231–245`. All expected values are traceable to implementation logic.

**Edge Case Coverage — STRONG.** GAP-1 covers: flag=1 no arg (escalation), flag=1 with hardened=0 arg (escalation overrides arg), flag unset (no escalation), hardened=1 arg no flag (original path regression), flag=0 (not treated as 1), flag=1 with non-playwright framework (env emission skipped). GAP-2 covers: --exit present (no warn), --exit absent (warn), --exit mid-string (recognized).

**Implementation Exercise — CLEAR.** Sources real `gates_ui_helpers.sh`, `preflight.sh`, and `preflight_checks_ui.sh`. Calls `_ui_deterministic_env_list` and `_preflight_check_ui_test_config` directly. `_reset_pf_state` resets counters but does not stub any implementation functions.

**Test Weakening — N/A.** New file; no prior assertions exist.

**Test Naming — CLEAR.** GAP-1.x names describe flag state and expected outcome. GAP-2.x names describe fixture content and which condition (presence/absence of `--exit`) produces which outcome.

**Scope Alignment — CLEAR.** M131 escalation hook at `gates_ui_helpers.sh:65–67` is exactly what GAP-1.1 and GAP-1.2 exercise. CY-2 guard at `preflight_checks_ui.sh:232–239` is exactly what GAP-2.x exercises. No stale or orphaned references.

**Test Isolation — CLEAR.** GAP-1.x uses `_clear_gate_vars` to set `PROJECT_DIR="$TMPDIR_BASE"` (empty dir). GAP-2.x creates a fresh `PROJ=$(mktemp -d)` per sub-test with `rm -rf "$PROJ"` cleanup after each. No mutable project state is read. The `_reset_pf_state` function correctly unsets the four `PREFLIGHT_UI_*` contract vars between tests.

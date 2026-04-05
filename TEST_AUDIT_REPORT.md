## Test Audit Report

### Audit Summary
Tests audited: 4 files, 60 test functions (7 in test_platform_fragments.sh, 44 in test_watchtower_distribution_toggle.sh, 3 in test_nonblocking_log_structure.sh, 6 in test_watchtower_css_sync.sh)
Verdict: CONCERNS

---

### Findings

#### INTEGRITY: Broken pipe makes Test 9 always pass
- File: tests/test_watchtower_distribution_toggle.sh:277
- Issue: The assertion uses `echo "$BREAKDOWN_FUNC" | grep -q "else {" | head -1`. The `-q` flag on `grep` suppresses all output; the pipe to `head -1` receives zero bytes. On Linux, `head -1` with empty input exits 0. The `if` statement tests `head -1`'s exit code — not `grep`'s — so this assertion always passes unconditionally, regardless of whether `"else {"` exists in the function body. The actual implementation does contain `} else {` at app.js:808, so the current verdict is accidentally correct, but the assertion provides zero protection against regressions that remove the else branch.
- Severity: HIGH
- Action: Remove the spurious `| head -1`. Correct form: `if echo "$BREAKDOWN_FUNC" | grep -q "else {"; then`

#### SCOPE: Dead assertions for non-existent "Test Audit Concerns" blocks
- File: tests/test_nonblocking_log_structure.sh:46-63
- Issue: Tests 3a and 3b scan `NON_BLOCKING_LOG.md` for `### Test Audit Concerns (2026-03-28)` and `### Test Audit Concerns (2026-03-29)` blocks. Neither block exists in the file. When `grep -c` returns 0, neither the `> 1` nor the `== 1` branch fires — no pass is recorded and no fail is recorded. The TESTER_REPORT reports "2 passed, 0 failed", consistent with only Tests 1 and 2 counting. These assertions are dead code that silently contribute nothing to the pass/fail totals.
- Severity: MEDIUM
- Action: Remove the dead Test 3a/3b blocks. If duplicate-block detection is valuable, replace with a check meaningful against the current file structure (e.g., assert the Resolved section has at least one `- [x]` item).

#### EXERCISE: Test 27 writes mock file to production platform directory
- File: tests/test_platform_fragments.sh:86-94
- Issue: Test 27 creates `${TEKHTON_HOME}/platforms/web/coder_guidance.prompt.md` — inside the live `platforms/web/` adapter directory — rather than writing under `TEST_TMPDIR`. The file is cleaned up inline (line 94) and by the EXIT trap (line 27). Today `platforms/web/` contains only `.gitkeep`, so there is no immediate collision. However, when M58 populates `platforms/web/coder_guidance.prompt.md`, the trap will delete the production file unconditionally on any test exit, corrupting the web platform adapter.
- Severity: MEDIUM
- Action: Write the mock file to a temp path under `$TEST_TMPDIR`, then temporarily override the platform lookup (e.g., stub `_read_platform_file` for the test's scope, or set `TEKHTON_HOME` to a temp directory with a pre-populated `platforms/web/` subtree). Remove the production path from the EXIT trap.

#### WEAKENING: NON_BLOCKING_LOG.md open items removed without per-item verification in TESTER_REPORT
- File: NON_BLOCKING_LOG.md (pre-verifier: net loss of 2 assertions; diff shows 4 `- [ ]` items removed, `(none)` added)
- Issue: All four open items were removed and replaced with `(none)`. Three are verifiably addressed: "Avg Turns" rename confirmed at app.js:784, `aria-pressed` confirmed at app.js:783, `detox` mapping confirmed absent from platforms/_base.sh. The fourth (test_platform_base.sh over 300-line ceiling) is addressed by the split into test_platform_fragments.sh. The resolution is correct. However, the TESTER_REPORT lists only 2 of the 4 resolved items in its "Files Modified" section — the test split and detox mapping removal are not explicitly verified, leaving the mechanical weakening flag without full written justification.
- Severity: LOW
- Action: No code change needed. The TESTER_REPORT should enumerate all 4 resolved items with a one-line verification note for each. Accept as-is; flag for process improvement.

---

### Scope Alignment Note
`INTAKE_REPORT.md` was deleted by the coder. No test file in the audit context imports or references `INTAKE_REPORT.md` — no orphaned tests.

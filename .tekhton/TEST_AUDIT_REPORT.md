## Test Audit Report

### Audit Summary
Tests audited: 3 files, 6 test cases
- `tests/test_audit_bash_env_coverage.sh` — 3 test cases (fallback-guarded, fallback-unguarded, single-quoted false-positive)
- `tests/testdata/audit_bash_env/07-single-quoted.sh` — fixture file (no test functions)
- `tests/test_m27_sweep_regression.sh` — 3 test cases (Cases 1, 2, 3)
Verdict: CONCERNS

---

### Findings

#### ISOLATION: test_m27_sweep_regression.sh Case 2 reads a pipeline artifact path
- File: tests/test_m27_sweep_regression.sh:58-63
- Issue: Case 2 asserts that `.tekhton/M27_INVENTORY.md` is absent from the working tree by
  directly testing `[[ -f "${TEKHTON_HOME}/.tekhton/M27_INVENTORY.md" ]]`. The `.tekhton/`
  directory is a pipeline-generated artifact store (cf. `.tekhton/CODER_SUMMARY.md`,
  `.tekhton/REVIEWER_REPORT.md`). The test's pass/fail depends on whether a prior pipeline run
  (m27.2) correctly executed `git rm` — the definition of a pipeline-state-dependent test. If
  any developer or pipeline re-runs m27.1 (which re-generates the inventory), the file reappears
  and this test fails with no code change. There is no fixture isolation.
- Severity: HIGH
- Action: Convert to a fixture-isolated check: the test's actual contract is that the m27.2 sweep
  consumed and deleted a transient artifact. The correct assertion is against the committed tree
  via `git ls-files .tekhton/M27_INVENTORY.md` (should print nothing), not the working-tree file
  system. Alternatively, restrict this acceptance criterion to the pipeline's own post-run
  cleanup gate rather than a self-test, since self-tests must be runnable in any working-tree
  state without depending on what a prior pipeline run did or didn't delete.

#### ISOLATION: test_m27_sweep_regression.sh Case 1 scans the live source tree with no fixture
- File: tests/test_m27_sweep_regression.sh:34-48
- Issue: Case 1 runs `bash "${AUDIT_SCRIPT}"` with no arguments, which scans all `lib/*.sh` and
  `stages/*.sh` files in the current working tree. The test carries no fixture data of its own;
  its pass/fail is coupled to the state of 102+ checked-in source files. Any future edit —
  including a legitimate feature branch in progress — that introduces a bare `${VAR}` read of a
  contract variable will cause this test to fail on that branch. This is intentional by design
  as a global regression guard (the same pattern as running `shellcheck` or `golangci-lint` in
  CI), but it strictly violates the isolation requirement: there is no fixture copy and the test
  outcome depends on the full source tree state.
- Severity: MEDIUM
- Action: This is a category of test that belongs in a CI gate (e.g., `tests/run_static_checks.sh`
  alongside shellcheck and golangci-lint), not in the unit/self-test suite. Moving it to a
  clearly-labelled static analysis category would communicate the intentional global-state
  dependency and prevent contributors from being surprised when a feature branch breaks it.
  If keeping it in the self-test suite, add a comment block stating explicitly that this test
  depends on the state of all `lib/` and `stages/` files and will fail on any branch that
  introduces new unguarded reads.

#### EXERCISE: _strip_m27_defaults is locally re-defined, not sourced from its production location
- File: tests/test_m27_sweep_regression.sh:80-83
- Issue: Case 3 claims to validate "the `_strip_m27_defaults` filter added to
  `test_m84_static_analysis.sh`" (per the test header comment), but instead re-defines the
  function locally (lines 80-83). The two definitions are currently identical. However, if the
  production function in `test_m84_static_analysis.sh` is patched — for example, to add `-F`
  to fix the regex metachar issue flagged in the REVIEWER_REPORT (`grep -v "${fname}}"` treats
  the `.` in `SCOUT_REPORT.md}` as a regex wildcard) — this regression test will not detect
  the divergence. It validates only its own local copy.
- Severity: MEDIUM
- Action: Either (a) source the function from its canonical location before Case 3:
  `source "${TEKHTON_HOME}/tests/test_m84_static_analysis.sh"` (accepted isolation risk since
  that file is a test, not production code), or (b) acknowledge in the comment that Case 3 tests
  the algorithm's correctness in isolation, not the specific implementation in test_m84, and
  update the header comment to match. Option (b) is lower risk; the important thing is that the
  comment accurately describes what is being tested so a future maintainer doesn't trust this
  test as a divergence detector.

#### ISOLATION: Binary-absent PATH stripping may not exclude all tekhton installation paths
- File: tests/test_audit_bash_env_coverage.sh:31-32
- Issue: The binary-absent simulation uses three defenses: (1) `TEKHTON_BIN=/nonexistent`
  neutralizes the env-var lookup, (2) copying the script to a tmpdir neutralizes the
  `${REPO_ROOT}/tekhton` and `${REPO_ROOT}/bin/tekhton` file checks, and (3)
  `_NO_BIN_PATH` strips only `${TEKHTON_HOME}/bin` from PATH. Defense (3) misses any
  `tekhton` reachable via `~/go/bin`, `/usr/local/bin`, or a developer's custom `bin/` on
  PATH. If `command -v tekhton` in the audit subprocess succeeds via such a path, the fallback
  branch never executes, no `# WARNING:` appears on stderr, and both `fallback-guarded-warning`
  and `fallback-unguarded-warning` assertions fail unexpectedly.
- Severity: LOW
- Action: Replace the selective strip with a minimal safe PATH:
  `_NO_BIN_PATH="/usr/bin:/bin"`. This is more reliable than trying to enumerate and remove
  every possible installation location.

#### NAMING: Case 3 labels do not encode the known-false-positive intent
- File: tests/test_audit_bash_env_coverage.sh:136-137
- Issue: Labels `"single-quoted-exit"` and `"single-quoted-finding"` assert that a known
  false positive IS flagged (exit 1, finding present). If the scanner is later fixed to
  correctly skip intra-line single-quoted content, these assertions flip to failure. The
  resulting message `FAIL: single-quoted-exit — expected exit 1, got 0` reads as a detection
  regression rather than evidence of a fix, sending a maintainer to debug in the wrong direction.
- Severity: LOW
- Action: Rename labels to encode the known-false-positive context, e.g.,
  `"known-fp-single-quoted-exit"` and `"known-fp-single-quoted-finding"`. The resulting
  failure message immediately signals that a documented limitation was corrected and the test
  requires a deliberate update.

---

### Notes

**Assertion honesty — PASS.** All assertions derive their expected values from real implementation
behavior. Cases 1–2 in `test_audit_bash_env_coverage.sh` exercise the actual `_pipeline_conf_keys()`
fallback and `_scan_files()` awk scanner; expected values come from the implementation logic, not
from literals that match by coincidence. Case 3 explicitly documents that it is asserting known
misbehavior (false positive), which is honest. Cases 1–3 in `test_m27_sweep_regression.sh` derive
their expected values from the m27.2 acceptance criteria. No `assertTrue(True)` or hard-coded
tautological assertions found.

**Edge cases — PASS.** Both guarded and unguarded forms are tested; the fallback allowlist path and
the binary-present path are each exercised. The `_strip_m27_defaults` filter is tested with the
close-brace (strip), bare-literal (preserve), and grep-r-format (strip) cases. Adequate coverage
for the scope.

**Weakening — PASS.** All three files under audit are net-new. No existing assertions were removed
or relaxed. `test_audit_bash_env_coverage.sh` is an addition to the existing
`tests/test_audit_bash_env.sh` suite; no overlapping cases were modified.

**Scope alignment — PASS.** All fixture references (`01-guarded.sh`, `02-unguarded.sh`,
`07-single-quoted.sh`) exist in the working tree. No imports reference deleted modules.
`07-single-quoted.sh` is a new fixture consistent with the new test case; no stale references found.

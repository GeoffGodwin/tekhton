## Test Audit Report

### Audit Summary
Tests audited: 1 file, 27 test assertions (tests/test_m29_milestone_conformance.sh)
Freshness sample: 3 files reviewed (internal/finalize/mark_done_test.go,
notes_hooks_test.go, orchestrator_test.go — not modified this run)
Verdict: CONCERNS

---

### Findings

#### ISOLATION: Test reads live mutable pipeline state files without fixture copies
- File: tests/test_m29_milestone_conformance.sh:16-57
- Issue: MILESTONE_DIR is resolved from the live working tree
  (`TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"`), and all four
  files tested — `m29-detect-port.md`, `m29.1-detect-core-and-report.md`,
  `m29.2-detect-domain-detectors.md`, and `MANIFEST.cfg` — are live pipeline state
  files managed by the runtime. `MANIFEST.cfg` has its `status` column updated by
  the finalize hooks as milestones transition. Milestone `.md` files are deleted on
  close by `internal/finalize/cleanup_milestone.go`. The test creates no fixture copies
  in a temp directory; it reads the live working tree unconditionally, so its outcome
  depends on the current pipeline run state.
- Severity: HIGH
- Action: Add a lifecycle guard at the top of the script. If MANIFEST shows m29.1 or
  m29.2 already at status=done (or either milestone file is absent), print a SKIP
  message and exit 0 — the conformance was verified during authoring and the arc has
  since closed. Example guard after line 57:
  ```bash
  # Skip gracefully once the milestone arc has progressed past the authoring window.
  if ! grep -qE '^m29\.1\|[^|]+\|todo\|' "$MANIFEST" 2>/dev/null || \
     ! grep -qE '^m29\.2\|[^|]+\|todo\|' "$MANIFEST" 2>/dev/null; then
      echo "  SKIP: m29 arc has progressed; conformance tests no longer applicable"
      exit 0
  fi
  ```
  This makes the test self-expiring rather than permanently failing after m29.1 closes.

#### SCOPE: Transient `status: "todo"` assertions will permanently break CI after m29.1 closes
- File: tests/test_m29_milestone_conformance.sh:76-79, 105-108, 219-228
- Issue: Suite 1 asserts `status: "todo"` in m29.1's meta block (line 77); Suite 2
  asserts the same for m29.2 (line 105); Suite 7 checks MANIFEST regex patterns
  `^m29\.1\|[^|]+\|todo\|` (line 219) and `^m29\.2\|[^|]+\|todo\|` (line 225). When
  the pipeline closes m29.1 these assertions flip to `done` in both the file and
  MANIFEST, causing four permanent failures on every subsequent `bash tests/run_tests.sh`
  invocation. The milestone file itself is deleted on close, so the existence checks and
  content assertions in Suite 1 (lines 64-85) also fail permanently thereafter.
- Severity: HIGH
- Action: The lifecycle guard recommended in the ISOLATION finding above resolves this
  as a side effect — once the guard fires, the suite exits 0 before reaching the
  status assertions. Alternatively, if the test is meant to remain active for the full
  arc lifetime, convert the status assertions to check only the immutable properties
  (`id:` value, Depends On row, Watch For content, fixture names) and remove the
  `status: "todo"` checks entirely.

---

### Positive Findings (No Issues)

**Assertion Honesty — PASS.** All 27 assertions grep against real file content using
patterns derived from the actual milestone spec and MANIFEST format. The `_section_has`
helper correctly scopes to the named markdown section. The `_ac_has "$M29_1" "4\.29\.0"`
negative assertion (line 149) tests a genuine behavioral invariant, not a tautology.
No assertion always passes or compares a value against a constant not derived from the
implementation.

**Edge Case Coverage — PASS.** The suite covers the expected negative: AC4 explicitly
asserts that m29.1's Acceptance Criteria section does NOT contain the 4.29.0 VERSION
reference (line 149). Missing-file paths are handled: every `grep` call uses `2>/dev/null`
and the `if [[ -f ... ]]` blocks at lines 64 and 93 gate subsequent checks behind
existence. The MANIFEST assertions use exact regex patterns rather than loose substring
matches.

**Implementation Exercise — PASS.** All 27 tests read the actual deliverable files
(the milestone markdown and MANIFEST.cfg). No mocking. The `_section_has` helper uses
real awk + grep against the real files.

**Test Weakening — N/A.** This is a new file; no prior tests existed to weaken.

**Naming and Intent — PASS.** Suite headers (`Suite 1: m29.1 file existence and meta`,
etc.) and individual pass/fail messages encode the scenario and expected outcome clearly.
The file-header comment maps each suite to its parent AC number.

**Scope Alignment — PASS.** The seven suites map 1:1 to the seven acceptance criteria in
`m29-detect-port.md`. The coder's single actual change — adding a read-only contract
bullet to m29.2's `## Watch For` section — is directly exercised by Suite 5, line 172.
No tests reference deleted or renamed symbols.

---

### Freshness Sample — No Issues Found

None of the three Go finalize files were modified this run, and none are affected by
the m29 coder change (which touched only `.claude/milestones/m29.2-detect-domain-
detectors.md`).

- **internal/finalize/mark_done_test.go**: Uses `t.TempDir()` + `os.WriteFile` to build
  isolated MANIFEST fixtures. Asserts against real `manifest.Load` + `MarkDone.Run`
  output. No live project files read. Properly isolated.
- **internal/finalize/notes_hooks_test.go**: Uses `t.TempDir()` + copies from the
  committed `internal/notes/testdata/golden/` fixture. Uses `t.Setenv` to neutralize
  any pipeline env leak. Properly isolated.
- **internal/finalize/orchestrator_test.go**: Uses in-memory `fakeHook` doubles and
  `HookOrder()` introspection. No filesystem reads of live state. Properly isolated.

All three freshness-sample files are in scope alignment with the current codebase.
No orphaned references, stale assertions, or weakened checks detected.

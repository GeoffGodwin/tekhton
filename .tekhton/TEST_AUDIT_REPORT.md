## Test Audit Report

### Audit Summary
Tests audited: 1 file, 28 test assertions (tests/test_m33_milestone_structure.sh)
Freshness sample: 3 files reviewed (cmd/tekhton/detect_test.go,
internal/detect/detect_test.go, internal/detect/languages_test.go — not modified this run)
Verdict: CONCERNS

---

### Findings

#### ISOLATION: Tests read live mutable milestone files without fixture isolation
- File: tests/test_m33_milestone_structure.sh:54-57
- Issue: All four file paths under test (`M33_PARENT`, `M33_1`, `M33_2`, `MANIFEST`) resolve
  directly to live `.claude/milestones/` files in the working tree. These files are mutable:
  the coder edits them mid-run (this very run modified `m33.2-dashboard-parsers.md`), and
  CLAUDE.md states the finalize orchestrator deletes milestone files from the working tree
  when a milestone completes (`internal/finalize/cleanup_milestone.go`). When m33.1 and
  m33.2 close, every assertion in suites 1–5 (and the AC3/AC4 checks in suites 3–4) will
  fail because the files will no longer exist. The test's pass/fail outcome is permanently
  coupled to transient pipeline state rather than a stable fixture snapshot.
- Severity: HIGH
- Action: Copy the four target files into a temp directory at test start and point the path
  variables at those copies. Pattern:
  ```bash
  _tmpdir=$(mktemp -d)
  trap 'rm -rf "$_tmpdir"' EXIT
  cp "$M33_PARENT" "$M33_1" "$M33_2" "$MANIFEST" "$_tmpdir/"
  M33_PARENT="$_tmpdir/m33-dashboard-port.md"
  M33_1="$_tmpdir/m33.1-dashboard-emitters.md"
  M33_2="$_tmpdir/m33.2-dashboard-parsers.md"
  MANIFEST="$_tmpdir/MANIFEST.cfg"
  ```
  Additionally, add a lifecycle guard that exits 0 (SKIP) when the milestone files are
  already absent from the working tree, so the test self-expires rather than permanently
  failing after both m33 children close:
  ```bash
  if [[ ! -f "${MILESTONE_DIR}/m33.1-dashboard-emitters.md" ]] && \
     [[ ! -f "${MILESTONE_DIR}/m33.2-dashboard-parsers.md" ]]; then
      echo "  SKIP: m33 arc has closed; conformance tests no longer applicable"
      exit 0
  fi
  ```

#### INTEGRITY: Unconditional pass() call at line 210 always fires
- File: tests/test_m33_milestone_structure.sh:210
- Issue: `pass "m33 parent status verified via meta block (split)"` at line 210 is
  unconditional — it always increments `PASS` by 1 regardless of whether `M33_PARENT`
  exists or contains `status: "split"`. The two guarded checks at lines 195–205 are the
  real assertions; this call adds a phantom assertion that can never be FAIL. The tester
  report's "Passed: 28" count is inflated by 1: a run where the grep at line 201 fails
  (wrong or missing status) would still report 28 passed instead of 27. The comment
  ("positive check above is sufficient") implies the author intended to remove a redundant
  negative check, but left an always-true stub in its place.
- Severity: LOW
- Action: Delete line 210. The two conditional checks in Suite 6 are sufficient; the
  unconditional `pass()` adds no diagnostic value and makes the count misleading.

#### COVERAGE: _section_has helper has no dedicated edge-case coverage
- File: tests/test_m33_milestone_structure.sh:32-39
- Issue: The `_section_has` awk helper is the only non-trivial logic in this test file.
  It has no dedicated edge-case tests: keyword present in the file but outside the named
  section, section present but empty body, section heading absent entirely, file missing.
  If the awk stop-condition (`/^## /{ found=0 }`) were broken, all positive assertions
  would still pass as long as the keyword appears anywhere in the file—a false-green
  scenario the current tests would not detect.
- Severity: LOW
- Action: Add two or three inline fixture strings (heredoc into `$_tmpdir`) that exercise
  `_section_has` in isolation: (a) keyword in a different section than the one named;
  (b) named section present but body empty; (c) file absent. These synthetic fixtures
  keep the test fully self-contained and take fewer than 20 lines to add.

---

### Positive Findings (No Issues)

**Assertion Honesty — PASS.** All conditional assertions grep against real file content
using patterns derived from the actual milestone spec and MANIFEST format. The `_section_has`
helper correctly scopes to the named markdown section via the awk stop rule. The negative
assertions in Suite 7 (lines 223–232: `go test` and `grep -rn` absent from parent AC) test
genuine behavioral invariants, not tautologies. No conditional assertion compares a value
against a hardcoded constant not derivable from the implementation.

**Implementation Exercise — PASS.** All tests read the actual deliverable files (milestone
markdown + MANIFEST.cfg). No mocking. The `_section_has` and `_files_modified_has` helpers
use real awk + grep against the real files.

**Test Weakening — N/A.** This is a new file; no prior test file existed to weaken.

**Naming and Intent — PASS.** Suite echo headers and individual pass/fail messages encode
both the scenario and the expected outcome clearly (e.g., "m33.2 lists dashboard_v1.go as
Modify (parse-side extender)"). The file-header comment maps each suite to its parent AC.

**Scope Alignment — PASS.** The eight suites map directly to the eight acceptance criteria
in `m33-dashboard-port.md`. The coder's actual change—adding two rows to m33.2's `## Files
Modified` table (`internal/proto/dashboard_v1.go Modify` and `internal/proto/dashboard_v1_test.go
Modify`)—is directly exercised by Suite 3, lines 128–151. No tests reference deleted or
renamed symbols.

---

### Freshness Sample — No Issues Found

The three detect-test files were not modified this run. The m33 coder change touched only
`.claude/milestones/m33.2-dashboard-parsers.md` (no Go or bash code); none of the detect
tests exercise dashboard or milestone logic.

- **cmd/tekhton/detect_test.go**: Exercises the CLI surface with `cobra.Command` test
  helpers. No live project files read. Properly isolated.
- **internal/detect/detect_test.go**: Table-driven tests against synthetic fixture
  directories created via `t.TempDir()`. Properly isolated.
- **internal/detect/languages_test.go**: Pure in-memory language detection logic. No
  filesystem reads. Properly isolated.

All three freshness-sample files are in scope alignment with the current codebase.
No orphaned references, stale assertions, or weakened checks detected.

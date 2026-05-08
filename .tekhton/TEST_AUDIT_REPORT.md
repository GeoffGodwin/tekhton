## Test Audit Report

### Audit Summary
Tests audited: 2 files, 4 new test functions (classify_test.go: 2 new; config_test.go: 2 new)
(Freshness-sample files reviewed: cross_test.go, redact_test.go, sentinels_test.go — no issues found)
Verdict: PASS

### Findings

#### SCOPE: Shell orphan detector flags Go built-in functions as stale symbols
- File: internal/config/config_test.go (lines 462, 472, 519, 534), internal/errors/classify_test.go (lines 94, 101)
- Issue: The pre-verified STALE-SYM entries for `append` and `len` are false positives. Both are Go built-in functions that live in every Go program's pre-declared universe scope; they have no source-file definition within the repo. The shell-based symbol scanner has no knowledge of Go's built-in namespace and will always report these. No test code is stale or orphaned.
- Severity: LOW
- Action: No test change needed. The shell symbol scanner should filter Go built-in identifiers (`append`, `len`, `cap`, `make`, `new`, `delete`, `copy`, `close`, `panic`, `recover`, `print`, `println`) when processing `.go` files. This is a tooling gap, not a test integrity issue.

None — no other issues found.

---

### Detailed Assessment by Rubric Point

#### internal/errors/classify_test.go — new functions: TestIsNonDiagnosticLine_PnpmYarnNotice, TestIsNonDiagnosticLine_PnpmYarnNotice_ClassifyWithStats

**1. Assertion Honesty — PASS**
Every case in `TestIsNonDiagnosticLine_PnpmYarnNotice` derives from actual behavior in `classify.go`:
- `pnpm notice` and `yarn notice` cases (want: true) match the two new `noiseLineREs` entries at `classify.go:38–39`.
- Leading-whitespace cases pass because the regexes use `^[[:space:]]*` anchors.
- Uppercase cases pass because the regexes use the `(?i)` flag.
- Allow-list-override cases (want: false, lines containing "error", "TS2304", "ECONNREFUSED") match the `failureTermRE` check at `classify.go:63–65`, which runs before the deny-list loop.
- Regression guard cases for `npm notice` and `npm warn` match the pre-existing entries at `classify.go:35–36`.

`TestIsNonDiagnosticLine_PnpmYarnNotice_ClassifyWithStats` asserts `r.TotalLines == 1` per record. In `ClassifyWithStats` (`classify.go:159–165`), `IsNonDiagnosticLine` is called before incrementing `totalLines`, so the three pnpm/yarn notice lines are skipped and only the TS2304 error line counts. The assertion is correct.

**2. Edge Case Coverage — PASS**
Covers: bare format, colon-suffix format, leading whitespace, uppercase variants, allow-list-override (error term, TS-error term, ECONNREFUSED), npm regression guard, and the end-to-end ClassifyWithStats integration path.

**3. Implementation Exercise — PASS**
Both functions call the real `terr.IsNonDiagnosticLine` and `terr.ClassifyWithStats` implementations. No mocking.

**4. Test Weakening — N/A**
No existing test functions were modified. New functions were appended.

**5. Test Naming — PASS**
`TestIsNonDiagnosticLine_PnpmYarnNotice` encodes the scenario (pnpm/yarn notice lines) and the expected outcome (filtered as non-diagnostic). `TestIsNonDiagnosticLine_PnpmYarnNotice_ClassifyWithStats` additionally signals the end-to-end integration scope.

**6. Scope Alignment — PASS**
No reference to deleted files. All imports target `internal/errors` at the correct import path. The pnpm/yarn regex entries are confirmed present in `classify.go:38–39`.

**7. Test Isolation — PASS**
All inputs are inline string literals. No reads from `.tekhton/`, `.claude/`, or any mutable pipeline artifact.

---

#### internal/config/config_test.go — new functions: TestApplyLateDefaults_EmptyFastPath, TestApplyLateDefaults_NonEmptyPath

**1. Assertion Honesty — PASS**
`TestApplyLateDefaults_EmptyFastPath`:
- Guards itself with `t.Skip` when `len(lateDefaults) != 0`, making the test meaningful only while the slice is empty — exactly the current state (`defaults.go:613: var lateDefaults = []defaultRule{}`).
- Asserts that calling `applyLateDefaults` with an empty slice leaves `cfg.Values` unchanged (`len == 1`, existing key value preserved). This matches the early-return guard at `defaults.go:46–48`.

`TestApplyLateDefaults_NonEmptyPath`:
- Uses `lit("late_value")` from `defaults.go:74` (accessible in `package config`) to install a sentinel rule.
- Verifies that an absent key receives the default value and a present key is left alone — matching the `:=` semantics loop at `defaults.go:49–54`.
- `saved := lateDefaults; t.Cleanup(func() { lateDefaults = saved })` correctly restores the package-level variable after the test.

No hard-coded values appear that are not derived from the implementation.

**2. Edge Case Coverage — PASS**
Covers: empty-slice fast path, absent-key assignment, and present-key non-overwrite (both branches of the `if _, ok := cfg.Values[r.Key]; ok` check).

**3. Implementation Exercise — PASS**
Both functions call `applyLateDefaults` directly (package-internal function, accessible because the test is in `package config`). No mocking.

**4. Test Weakening — N/A**
No existing test functions were modified. New functions were appended.

**5. Test Naming — PASS**
`TestApplyLateDefaults_EmptyFastPath` and `TestApplyLateDefaults_NonEmptyPath` each encode the branch under test in the name.

**6. Scope Alignment — PASS**
`lateDefaults` is still present as a package-level `[]defaultRule` variable at `defaults.go:613`. No stale references.

**7. Test Isolation — PASS**
Neither new test reads any file. The `lateDefaults` mutation in `TestApplyLateDefaults_NonEmptyPath` is saved and restored via `t.Cleanup`. Neither test calls `t.Parallel()`, so no concurrent write to the shared variable can occur from within these tests.

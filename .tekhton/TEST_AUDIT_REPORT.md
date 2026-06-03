## Test Audit Report

### Audit Summary
Tests audited: 3 files, 28 test functions
Verdict: CONCERNS

### Findings

#### INTEGRITY: No-op test makes zero assertions
- File: internal/stages/staglog/staglog_test.go:51
- Issue: `TestStaglogNew_FallsBackToOnePerOne` performs no assertions and
  exercises no observable behavior. It calls `NewWithWriter(&buf, 0, 0)` — not
  `New()`, the function it claims to cover — assigns the result to `_`, and
  returns. The comment "not exercising New() — its env path is below" implies
  behavior is tested later in the same function, but the function ends there
  with no assertions. This test always passes regardless of how `New()` or
  `NewWithWriter()` behave. The behavior it nominally covers (nil-req defaults
  to pos=1, count=1) is correctly asserted by `TestStaglogNew_NilReq_DefaultsToOneOne`
  (line 82); the env-read path is covered by `TestStaglogNew_FromEnv` (line 103).
- Severity: HIGH
- Action: Remove `TestStaglogNew_FallsBackToOnePerOne` entirely. Its intended
  coverage is already provided by the two tests above. Do not add assertions to
  salvage it — that would create exact duplicates of existing tests.

#### NAMING: Test name encodes neither scenario nor expected outcome
- File: internal/stages/docs/stage_test.go:225
- Issue: `TestEnvBoolEnvInt` exercises two unrelated utility functions
  (`envBool` and `envInt`) in one function. The name gives no signal about
  what failure modes are under test, which makes it harder to diagnose from
  test output alone. The tests that immediately follow it
  (`TestEnvBool_UnknownValue`, `TestEnvInt_ZeroInput`, `TestEnvInt_EmptyOrUnset`)
  correctly use the scenario-and-outcome naming convention this one lacks.
- Severity: LOW
- Action: Split into `TestEnvBool_KnownValues` and `TestEnvInt_ParseAndFallback`,
  aligning with the surrounding naming convention.

#### NAMING: Test comment contradicts fixture
- File: internal/stages/docs/skip_test.go:172
- Issue: `TestExtractPublicSurface_AlwaysIncludesDefaults` opens with the comment
  "Section present but empty body" yet the CLAUDE.md fixture contains the word
  `stub` in the section body, making it non-empty. The implementation returns
  `nil` for a trimmed-empty section (skip.go:133), so the comment implies a
  different code path than is actually exercised. The test is logically correct —
  defaults are seeded whenever the section is present and non-empty — but the
  misleading comment risks a future maintainer assuming the empty-body path is
  covered when it is not.
- Severity: LOW
- Action: Update the comment to "Section present with minimal body — defaults
  should still seed the slice." If empty-body behavior needs verification, add a
  separate `TestExtractPublicSurface_EmptyBody` fixture with a section whose
  trimmed content is blank and assert `nil` is returned.

### Non-Findings (all rubric points examined, no additional issues)

**ASSERTION HONESTY:** All expected values are derived from implementation
logic. `atoiOr` returns fallback for n≤0 so `TestStaglogAtoiOr`'s assertion of
7 for input "0" is correct (skip.go is not involved). `envBool` returns `false`
for `""` regardless of fallback (stage.go:185), so `TestEnvBoolEnvInt`'s
assertion `if envBool("", true)` is a genuine correctness check. `globToRegexp`
translates `[*` to `[.*` (unclosed character class), so
`TestFilesMatchSurface_GlobCompileError`'s expectation of `false` matches the
`continue` in `filesMatchSurface` (skip.go:186). No hard-coded magic numbers or
`assertTrue(True)` patterns found.

**WEAKENING:** The tester added new tests only; no pre-existing assertions in
any of the three files were removed or broadened.

**EXERCISE:** All test functions call real implementation code. `stage_test.go`
drives `RunStage` through every gate using a real temp-dir git repo plus a
recording `fakeAgentRunner` seam. `skip_test.go` calls `shouldSkip`,
`extractDocResponsibilities`, `extractPublicSurface`, `filesMatchSurface`, and
`changedFiles` directly. `staglog_test.go` calls `New`, `NewWithWriter`,
`atoiOr`, and `envOrInt` with non-trivial inputs.

**SCOPE:** All symbols referenced in the audit files exist in the current
codebase. No imports reference deleted files (`stages/docs.sh`,
`lib/docs_agent.sh`). The `fakeAgentRunner` type correctly implements the
`AgentRunner` interface (stage.go:29).

**ISOLATION:** Every test creates its own fixture state in `t.TempDir()`.
No test reads live pipeline artifacts, run logs, or mutable project-state
files from `.tekhton/` or `.claude/`.

**COVERAGE (informational):** `internal/stages/docs/prepare.go`
(`prepareTemplateVars`, `safeReadFile`, `collectGitDiffStat`) is exercised by
`prepare_test.go`, which the coder summary lists as created but which was not in
the tester's modified-file set and falls outside this audit's scope. It should
appear in the next audit cycle if modified.

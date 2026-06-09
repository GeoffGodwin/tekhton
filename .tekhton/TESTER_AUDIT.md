## Test Audit Report

### Audit Summary
Tests audited: 3 files, 17 Go test functions + 7 bash scenarios
Verdict: CONCERNS

---

### Findings

#### SCOPE: checkAndMoveMisplacedSummaries does not exist — compilation failure
- File: internal/stages/coder/coder_summary_path_test.go:52, :101, :132, :176
- Issue: All four test functions call `o.checkAndMoveMisplacedSummaries()`, but no such method exists on `*orchestrator` in the coder package. `grep -r checkAndMoveMisplacedSummaries internal/` finds the symbol only in the milestone design file (`.claude/milestones/m06-staging-allowlist-and-coder-summary-path.md`) and the test file itself — never in any `.go` implementation file. The package will not compile. The tester's own report notes "m06 Goal B hook unimplemented."
- Severity: HIGH
- Action: The test is correctly written for the intended behavior (move-on-absent-canonical, delete-misplaced-on-canonical-present, no-op-on-clean). Add `checkAndMoveMisplacedSummaries()` to `internal/stages/coder/orchestrator.go` (or a sibling file) per the m06 milestone spec. Do not modify the tests — they define the acceptance criteria accurately.

#### SCOPE: .gitignore absent from allowlist — A1/A2 assertions will fail at runtime
- File: tests/test_finalize_allows_gitignore.sh:73, :81
- Issue: Scenarios A1 and A2 assert that `.gitignore` appears in `_pipeline_bookkeeping_globs()` and that `_is_path_allowed ".gitignore"` returns 0. Inspection of `lib/finalize_commit_staging.sh:50-65` confirms `.gitignore` is NOT present in the `_pipeline_bookkeeping_globs` heredoc — the list ends with `Makefile` and contains no `.gitignore` entry. Running the test against the current implementation produces two failures. The tester's report notes "m06 Goal A unimplemented."
- Severity: HIGH
- Action: Add `.gitignore` as an explicit entry in `_pipeline_bookkeeping_globs()` in `lib/finalize_commit_staging.sh`. The tests themselves are correctly written — A3 (`.env` stays rejected) and A4 (declared file stays allowed) are still valid and will pass once A1/A2's implementation gap is filled.

---

### Passing Observations (no action required)

**internal/provider/claude/claude_test.go — PASS**

All 13 test functions are well-formed:

- *Assertion honesty*: Every assertion traces to real implementation logic. `TestProvider_Name` checks the literal `"claude"` string returned by `func (p *Provider) Name() string { return "claude" }`. Outcome integer comparisons in `TestTranslateOutcome_*` map directly to the `translateOutcome()` switch table and `IsNullRun()` precedence rule. No hard-coded magic numbers.

- *Edge case coverage*: nil request, nil supervisor, and write-prompt-file failure are all tested independently. `TestTranslateOutcome_UpstreamWithLowTurns` pins the IsNullRun-beats-ErrorCategory precedence when `turns_used ≤ DefaultNullRunThreshold` — an easy-to-miss off-by-one regression surface.

- *Implementation exercise*: `TestWritePromptFile` and `TestWritePromptFile_CleanupRemovesFile` call the real `writePromptFile` function with no mocking. `TestProvider_StreamingEvents` drives `RunAgent` end-to-end, only stubbing the supervisor.

- *Weakening check*: `TestProvider_StreamingEvents` adds two new `Timestamp.IsZero()` assertions that were absent before — this is a strengthening, not a weakening.

- *Naming*: All names encode scenario and expected outcome (`TestTranslateOutcome_UpstreamWithLowTurns`, `TestProvider_EventChan_ClosedOnWritePromptFileError`). No generic names.

- *Isolation*: `t.TempDir()` and `t.Setenv()` are used throughout. No reads of live project state.

**tests/test_finalize_allows_gitignore.sh — A3, A4, B structure are sound**

Scenarios A3 (`.env` rejected), A4 (declared `internal/foo.go` allowed), and the conditional Scenario B skeleton are correctly written with fixture isolation (temp git repo in `$(mktemp -d)`). B1/B2/B3 gracefully skip when `_do_git_commit` is unavailable. The test structure and isolation approach are correct; only the missing implementation causes A1/A2 to fail.

**internal/stages/coder/coder_summary_path_test.go — test logic is sound**

The test design is correct:
- Each case creates its own `t.TempDir()` — no shared mutable state.
- `MisplacedRootCanonicalPresent` (line 80) includes a `canonicalContent` fixture and asserts it byte-for-byte after the hook runs, catching an implementation that truncates the canonical before removing the misplaced file.
- `CleanState` (line 123) checks both root and `.tekhton/` directories for unexpected file creation.
- `CoderSummaryMisplaced` (line 159) covers `CODER_SUMMARY.md` in addition to `JR_CODER_SUMMARY.md`, matching the milestone spec.

The tests need the implementation to compile — they do not need to be rewritten.

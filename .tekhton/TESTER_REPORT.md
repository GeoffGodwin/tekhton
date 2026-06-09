## Test Audit Report

### Audit Summary
Tests audited: 4 files, 25 test functions/scripts
Verdict: PASS

### Findings

#### NAMING: loadFixture comment claims skip but implementation fatals
- File: internal/provider/claude/parity_test.go:51-52
- Issue: The comment on `loadFixture` reads "The test is skipped if the file does not exist" but the implementation calls `t.Fatalf` — the test fails hard, it does not skip. All five referenced fixture files do exist and the test passes correctly, but the misleading comment could cause a future contributor to add a fixture guard with `t.Skip` expecting graceful degradation instead of the hard-fail-on-missing contract the helper actually enforces.
- Severity: LOW
- Action: Change comment to "The test fails if the file does not exist — fixtures are required, not optional."

#### COVERAGE: StreamingEvents test does not assert Timestamp fields are non-zero
- File: internal/provider/claude/claude_test.go:64-105
- Issue: `TestProvider_StreamingEvents` verifies event Kind and Turn fields but never checks that `event.Timestamp` is non-zero. The `provider.Event.Timestamp` field is set via `time.Now()` in the implementation for all three events; a future regression that zeroed it (e.g. a struct-literal change that drops the Timestamp assignment) would not be caught by this test.
- Severity: LOW
- Action: Add `if events[i].Timestamp.IsZero() { t.Errorf(...) }` for at least the TurnStart and RunEnd events.

#### NAMING: Redundant second assertion in TestTranslateOutcome_UpstreamWithLowTurns
- File: internal/provider/claude/claude_test.go:206-209
- Issue: The assertion `if got == provider.OutcomeUpstreamError { t.Error(...) }` on line 207 is dead code in all reachable paths. It can only fire if `got != OutcomeNullRun` (line 203) also fired — but that check already records a failure, and if `got == OutcomeNullRun` the second condition is false and never triggers. The second check does not add coverage; it only adds noise to failure output if the first check fires.
- Severity: LOW
- Action: Remove the redundant second assertion; the first is sufficient and its message already explains the expected behavior.

#### ISOLATION: test_no_tracked_sentinels.sh outcome depends on live git state
- File: tests/test_no_tracked_sentinels.sh:15
- Issue: `git ls-files '.tekhton/.[!.]*'` reads live repository tracking state at run time. If the script is executed during a transition where a sentinel is temporarily tracked (e.g. during a `.gitignore` migration like the m05 fix the test itself uncovered), the test fails in a way that is not reproducible from a fixture. This is structurally different from the Go tests, which all use controlled fixtures or in-memory stubs.
- Severity: LOW
- Action: This is intentional design for a repository hygiene guard — it is correct that it reads live state. Add a comment to the script header documenting that the test is a repo-state gate (not a unit test) so future contributors understand why it cannot be fixture-isolated.

### Assertions Verified Against Implementation

All material assertions in the audited test files were verified against the
implementation and fixture data:

- `null_run.json` (exit_code=1, turns_used=1, outcome=fatal_error) → `IsNullRun()`
  returns true (turns_used=1 ≤ DefaultNullRunThreshold=2) → OutcomeNullRun ✓
- `upstream_error.json` (exit_code=1, turns_used=3, error_category=UPSTREAM) →
  IsNullRun()=false (turns=3 > threshold), CategoryUpstream branch → OutcomeUpstreamError ✓
- `max_turns_exhausted.json` (exit_code=0, outcome=turn_exhausted) →
  OutcomeTurnExhausted switch arm → OutcomeMaxTurns ✓
- `trivial_success.json` (exit_code=0, outcome=success) → OutcomeSuccess ✓
- `multi_turn_with_tools.json` (exit_code=0, outcome=success) → OutcomeSuccess ✓
- `(nil result, context.Canceled)` path → `fmt.Errorf("... %w", supErr)` wraps
  context.Canceled; errors.Is(err, context.Canceled) remains true ✓
- `(non-nil result, context.Canceled)` path → returns `(translateResult(v1), supErr)`
  directly; supErr is context.Canceled unwrapped, errors.Is works ✓
- IsNullRun precedence over CategoryUpstream in translateOutcome confirmed at
  internal/provider/claude/claude.go:149 ✓
- RawProviderData populated via `json.Marshal(v1)` on every translateResult call ✓
- CoderTools slice length 6 matches canonical.go:122 `{Read, Write, Edit, Bash, Glob, Grep}` ✓
- IntakeTools read-only contract: {Read, Glob, Grep} — none have ModifiesFiles or
  ExecutesShell ✓
- ReviewerTools contains Bash, no ModifiesFiles tools ✓
- All six canonical tool BehaviorHints match their declarations in canonical.go ✓
- defer close(req.EventChan) at claude.go:69 fires before writePromptFile —
  channel-closed-on-error test correctly pins this ordering ✓

## Test Audit Report

### Audit Summary
Tests audited: 4 files, 29 test functions
(primary: drift_integration_test.go × 4 tests;
freshness sample: architect_test.go × 9, plan_parser_test.go × 9, remediation_test.go × 7)
Verdict: PASS

### Findings

#### ISOLATION: setupFixture drift-counter format does not match drift.Log API
- File: internal/stages/architect/architect_test.go:61-86
- Issue: `setupFixture` writes the audit counter in the format
  `## Audit Counter\n\nruns_since_audit: 6\nlast_audit: never`. The comment in
  `drift_integration_test.go:64-66` explicitly documents that the canonical format
  is `- Runs since audit: N` under a `## Metadata` list (title-case, space-separated,
  dash-list item) to match the regex in `drift.Log.GetRunsSinceAudit`. The two
  formats diverge: `setupFixture` uses a lowercase underscore key in a different
  section header. In tests that use `setupFixture` (all nine tests in architect_test.go),
  `resetAuditCounter` calls `drift.NewLog.ResetRunsSinceAudit()`, which returns an
  error it cannot parse; the error is swallowed by the `|| true`-style guard in
  `resetAuditCounter`; the counter is never updated; and no assertion in
  `architect_test.go` checks the counter value, so the silent failure is invisible.
  `CountUnresolved()` is unaffected because both formats use standard `- [ ]`
  items under `## Unresolved Observations`. The `drift_integration_test.go` tests
  were added to fill this gap, which is good — but the root inconsistency in
  `architect_test.go`'s fixture helper remains.
- Severity: MEDIUM
- Action: In `setupFixture`, replace the `## Audit Counter\n\nruns_since_audit: ...`
  block with `## Metadata\n- Last audit: never\n- Runs since audit: N\n`,
  matching the format in `writeDriftLogWithCounter`. This ensures `resetAuditCounter`
  is genuinely exercised (not silently skipped) in architect_test.go tests. No
  new counter-value assertions are needed in that file; drift_integration_test.go
  already owns those.

#### COVERAGE: SimplificationScenario omits total agent-call count assertion
- File: internal/stages/architect/drift_integration_test.go:193-209
- Issue: `TestRunStage_FullAuditPath_SimplificationScenario` asserts sr and jr
  dispatch counts by label but does not assert total `len(a.calls)`. The baseline
  plan produces 4 calls (architect + sr + jr + expedited reviewer). A spurious
  extra agent call would not be caught here. The parallel test in
  `architect_test.go:130` asserts `len(a.calls) == 4` for the same scenario, so
  the suite has coverage — but the integration test that was added to close parity
  gaps does not replicate it, leaving the integration scenario weaker than the
  unit test for this one property.
- Severity: LOW
- Action: Add `if len(a.calls) != 4 { t.Errorf("agent calls: want 4 (arch+sr+jr+review), got %d (%v)", len(a.calls), labels(a.calls)) }` after the sr/jr count assertions.

#### NAMING: Dead `a.err = nil` assignment in UpstreamErrorReturnsPass
- File: internal/stages/architect/architect_test.go:271
- Issue: `TestRunStage_UpstreamErrorReturnsPass` calls `withStubs(t)` to install a
  `*fakeAgent` as `a`, then on the very next line sets `a.err = nil` (a no-op —
  the zero value), then immediately replaces the agent runner with `&upstreamAgent{}`
  via `SetAgentRunner`. The variable `a` is never read again. The comment "Force
  the architect agent to return an UPSTREAM-classified result" correctly describes
  `upstreamAgent`, not `a.err`. The dead line suggests an abandoned approach that
  was not cleaned up.
- Severity: LOW
- Action: Remove `a.err = nil` and change `a, _, _ := withStubs(t)` to `_, _, _ =
  withStubs(t)` (keeping withStubs to restore the build-gate and TUI seams), or
  drop `withStubs` and register only the agent cleanup. Either way eliminates the
  misleading dead assignment.

---

### Passing Rubric Points

**Assertion Honesty — PASS.**
All numeric assertions in `drift_integration_test.go` are traceable to implementation
logic. OOS count of 1 follows from applying `oosFilters` to plan_baseline.md's Out
of Scope section: "Refactor the orchestrate retry loop..." passes all four patterns;
"No items remain in the security domain." is dropped by `(?i)^No (items?|observations?)\b`;
"None" is dropped by `(?i)^None\b`. HA count of 2 follows from applying `designDocFilters`
to plan_baseline.md's Design Doc Observations: the first two bullets survive; the last
three are dropped by the HUMAN_ACTION, route-to-human, and All-observations-documented
patterns respectively. Post-resolve drift count of 1 follows from resolve-all (5→0) +
AppendEntries (re-add 1 OOS). Build-broken drift count of 2 follows from the early
return before step 5 (no ResolveAllObservations called). No magic constants.

**Implementation Exercise — PASS.**
Tests call `RunStage` directly with real `drift.NewLog` / `drift.NewHumanAction`
implementations. Only the non-deterministic boundaries are stubbed (supervisor via
`fakeAgent`, build gate via `fakeBuildGate`, TUI via `fakeTUI`). The full audit-path
code — plan parsing, filter chains, drift resolution, OOS re-add, human action
surfacing, audit counter reset — executes unconditionally in all four tests.

**Test Weakening — N/A.**
`drift_integration_test.go` is a new file. No existing tests were modified.

**Test Naming — PASS.**
All four functions in the primary file encode scenario and expected outcome:
`_SimplificationScenario`, `_JrWorkOnlyScenario`, `_DesignDocOnlyScenario`,
`_BuildBroken_DriftUnchangedCounterReset`. Freshness sample follows the same convention.

**Scope Alignment — PASS.**
Agent label strings asserted in `drift_integration_test.go` ("Coder (architect
remediation)", "Jr Coder (architect remediation)") match exactly what `runRework`
sets in `remediation.go:36-37`. Exit-reason strings ("audit_complete", "build_broken")
match `passResult` calls in `architect.go`. Fixture filenames match `config.go` field
names. No orphaned references.

**Test Isolation — PASS (drift_integration_test.go).**
All fixture directories created via `t.TempDir()`. All env overrides applied via
`t.Setenv()` (auto-restored). No reads from live build reports, pipeline logs, causal
logs, `.claude/logs/*`, or other mutable project-state files. The MEDIUM finding above
applies to `architect_test.go` (freshness sample), not to the primary audit file.

**plan_parser_test.go — PASS.**
Nine tests with good edge case coverage: empty input, nil reader, multiline bullet
joining, None placeholder detection, and per-pattern filter verification. All fixtures
are inline strings or checked-in testdata files (static source, not run artifacts).
Named descriptively. No issues.

**remediation_test.go — PASS.**
Seven tests covering sr/jr model routing, turn-budget arithmetic (CoderMaxTurns/3
integer division, clamp-to-1), unknown-kind error propagation, and error forwarding.
Uses `withFakeAgent` to record calls without invoking the real supervisor. Label,
model, MaxTurns, and AllowedTools are each asserted individually. Named descriptively.
No issues.

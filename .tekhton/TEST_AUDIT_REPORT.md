## Test Audit Report

### Audit Summary
Tests audited: 4 files, 37 test functions
(classify_test.go: 17, recovery_test.go: 4, agent_test.go: 11, diagnose_test.go: 11;
table-driven cases within a single function counted as one function each)
Verdict: PASS

### Findings

#### COVERAGE: TestPatterns_Indexed is a minimal registry smoke test
- File: internal/errors/classify_test.go:171
- Issue: `TestPatterns_Indexed` only asserts `len(terr.Patterns()) != 0` (non-empty
  registry). A registry accidentally reduced to a single garbage entry would still
  pass. Pattern correctness is implicitly covered by the routing tests that exercise
  specific patterns (TS2304, ECONNREFUSED, etc.), but there is no explicit spot-check
  verifying that a known entry has the correct Category, Safety, or Regex.
- Severity: LOW
- Action: Optional — add an assertion that a well-known entry (e.g., `error TS[0-9]+:`
  with Category=code) is present and compiled correctly. The existing routing tests
  provide sufficient implicit coverage; this is not urgent.

#### COVERAGE: TestDiagnoseClassify_AllMode asserts pipe count only
- File: cmd/tekhton/diagnose_test.go:130
- Issue: The `--mode all` integration test verifies each output line has exactly
  3 pipes (4 fields) but does not assert field content. An implementation emitting
  `x|y|z|w` for every line would pass. Field-level content is already validated at
  the unit level in `classify_test.go::TestClassifyAll_FormatAllLegacy` and
  `TestClassifyAll_UnmatchedSentinel`, so no functional coverage gap exists.
- Severity: LOW
- Action: Optional — assert at least one output line begins with a known category
  token (e.g., `service_dep|`) to give the integration layer an independent signal
  against regressions in `--mode all` output content.

#### NAMING: TestClassifyAgent_AgentScope uses sequential assertions instead of sub-tests
- File: internal/errors/agent_test.go:85
- Issue: Six distinct agent-scope scenarios (null_activity_timeout, activity_timeout,
  null_run, max_turns, no_summary, scope_unknown) are exercised with sequential
  assertions and inline comments rather than `t.Run(…)` sub-tests. A single failure
  halts all remaining checks in the function, and `go test -run` cannot target
  individual scenarios.
- Severity: LOW
- Action: Refactor into table-driven `t.Run` sub-tests matching the pattern used
  in `TestClassifyAgent_Upstream`. The assertions themselves are correct; only the
  structure needs updating.

---

### Per-File Rubric Notes

#### internal/errors/classify_test.go (17 test functions)

**1. Assertion Honesty — PASS**
All assertions derive from actual function calls with meaningful inputs.
- `IsNonDiagnosticLine` allow-list and deny-list cases trace directly to
  `failureTermRE` and `noiseLineREs` in `classify.go:30–46`.
- Routing tokens (`RouteCodeDominant`, `RouteNoncodeDominant`, `RouteMixedUncertain`,
  `RouteUnknownOnly`) are the package constants, not string literals.
- Threshold boundary tests (50% below, 60% at) exercise the
  `NoncodeConfidenceThreshold = 60` constant and the integer division in
  `ClassifyRoutingDecision:296–299`.
- `FormatStatsLegacy` and `FormatAllLegacy` pipe counts (7 and 3 respectively)
  match the `fmt.Sprintf` field counts in `classify.go:138,260`.
- The unmatched sentinel values (`Category: "code"`, `Diagnosis: "Unclassified
  build error"`) appear verbatim in `ClassifyAll:238–242`.

**2. Edge Case Coverage — PASS**
Empty inputs exercised for `HasExplicitCodeErrors`, `HasOnlyNoncodeErrors`,
`ClassifyAll`, and `ClassifyRoutingDecision`. Code+noise mixes, unmatched sentinel
records, BiflShape (env-only + unrecognised noise), and both sides of the 60%
threshold are covered. M127 invariant (unmatched lines must not pollute `ClassifyWithStats`
with a "code" record) is explicitly asserted.

**3. Implementation Exercise — PASS**
All tests call the real Go functions. No mocking.

**4. Weakening — N/A** (file is new)

**5. Test Naming — PASS**
Names encode scenario and expected outcome throughout (e.g.,
`TestClassifyRoutingDecision_NoncodeJustBelowThreshold`,
`TestHasOnlyNoncodeErrors_BiflShape`, `TestClassifyAll_UnmatchedSentinel`).

**6. Scope Alignment — PASS**
No reference to deleted bash files. All imports target `internal/errors` at the
correct import path.

**7. Test Isolation — PASS**
All inputs are inline string literals. No reads from mutable project files.

---

#### internal/errors/recovery_test.go (4 test functions)

**1. Assertion Honesty — PASS**
All 27 (category, subcategory) pairs in `SuggestRecovery` are exercised across
`TestSuggestRecovery_KnownPairs` and `TestSuggestRecovery_RemainingPairs`. Each
`contains` substring appears verbatim in the corresponding `case` return value in
`recovery.go:11–77`. The context-interpolation test verifies both the filled path
(`/tmp/PIPELINE_STATE.md`) and the default path (`.claude/PIPELINE_STATE.md`),
both of which trace to the same `case "PIPELINE/state_corrupt"` block. No hard-coded
constants unrelated to the implementation.

**2. Edge Case Coverage — PASS**
Every known pair is covered; the unknown-pair fallback (`WHATEVER/unknown`) and the
empty-subcategory path are exercised. State-corrupt context interpolation is tested
with and without the optional argument.

**3–7 — PASS** (new file, no mocking, no isolation issues, descriptive names, all
package references correct)

---

#### internal/errors/agent_test.go (11 test functions)

**1. Assertion Honesty — PASS**
All expected subcategory strings (`api_rate_limit`, `oom`, `null_run`, etc.) are the
values emitted by the corresponding `AgentClassification` struct literals in
`agent.go:100–190`. The `FormatLegacy` pipe-field count (4) and `parts[2] == "true"`
for OOM both trace to `FormatLegacy:31–36`. `IsKnownAgentSubcategory` assertions
match `knownAgentSubcategories` map in `agent.go:251–256`. The `capHead` truncation
test places the rate-limit JSON signal within the first 65536 bytes and verifies
survival — consistent with `capHead(opts.Stderr, 65536)` at `agent.go:96`.

**2. Edge Case Coverage — PASS**
Both transient and non-transient UPSTREAM variants, all five ENVIRONMENT triggers,
both exit-124 timeout branches (turns=0 vs turns>0), null_run vs max_turns vs
no_summary vs scope_unknown, all four PIPELINE patterns, SIGSEGV (exit 139),
Anthropic-hint fallback, and generic internal fallback are covered. `IsTransient`
is tested for all meaningful combinations including false-positives (disk_full,
service_dep not transient).

**3–7 — PASS** (new file, real implementations, descriptive names, correct package
references, no mutable file reads). See LOW naming finding above for
`TestClassifyAgent_AgentScope`.

---

#### cmd/tekhton/diagnose_test.go (11 test functions)

**1. Assertion Honesty — PASS**
`runDiagnose` drives the real Cobra command tree via `newRootCmd()` with in-memory
buffers. Exit codes are extracted via the concrete `errExitCode` type (same package).
All routing token assertions, pipe counts, and substring checks trace directly to the
implementation behavior verified in unit tests above. `TestDiagnoseRedact` verifies
`sk-ant-test` is absent after redaction — consistent with `redactSKAntRE` replacing
`sk-ant-[A-Za-z0-9_-]*` in `redact.go:24`.

**2. Edge Case Coverage — PASS**
All five `diagnose` subcommands exercised. Both exit-code paths for `--has-code`
and `--has-only-noncode` tested. All five `--mode` values (routing, stats, all,
filter-code, annotate) exercised. Unknown `--mode` error path tested. `is-transient`
tested for both transient and non-transient cases.

**3. Implementation Exercise — PASS**
All tests use the real Cobra command dispatch path. No internal function is mocked.

**4. Weakening — N/A** (file is new)

**5. Test Naming — PASS**
All names encode the subcommand, flag, or mode under test and the expected outcome
(e.g., `TestDiagnoseClassify_UnknownModeExits`, `TestDiagnoseClassify_HasOnlyNoncode`).

**6. Scope Alignment — PASS**
`diagnose_test.go` is in `package main`, giving it access to unexported types
(`errExitCode`, `newRootCmd`) without any import of deleted bash files. The
`classify-agent` subcommand is tested via `--exit 137` (not `--stderr-file`), which
is correct: the file-path flags are optional and the test exercises the in-memory path.

**7. Test Isolation — PASS**
All inputs are inline strings passed via `strings.NewReader`. No reads from
`.tekhton/`, `.claude/`, or any mutable pipeline artifact.

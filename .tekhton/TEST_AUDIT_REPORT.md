## Test Audit Report

### Audit Summary
Tests audited: 1 modified file (internal/supervisor/retry_test.go — 5 new test functions,
audited against retry.go); 2 freshness-sample files (internal/dag/validate_test.go —
9 functions; tests/test_clarify_coder_nullrun.sh — shell unit suite).
Verdict: CONCERNS

### Findings

#### SCOPE: Coder-authored tests lack independent tester review
- File: internal/supervisor/retry_test.go:181-238
- Issue: The tester report claims exactly 1 new test (`TestRetryPolicy_Delay_BaseDelayZeroOverridesConfiguredFloor`). The actual file contains 5 new tests. The other 4 — `TestRetry_MaxAttemptsZero_Errors`, `TestRetry_MaxAttemptsNegative_Errors`, `TestRetryPolicy_Delay_BaseDelayZeroReturnsZero`, `TestRetryPolicy_Delay_BaseDelayNegativeReturnsZero` — were authored by the coder alongside the implementation they exercise. The tester ran `go test ./...` but did not independently review those 4 tests for quality or correctness. Separately, `cmd/tekhton/state_cmd_test.go` (7 new tests covering state update/clear/read) was written entirely by the coder and is absent from the tester's scope. The tests are substantively correct on inspection (see rubric notes below), so this is a process gap, not a correctness failure.
- Severity: MEDIUM
- Action: On the next cycle touching these files, the tester should perform an independent integrity pass over the 4 coder-written retry tests and the 7 state-cmd tests. No code changes are needed now.

#### SCOPE: cmd/tekhton/state_cmd_test.go absent from audit context
- File: cmd/tekhton/state_cmd_test.go (new, untracked per git status)
- Issue: This file (159 lines, 7 test functions) was listed by the coder as a deliverable but was not provided in the "Test Files Under Audit (modified this run)" list. Per audit rules, findings cannot be raised against unlisted files. Flagging as a coverage gap so the next cycle includes it in scope.
- Severity: LOW
- Action: Add cmd/tekhton/state_cmd_test.go to the test audit scope on the next cycle that modifies cmd/tekhton/.

#### SCOPE: Shell-detected STALE-SYM entries are false positives
- File: internal/supervisor/retry_test.go
- Issue: The orphan detector flagged `append`, `len`, and `make` as symbols "not found in any source definition." These are Go built-ins; they have no source definition in the repo. `cancel` is a local variable returned from `context.WithCancel` at line 251 — it is not a package-level symbol. The shell scanner does not model Go's built-in namespace or local variable scoping.
- Severity: LOW
- Action: Dismiss all four STALE-SYM entries. No test changes needed.

---

## Per-File Rubric Notes

### internal/supervisor/retry_test.go

**1. Assertion Honesty — PASS**
All five new test assertions are derived directly from implementation behavior:
- `TestRetry_MaxAttemptsZero_Errors` checks `strings.Contains(err.Error(), "MaxAttempts must be > 0")`. Implementation (retry.go:161): `fmt.Errorf("supervisor: MaxAttempts must be > 0, got %d", p.MaxAttempts)`. Substring match is correct and non-trivial.
- `TestRetry_MaxAttemptsNegative_Errors` uses `MaxAttempts: -3`; same guard fires.
- `TestRetryPolicy_Delay_BaseDelayZeroReturnsZero` asserts `p.Delay(1,"") == 0` and `p.Delay(5,"api_rate_limit") == 0` when `BaseDelay: 0`. Implementation (retry.go:59-61): `if p.BaseDelay <= 0 { return 0 }`. The early return precedes all other computation; the second call with a floor subcategory tests the ordering explicitly.
- `TestRetryPolicy_Delay_BaseDelayZeroOverridesConfiguredFloor` sets `Floors["api_rate_limit"]=60s` and `BaseDelay=0`, asserts result is 0. Implementation fires the early-return at retry.go:59 before the Floors map lookup at retry.go:76-81. Test correctly models execution order.
- `TestRetryPolicy_Delay_BaseDelayNegativeReturnsZero` uses `BaseDelay: -1*time.Second`. Same guard fires. No hard-coded magic values unconnected to implementation logic anywhere in the suite.

**2. Edge Case Coverage — PASS**
New tests cover: MaxAttempts=0 (boundary), MaxAttempts=-3 (below boundary), BaseDelay=0 (zero), BaseDelay<0 (negative), floor interaction when BaseDelay=0. Ratio of error-path tests to happy-path tests across the full suite is approximately 3:1. Adequate.

**3. Implementation Exercise — PASS**
Tests call `retryLoop` and `p.Delay` directly (same package). `fakeRunner` stubs only the agent-invocation seam; all retry-loop control flow is real. `instantAfter` stubs only the clock seam; the select/cancel logic is real.

**4. Test Weakening Detection — PASS**
No existing test bodies were modified. All changes are additive (new test functions appended after line 238).

**5. Test Naming — PASS**
All five new function names encode both the scenario and the expected outcome (`_Errors`, `_ReturnsZero`, `_OverridesConfiguredFloor`). Consistent with the pre-existing naming convention in the file.

**6. Scope Alignment — PASS**
All references to `retryLoop`, `RetryPolicy`, `Delay`, `DefaultPolicy`, and sentinel errors (`ErrUpstreamRateLimit`, `ErrUpstreamAuth`, `ErrQuotaExhausted`, `ErrQuotaPauseCapped`, `ErrUpstreamUnknown`) are present in retry.go. No stale symbols. The deleted `.tekhton/INTAKE_REPORT.md` is not referenced by any audited test.

**7. Test Isolation — PASS**
Causal log tests create a temp dir via `t.TempDir()` (line 378). Agent behavior is stubbed via `fakeRunner`. Clock is stubbed via `instantAfter`. No test reads from live pipeline state files, build reports, or mutable project artifacts.

---

### internal/dag/validate_test.go (freshness sample)

Fixtures are inline string literals, not live manifest files. `loadFixture` and `writeFile` use isolated temp directories. Assertions check typed errors via `errors.Is` (`ErrMissingDep`, `ErrCycle`, `ErrDuplicateID`), not string parsing. File not modified this run; no scope drift. PASS on all rubric points.

### tests/test_clarify_coder_nullrun.sh (freshness sample)

`TEKHTON_HOME` is derived from the script's own path (not a global). `TMPDIR` is isolated per-run with `mktemp -d` and cleaned up via `trap ... EXIT`. No reads from live `.tekhton/` state files, build reports, or pipeline logs. Not modified this run; no scope drift. PASS on all rubric points.

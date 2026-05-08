## Test Audit Report

### Audit Summary
Tests audited: 1 file, 4 test functions (14 test cases total — 11 table-driven in TestPipelineRequestValidate + 3 top-level)
Verdict: PASS

### Findings

#### COVERAGE: TestPipelineRoundTrip verifies only 2 of 9+ populated result fields
- File: internal/proto/pipeline_v1_test.go:171
- Issue: `TestPipelineRoundTrip` marshals a `PipelineAttemptResultV1` with 9 populated fields but only asserts `len(out.Stages) == 3` and `out.Stages[1].NextAction == "rework"`. Post-unmarshal, `out.Proto`, `out.Outcome`, `out.Verdict`, `out.AgentCalls`, `out.DurationSec`, `out.Stages[0].Verdict`, `out.Stages[2].ReviewCycle`, and `out.Stages[2].Verdict` are not verified. A mismatched JSON tag on any unverified field would go undetected.
- Severity: MEDIUM
- Action: Add assertions for `out.Proto`, `out.Outcome`, `out.Verdict`, `out.AgentCalls`, `out.DurationSec`, and at least one field from the first and third stage entries. The round-trip test's value is catching tag/type mismatches — partial coverage undermines that goal.

#### COVERAGE: TestPipelineRequestMarshalIndented skips 3 of 8 populated fields
- File: internal/proto/pipeline_v1_test.go:124
- Issue: The test populates `ReviewCycle: 1`, `BuildAttempt: 0`, and `ProjectDir: "/tmp/proj"` but never asserts `out.ReviewCycle`, `out.BuildAttempt`, or `out.ProjectDir` after unmarshaling. A missing or misspelled JSON tag on any of these fields would not be caught.
- Severity: LOW
- Action: Add `out.ReviewCycle != in.ReviewCycle`, `out.BuildAttempt != in.BuildAttempt`, and `out.ProjectDir != in.ProjectDir` assertions.

#### COVERAGE: TestPipelineEnsureProto only tests the stamp-when-empty path
- File: internal/proto/pipeline_v1_test.go:158
- Issue: Both `EnsureProto` implementations guard with `if r.Proto == ""`. The test only calls `EnsureProto` on a zero-value struct and verifies the proto is stamped. The no-op path — where proto is already set and must not be overwritten — is not tested.
- Severity: LOW
- Action: Add a second subcase that pre-sets `r.Proto = "something-else"` and asserts `EnsureProto` leaves it unchanged.

#### COVERAGE: "review_cycle" want substring is ambiguous against "max_review_cycles" error text
- File: internal/proto/pipeline_v1_test.go:57
- Issue: The "negative review cycle" case uses `want: "review_cycle"` as the expected error substring (checked via `strings.Contains`). The string `"review_cycle"` is also a substring of `"max_review_cycles must be >= 0"`. In the current implementation this is harmless — `ReviewCycle` is validated before `MaxReviewCycles` and the test case leaves `MaxReviewCycles` at 0 — but the assertion would spuriously pass if the wrong validation branch fired. The sibling case "negative max_review_cycles" correctly uses the unambiguous `want: "max_review_cycles"`.
- Severity: LOW
- Action: Tighten to `want: "review_cycle must be"` to distinguish from the `max_review_cycles` error path.

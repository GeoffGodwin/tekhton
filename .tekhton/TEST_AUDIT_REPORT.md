## Test Audit Report

### Audit Summary
Tests audited: 4 files, 37 test functions
- `internal/intake/helpers_test.go` — 20 functions (PRIMARY — modified this run; 18 by coder, 2 added by tester)
- `internal/intake/verdict_test.go` — 12 functions (freshness sample)
- `cmd/tekhton/intake_test.go` — 5 functions (freshness sample)
- `internal/supervisor/decoder_test.go` — unrelated to m36.2 (freshness sample, no scope issues)

Verdict: PASS

### Findings

#### INTEGRITY: Weak assertion in TestHandleTweakedNonMilestone
- File: internal/intake/verdict_test.go:327
- Issue: The test asserts only `v.Task == ""` (i.e., Task is non-empty) after `HandleTweaked` in non-milestone mode. It does not verify the content of `v.Task`. `ParseTweaks("testdata/report_tweaked.md")` returns the `## Tweaked Content` block; `ApplyTweakTask` then sets `v.Task` to the first non-empty line (`"# m99.9 — Test Milestone (PM-tweaked)"`). A regression that set Task to any non-empty string — including whitespace or a stale value — would pass this check. The full round-trip is exercised by `TestApplyTweakTask`, but this test leaves the caller-level assertion underconstrained.
- Severity: MEDIUM
- Action: Replace `if v.Task == ""` with a content-specific check such as `if !strings.Contains(v.Task, "m99.9")` to pin the actual extracted value.

#### COVERAGE: MilestoneFileResolver alternate-lookup path in ApplyTweakMilestone untested
- File: internal/intake/helpers_test.go (missing test)
- Issue: `ApplyTweakMilestone` contains a resolver fallback at helpers.go:221-226 — when `msNum + ".md"` does not exist in MilestoneDir, it calls `h.MilestoneFileResolver(msNum)` to find the real filename. No test exercises this branch. The only resolver-seam test is `TestMilestoneContent_DAGFile`, which covers `MilestoneContent`, not `ApplyTweakMilestone`. A regression in the resolver dispatch for the apply path would surface only at runtime via the bash passthrough tests, not in the Go unit suite.
- Severity: LOW
- Action: Add a test that sets `h.MilestoneFileResolver` to return a known filename (e.g. `"m99.9-verbose-title.md"`) and calls `ApplyTweakMilestone` with the numeric ID `"m99.9"` against a MilestoneDir that has the verbose-title file but not `m99.9.md`; assert the resolver-found file is written and backed up correctly.

#### NAMING: Unreachable `return` after `t.Skipf` in TestBashShimDoesNotRedefineStrings
- File: internal/intake/verdict_test.go:275
- Issue: `t.Skipf(...)` calls `runtime.Goexit()` internally; the `return` on the immediately following line is unreachable dead code. This suggests a misunderstanding of `t.Skipf` vs. a normal early-return guard, and is mildly misleading to future readers.
- Severity: LOW
- Action: Remove the `return` statement. No behavior change; `t.Skipf` already terminates the goroutine.

#### COVERAGE: TestExtractInlineMilestoneBlock_H6DoesNotStop pins gap behavior without a discoverable marker
- File: internal/intake/helpers_test.go:371
- Issue: The test correctly documents that `inlineHeadingRE = ^#{1,5}\s` does not match H6, so H6 headings do not stop inline milestone extraction. The comment is clear, but there is no `t.Log` statement or similar mechanism that surfaces the gap in verbose test output (`go test -v`). If a developer later fixes the regex, the test will fail in the non-obvious direction (the H6 line would no longer be present in the output), which could be misread as a test failure rather than a gap closure.
- Severity: LOW
- Action: Add `t.Log("known gap: inlineHeadingRE ^#{1,5}\\s does not match H6 — fix will break this test intentionally")` so the gap is visible under `-v` and easily searchable.

### Scope Alignment (freshness sample)

- `internal/intake/verdict_test.go` — fully aligned. All referenced symbols (`ErrHalt`, `MsgTweaksRejected`, `MsgClarifyCompleteHalt`, `VerdictHandler`, `ErrTweakRejected`, `pinTimestamp`) exist in the current `internal/intake/` package. Testdata fixture paths match the files present under `testdata/`. Golden-file comparison normalizes timestamps via regex before diffing — robust against time-of-day variation. No orphaned references.
- `cmd/tekhton/intake_test.go` — fully aligned. `newIntakeCmd()` is registered in `cmd/tekhton/main.go`. `buildTekhtonBinary` is shared via `cmd/tekhton/security_test.go` (same `package main` test binary). Fixture paths resolve correctly relative to the test binary CWD. No orphaned references.
- `internal/supervisor/decoder_test.go` — not touched by m36.2; no scope issues introduced.

### Passing Rubric Points

**Assertion Honesty — PASS.**
All numeric and string assertions are derived from real implementation behavior or testdata fixtures. Size-guard thresholds (50%, 20-line floor) match `ApplyTweakMilestone` parameters. Confidence values (95, 60, 100) match fixture file content and clamp logic in `ParseConfidence`. Hash value in `TestContentHash` and `TestIntakeCmd_ContentHash` is the standard SHA-256 of `"hello world"` produced by Go's `crypto/sha256` — not a fabricated constant. PipelineState arg ordering in `TestRejectionMessageByteIdentity` matches the literal call at verdict.go:163-165.

**Implementation Exercise — PASS.**
Tests call real `Helpers` and `VerdictHandler` methods. `newTestHelpers` wires a real temp-dir Helpers struct; only non-deterministic boundaries (stdin, timestamps, dates) are overridden via package-level var seams. No test mocks the function under test.

**Test Weakening — N/A.**
The two tests added by the tester (`TestExtractInlineMilestoneBlock_H6DoesNotStop` and `TestAddPMMetadata_UnclosedMetaBlockFallback`) are appended to the end of `helpers_test.go`. No existing assertions were removed or broadened.

**Test Naming — PASS.**
All test names encode scenario and expected outcome: `_SizeGuardReject`, `_SizeGuardAccept`, `_SmallMilestoneNoGuard`, `_InsertAfterMetaBlock`, `_InsertAfterFirstLine`, `_UpdateExisting`, `_DAGFile`, `_InlineFallback`, `_NonMilestoneMode`, `_H6DoesNotStop`, `_UnclosedMetaBlockFallback`.

**Test Isolation — PASS.**
All tests use `t.TempDir()` for mutable state or checked-in `testdata/` for fixtures. `TestBashShimDoesNotRedefineStrings` reads checked-in source files (`lib/intake_helpers.sh`, `lib/intake_verdict_handlers.sh`), not pipeline run artifacts — this is acceptable. No test reads `.tekhton/*.md`, `.claude/logs/*`, or any other mutable project-state file.

# Non-Blocking Notes Log

Accumulated reviewer notes that were not blocking but should be addressed.
Items are auto-collected from `## Non-Blocking Notes` in REVIEWER_REPORT.md.
The coder is prompted to address these when the count exceeds the threshold.

## Open
- [ ] [2026-05-08 | "Implement Milestone 19: tekhton run Top-Level Command"] `runner.go:251` (`BashHookRunner.Finalize`): `res.Disposition` is dereferenced at line 251 before the `if res != nil` guard at line 253, making the guard unreachable dead code. Both callers pass non-nil `res`, so no runtime risk, but the guard is misleading. Promote it above the env-append block or remove it. (Carried from cycle 1; rework did not touch this path.)
- [ ] [2026-05-08 | "Implement Milestone 19: tekhton run Top-Level Command"] `resume.go:74` (`isCompleteLoopExit`): manual `len+slice` comparison still used instead of `strings.HasPrefix(exit, "complete_loop_")`. No correctness impact. (Carried from cycle 1.)
- [ ] [2026-05-08 | "Implement Milestone 19: tekhton run Top-Level Command"] `run.go` switch: `--dry-run` flag is accepted and stored in `RunRequestV1.DryRun` but the RunE dispatch switch has no dry-run branch — `tekhton run --task "x" --dry-run` will invoke agents for real. A comment at the dispatch switch noting this as deferred scope (m20 / Phase 5) would prevent future confusion. (Carried from cycle 1.)
- [ ] [2026-05-08 | "M18"] `cmd/tekhton/stage.go:86` — `_ = json.RawMessage(b)` is a no-op whose sole purpose is keeping the `encoding/json` import alive. The import is not otherwise needed in stage.go (json marshaling lives inside the proto methods). Remove the no-op and the import together; the file compiles and tests pass without them.
- [ ] [2026-05-08 | "M18"] `internal/pipeline/runner.go:279` — `runReviewLoop`'s `for {}` loop always exits on the first iteration via one of three unconditional `return` statements (lines 285, 288, 296, 302). The loop construct suggests in-process iteration is possible but the comment on lines 298–302 explains it never happens. A plain function body without the `for {}` would match the actual semantics and avoid future confusion.
- [ ] [2026-05-08 | "M18"] `cmd/tekhton/stage_test.go:14` — `TestStageEmitToStdout` discards captured output (`_ = out`) and only asserts no error is returned. The envelope content emitted to stdout is unverified. The `--to-result-file` path is well-covered by `TestStageEmitToResultFile`; consider extending this test to assert the stdout JSON shape.

## Resolved

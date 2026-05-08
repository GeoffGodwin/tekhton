# Reviewer Report — M18 Pipeline Runner + Stage Adapter

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- `cmd/tekhton/stage.go:86` — `_ = json.RawMessage(b)` is a no-op whose sole purpose is keeping the `encoding/json` import alive. The import is not otherwise needed in stage.go (json marshaling lives inside the proto methods). Remove the no-op and the import together; the file compiles and tests pass without them.
- `internal/pipeline/runner.go:279` — `runReviewLoop`'s `for {}` loop always exits on the first iteration via one of three unconditional `return` statements (lines 285, 288, 296, 302). The loop construct suggests in-process iteration is possible but the comment on lines 298–302 explains it never happens. A plain function body without the `for {}` would match the actual semantics and avoid future confusion.
- `cmd/tekhton/stage_test.go:14` — `TestStageEmitToStdout` discards captured output (`_ = out`) and only asserts no error is returned. The envelope content emitted to stdout is unverified. The `--to-result-file` path is well-covered by `TestStageEmitToResultFile`; consider extending this test to assert the stdout JSON shape.

## Coverage Gaps
- `internal/proto` package is at 67.2% (no milestone minimum). The `PipelineAttemptRequestV1.Validate` negative paths (missing `project_dir`, bad stage in `order`, negative counters) have no test coverage in `pipeline_v1_test.go`; add a table-driven validate test mirroring the `stage_v1_test.go` pattern.

## ACP Verdicts
- ACP-1: AC #3 / AC #4 — bash deletions deferred to m19 + m20 — **ACCEPT** — The deferral argument is technically sound on all five dependency axes: (1) `lib/gates.sh::run_build_gate` is a 5-phase gate with UI and dependency-constraint phases that have no Go counterpart yet; (2) 15 stage-side bash callers still depend on `run_build_gate` and remain the canonical implementation; (3) `_handle_pipeline_success/failure` depend on bash-only functions that are explicitly m19's port target; (4) `_run_pipeline_stages` lives in `tekhton.sh` not the milestone-named file; (5) `run_completion_gate` is in `lib/gates_completion.sh`, not `lib/gates.sh`. The bash files are not yet redundant — Rule 9 triggers when the Go side is complete and all callers migrated, not before. The carrier milestones (m19 for `lib/orchestrate_iteration.sh` deletion, m20 for `lib/gates.sh` deletion + entry-point flip) are authored.

## Drift Observations
- `internal/pipeline/runner.go:279` — `runReviewLoop`'s dead loop body (see Non-Blocking Note above) may attract future developers who add a second iteration without realizing the outer loop owns coder reruns. A short doc comment on the function stating "returns after exactly one review run" would guard against this drift.

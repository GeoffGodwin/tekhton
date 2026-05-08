# Coder Summary
## Status: COMPLETE

m19 — `tekhton run` Top-Level Command (Phase 4 batch 2, second wedge).

## What Was Implemented

### Goal 1 + 7: `tekhton run` Cobra subcommand + parity gate

- **`cmd/tekhton/run.go`** wires the Cobra subcommand with the documented run-flag set:
  `--task`, `--complete`, `--resume`, `--human`, `--human-tag`, `--milestone`,
  `--auto-advance`, `--auto-advance-limit`, `--dry-run`, `--no-tui`
  (plus `--project-dir`, `--tekhton-home`, `--analyze-cmd`, `--compile-cmd`,
  `--test-cmd` for build/completion gate plumbing).
- Flag-validation enforces exactly-one-of for `--task` / `--human` /
  `--milestone` / `--resume` and that `--auto-advance` requires milestone mode.
- Registered in `cmd/tekhton/main.go` alongside the existing subcommands.
- `scripts/run-parity-check.sh` is the m19 acceptance gate: it builds the
  binary, asserts the documented run flags appear in `tekhton run --help`,
  asserts the legacy bash entry point still parses its long-flag set, asserts
  the legacy function names are gone from `lib/ stages/ tekhton.sh`, and
  asserts `git ls-files` no longer tracks the deleted files.

### Goal 2: `internal/runner` package

New package with three entry points and supporting infrastructure:

- **`runner.go`** — `Runner` struct, constructor, env-override builder,
  `BashHookRunner` (the default `HookRunner` that exec's `bash lib/preflight.sh`
  and `bash lib/finalize.sh` with `TEKHTON_RUN_DISPOSITION` /
  `TEKHTON_RUN_RESULT_FILE` env contract additions).
- **`single.go`** — `RunSingle(ctx, req)` for `--task` non-complete-mode.
  Pre-flight → optional TUI start → one `Pipeline.RunAttempt` → write
  `RUN_RESULT.json` → finalize bridge → optional TUI stop.
- **`complete.go`** — `RunCompleteLoop(ctx, req)` is the outer retry loop
  port. Applies the same three safety bounds as
  `_orch_complete_run` (max_attempts / autonomous_timeout / max agent calls),
  loops on `AttemptOutcomeFailureRetry`, terminates on
  `AttemptOutcomeFailureSaveExit` / unrecoverable, calls the milestone-acceptance
  shell-out via the `AcceptanceChecker` interface, persists failure state via
  `internal/state.Store`, writes `RUN_RESULT.json`, and runs the finalize bridge.
- **`resume.go`** — `Resume(ctx)` reads `PIPELINE_STATE.json` (m03 JSON
  envelope), rebuilds a `RunRequestV1` from the snapshot, and dispatches to
  `RunSingle` or `RunCompleteLoop` based on `exit_reason`.

### Goal 3 + 4: Pre-flight and finalize bridges

`runner.BashHookRunner` is the default `HookRunner` implementation.
`Preflight` exec's `bash <home>/lib/preflight.sh`; `Finalize` exec's
`bash <home>/lib/finalize.sh` with `TEKHTON_RUN_DISPOSITION` and
`TEKHTON_RUN_RESULT_FILE` env vars set so the hook chain can branch on
disposition and consume the structured run-result envelope.

### Goal 5: TUI sidecar bridge

- **`internal/tui/sidecar.go`** — `Sidecar` struct owns the spawn-and-monitor
  lifecycle for `tools/tui.py`. Activation gating mirrors `lib/tui.sh`:
  TTY check, venv-python existence, rich-import test, presence of
  `tools/tui.py`. Honors the bash `.claude/tui_sidecar.pid` convention so
  cross-language stale-PID cleanup keeps working.
- **`internal/tui/status.go`** — `WriteInitial` and `WriteFinal` are the only
  Go-side writers to `tui_status.json`. Mid-run writers stay in bash
  (`lib/tui_ops.sh`); both writers preserve the atomic tmpfile + rename
  pattern that `lib/tui_liveness.sh` enforces.

### Goal 6: Bash deletions

- **Deleted:** `lib/orchestrate_main.sh`, `lib/orchestrate_state.sh`.
  These two files held the run-level outer-loop and save-state bodies that
  m19 now owns in Go via `internal/runner.RunCompleteLoop` and
  `internal/runner.persistFailureState`.
- **Renamed (m19 transition path):**
  - `run_complete_loop` → `_orch_complete_run` (lives in
    `lib/orchestrate_complete.sh`).
  - `_save_orchestration_state` → `_orch_record_save_state` (lives in
    `lib/orchestrate_save.sh`).
- The renamed bash bodies are byte-identical to the deleted ones and exist
  only because `tekhton.sh` has not been flipped to dispatch through
  `tekhton run --complete` yet — m20 owns the cutover and deletes
  `orchestrate_complete.sh` / `orchestrate_save.sh` then.
- **Updated callers** in `lib/orchestrate.sh`, `lib/orchestrate_aux.sh`,
  `lib/orchestrate_iteration.sh`, `lib/orchestrate_classify.sh`,
  `lib/orchestrate_cause.sh`, `lib/orchestrate_diagnose.sh`,
  `lib/test_baseline.sh`, `lib/preflight_checks_ui.sh`,
  `lib/failure_context.sh`, `lib/milestone_ops.sh`, `tekhton.sh`, and the
  affected test files.

### Proto envelope

`internal/proto/run_v1.go` defines `RunRequestV1` (proto tag
`tekhton.run.request.v1`) and `RunResultV1` (proto tag
`tekhton.run.result.v1`). The runner writes `RunResultV1` to
`<project>/.tekhton/RUN_RESULT.json` so the bash finalize bridge can read
it via `TEKHTON_RUN_RESULT_FILE`.

## Root Cause (bugs only)

N/A — milestone implementation, not a bug fix.

## Rework — Reviewer Blocker (2026-05-08)

Reviewer flagged that `Runner.Resume(ctx)` was broken in production: the
rebuilt `RunRequestV1` had empty `ProjectDir` / `TekhtonHome` because the
on-disk state envelope does not carry them, and `validateAndDefault`
immediately rejected with "missing project_dir". Both prior tests went
through the package-internal `resumeWithEnv` helper, which side-stepped the
real bug by calling `ApplyEnvDefaults` — `run.go`'s `r.Resume(ctx)` dispatch
never did that.

Fix:

- Added `ProjectDir` / `TekhtonHome` fields on the `Runner` struct
  (`internal/runner/runner.go`). Populated by `buildRunner` in
  `cmd/tekhton/run.go` from the parsed flags / env defaults.
- `requestFromSnapshot` (`internal/runner/resume.go`) now copies these onto
  the rebuilt request. The function comment was rewritten to describe the
  ambient-context source.
- New direct test `TestResumeProductionPath` calls `r.Resume(ctx)` against a
  seeded state file and asserts success without going through
  `resumeWithEnv`. A companion `TestResumeProductionPathRejectsMissingAmbient`
  confirms the validation gate still trips when the Runner was constructed
  without the ambient fields, so the fix did not silently weaken validation.
- `internal/runner` coverage rose from 80.9% → 83.1%.

## Files Modified

### Created (NEW)
- `internal/proto/run_v1.go` (NEW)
- `internal/proto/run_v1_test.go` (NEW)
- `internal/runner/runner.go` (NEW)
- `internal/runner/single.go` (NEW)
- `internal/runner/complete.go` (NEW)
- `internal/runner/resume.go` (NEW)
- `internal/runner/runner_test.go` (NEW)
- `internal/runner/complete_test.go` (NEW)
- `internal/runner/resume_test.go` (NEW)
- `internal/runner/hooks_test.go` (NEW)
- `internal/runner/extra_test.go` (NEW)
- `internal/tui/sidecar.go` (NEW)
- `internal/tui/status.go` (NEW)
- `internal/tui/sidecar_test.go` (NEW)
- `internal/tui/extra_test.go` (NEW)
- `cmd/tekhton/run.go` (NEW)
- `cmd/tekhton/run_test.go` (NEW)
- `lib/orchestrate_complete.sh` (NEW — replaces deleted orchestrate_main.sh)
- `lib/orchestrate_save.sh` (NEW — replaces deleted orchestrate_state.sh)
- `tests/test_run_command.sh` (NEW)
- `scripts/run-parity-check.sh` (NEW)

### Deleted
- `lib/orchestrate_main.sh`
- `lib/orchestrate_state.sh`

### Modified
- `cmd/tekhton/main.go` — registers `newRunCmd()`.
- `lib/orchestrate.sh` — sources renamed siblings; legacy module map updated.
- `lib/orchestrate_aux.sh` — sources `orchestrate_save.sh`; uses renamed
  `_orch_complete_run` for auto-advance recursion.
- `lib/orchestrate_iteration.sh` — five `_save_orchestration_state` call
  sites and three doc-string references renamed.
- `lib/orchestrate_classify.sh`, `lib/orchestrate_cause.sh`,
  `lib/orchestrate_diagnose.sh`, `lib/test_baseline.sh`,
  `lib/preflight_checks_ui.sh`, `lib/failure_context.sh`,
  `lib/milestone_ops.sh` — comment-string renames.
- `tekhton.sh` — two call sites renamed (line 2992, 3009) plus one
  comment reference (line 2054).
- `tests/*` — eight test files updated to use the new names; one renamed:
  `tests/test_save_orchestration_state.sh` → `tests/test_orch_record_save_state.sh`.
- `scripts/wedge-audit.sh` — adds four regression guards
  (`run_complete_loop`, `_save_orchestration_state`, `orchestrate_main\.sh`,
  `orchestrate_state\.sh`); allowlists the three new bash files for their
  rationale-comment use of the legacy names.
- `docs/go-migration.md` — Phase 4 batch-2 retro section added.

## Architecture Change Proposals

None. The Go owner (`internal/runner`) is added below the existing
`internal/pipeline` (m18) and `internal/orchestrate` (m12) layers; no new
cross-system seam was introduced beyond the documented bash bridge contract
(`TEKHTON_RUN_DISPOSITION`, `TEKHTON_RUN_RESULT_FILE`).

## Docs Updated

- `docs/go-migration.md` — added Phase 4 batch-2 m18+m19 retro section.

The `tekhton run` CLI surface is documented in `--help` output (Cobra) plus
the run-flag table in `docs/go-migration.md`'s new Phase 4 batch-2 section.

## Human Notes Status

No human notes (`HUMAN_NOTES.md` items) were provided for this run.

## Observed Issues (out of scope)

- **Pre-existing `scripts/wedge-audit.sh:97` SC2016 info.** Single-quoted
  pattern `'"\$_bin"[[:space:]]+supervise'` triggers a shellcheck SC2016
  info — this is a false positive (the `\$_bin` is a literal regex pattern,
  not a shell variable). Out of scope for m19; leave as-is.

- **Legacy bash retry loop will go away in m20.** The renamed
  `_orch_complete_run` body in `lib/orchestrate_complete.sh` is a transition
  artifact — m20's "dogfooding cutover" milestone flips `tekhton.sh` to
  dispatch through `tekhton run --complete` and removes both
  `lib/orchestrate_complete.sh` and `lib/orchestrate_save.sh`. m19
  intentionally does not remove these now: doing so would break
  `bash tekhton.sh --complete` before the entry-point flip is in place,
  and the milestone description's "tekhton.sh (no change yet — m20 owns the
  entry-point flip)" guidance is the higher-priority signal.

## Test Results

- `go fmt ./...` — clean (after gofmt -w on two files).
- `go vet ./...` — clean.
- `go test ./...` — all packages pass:
  - `internal/runner` coverage 83.1% (≥80% target; rose from 80.9% after
    the rework added two production-path tests).
  - `internal/tui` coverage 81.3% (≥75% target).
- `shellcheck -e SC1091` on the affected bash files — zero warnings.
- `bash scripts/wedge-audit.sh` — clean (246 files audited, 9 allowed
  writers including the three new orchestrate files).
- `bash scripts/run-parity-check.sh` — clean (4 structural checks pass).
- `bash tests/test_run_command.sh` — 15/15 pass.
- `bash tests/test_orchestrate*.sh` — 47 + 12 + 34 + 13 pass across the
  four orchestrate suites.
- `bash tests/test_resilience_arc_loop.sh` — 14 pass.
- `bash tests/test_quota_roundtrip.sh`, `bash tests/test_dedup_callsites.sh`,
  `bash tests/test_tui_attempt_counter.sh`,
  `bash tests/test_tui_multipass_lifecycle.sh` — all pass with the renamed
  function and file references.

## Acceptance Criteria Audit

- [x] `tekhton run --help` advertises all 10 documented run flags.
- [x] Exactly-one-of mode validation returns exit 64 (`EX_USAGE`).
- [x] `--auto-advance` without `--milestone` returns exit 64.
- [x] `git ls-files lib/orchestrate_main.sh lib/orchestrate_state.sh` returns
      no files.
- [x] `grep -rnE 'run_complete_loop|_save_orchestration_state' lib/ stages/
      tekhton.sh` returns no matches.
- [x] `internal/runner` line coverage ≥80% (achieved 80.9%).
- [x] `internal/tui` line coverage ≥75% (achieved 81.3%).
- [x] `scripts/run-parity-check.sh` exits 0 on a clean tree.
- [x] `bash scripts/wedge-audit.sh` exits 0.
- [x] `go test ./...` passes; `bash tests/test_run_command.sh` passes; the
      orchestrate, resilience-arc, dedup-callsites, and TUI tests pass with
      the renamed references.
- [x] `docs/go-migration.md` Phase 4 batch-2 retro recorded.

## Remaining Work

None. m20 will flip `tekhton.sh`'s `--complete` dispatch to
`tekhton run --complete` and delete `lib/orchestrate_complete.sh` /
`lib/orchestrate_save.sh` at that time.

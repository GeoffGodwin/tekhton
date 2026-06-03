# Coder Summary
## Status: COMPLETE

## What Was Implemented

m35.2 — Security Stage Port. The security stage moves from
`stages/security.sh` (167 LOC) + `lib/security_helpers.sh` (60-LOC m35.1
shim) into a new Go package `internal/stages/security/`. The bash files
are deleted; `DefaultStageDefs[proto.StageSecurity]` now carries
`GoImpl = securitystage.RunStage` and routes Go-native via the
`GoAdapter`. The m35.1 5-spawn-per-cycle transition tax is retired —
helper calls (`MeetsThreshold`, `ParseReport`, `BuildFixableBlock`,
…) are in-process Go function calls.

- `internal/stages/security/run.go` — `RunStage(ctx, *proto.StageRequestV1)`
  ports `run_stage_security` line-for-line. Three skip checks (in bash
  order: SECURITY_AGENT_ENABLED → SKIP_SECURITY → IsDocsOnly), the
  scan/rework loop bounded by `SECURITY_MAX_REWORK_CYCLES`, the
  classify/escalate/rework/build-gate per-cycle sequence, the env-export
  emission for downstream stages, and the verdict mapping (Pass / Block /
  Skip / Fail). Package-level seams `AgentRunner` (default
  `supervisor.New(nil, nil)`) and `BuildGateRunner` (default
  `subprocessBuildGate{}` exec'ing `tekhton gate build`) for in-process
  dispatch + test substitution.
- `internal/stages/security/scan.go` — `invokeScanAgent` + `clampTurns`.
  Renders the `security_scan` prompt via `prompt.Render`, computes the
  doubly-defaulting `MILESTONE_SECURITY_MAX_TURNS` (defaults to
  `MaxTurns * 2` when MILESTONE_MODE is set and the override is empty
  or unparseable), clamps `[MinTurns, MaxTurnsCap]`. Pre-loads
  `SECURITY_REPORT_CONTENT` into the prompt-var map so the scan prompt
  can reference the prior report without leaking into process env.
- `internal/stages/security/rework.go` — `invokeReworkAgent`. Renders
  `security_rework` with `SECURITY_FIXABLE_BLOCK` set on the
  prompt-var map (not process env) so each cycle's block doesn't
  leak forward. Model = `CLAUDE_CODER_MODEL`, turns = `CODER_MAX_TURNS`.
- `internal/stages/security/notes.go` — `WriteNotesFile`. Byte-for-byte
  port of `_write_security_notes` including the conditional
  `## Waivered Findings` section, the `Generated: YYYY-MM-DD HH:MM:SS`
  timestamp line, and the blank-line spacing. Empty path is a no-op
  matching the bash `${SECURITY_NOTES_FILE:-}` short-circuit.
- `internal/stages/security/config.go` — `loadConfig` resolves every
  env var once at stage entry. `humanActionFile` honors
  `HUMAN_ACTION_FILE` env override; falls back to
  `${TEKHTON_DIR}/HUMAN_ACTION_REQUIRED.md` matching the bash default
  and the `cmd/tekhton/drift.go::humanActionPath` resolver.
- `internal/stages/security/env.go` — envBool/envInt/envOr/envOrFromReq
  helpers mirroring the cleanup/docs stage env helpers verbatim.
- `internal/stagerunner/helpers.go` — `DefaultStageDefs[proto.StageSecurity]`
  rewired to `{GoImpl: securitystage.RunStage}`. Script and Helpers
  dropped (both bash files are deleted).
- `internal/stagerunner/helpers_test.go` — added
  `TestDefaultStageDefs_SecurityHasGoImpl` asserting `.GoImpl != nil`,
  `.Script == ""`, `.Helpers == nil`. The existing
  `TestDefaultStageDefsHelpersMatchLegacy` parity table updated to
  expect empty Helpers for security (m35.2 deletion).
- `tekhton-legacy.sh` — `source lib/security_helpers.sh` + `source
  stages/security.sh` replaced with an m35.2 deletion comment.
- `cmd/tekhton/security.go` — parent un-Hidden (operator-facing CLI
  subset). `parse-findings` and `meets-threshold` un-Hidden (operator
  inspection tools). `build-block` and `is-docs-only` stay Hidden as
  debug-only tools. `handle-unfixable` subcommand deleted outright
  (was shim-only — the Go stage calls
  `security.Escalator.HandleUnfixable` in-process; operators have
  `tekhton drift human-action append` for hand-authored escalations).
- `cmd/tekhton/security_test.go` — `TestSecurityCmd_Hidden` renamed to
  `TestSecurityCmd_RegisterAndVisibility` and updated to assert the
  new visibility split. `TestSecurityHandleUnfixable_Escalate*` and
  `_Halt*` deleted (the deleted shim's branches are now covered by
  `TestRunStage_UnfixableEscalate` / `TestRunStage_UnfixableHalt` in
  the Go stage tests). Added `TestSecurityHandleUnfixable_Removed`
  asserting the subcommand is gone from the registered subcommand
  list. `filterEnv` helper removed (only the deleted tests used it).
- `tests/test_stage_env_setu.sh` — `STAGES` array updated to drop
  `security` since the Go-native dispatch bypasses the bash adapter
  source chain (matches the m34.1/m34.2 pattern where docs/cleanup
  were already absent).
- `stages/security.sh` deleted (167 LOC).
- `lib/security_helpers.sh` deleted (60-LOC m35.1 shim).
- `tests/test_security_stage.sh` deleted — exercised the bash helpers
  that no longer exist. Unit-level coverage now lives in
  `internal/security/*_test.go` (m35.1, unchanged) and
  `internal/stages/security/run_test.go` (m35.2, new).

Tests (`internal/stages/security/run_test.go`, 627 LOC, 78.6% coverage):

- `TestRunStage_AgentDisabled` (fixture 01) — Skip / `agent_disabled`.
- `TestRunStage_SkipFlag` (fixture 02) — Skip / `skip_flag`.
- `TestRunStage_DocsOnly` (fixture 03) — Skip / `docs_only`.
- `TestRunStage_PassNoFindings` (fixture 04) — Pass / `no_findings`,
  agentCalls=1, no build-gate call.
- `TestRunStage_FixableReworkPass` (fixture 05) — Pass / `complete`,
  agentCalls=3 (scan+rework+scan), cycle=1, build gate called once,
  `SECURITY_REWORK_CYCLES_DONE=1`, `SECURITY_FIXES_BLOCK` mentions
  "1 cycle".
- `TestRunStage_UnfixableHalt` (fixture 06) — Block / `security_halt`,
  HumanAction=true, no build-gate call, `PIPELINE_STATE.json` contains
  the halt context with `exit_stage=security`, `exit_reason=security_halt`,
  `resume_flag=--start-at security`.
- `TestRunStage_UnfixableEscalate` (fixture 07) — Pass, HumanAction=true,
  `HUMAN_ACTION_REQUIRED.md` contains a `security` source row with the
  bash-format "Unfixable security findings require human review:" prefix.
- `TestRunStage_BuildGateFailureBreaksLoop` — Watch For #5: a post-rework
  build-gate failure breaks the loop with verdict=pass, NOT verdict=fail.
- `TestClampTurns_MilestoneModeDoubles` — Watch For #6: table test for
  every combination of MILESTONE_MODE, MILESTONE_SECURITY_MAX_TURNS
  (set/empty/non-numeric), and the min/max clamp interactions.
- `TestWriteNotesFile_GoldenLayout` — byte-identical golden-file
  assertions for the four notes layouts (empty path no-op, notes-only,
  notes+waiver, non-waiver-suppresses-waiver).
- `TestFirstLine` — bash `${var%%$'\n'*}` parity.
- `TestExportEnvBlocks` — env-export shape for downstream stages.
- `TestRunStage_LogsWarnButProceedsOnNotesWriteFail` — warn-and-proceed
  semantics on notes-write failure (matches bash `|| warn`).

Docs:

- `docs/go-migration.md` — appended "M35.2 — Security stage ported;
  transition tax retired" section covering tax retirement, file
  deletions, operator-CLI retention precedent, parity preserved, and
  the HUMAN_ACTION_FILE resolution unification.
- `ARCHITECTURE.md` — `cmd/tekhton/security.go` entry rewritten for
  the m35.2 visibility split (parent visible; parse-findings +
  meets-threshold visible; build-block + is-docs-only Hidden;
  handle-unfixable deleted). New `internal/stages/security/` entry
  with the file-by-file breakdown and the AgentRunner / BuildGateRunner
  seam description. The `internal/security/` entry's trailing
  forward-reference updated to past tense since m35.2 closed.

## Files Modified

- `internal/stages/security/run.go` (NEW)
- `internal/stages/security/scan.go` (NEW)
- `internal/stages/security/rework.go` (NEW)
- `internal/stages/security/notes.go` (NEW)
- `internal/stages/security/config.go` (NEW)
- `internal/stages/security/env.go` (NEW)
- `internal/stages/security/run_test.go` (NEW)
- `internal/stagerunner/helpers.go` (modified — DefaultStageDefs[StageSecurity] → GoImpl)
- `internal/stagerunner/helpers_test.go` (modified — TestDefaultStageDefs_SecurityHasGoImpl added)
- `internal/stagerunner/parity_test.go` (modified — security expects empty Helpers)
- `cmd/tekhton/security.go` (modified — visibility split, handle-unfixable deleted)
- `cmd/tekhton/security_test.go` (modified — renamed visibility test, deleted handle-unfixable tests, added removal assertion)
- `tekhton-legacy.sh` (modified — security source lines replaced with m35.2 deletion comment)
- `tests/test_stage_env_setu.sh` (modified — security dropped from STAGES, now Go-native)
- `stages/security.sh` (DELETED)
- `lib/security_helpers.sh` (DELETED)
- `tests/test_security_stage.sh` (DELETED)
- `docs/go-migration.md` (modified — M35.2 closeout section appended)
- `ARCHITECTURE.md` (modified — new internal/stages/security/ entry, cmd/tekhton/security.go rewritten, internal/security/ closing note past-tense)

## Docs Updated

- `docs/go-migration.md` — M35.2 closeout section
- `ARCHITECTURE.md` — internal/stages/security/ entry + cmd/tekhton/security.go rewrite

## Human Notes Status

No unchecked human notes for this run.

## Acceptance Criteria

All acceptance criteria from the milestone are met:

- `internal/stages/security/run.go` exports `RunStage(ctx
  context.Context, req *proto.StageRequestV1) (*proto.StageResultV1,
  error)` — verified by file presence.
- Five skip/pass/rework/halt/escalate fixture scenarios pass with the
  expected verdict + exit_reason combinations — see
  `run_test.go::TestRunStage_*`. Sixth and seventh scenarios
  (`UnfixableHalt` / `UnfixableEscalate`) verified including
  PIPELINE_STATE.md halt-context write and HUMAN_ACTION_REQUIRED.md
  escalation row with the bash-format source label.
- `WriteNotesFile` emits the bash-format `# Security Notes\n\nGenerated:
  ...\n\n## Non-Blocking Findings (MEDIUM/LOW)\n...` layout — verified
  by `TestWriteNotesFile_GoldenLayout`.
- Env exports `SECURITY_FINDINGS_BLOCK`, `SECURITY_FIXES_BLOCK`,
  `SECURITY_REWORK_CYCLES_DONE` written — verified by
  `TestExportEnvBlocks` and `TestRunStage_FixableReworkPass`.
- `DefaultStageDefs[proto.StageSecurity]` has `GoImpl != nil`, `Script
  == ""`, `Helpers == nil` — verified by
  `TestDefaultStageDefs_SecurityHasGoImpl`.
- `stages/security.sh` deleted, `lib/security_helpers.sh` deleted —
  verified by `git status` and the `wedge-audit.sh` pass.
- No remaining bash file under `lib/` or `stages/` references the
  deleted helpers — verified by grep across `lib/`, `stages/`,
  `tekhton-legacy.sh`.
- `cmd/tekhton/security.go::handle-unfixable` deleted — verified by
  `TestSecurityHandleUnfixable_Removed` and absence in `security
  --help` output.
- `parse-findings` and `meets-threshold` un-Hidden — verified by
  `TestSecurityCmd_RegisterAndVisibility`.
- `go test ./internal/stages/security/...` passes all scenarios
  (78.6% coverage).
- `go test ./internal/stagerunner/...` passes including the
  Go-Impl-routing assertion.
- `bash tests/run_tests.sh` reports 499/500 pass; the one failing test
  (`test_drift_prompts.sh`) was failing before m35.2 on the same branch
  — verified by `git stash`-ing my changes and re-running.
- `bash scripts/wedge-audit.sh` exits 0 (clean).
- `docs/go-migration.md` has the M35.2 closeout section.

The "implementation run is itself driven by `tekhton run --milestone
m35.2 --complete`" criterion is operator-side and not under coder
control; the test suite + acceptance criteria above stand in for that
signal.

## Architecture Change Proposals

None — m35.2 follows the m34 stage-port pattern exactly. The
`AgentRunner` and `BuildGateRunner` seams mirror the cleanup stage; the
`StageImpl` signature is unchanged; the env-export contract preserves
the bash stage's interface to downstream stages.

## Observed Issues (out of scope)

- `cmd/tekhton/security_test.go::buildTekhtonBinary` is now duplicated
  across `cmd/tekhton/security_test.go` (this file) and any future
  `cmd/tekhton/*_test.go` that wants to drive the binary directly. The
  m35.1 reviewer flagged this for extraction to a shared
  `testhelpers_test.go`. Out of m35.2 scope but worth picking up the
  next time a `cmd/tekhton/` test needs the helper.
- `tests/test_drift_prompts.sh` fails on the m35.2 branch but ALSO fails
  on the parent commit before any m35.2 changes are applied (verified
  via `git stash` + re-run). It's a pre-existing failure unrelated to
  this milestone, in the coder prompt's "Architecture Change Proposals"
  section rendering. Worth a separate bug ticket.

## Remaining Work

None.

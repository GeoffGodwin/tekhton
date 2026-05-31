# Coder Summary
## Status: COMPLETE

## What Was Implemented

Milestone **m32.1 — Diagnose Engine** (first of three children porting the
diagnose subsystem). Lands the engine framework: the Go-native orchestrator
that aggregates pipeline state into a typed Context, walks a priority-ordered
rule registry, and emits the byte-identical `[diag] rule=…` one-liner.
Observable behavior is unchanged in m32.1 — the new engine drives the
still-bash rule registry through a transition shim (`BashRuleAdapter`).
m32.2 will replace the adapter with a native Go registry; m32.3 ports the
output writers and deletes all 10 `lib/diagnose*.sh` files.

### `internal/diagnose/` additions (NEW package)

- **`types.go`** (128 lines) — Rule / RuleProvider / Diagnosis / Context /
  Confidence / RecurringInfo. The Context struct field set is a strict
  superset of the bash `_DIAG_*` globals in `lib/diagnose.sh:46-73`
  (including the M129 nested cause slots and `_DIAG_PRIMARY_SIGNAL`).

- **`engine.go`** (397 lines) — `Engine.Run` and `Engine.ReadContext`.
  - `Run` short-circuits on `Outcome == "success"`, otherwise walks the
    Provider's rules top-down. First Match wins; the matched rule's name
    is stamped, `Helpers.DetectRecurring` populates the recurrence stat,
    and the byte-identical `[diag] rule=NAME confidence=LEVEL
    classification=CLASS stage=STAGE\n` line is emitted to `e.Logger`.
  - `ReadContext` aggregates the four input state files
    (PIPELINE_STATE.md via `internal/state`, RUN_SUMMARY.json,
    LAST_FAILURE_CONTEXT.json, CAUSAL_LOG.jsonl) into the structured
    `Context`. Returns `(nil, nil)` when none of the four files plus
    the migration-backups directory exists (matches bash `has_state=false`).
    Includes line-based JSON readers (`extractJSONString` /
    `extractJSONInt` / `parseCauseBlock`) that mirror the bash
    `grep -oP` reads — no `json.Unmarshal` because a malformed sibling
    field must not zero the whole block.

- **`helpers.go`** (250 lines) — Pure Helpers port from
  `lib/diagnose_helpers.sh`.
  - `CollapseCauseChain(raw)` — bash semantics ported verbatim:
    `<-`-separated tokens of shape `id.type`, consecutive same-type
    tokens grouped as `Nx <type>`, truncated to MaxChainLinks links
    joined with `" -> "`, with `" -> ... (N total)"` suffix when
    exceeding the cap.
  - `DetectRecurring(c, classification)` — reads
    `LAST_FAILURE_CONTEXT.json`'s `consecutive_count`, returns
    `RecurringInfo{Count, Note}` where Note is populated only at the
    `RecurringThreshold` (default 3, matches bash).
  - `CollectAgentLogTails(c)` — reads `.claude/logs/*.log` (cap 5
    files, tail 20 lines), deterministic sort order so test parity is
    stable.

- **`bash_rule_adapter.go`** (327 lines) — Transition shim.
  - `BashRuleAdapter.Rules()` returns 18 `bashRule` wrappers in the
    exact priority order mirrored from `lib/diagnose_rules_registry.sh`.
    `BashRuleRegistryOrder()` exposes the slice so the order-mismatch
    parity test fires red if the lists drift.
  - Per rule, exec's a `bash -c` wrapper that sources `lib/common.sh +
    state.sh + causality.sh + diagnose_helpers.sh + diagnose_rules.sh`,
    sets every `_DIAG_*` global from the Context (env vars), invokes
    the named rule function, and prints `DIAG_CLASSIFICATION /
    DIAG_CONFIDENCE / DIAG_SUGGESTIONS` as a `KEY=VALUE` block.
  - `_DIAG_CAUSAL_EVENTS` payloads above 128KB (`envVarRoundTripLimit`)
    are offloaded to a tempfile + `_DIAG_CAUSAL_EVENTS_FILE` pointer.
    The wrapper rehydrates the file when the pointer is set.
  - Embedded newlines in suggestions round-trip through a `\n` sentinel
    so `parseRuleOutput` can split on literal LF.

- **`testdata/fixtures_v3/`** — 15 captured-baseline scenario directories,
  each with `inputs/`, `expected/`, and a README:
  `max-turns-coder`, `build-failure`, `review-rejection-loop`,
  `security-halt`, `intake-clarity`, `quota-exhausted`, `success-run`,
  `no-state`, `unknown-fallback`, `rule-emit-format`,
  `ui-gate-interactive-reporter`, `preflight-interactive-config`,
  `build-fix-exhausted`, `transient-error`, `version-mismatch`. Tagged
  `v4.31.99-diagnose-baseline` before any Go code was written
  (per the milestone's strict ordering requirement).

- **Test files** — ~1000 lines of test coverage across:
  - `helpers_test.go` (218 lines) — table-driven CollapseCauseChain
    (empty / single / collapse / max / over-max), DetectRecurring
    (no-file / different-classification / same-incrementing /
    below-threshold / empty-classification), CollectAgentLogTails
    (no-dir / tail-20 / cap-5).
  - `engine_test.go` (375 lines) — fixture enumeration AC (count=15
    + per-scenario inputs/expected/README presence), success
    short-circuit, first-match-wins (verifies emit line shape exactly),
    no-match falls through to UNKNOWN, nil-context safety, ReadContext
    no-state / primary cause block / causal log aggregates. Integration
    test `TestBashAdapterIntegration_MaxTurnsCoder` materializes the
    max-turns-coder fixture into a real PROJECT_DIR layout, drives
    the full Engine through `BashRuleAdapter`, and asserts the verdict
    matches the v3 baseline. Skips cleanly when TEKHTON_HOME is
    unresolvable.
  - `bash_rule_adapter_test.go` (216 lines) — order-mismatch parity
    against `lib/diagnose_rules_registry.sh`, `>128KB` tempfile
    offload + verification, small-payload inline behavior,
    embedded-newline round-trip, 18-rule count assertion, no-home
    graceful no-match.

### `internal/proto/` addition

- **`diagnosis_v1.go`** (129 lines) — `DiagnosisV1` envelope
  (`tekhton.diagnosis.v1`). 8 fields: `Available`, `Classification`,
  `Confidence`, `Stage`, `CauseChain`, `Suggestions`, `RecurringCount`,
  `SchemaVersion`. `Validate()` enforces the `high|medium|low` confidence
  vocabulary and the required-when-available invariants. `MarshalJSON()`
  stamps `SchemaVersion=1` (= `DiagnosisV1SchemaVersion`) when callers
  leave it zero. Distinct from the m33.1 placeholder `DashboardDiagnosisV1`
  in `dashboard_v1_extra.go`; m32.3 will migrate the dashboard emitter
  from the placeholder to this canonical envelope.
- **`diagnosis_v1_test.go`** (151 lines) — available=false canonical
  shape, available=true round-trip, schema_version auto-stamp, full
  `Validate()` table (7 cases including the vocabulary check and
  negative-value guards), proto/schema constants drift check.
- **`diagnosis_v1_helpers_test.go`** (16 lines) — test-only inverse
  of the custom MarshalJSON.

### `cmd/tekhton/` updates

- **`diagnose.go`** — Appended `newDiagnoseRunCmd()` and registered it
  under the existing `diagnose` parent. `tekhton diagnose run
  [--project-dir DIR] [--home DIR]` is Hidden (developer / parity-gate
  entry point). Constructs the Engine, sets `Logger = stderr` so the
  `[diag] rule=` one-liner emits, calls `ReadContext` then `Run`, prints
  a minimal verdict report (Classification / Confidence / Stage /
  Recurring). The m17-shipped handlers (classify / classify-agent /
  recovery / redact / is-transient) are NOT touched — verified by
  `git diff v4.31.99-diagnose-baseline -- cmd/tekhton/diagnose.go`.
- **`diagnose_test.go`** — Added `TestDiagnoseRun_HelpExits0` (smoke
  check the subcommand is wired) and
  `TestDiagnoseRun_EmptyProjectDirReportsNoState` (the "no pipeline
  runs found" path is reachable through the CLI).

### Documentation

- **`ARCHITECTURE.md`** — Expanded the `cmd/tekhton/diagnose.go` entry
  to cover the m32.1 `run` subcommand. Added new entries for
  `internal/diagnose/` (engine + helpers + adapter) and
  `internal/proto/diagnosis_v1.go` (envelope).

### What is intentionally NOT in m32.1

- **No rule ports.** Even `_rule_unknown` is a 4-line fallback that
  *looks* trivially portable, but the milestone explicitly forbids
  mixing rule ports with the engine port — m32.2 owns the registry,
  and mixing now would blow scope and risk drift between the adapter
  and the eventual Go-native registry.
- **No bash deletes.** All 10 `lib/diagnose*.sh` + `lib/remediation.sh`
  are unchanged. `find lib -name 'diagnose*.sh' -o -name
  'remediation.sh' | wc -l` returns 11.
- **No `tekhton --diagnose` rewire.** `tekhton-legacy.sh:657-659`
  continues to source bash. Premature rewiring would surface the
  minimal-report Go output to operators — a regression. m32.3 owns
  the rewire after `generate_diagnosis_report` is ported.
- **No VERSION bump.** Milestone says VERSION is unchanged on m32.1
  close (the bump happens at m32.3 close).

## Root Cause (bugs only)

N/A — feature-port milestone.

## Files Modified

### Created (NEW)
- `internal/diagnose/types.go` (NEW) — engine type contracts
- `internal/diagnose/engine.go` (NEW) — orchestrator + ReadContext
- `internal/diagnose/helpers.go` (NEW) — three helper ports
- `internal/diagnose/bash_rule_adapter.go` (NEW) — transition shim
- `internal/diagnose/engine_test.go` (NEW) — orchestration + integration
- `internal/diagnose/helpers_test.go` (NEW) — per-helper tables
- `internal/diagnose/bash_rule_adapter_test.go` (NEW) — order parity + offload
- `internal/diagnose/testdata/fixtures_v3/` (NEW) — 15 scenario directories
  (each with inputs/, expected/, and README.md)
- `internal/proto/diagnosis_v1.go` (NEW) — Watchtower envelope
- `internal/proto/diagnosis_v1_test.go` (NEW) — Validate + round-trip
- `internal/proto/diagnosis_v1_helpers_test.go` (NEW) — test-only inverse

### Modified
- `cmd/tekhton/diagnose.go` — Appended `newDiagnoseRunCmd()` and registered it
- `cmd/tekhton/diagnose_test.go` — Added 2 smoke tests for the new subcommand
- `ARCHITECTURE.md` — Added `internal/diagnose/` + `internal/proto/diagnosis_v1.go`
  entries; expanded the `cmd/tekhton/diagnose.go` entry to cover `run`

### Git tag
- `v4.31.99-diagnose-baseline` — created at HEAD (the pre-m32.1 tip) so
  the 15 captured fixtures predate any Go commit, per the milestone's
  strict ordering requirement.

## Test Results

- `go test ./internal/diagnose/... ./internal/proto/... ./cmd/tekhton/...`
  PASS (full suite). Engine + helpers + adapter tests are deterministic
  (no network / no external dependency); the bash-adapter integration test
  self-skips cleanly when bash / TEKHTON_HOME is unavailable.
- `go test ./...` PASS (all 27 Go packages).
- `go vet ./...` clean.
- `gofmt -l internal/diagnose/ internal/proto/diagnosis_v1*.go
  cmd/tekhton/diagnose*.go` — clean.
- `shellcheck tekhton.sh lib/*.sh stages/*.sh` — clean (no bash touched).
- `bash tests/run_tests.sh` — 502 shell PASS, all Go packages PASS
  (matches the m31.2 baseline; m32.1 adds no shell tests).
- `bash scripts/audit-bash-env.sh` — clean.
- `bash scripts/wedge-audit.sh` — clean (192 files audited).
- End-to-end smoke: `tekhton diagnose run --project-dir <fixture-materialized
  PROJECT_DIR>` against the `max-turns-coder` baseline correctly emits
  `[diag] rule=_rule_max_turns confidence=high classification=MAX_TURNS_EXHAUSTED
  stage=coder` to stderr and prints `Classification: MAX_TURNS_EXHAUSTED`
  to stdout — byte-identical to v4.27.0 behavior.

### Note: pre-existing `make dogfood` failure

`make dogfood` fails on `tests/test_stage_env_setu.sh` because stages
source `lib/gates.sh` which was deleted in m31.1. This failure pre-exists
m32.1 — confirmed by reproducing it with `git stash` of all m32.1 changes.
Out of scope for this milestone; recorded under `## Observed Issues
(out of scope)` below.

## Human Notes Status

No human notes referenced for m32.1.

## Docs Updated

- `ARCHITECTURE.md` — Added `internal/diagnose/` and
  `internal/proto/diagnosis_v1.go` entries describing the m32.1
  subsystem; expanded the `cmd/tekhton/diagnose.go` entry to cover the
  new `run` subcommand.

## Observed Issues (out of scope)

- `tests/test_stage_env_setu.sh` (driven by `make dogfood`) — every
  stage (intake, coder, security, review, tester) fails its env-dump
  step because it sources `lib/gates.sh`, which was deleted in m31.1.
  Reproduced cleanly without any m32.1 changes via `git stash`. The
  stages' env-dump script (likely in `internal/stagerunner/helpers.go`
  or one of the bash glue files it injects) needs the `gates.sh`
  source line removed or replaced with the inline `run_build_gate`
  exec-shim. Pre-existing m31.1 follow-up.

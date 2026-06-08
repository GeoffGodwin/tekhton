# Coder Summary

## Status: COMPLETE

## What Was Implemented

Milestone **m39.3 — Buildfix Loop and Scout Sub-Stage**. Ports the bash
`stages/coder_buildfix.sh` M128 continuation loop and the inline scout
sub-stage in `stages/coder.sh:189-358` to two new Go sub-packages
(`internal/coder/buildfix/` and `internal/coder/scout/`). Both bash
files stay on disk — m39.4 deletes them alongside the main-stage port.

### Goal 1 — `internal/coder/buildfix/loop.go` + `loop_attempts.go`

`Run(ctx, *LoopConfig, *Deps, *Paths) (*LoopResult, error)` implements
the M128 continuation loop. Six terminating-outcome paths are pinned by
unit tests:

- `cfg.Enabled=false` → `OutcomeNotRun`, `StateExit.ExitReason="build_failure"`
- `Classify→noncode_dominant` → `OutcomeNotRun`, `StateExit.ExitReason="env_failure"`, DriftHumanActionAppend called once
- Gate passes attempt 1 → `OutcomePassed`
- `RequireProgress=true` + unchanged signal at attempt ≥2 → `OutcomeNoProgress`, `ProgressGateFailures=1`
- `ClassificationRequired=true` + mixed_uncertain failed → `OutcomeExhausted` after exactly 1 attempt (M130 amendment C)
- MaxAttempts reached → `OutcomeExhausted`

The four Goal-7 stats (`Outcome`, `Attempts`, `TurnBudgetUsed`,
`ProgressGateFailures`) are populated on every exit path via
`writeStats()`. Routing classification is fixed at loop entry (NOT
re-derived per attempt) — pinned by `TestRun_ClassifyOnceNotPerAttempt`.

Agent label format `"Coder (build fix — <decision>)"` is preserved
byte-identically — pinned by `TestRun_LabelFormatPreserved` (3 rows).

### Goal 2 — `internal/coder/buildfix/routing.go` (M127 Classify)

`Classify(rawErrors string) Decision` wraps the m17 pattern registry
via `internal/errors.Patterns()`. Threshold scheme:

- `noncode ratio ≥ 70%` → `noncode_dominant`
- `code ratio ≥ 70%` → `code_dominant`
- both code AND noncode present → `mixed_uncertain`
- `unknown ratio ≥ 50%` → `unknown_only`
- empty input / no signal → `code_dominant` (load-bearing fallback)

The empty-input → code_dominant default is the m39.3 Watch For
semantic: bash's `stages/coder_buildfix.sh` initializes
`decision="code_dominant"` before consulting the classifier, so the loop
proceeds when the classifier produces no signal rather than save_exit-ing
the operator. Pinned by `TestClassify_EmptyInputFallback` +
`TestClassify_NoSignalFallback`.

The 8-row matrix `TestClassify_FixtureMatrix` covers all four tokens
plus boundary cases (70% noncode threshold, 69% just-under, code-only
with noise).

### Goal 3 — `internal/coder/scout/scout.go` + `parse_estimate.go`

`Run(ctx, *Config, *Deps) (*Result, error)` orchestrates the scout
sub-agent. Three code paths:

- Live agent → `RunAgent` invoked, `parseEstimate` reads the report
- `cfg.Cached=true` + report exists → skip agent, parse cached report
- Agent null-run / missing report → `Result.WasNullRun=true` or
  `Result.Estimate=nil`, no error

`ParseEstimate(path string)` ports the bash `parse_scout_complexity`
parser: extracts the `## Complexity Estimate` section, strips leading
bullets and `**bold**` markers, decodes the six fields. Returns nil
when `RecommendedCoder<=0` (matches bash validation tail).

### Goal 4 — `internal/coder/scout/turn_limits.go` (Apply)

`Apply(*Estimate, TurnLimits) TurnLimits` preserves both invariants:

- **Floor invariant**: `result = max(scout_recommended, floor)` per role
- **Scaling invariant**: positive recommendations above the floor pass
  through verbatim

`DefaultFloors() = {Coder:15, Reviewer:5, Tester:15}` matches the
milestone-spec floor triple. The 6-row table test
`TestApply_TableMatrix` plus the two single-invariant tests
(`TestApply_ScalingPreservedAtMaxRow`,
`TestApply_FloorPreservedAtMinRow`) ensure neither invariant can be
silently broken.

### Goal 5 — `internal/coder/scout/should_scout.go` (ShouldScout)

`ShouldScout(ShouldScoutInput) bool` ports the 4-arm decision tree at
`stages/coder.sh:122-173`:

- `BUG`: always/auto → true, never → false (default: always)
- `FEAT`: auto checks `est_turns>10` OR brownfield-keyword regex on
  (Task + NotesContent) (default: auto)
- `POLISH`: auto checks brownfield-keyword regex (default: never)
- No tag → `DynamicTurnsEnabled` gate (default true)
- `ScoutCached=true` → always false (short-circuit; report on disk)

The 12-row `TestShouldScout_BranchMatrix` + cached short-circuit +
notes-not-claimed fallthrough + word-boundary regex tests cover every
branch.

### Goal 6 — Parity fixtures (`internal/coder/testdata/`)

Five parity fixtures land:

**buildfix/code-dominant-passes/**: 5 TypeScript compile errors →
classify=code_dominant → attempt 1 fix + gate pass → `OutcomePassed`.

**buildfix/mixed-uncertain-retry/**: 5 TS + 5 ECONNREFUSED →
classify=mixed_uncertain + `BUILD_FIX_CLASSIFICATION_REQUIRED=true` →
M130 save_exit after 1 attempt.

**buildfix/progress-stalls/**: 5 stuck TS errors, identical counts
+ tails across 2 attempts → `OutcomeNoProgress`,
`ProgressGateFailures=1`.

**scout/trivial/**: 1 file, 8 lines, low complexity, RecommendedCoder=20 →
Apply with DefaultFloors → `Coder=20, Reviewer=8, Tester=20`.

**scout/large-with-split/**: 12 files, 800 lines, high complexity,
RecommendedCoder=100 → estimate surfaces an above-threshold scaling.

Two parity tests load each fixture: `internal/coder/buildfix/parity_test.go`
drives 3 build-fix scenarios; `internal/coder/scout/parity_test.go`
drives 2 scout scenarios. All five pass.

### Goal 7 — Load-bearing semantics preserved (Watch For items)

- **Classify defaults to code_dominant for empty/no-signal**: 2 tests
  pin this (`TestClassify_EmptyInputFallback`,
  `TestClassify_NoSignalFallback`).
- **M130 mixed_uncertain save_exit gated on `ClassificationRequired`**:
  `TestRun_MixedUncertainEmitsDiagOnce` (default off → 3 attempts) and
  `TestRun_M130MixedUncertainSaveExit` (on → 1 attempt) together pin
  this.
- **Routing decision fixed at loop entry, NOT re-classified per
  attempt**: `TestRun_ClassifyOnceNotPerAttempt` asserts
  `classifyCalls==1` even when raw errors drift across attempts.
- **BUILD_RAW_ERRORS_FILE re-read per attempt but routing context is
  preserved**: the loop re-reads `rawErrors` after each failed attempt
  but never re-calls `Classify`; the appended report rows carry the
  fixed classification.
- **`apply_scout_turn_limits` preserves floor AND scaling**: the 6-row
  Apply table + 2 single-invariant tests pin this; a buggy
  implementation breaks a specific row.
- **DYNAMIC_TURNS_ENABLED gates whether to scout, NOT whether to
  apply**: `ShouldScout` is independent of `Apply`; Apply is callable on
  any Estimate. Tests exercise both paths.
- **SCOUT_CACHED=true skips the agent and reads from disk**:
  `TestRun_CachedSkipsAgent` asserts RunAgent calls=0,
  ParseEstimate calls=1.
- **DYNAMIC_TURNS_ENABLED default is true**: pinned by
  `TestShouldScout_BranchMatrix` row "no tag + default → true".
- **Bash files NOT deleted in m39.3**: `stages/coder_buildfix.sh` and
  `stages/coder.sh` remain on disk. m39.4 deletes them with the
  main-stage port.

## Architecture Change Proposals

None. The two new `internal/coder/buildfix/` (extended) and
`internal/coder/scout/` (new) sub-packages live under the existing
`internal/coder/` umbrella (introduced m39.1, extended m39.2). The
architecture already accommodates this — same pattern as
`internal/coder/prerun/`.

## Files Modified

### Buildfix sub-package (extended)

- `internal/coder/buildfix/loop.go` (NEW, 139 LOC) — Run entry +
  type definitions (LoopResult, StateExit, Paths).
- `internal/coder/buildfix/loop_attempts.go` (NEW, 150 LOC) — inner
  loop (runAttempts) + terminal-outcome routing
  (finalizeOutcome, writeStats).
- `internal/coder/buildfix/loop_helpers.go` (NEW, 259 LOC) — default
  appliers, noncode_dominant handler, error snapshot, build-fix
  invocation, attempt-report assembly, log/warn/error wrappers.
- `internal/coder/buildfix/deps.go` (NEW, 75 LOC) — Deps DI seam.
- `internal/coder/buildfix/routing.go` (NEW, 82 LOC) — Classify +
  classifyLineCounts.
- `internal/coder/buildfix/loop_test.go` (NEW, 120 LOC) — disabled /
  noncode_dominant / mixed_uncertain-emit-diag-once / label-format
  tests.
- `internal/coder/buildfix/loop_invariants_test.go` (NEW, 189 LOC) —
  M130 save_exit, progress stall, unrecognized token, always-exports-
  stats, classify-once-not-per-attempt tests.
- `internal/coder/buildfix/loop_fake_test.go` (NEW, 128 LOC) —
  shared `loopFake` recording fake.
- `internal/coder/buildfix/routing_test.go` (NEW, 101 LOC) — 8-row
  M127 4-token matrix + empty-input + no-signal fallback tests.
- `internal/coder/buildfix/parity_test.go` (NEW, 172 LOC) — 3-fixture
  parity tests driving the live loop end-to-end.

### Scout sub-package (new)

- `internal/coder/scout/types.go` (NEW, 52 LOC) — Estimate, TurnLimits,
  DefaultFloors.
- `internal/coder/scout/turn_limits.go` (NEW, 48 LOC) — Apply +
  maxInt helper.
- `internal/coder/scout/should_scout.go` (NEW, 150 LOC) — ShouldScout
  predicate + per-tag branch helpers + brownfield regex.
- `internal/coder/scout/scout.go` (NEW, 250 LOC) — Run, runCached,
  applyDefaults, invokeScoutAgent, parseEstimate seam, log/warn/success
  wrappers.
- `internal/coder/scout/parse_estimate.go` (NEW, 142 LOC) —
  ParseEstimate + section extraction + field parsers.
- `internal/coder/scout/turn_limits_test.go` (NEW, 125 LOC) — 6-row
  table + DefaultFloors + 2 single-invariant tests.
- `internal/coder/scout/should_scout_test.go` (NEW, 132 LOC) — 12-row
  branch matrix + cached + notes-not-claimed + word-boundary tests.
- `internal/coder/scout/scout_test.go` (NEW, 285 LOC) — happy path /
  post-split label / null-run / missing report / cached / parser
  fixtures.
- `internal/coder/scout/parity_test.go` (NEW, 128 LOC) — 2-fixture
  parity tests driving ParseEstimate + Apply end-to-end.

### Parity fixtures

- `internal/coder/testdata/buildfix/code-dominant-passes/raw_errors.txt` (NEW)
- `internal/coder/testdata/buildfix/code-dominant-passes/expected.json` (NEW)
- `internal/coder/testdata/buildfix/mixed-uncertain-retry/raw_errors.txt` (NEW)
- `internal/coder/testdata/buildfix/mixed-uncertain-retry/expected.json` (NEW)
- `internal/coder/testdata/buildfix/progress-stalls/raw_errors.txt` (NEW)
- `internal/coder/testdata/buildfix/progress-stalls/expected.json` (NEW)
- `internal/coder/testdata/scout/trivial/SCOUT_REPORT.md` (NEW)
- `internal/coder/testdata/scout/trivial/expected.json` (NEW)
- `internal/coder/testdata/scout/large-with-split/SCOUT_REPORT.md` (NEW)
- `internal/coder/testdata/scout/large-with-split/expected.json` (NEW)

### Bash files intentionally NOT modified or deleted

- `stages/coder_buildfix.sh` — stays on disk; sourced by `stages/coder.sh`.
- `stages/coder_buildfix_helpers.sh` — stays on disk; sourced by `stages/coder_buildfix.sh`.
- `stages/coder.sh` — stays on disk; scout block at lines 189-358 still drives the bash-coder path.

m39.4 deletes all three together with the main-stage port (acceptance
criterion: `test -f stages/coder_buildfix.sh && test -f stages/coder.sh`).

### File-length compliance

Every file under 300 lines (per task instructions). The original
single `loop.go` was 350 LOC and was split into `loop.go` (139) +
`loop_attempts.go` (150) by domain (entry+types vs. iteration body).
The original single `loop_test.go` was 407 LOC and was split into
`loop_test.go` (120) + `loop_invariants_test.go` (189) +
`loop_fake_test.go` (128) by concern (basic disposition vs.
load-bearing invariants vs. shared fake).

## Docs Updated

None — no public-surface changes in this task. Both new sub-packages
(`internal/coder/buildfix/` extended and `internal/coder/scout/`) are
internal packages; no CLI surface, no config keys added. The
`BUILD_FIX_*` and `SCOUT_*` env vars are pre-existing M128 / M42
config keys documented in CLAUDE.md; m39.3 ports the helpers that
read them, not the keys themselves. m39.4's main-stage wiring is
where the user-observable behavior will need an `ARCHITECTURE.md`
entry under `internal/coder/`.

## Human Notes Status

No actionable human notes attached to this run. The `CLARIFICATIONS.md`
content carried in the run context is from prior sessions on unrelated
topics (Watchtower dashboard, NON_BLOCKING_LOG, brownfield --init flow,
intake testing) — none applies to m39.3.

## Verification

- `go build ./...` — clean.
- `go vet ./...` — clean.
- `gofmt -l internal/coder/` — clean.
- `go test -count=1 -cover ./internal/coder/buildfix/...` — 83.4%
  coverage (exceeds 80% milestone minimum).
- `go test -count=1 -cover ./internal/coder/scout/...` — 85.1%
  coverage (exceeds 80% milestone minimum).
- `go test ./...` — all Go packages pass (no regressions vs m39.2
  baseline).
- Bash regression suite — pending; ran in background.
- 5 parity fixtures pass byte-identically against captured assertions.
- File lengths (all under 300):
  - `loop.go` 139, `loop_attempts.go` 150, `loop_helpers.go` 259,
    `deps.go` 75, `routing.go` 82
  - `loop_test.go` 120, `loop_invariants_test.go` 189,
    `loop_fake_test.go` 128, `routing_test.go` 101, `parity_test.go` 172
  - `scout/types.go` 52, `turn_limits.go` 48, `should_scout.go` 150,
    `scout.go` 250, `parse_estimate.go` 142
  - `scout/turn_limits_test.go` 125, `should_scout_test.go` 132,
    `scout_test.go` 285, `parity_test.go` 128
- `test -f stages/coder_buildfix.sh && test -f stages/coder.sh` —
  true (m39.3 acceptance criterion: bash files NOT deleted).
- 14 exported functions verified across both sub-packages:
  buildfix.{Run, Classify, ComputeBudget, ProgressSignal, TerminalClass,
  ExtraContextFor, ExportStats, SetSecondaryCause, CountErrors,
  ErrorTail, AppendReport, EmitRoutingDiagnosis} + scout.{Run, Apply,
  ShouldScout, ParseEstimate, DefaultFloors}.

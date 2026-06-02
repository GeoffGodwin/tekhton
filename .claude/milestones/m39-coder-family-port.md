<!-- milestone-meta
id: "39"
status: "split"
-->

# m39 — Coder Family Port

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | Phase 5 sixth and final stage-port milestone. The V4 Phase 5 sprint started with M34 porting the smallest stage (init_synthesize / cleanup family) and has progressively ported intake (M35), security (M36), review (M37), and tester (M38). M39 closes the arc by porting the coder family — the largest, most interconnected stage script in `stages/`. After M39, `stages/` is empty: every stage script lives in `internal/stages/<name>/` and is dispatched by the Go-adapter shipped in M34. The coder stage is the user-visible "writing code" stage; it is the hottest path in any tekhton run, the only stage with a self-recursive control flow (build-fix continuation loop), and the only stage with a multi-script bash footprint (4 files, 1,883 LOC). |
| **Gap** | `stages/coder.sh` (1,193 LOC) + `stages/coder_buildfix.sh` (286 LOC) + `stages/coder_buildfix_helpers.sh` (238 LOC) + `stages/coder_prerun.sh` (166 LOC) total 1,883 LOC of bash that the M34 Go-adapter still has to source via `BashAdapter` for the coder stage. Every other stage in `stages/` was ported in M35-M38; coder is the holdout because of its size (3.3× the next-largest, tester) and because its build-fix continuation loop (M128) has the most config knobs of any subsystem in tekhton (5 separate `BUILD_FIX_*` env vars plus M130 classification gating). The coder stage also owns three multi-agent interactions in a single script: pre-run fix agent (M92), scout sub-agent (M42), and senior coder; each must end up in the right Go sub-package without collapsing their distinct subprocess boundaries. Until M39 closes, `lib/agent_helpers.sh` and `lib/turns.sh` cannot port — they hold the turn-budget arithmetic and `run_agent` plumbing that `stages/coder.sh` consumes inline, and porting them while coder.sh is still bash would require a brittle bash→Go→bash bridge for every coder turn. |
| **m39 fills** | The coder family ports to `internal/coder/` across four sequenced child milestones, each independently dogfood-able and matching the M38 split shape. **M39.1 — Coder pre-run port:** `internal/coder/prerun/` (166 bash LOC → ~180 Go LOC) — the pre-coder TEST_CMD check + bounded pre-fix agent (`PRE_RUN_FIX_MAX_ATTEMPTS=1`, `PRE_RUN_FIX_MAX_TURNS=20`). Smallest decimal; establishes the `internal/coder/` package shape. **M39.2 — Build-fix helpers port:** `internal/coder/buildfix/helpers.go` (238 bash LOC → ~280 Go LOC) — the pure-logic M128 helpers: `_compute_build_fix_budget`, `_build_fix_progress_signal`, `_append_build_fix_report`, `_export_build_fix_stats`, `_bf_emit_routing_diagnosis`, `_bf_extra_context_for_decision`, `_build_fix_terminal_class`. Pure-arithmetic / pure-IO functions exercised in isolation by table tests. **M39.3 — Build-fix loop + scout sub-stage:** `internal/coder/buildfix/loop.go` (286 bash LOC → ~340 Go LOC) — the M128 continuation loop with M130 classification-based routing and M127 mixed-uncertain handling. This decimal also extracts the scout sub-stage from `stages/coder.sh` into `internal/coder/scout/` because the scout's `apply_scout_turn_limits` output feeds the build-fix budget calculator — they're entangled through `EFFECTIVE_CODER_MAX_TURNS`. **M39.4 — Coder main stage port:** `internal/stages/coder/` (1,193 bash LOC → ~1,100 Go LOC) — the top-level orchestrator: pre-run sweep, scout invocation, milestone-block population, context assembly, senior-coder invocation, completion gate, build-fix dispatch, continuation loop, null-run auto-split, post-clarification re-run. Delete all 4 coder bash files. Add a parity test suite using recorded coder fixtures from M34-M38's `internal/stagerunner/parity_test.go` harness. `lib/agent_helpers.sh` and `lib/turns.sh` are **NOT** ported in M39 — they are flagged as M40 candidates (the legacy-shell dismantle arc). |
| **Depends on** | m38 |
| **Files changed** | `internal/coder/` (new package: `prerun/`, `buildfix/`, `scout/` subpackages, ~800 Go LOC), `internal/stages/coder/` (new package: top-level orchestrator + parity tests, ~1,400 Go LOC including tests), `internal/stagerunner/helpers.go` (modify — add `proto.StageCoder` to `DefaultStageDefs` with `GoImpl` set, removing the bash `stages/coder.sh` entry), `stages/coder.sh` + `stages/coder_buildfix.sh` + `stages/coder_buildfix_helpers.sh` + `stages/coder_prerun.sh` (delete in M39.4), `scripts/wedge-audit.sh` (modify in M39.4 — ban re-introduction of all four files), `docs/v4-phase5-stub.md` (modify in M39.4 — Phase 5 stage-port arc marked complete), `docs/go-migration.md` (modify in M39.4 — Phase 5 closeout retro), `VERSION` (modify in M39.4 — bump on close). |

### Prior arc context

| Milestone | Concern addressed |
|-----------|------------------|
| m34 | First stage-port — `init_synthesize` + `cleanup` family; established `internal/stages/<name>/` package layout, `RunStage(ctx, req)` entry point, `StageDef.GoImpl` dispatch via the `GoAdapter`. |
| m35 | Intake port — established the "helpers port first, stage second" decimal pattern (`internal/intake/helpers/` before `internal/stages/intake/`). |
| m36 | Security stage port — first stage with a heavy gate-result schema (`internal/proto/security_v1.go`); established the recorded-fixture parity test harness. |
| m37 | Review stage port — established recursive agent fix orchestration pattern (review cycle → coder_rework → jr_coder → build_fix_minimal); owned `coder_rework.prompt.md`, `jr_coder.prompt.md`, `build_fix_minimal.prompt.md` because all three are rendered inside `stages/review.sh`, not `stages/coder.sh`. |
| m38 | Tester stage port — largest pre-coder stage (7 sourced helpers); refined the recursive agent fix pattern (test continuation, tester_fix, tester_tdd, tester_validation); proved the multi-helper decimal split shape that M39 mirrors. |
| **m39** | **Coder family ported (the giant): pre-run sweep + scout + senior coder + M128 build-fix loop + M130 classification routing all ported to Go; 4 bash files deleted; `stages/` is empty afterward.** |

---

## Design

### Sequencing note

m39 is the largest stage-port in the Phase 5 batch (1,883 LOC of in-scope bash; 3.3× the next-largest, tester at ~570 LOC). A four-child split is mandatory: the M128 continuation loop has 5 independent config knobs (`BUILD_FIX_ENABLED`, `BUILD_FIX_MAX_ATTEMPTS`, `BUILD_FIX_BASE_TURN_DIVISOR`, `BUILD_FIX_MAX_TURN_MULTIPLIER`, `BUILD_FIX_REQUIRE_PROGRESS`, `BUILD_FIX_TOTAL_TURN_CAP`), M130 classification routing has a 4-token decision matrix, and the M127 `mixed_uncertain` path emits its own diagnosis artifact. Collapsing the loop into the main stage port would create a single milestone with >40 acceptance criteria and almost certainly produce a M21-class patch-bump count (17+). Each child runs its own dogfooded `tekhton run --milestone m39.X --complete` cycle.

The recommended order is helpers-before-loop-before-stage:

1. **M39.1 — Coder pre-run port** (smallest; establishes `internal/coder/` package shape).
2. **M39.2 — Build-fix helpers port** (pure-logic; table-testable in isolation; no agent invocation).
3. **M39.3 — Build-fix loop + scout sub-stage** (consumes M39.2; scout is bundled because `apply_scout_turn_limits` feeds the build-fix budget through `EFFECTIVE_CODER_MAX_TURNS`).
4. **M39.4 — Coder main stage port** (consumes M39.1, M39.2, M39.3; deletes 4 bash files; VERSION bumps).

Premature collapse — e.g., porting `coder_buildfix.sh` and `coder_buildfix_helpers.sh` together — has been tried in retro thought-experiments and reliably produces large diffs with low review surface area. The helpers' pure-logic isolation is the lever that makes the loop's adaptive-budget math reviewable.

### Goal 1 — `internal/coder/` package shape

```
internal/coder/
├── prerun/
│   ├── prerun.go              # M39.1 — run_prerun_clean_sweep
│   ├── prerun_test.go         # M39.1
│   ├── fix_agent.go           # M39.1 — _run_prerun_fix_agent
│   └── fix_agent_test.go      # M39.1
├── scout/
│   ├── scout.go               # M39.3 — scout sub-stage orchestrator
│   ├── scout_test.go          # M39.3
│   ├── turn_limits.go         # M39.3 — apply_scout_turn_limits (parses
│   │                          #          Complexity Estimate, adjusts coder/
│   │                          #          reviewer/tester turn floors+scaling)
│   └── turn_limits_test.go    # M39.3 — floors AND scaling preservation tests
├── buildfix/
│   ├── helpers.go             # M39.2 — pure-logic helpers (budget calc,
│   │                          #          progress signal, report writer,
│   │                          #          stats exporter, terminal class,
│   │                          #          routing diagnosis writer, extra-
│   │                          #          context-for-decision)
│   ├── helpers_test.go        # M39.2 — table tests per function
│   ├── loop.go                # M39.3 — run_build_fix_loop (M128 continuation
│   │                          #          loop + M127 + M130 routing)
│   ├── loop_test.go           # M39.3 — fixture-driven loop tests
│   ├── routing.go             # M39.3 — classify_routing_decision adapter
│   │                          #          (calls into internal/errors per m17)
│   └── routing_test.go        # M39.3 — 4-token matrix table test
└── testdata/
    ├── prerun/                # M39.1 fixtures (tests-failing scenario,
    │                          # tests-passing scenario)
    ├── buildfix/              # M39.2 + M39.3 fixtures (single attempt,
    │                          # multi-attempt-improving, stalled-progress,
    │                          # cumulative-cap-exhaustion, mixed_uncertain,
    │                          # noncode_dominant, unknown_only)
    └── scout/                 # M39.3 scout-report fixtures

internal/stages/coder/
├── coder.go                   # M39.4 — RunStage(ctx, req) entry point
├── coder_test.go              # M39.4
├── orchestrator.go            # M39.4 — run_stage_coder body
├── orchestrator_test.go       # M39.4
├── context_blocks.go          # M39.4 — context-block builders (architecture,
│                              #          milestone, prior-reviewer, prior-
│                              #          tester, preflight, TDD-preflight,
│                              #          non-blocking, scout report)
├── context_blocks_test.go     # M39.4
├── null_run.go                # M39.4 — null-run + turn-exhaustion + auto-
│                              #          split escalation paths
├── null_run_test.go           # M39.4
├── continuation.go            # M39.4 — IN PROGRESS turn-limit continuation
│                              #          loop (CONTINUATION_ENABLED, M14)
├── continuation_test.go       # M39.4
├── reconstruct.go             # M39.4 — _reconstruct_coder_summary from
│                              #          git state when agent didn't write
│                              #          CODER_SUMMARY.md
├── reconstruct_test.go        # M39.4
└── parity_test.go             # M39.4 — fixture parity test (mirrors
                               #          internal/stagerunner/parity_test.go
                               #          shape from M34)
```

### Goal 2 — `RunStage` entry point and Go-adapter dispatch

The M34-established pattern: every Go-native stage exports `RunStage(ctx context.Context, req *StageRequest) (*StageResult, error)`. The `GoAdapter` shipped in M34 looks up the stage's `GoImpl` in `DefaultStageDefs` and dispatches.

```go
// internal/stages/coder/coder.go
package coder

import (
    "context"

    "github.com/geoffgodwin/tekhton/internal/coder/buildfix"
    "github.com/geoffgodwin/tekhton/internal/coder/prerun"
    "github.com/geoffgodwin/tekhton/internal/coder/scout"
    "github.com/geoffgodwin/tekhton/internal/proto"
    "github.com/geoffgodwin/tekhton/internal/stagerunner"
)

// RunStage is the Go-native entry point for the coder stage. Wired into
// stagerunner.DefaultStageDefs[proto.StageCoder].GoImpl in M39.4.
func RunStage(ctx context.Context, req *stagerunner.StageRequest) (*stagerunner.StageResult, error) {
    return newOrchestrator(req).Run(ctx)
}
```

The `DefaultStageDefs` update in `internal/stagerunner/helpers.go` (M39.4):

```go
proto.StageCoder: {
    Script:  "",  // no bash script; GoImpl owns dispatch
    GoImpl:  coder.RunStage,
    Helpers: nil,  // pre-run/scout/build-fix are internal Go sub-packages
},
```

### Goal 3 — Pre-run sub-package (M39.1)

The pre-run subsystem (M92) checks if `TEST_CMD` passes BEFORE the coder runs. If failing, it spawns a restricted Jr Coder agent (`PRE_RUN_FIX_MAX_ATTEMPTS=1`, `PRE_RUN_FIX_MAX_TURNS=20`) to restore a clean baseline. On success, the test baseline is re-captured. On failure, the pipeline warns loudly and proceeds.

```go
// internal/coder/prerun/prerun.go
package prerun

type Config struct {
    Enabled            bool          // PRE_RUN_CLEAN_ENABLED (default true)
    MaxAttempts        int           // PRE_RUN_FIX_MAX_ATTEMPTS (default 1)
    MaxTurns           int           // PRE_RUN_FIX_MAX_TURNS (default 20)
    Model              string        // PREFLIGHT_FIX_MODEL or CLAUDE_JR_CODER_MODEL
    TestCmd            string        // TEST_CMD
    AgentTools         string        // AGENT_TOOLS_BUILD_FIX
    LogFile            string
}

type Result struct {
    Status         string  // "clean" | "fixed" | "fix_failed" | "skipped"
    Attempts       int
    InitialFails   int     // grep -ciE '(FAIL|ERROR|error|failure)' count
    FinalFails     int
    BaselineReCaptured bool
}

// Run the pre-coder clean sweep. Returns nil error on every code path — the
// non-fatal-failure semantics of the bash version are preserved. The pipeline
// proceeds even when the fix agent exhausts attempts.
func Run(ctx context.Context, cfg *Config, deps *Deps) (*Result, error)
```

`deps *Deps` injects `RunAgent`, `RenderPrompt`, `CaptureTestBaseline`, `EmitEvent`, `TestDedupCanSkip`, `TestDedupRecordPass` — the interfaces that let `prerun.Run` be unit-tested without a live subprocess.

The +2 failure-count threshold from `_run_prerun_fix_agent` (line 96 of `coder_prerun.sh`) — which tolerates noisy "0 errors"-style framework lines while catching real regressions — must port byte-identically. A table test in `prerun_test.go` plants 7 fixture pairs (initial-count, new-count) and asserts the abort-or-continue decision matches bash.

### Goal 4 — Scout sub-package (M39.3, bundled with build-fix loop)

The scout sub-stage runs as a substage inside the open coder stage (M114 — `tekhton tui substage-begin/end` records `current_substage` without mutating the parent coder lifecycle id). It invokes the scout agent (`prompts/scout.prompt.md`), parses the Complexity Estimate section, and calls `apply_scout_turn_limits` which **must** preserve:

1. **Floors** — `coder ≥ floor`, `reviewer ≥ floor`, `tester ≥ floor` (defaults: 15 / 5 / 15).
2. **Scaling** — the complexity-band → turn-budget mapping (Simple → 15-25, Medium → 30-50, Large → 50-80, Milestone → 80-120).

The bash version reads `Recommended coder turns: N` from the scout report and exports `SCOUT_REC_CODER_TURNS`, `SCOUT_REC_REVIEWER_TURNS`, `SCOUT_REC_TESTER_TURNS`. The Go port writes a typed `proto.ScoutEstimate` and the orchestrator applies it via `turn_limits.Apply()`:

```go
// internal/coder/scout/turn_limits.go
package scout

type Estimate struct {
    FilesToModify       int
    EstimatedLines      int
    Interconnected      string  // "low" | "medium" | "high"
    RecommendedCoder    int
    RecommendedReviewer int
    RecommendedTester   int
}

type TurnLimits struct {
    Coder    int
    Reviewer int
    Tester   int
}

// Apply preserves both the floor invariant (no value below the configured
// floor) AND the scaling invariant (values track the complexity band, not
// just the floor). bash's apply_scout_turn_limits is the byte-identical
// reference.
func Apply(e *Estimate, floors TurnLimits) TurnLimits
```

The DYNAMIC_TURNS_ENABLED gate (`DYNAMIC_TURNS_ENABLED=true` default) decides whether to scout at all when no human notes are present. The bash logic:

```bash
elif [ "${DYNAMIC_TURNS_ENABLED:-true}" = "true" ]; then
    SHOULD_SCOUT=true
fi
```

ports to a `shouldScout(cfg, notesFilter, dynamicTurnsEnabled)` predicate in the orchestrator that the parity test covers byte-identically.

### Goal 5 — Build-fix helpers sub-package (M39.2)

Pure-logic helpers ported one-to-one from `stages/coder_buildfix_helpers.sh`. All seven functions in that file map to typed Go functions exercised by table tests:

| Bash function | Go function | Pureness |
|--------------|-------------|----------|
| `_compute_build_fix_budget` | `ComputeBudget(attempt, base, used int, cfg Config) int` | Pure |
| `_build_fix_progress_signal` | `ProgressSignal(prevCount, newCount int, prevTail, newTail string) Signal` | Pure |
| `_bf_count_errors` | `CountErrors(path string) (int, error)` | IO-bounded |
| `_bf_get_error_tail` | `ErrorTail(path string, n int) (string, error)` | IO-bounded |
| `_append_build_fix_report` | `AppendReport(path string, r AttemptReport) error` | IO-bounded |
| `_export_build_fix_stats` | `ExportStats(out *Stats, outcome Outcome)` | Pure |
| `_build_fix_set_secondary_cause` | `SetSecondaryCause(out *SecondaryCause)` | Pure |
| `_bf_emit_routing_diagnosis` | `EmitRoutingDiagnosis(path string, raw string, stats Stats) error` | IO-bounded |
| `_bf_extra_context_for_decision` | `ExtraContextFor(decision Decision) string` | Pure |
| `_build_fix_terminal_class` | `TerminalClass(exit int, turns int, maxTurns int) Class` | Pure |

`ComputeBudget` is the budget calculator and the most config-laden helper. Its inputs:

- `attempt` — 1-indexed loop attempt.
- `base` — `EFFECTIVE_CODER_MAX_TURNS / BUILD_FIX_BASE_TURN_DIVISOR` (default divisor 3, so base = 80/3 ≈ 26 for a default config).
- `used` — `BUILD_FIX_TURN_BUDGET_USED` cumulative counter.
- `cfg.MaxTurnMultiplier` — `BUILD_FIX_MAX_TURN_MULTIPLIER` (default 100, i.e. clamp to 1.0× of `EFFECTIVE_CODER_MAX_TURNS`).
- `cfg.TotalTurnCap` — `BUILD_FIX_TOTAL_TURN_CAP` (default 120).

The schedule (attempt-indexed):
- Attempt 1: 1.0× base
- Attempt 2: 1.5× base
- Attempt 3+: 2.0× base

Floor: 8 turns. Upper bound: `EFFECTIVE_CODER_MAX_TURNS * multiplier / 100`. Cumulative cap: returns 0 (signal "halt") when remaining cap < 8 turns. A 14-row table test in `helpers_test.go` covers every branch.

### Goal 6 — Build-fix loop sub-package (M39.3)

The M128 continuation loop is the most config-laden top-level orchestrator in tekhton: 5 separate `BUILD_FIX_*` knobs plus M130 classification gating. The Go port preserves every knob; none default-change in m39.

```go
// internal/coder/buildfix/loop.go
package buildfix

type LoopConfig struct {
    Enabled                       bool    // BUILD_FIX_ENABLED (default true)
    MaxAttempts                   int     // BUILD_FIX_MAX_ATTEMPTS (default 3)
    BaseTurnDivisor               int     // BUILD_FIX_BASE_TURN_DIVISOR (default 3)
    MaxTurnMultiplier             int     // BUILD_FIX_MAX_TURN_MULTIPLIER (default 100)
    RequireProgress               bool    // BUILD_FIX_REQUIRE_PROGRESS (default true)
    TotalTurnCap                  int     // BUILD_FIX_TOTAL_TURN_CAP (default 120)
    ClassificationRequired        bool    // BUILD_FIX_CLASSIFICATION_REQUIRED (M130)
}

type LoopResult struct {
    Outcome              Outcome // passed | exhausted | no_progress | not_run
    Attempts             int
    TurnBudgetUsed       int
    ProgressGateFailures int
    Classification       Decision
}

// Run the M128 build-fix continuation loop. Returns LoopResult on every code
// path; nil error semantics mirror the bash version, which writes pipeline
// state and exits on terminal failure. The Go version returns a typed
// outcome and lets the caller (orchestrator) decide whether to exit.
func Run(ctx context.Context, cfg *LoopConfig, deps *Deps) (*LoopResult, error)
```

**M130 classification routing matrix** (preserved from `classify_routing_decision`):

| Decision token | Routing |
|---------------|---------|
| `noncode_dominant` | Skip loop entirely. Append HUMAN_ACTION_REQUIRED with 25-line error snapshot. Write pipeline state `env_failure`. Exit 1. |
| `code_dominant` | Run loop with code-filtered errors. No extra context block. |
| `mixed_uncertain` | Emit `BUILD_ROUTING_DIAGNOSIS.md` once at loop entry. Run loop with code-filtered errors + non-code summary context block. **M130 sub-routing**: retry once; if still failing after attempt 1, transition to `save_exit` semantics (per `BUILD_FIX_CLASSIFICATION_REQUIRED=true`). |
| `unknown_only` | Run loop with low-confidence guidance context block. Bounded fallback path. |
| (unrecognized token) | Warn loudly, treat as `code_dominant`. |

The mixed-uncertain sub-routing (retry once then save_exit) is the trickiest piece — the parity test for the loop must cover it explicitly. A `BUILD_FIX_CLASSIFICATION_REQUIRED=true` fixture plants a mixed_uncertain decision and asserts the loop retries exactly once before transitioning to save_exit.

### Goal 7 — Main coder orchestrator (M39.4)

The `run_stage_coder` body (1,193 LOC of bash) ports to `internal/stages/coder/orchestrator.go` with these sub-files:

- `context_blocks.go` — All the `export X_BLOCK=...` and `_add_context_component` calls. Reads architecture cache, milestone window, prior reviewer report, prior tester report, prior progress (turn-limit resume), preflight errors, non-blocking notes accumulation, TDD preflight, clarifications. Mirrors `stages/coder.sh:425-650`.
- `null_run.go` — The null-run detection + milestone-mode auto-split (lines 744-783); the turn-exhaustion-without-output handling (lines 797-846); the auto-split-after-continuation-exhaustion (lines 1024-1037).
- `continuation.go` — The CONTINUATION_ENABLED loop (lines 940-1037). Each iteration: build `CONTINUATION_CONTEXT` via `build_continuation_context`, re-render `coder.prompt.md`, invoke agent, accumulate turns, check status.
- `reconstruct.go` — `_reconstruct_coder_summary` (lines 50-92). Reads git state, writes minimal `CODER_SUMMARY.md` so downstream stages don't crash. Status param ("COMPLETE" default; "FAILED" / "INCOMPLETE" on error paths) preserved.

**Senior-vs-jr coder routing:** The user-supplied scope description mentions a jr-coder routing inside `coder.sh` based on scout's complexity estimate. **In the actual current `stages/coder.sh`, this routing does not exist** — jr coder is only invoked from `stages/review.sh` (the rework cycle, M37 territory) and from the rejected-clarification fallback path. The M39.4 design preserves current behavior: `coder.sh` renders only `coder.prompt.md` (or its tag-specific variants `coder_note_bug` / `coder_note_feat` / `coder_note_polish`). No jr routing in M39.4. **If the user wants jr-routing-by-scout-complexity, it is out of scope and lands as a separate post-M40 feature.** Documented under Watch For.

**Rework-prompt selection:** Similarly, `coder_rework.prompt.md` is rendered inside `stages/review.sh` (line 275, when `REVIEW_CYCLE >= 2` and there are Complex Blockers). It is **not** rendered by `stages/coder.sh`. M37 owns the port of that template's invocation; M39.4 does not re-port it. Documented under Watch For so an implementer doesn't accidentally fold it into the coder package.

### Goal 8 — Bash file deletion and wedge-audit ban (M39.4)

After every caller is migrated and the parity test suite passes, delete in one commit:

```
git rm stages/coder.sh
git rm stages/coder_buildfix.sh
git rm stages/coder_buildfix_helpers.sh
git rm stages/coder_prerun.sh
```

Extend `scripts/wedge-audit.sh`:

```bash
# m39: forbid re-introduction of the coder bash family.
if find stages -maxdepth 1 -name 'coder*.sh' 2>/dev/null | grep -q .; then
    echo "FAIL: stages/coder*.sh ported to internal/coder/ + internal/stages/coder/ in m39." >&2
    echo "  Re-introducing them breaks the Phase 5 stage-port closeout. See docs/go-migration.md." >&2
    exit 1
fi
```

After this commit lands, `stages/` is empty. The wedge audit also asserts `[[ $(find stages -maxdepth 1 -name '*.sh' | wc -l) -eq 0 ]]` as a final witness.

### Goal 9 — Parity test harness reuse

M34 shipped `internal/stagerunner/parity_test.go` with a `recordedFixtures` test pattern: each fixture is a captured stage run (pipeline state, agent transcripts, output artifacts) that the Go stage is replayed against, with byte-identical artifact assertions. M39.4 adds 8 coder fixtures:

| Fixture | What it exercises |
|---------|-------------------|
| `coder-clean-baseline` | Pre-run clean; no fix agent needed; happy path through scout + coder. |
| `coder-prerun-fix-succeeds` | TEST_CMD failing pre-coder; pre-run fix agent succeeds; baseline re-captured. |
| `coder-prerun-fix-fails` | Pre-run fix exhausts `PRE_RUN_FIX_MAX_ATTEMPTS=1`; pipeline proceeds with warn. |
| `coder-scout-trivial` | Scout returns trivial complexity; coder turn budget stays at floor. |
| `coder-scout-large-with-split` | Scout returns large complexity that exceeds the sizing threshold; milestone splits; post-split scout runs. |
| `coder-buildfix-code-dominant-passes` | Build fails; routing = code_dominant; loop succeeds in attempt 1. |
| `coder-buildfix-mixed-uncertain-retry` | Routing = mixed_uncertain; loop retries once then save_exit per M130. |
| `coder-buildfix-progress-stalls` | Routing = code_dominant; loop runs 2 attempts; progress signal = unchanged; bails with `BUILD_FIX_OUTCOME=no_progress`. |

Each fixture lives under `internal/stages/coder/testdata/fixtures/<name>/` with the captured baseline. The parity test runs the Go orchestrator against the fixture's input state and diffs the post-run artifacts.

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `.claude/milestones/m39.1-coder-prerun-port.md` | Create | Child milestone — pre-run sub-package port. |
| `.claude/milestones/m39.2-buildfix-helpers-port.md` | Create | Child milestone — pure-logic helpers port. |
| `.claude/milestones/m39.3-buildfix-loop-and-scout.md` | Create | Child milestone — M128 loop + M130 routing + scout sub-stage port. |
| `.claude/milestones/m39.4-coder-main-stage-port.md` | Create | Child milestone — main orchestrator port, 4 bash deletes, VERSION bump. |
| `.claude/milestones/MANIFEST.cfg` | Modify (by human at review pass) | Add five rows for m39 / m39.1 / m39.2 / m39.3 / m39.4. Not authored by this milestone — the human owns it. |

---

## Acceptance Criteria

- [ ] All four child milestone files (`m39.1-coder-prerun-port.md`, `m39.2-buildfix-helpers-port.md`, `m39.3-buildfix-loop-and-scout.md`, `m39.4-coder-main-stage-port.md`) exist under `.claude/milestones/` and pass the m85 acceptance-criteria linter.
- [ ] Each child's `Depends on` row in `## Overview` matches the corresponding `depends_on` column in `MANIFEST.cfg` (m39.1 depends on m38.6; m39.2 depends on m39.1; m39.3 depends on m39.2; m39.4 depends on m39.3).
- [ ] No bash files under `stages/coder*.sh` are deleted by this parent milestone — deletions live in M39.4.
- [ ] No `VERSION` bump happens at the parent level — the bump lives in M39.4 on close.
- [ ] `internal/coder/` and `internal/stages/coder/` do not yet exist on disk when this parent is filed (the children create them); the parent only authors the design.
- [ ] The parent's status in `MANIFEST.cfg` is `split` (not `todo` / `in_progress` / `done`); the runtime treats split-status parents as descriptive-only and does not schedule them for execution.

## Watch For

- **Scout turn-budget adjustment must preserve floors AND scaling.** `apply_scout_turn_limits` in bash applies the complexity band (Simple / Medium / Large / Milestone) AND a floor invariant (coder ≥ 15, reviewer ≥ 5, tester ≥ 15 by default). The Go port (M39.3) must reproduce BOTH: floors as a clamp, scaling as a band-to-range mapping. A parity-gate test plants a "Files to modify: 1, Estimated lines: 8" scout report and asserts the result tracks the Simple band (coder 15-25) AND clamps to the configured floor — not one or the other.
- **The jr-coder routing by scout complexity does NOT exist in `stages/coder.sh` today.** The user-facing description of M39 mentions "when scout estimates trivial scope, route to jr coder agent (`Files to modify: <=1, Estimated lines: <=20, Interconnected: low`)" — but `stages/coder.sh` has no jr-coder path. Jr coder is invoked from `stages/review.sh` (rework cycle, M37) and from the fallback clarification path only. **M39.4 does NOT add jr-routing-by-scout-complexity** — that's a new feature, not a port. If the user wants it added as part of m39, it belongs in a separate decimal (e.g., m39.5) that lands after the port closes. Documented here so a future implementer doesn't try to invent the routing during the port.
- **`coder_rework.prompt.md` is rendered by `stages/review.sh`, not `stages/coder.sh`.** It fires when `REVIEW_CYCLE >= 2` AND `HAS_COMPLEX` blockers AND `REVIEW_CYCLE < MAX_REVIEW_CYCLES`. M37 owns that template's invocation; M39.4 does not touch it. Searching for `render_prompt "coder_rework"` in the current tree returns one hit: `stages/review.sh:275`. Do NOT add a `coder_rework` rendering to `internal/stages/coder/`.
- **The M128 build-fix loop has 6 separate config knobs — preserve every one byte-identically.** `BUILD_FIX_ENABLED` (gate the loop), `BUILD_FIX_MAX_ATTEMPTS` (default 3), `BUILD_FIX_BASE_TURN_DIVISOR` (default 3 — used as `EFFECTIVE_CODER_MAX_TURNS / divisor`), `BUILD_FIX_MAX_TURN_MULTIPLIER` (default 100 — `* multiplier / 100` upper-bound clamp), `BUILD_FIX_REQUIRE_PROGRESS` (default true — bail when progress signal stalls), `BUILD_FIX_TOTAL_TURN_CAP` (default 120 — cumulative cap across all attempts). Every default must port verbatim. A unit test in `helpers_test.go` asserts each default constant.
- **M130 classification routing has a non-trivial 4-token matrix.** Tokens: `noncode_dominant` (skip loop, write human action, exit), `code_dominant` (loop with code-filtered errors), `mixed_uncertain` (emit BUILD_ROUTING_DIAGNOSIS.md, run loop with extra context, **retry once then save_exit per `BUILD_FIX_CLASSIFICATION_REQUIRED`**), `unknown_only` (low-confidence guidance, bounded fallback). The mixed_uncertain retry-once-then-save_exit sub-routing is the most subtle piece — a parity test must cover it explicitly.
- **The pre-coder fix agent runs in a separate subprocess with its own context.** Bash forks a fresh `run_agent` invocation; the agent does not see the main coder's context, conversation, or scratch state. The Go port (`internal/coder/prerun/`) must preserve subprocess isolation — don't accidentally pass the main orchestrator's `Context` into the pre-run fix agent's `RunAgent` call. The pre-run agent gets its own typed `agent.Invocation` with only the test-output + preflight_fix prompt template, mirroring bash.
- **`PRE_RUN_FIX_MAX_ATTEMPTS=1` and `PRE_RUN_FIX_MAX_TURNS=20` defaults are load-bearing.** The pre-run fix is intentionally bounded — one attempt, 20 turns — to keep the pre-coder phase cheap. Operators reading the pipeline log expect "Fix attempt 1/1..." not "1/3". The Go port preserves these defaults byte-identically; a unit test in `prerun_test.go` asserts both constants.
- **`stages/` is empty after M39 closes.** The wedge audit asserts this. If any future port adds a new bash stage script, it must land under `internal/stages/<name>/` from day one — `stages/` is closed forever after M39. Document this in `scripts/wedge-audit.sh` and `docs/go-migration.md`.
- **`lib/agent_helpers.sh` and `lib/turns.sh` are NOT ported in M39.** They are tightly coupled to the `run_agent` invocation pattern that the stages used, and they are still consumed by other lib helpers (sourced by `DefaultLibHelpers`). Porting them inside M39 would balloon scope past the "stage port" boundary. They are M40 candidates — flagged in Seeds Forward.

## Seeds Forward

- **M39.1 — Coder pre-run port:** Lands `internal/coder/prerun/`. Establishes the `internal/coder/` package shape that M39.2-M39.4 plug into. Smallest decimal — uses M38's recorded-fixture parity harness for a 2-fixture test (clean / fix-succeeds / fix-fails).
- **M39.2 — Build-fix helpers port:** Pure-logic helpers under `internal/coder/buildfix/helpers.go`. Table-tested in isolation. The `ComputeBudget` function gets a 14-row table test covering every branch of the adaptive-budget arithmetic plus every cumulative-cap edge case.
- **M39.3 — Build-fix loop + scout sub-stage:** Consumes M39.2. Ports `coder_buildfix.sh` to `internal/coder/buildfix/loop.go` AND the scout sub-stage from `stages/coder.sh:189-358` to `internal/coder/scout/`. The bundling is deliberate: scout's turn-limit output feeds the build-fix budget through `EFFECTIVE_CODER_MAX_TURNS`, so porting them in separate decimals would require a brittle adapter.
- **M39.4 — Coder main stage port:** Consumes everything. Ports `stages/coder.sh` (1,193 LOC) to `internal/stages/coder/` with sub-files for context blocks, null-run handling, continuation loop, summary reconstruction. Deletes all 4 coder bash files. Updates `stagerunner/helpers.go` to wire `proto.StageCoder.GoImpl`. Extends `wedge-audit.sh` to ban re-introduction. Bumps `VERSION`. Updates `docs/v4-phase5-stub.md` (Phase 5 stage-port arc marked complete) and `docs/go-migration.md` (Phase 5 closeout retro).
- **After M39, `stages/` is empty.** Every stage now lives in `internal/stages/<name>/`. The next major V4 work is dismantling `tekhton-legacy.sh` (3,152 LOC) — its argv parsing, mode dispatch, env setup (the `DefaultLibHelpers` source block, environmental defaults, lifecycle hooks), and the `--diagnose` / `--migrate` / `--health` early-checks all need Go homes. That's a separate initiative (likely M40+) and probably wants its own design pass — possibly a multi-milestone arc on the order of M21 (finalize) or M22 (preflight). Out of M39 scope.
- **`lib/agent_helpers.sh` and `lib/turns.sh` are M40 candidates.** Both are tightly coupled to the agent invocation pattern the stages used: `run_agent` lives in `lib/agent.sh` and pulls in `lib/agent_helpers.sh` for `print_run_summary` and `lib/turns.sh` for `compute_turn_budget`. With every stage now Go-native, the in-process Go callers can use a typed `agent.Run()` API directly — but the bash callers in `lib/` (e.g., `tekhton-legacy.sh`, finalize hooks) still need the bash entry points. M40 (or a M40-prefixed arc) ports `lib/agent_helpers.sh` and `lib/turns.sh` to `internal/agent/` and rewires the bash callers via the m17-pattern subprocess exec. Flagged here so M40 design doesn't start from a blank page.
- **Stage-port arc retro:** Track every patch bump landed during M39.1-M39.4 with a one-line postmortem in `docs/go-migration.md`. M21 had 17 bumps; M22 had 9. Expected range for M39 across all four children: 15-30 (coder is bigger than diagnose). A bump count significantly above the m21 high-water mark is a signal to pause and audit the design.
`

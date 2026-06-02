<!-- milestone-meta
id: "37"
status: "split"
-->

# m37 — Review Stage Port

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | Phase 5 — fourth stage-port milestone in the V4 Phase 5 sprint. M34 established the Go-adapter pattern (`internal/stages/<name>/RunStage(ctx, req) (result, error)` + `StageDef.GoImpl` + `GoAdapter` dispatcher); M35 and M36 refined it across two further stages. M37 lands the most cycle-heavy stage in the pipeline: `stages/review.sh` (385 LOC) plus its sidecar `stages/review_helpers.sh` (78 LOC). Review is the stage where the pipeline's verdict-routing pressure peaks — every CHANGES_REQUIRED verdict re-routes through `coder_rework.prompt.md`, every APPROVED verdict gates onto the tester, every cycle bumps `REVIEW_CYCLE` toward `MAX_REVIEW_CYCLES`, and every specialist blocker spins a second sub-rework. Until M37, review still runs in bash via the `BashAdapter` path while every adjacent stage has moved to `GoImpl`. The cross-stage handoff cost (env composition, source-time helper graph, /tmp request-result file round-trip) is now strictly larger for review than for any other stage in the pipeline. M37 closes that gap. |
| **Gap** | `stages/review.sh` (385 LOC) is the only remaining cycle-driven stage that runs through `BashAdapter`. Its `run_stage_review` function does six things in one big while-loop: (1) skip-heuristic gating (M42 polish, M48 diff-size threshold), (2) per-cycle context assembly (architecture cache, repo-map slice, MILESTONE_BLOCK focus, PRIOR_BLOCKERS_BLOCK toggle), (3) reviewer agent invocation with adaptive turn-budget recalibration (>=85% usage → bump by 25% up to `REVIEWER_MAX_TURNS_CAP`), (4) report parsing — verdict extraction with two grep strategies (heading-anchored and inline fallback), ACP-verdict slice extraction, blocker-line counting via `awk` between section headings, (5) rework routing — `HAS_COMPLEX > 0` → senior coder rework + optional jr-coder follow-up + post-fix build gate; `HAS_SIMPLE > 0` only → jr coder rework + post-fix build gate; each path can retry through a `build_fix_minimal` escalation if the build gate fails twice, (6) terminal-cycle handling — synthesize a minimal `REVIEWER_REPORT.md` with `APPROVED_WITH_NOTES` and trip the commit gate when the agent fails to produce a report at the last cycle. `stages/review_helpers.sh` (78 LOC) holds `_route_specialist_rework`, which runs after the loop closes with an APPROVED verdict: if specialist reviewers reported blockers, push an extra senior-coder rework round + a fresh reviewer pass, but bail with `specialist_blockers` exit if the cycle counter has already hit max. None of this is in Go yet. Review-stage failures continue to surface in the bash pipeline state and run-summary plumbing through the BashAdapter envelope writer instead of returning a typed `proto.StageResultV1` straight from a `RunStage` call. |
| **m37 fills** | The review stage ports to `internal/stages/review/` across two sequenced child milestones following the M34 pattern. **M37.1 — Review helpers + reviewer-result parser:** `internal/review/` package, pure logic chunk. Ports `stages/review_helpers.sh` (the specialist-rework router) plus extracts the report-parsing logic from `stages/review.sh` into a reusable parser: read `REVIEWER_REPORT.md`, classify the verdict (`APPROVED` / `APPROVED_WITH_NOTES` / `CHANGES_REQUIRED` / `REPLAN_REQUIRED`), extract complex-blocker and simple-blocker lists, extract `## ACP Verdicts` slice, compute cycle bookkeeping (current cycle, remaining cycles, at-max signal). Unit-tested with fixtures captured from current bash runs. **M37.2 — Review stage port:** `internal/stages/review/` package consuming the M37.1 parser. Ports the main `run_stage_review` flow — skip heuristics, cycle loop, rework routing, build-gate escalation, terminal-cycle synthesis — registers via `StageDef.GoImpl`, deletes both bash files, parity-tested against a recorded reviewer-output fixture. The cycle loop stays internal to `RunStage` for now (returns once with a final verdict + cycle count). **Cycle-loop placement (design decision, revisitable):** keep the cycle internal to `internal/stages/review/RunStage`. The Go package owns the review→rework→reviewer loop end-to-end and returns a single `proto.StageResultV1` envelope to the runner once a terminal state is reached (APPROVED/APPROVED_WITH_NOTES, max-cycles exhaustion, REPLAN_REQUIRED user decision, specialist-blockers exit). This mirrors current bash behaviour byte-for-byte and avoids opening an orchestrator-touching design question in Phase 5. The implementer should feel free to revisit if the cycle loop turns out to leak state into the runner that's harder to thread back than a single return — but the default is in-stage cycling, and `internal/orchestrate/` does NOT learn about review cycles in this milestone. |
| **Depends on** | m36 |
| **Files changed** | `internal/review/` (new package, ~250 Go LOC: `parser.go`, `parser_test.go`, `specialist.go`, `specialist_test.go`, `testdata/`), `internal/stages/review/` (new package, ~450 Go LOC: `run.go`, `run_test.go`, `cycle.go`, `cycle_test.go`, `rework.go`, `rework_test.go`, `parity_test.go`, `testdata/`), `internal/stagerunner/helpers.go` (modify — `StageReview` entry in `DefaultStageDefs` gets `GoImpl` set, `stages/review_helpers.sh` removed from Helpers list once both bash files delete), `stages/review.sh` (delete in m37.2), `stages/review_helpers.sh` (delete in m37.2), parity test fixture under `internal/stages/review/testdata/fixtures_v4/` (captured before the bash deletes land). |

### Prior arc context

| Milestone | Concern addressed |
|-----------|------------------|
| m34 | First stage-port milestone — established `internal/stages/<name>/RunStage(ctx, req) (result, error)` entry-point shape, `StageDef.GoImpl` field on `stagerunner.StageDef`, and the `GoAdapter` that dispatches Go-native stages from `BashAdapter.Run`. |
| m35 | Second stage-port — refined the pattern under load (a stage with side-effecting helpers); validated that `StageResult` fan-out matches bash globals one-for-one. |
| m36 | Third stage-port — intake. M36.2 introduced verdict-routing helpers in `internal/intake/` that classify reviewer-style verdict tokens; M37.1 reuses these helpers for the review's rework-routing decision (CHANGES_REQUIRED → senior vs. jr vs. both). |
| **m37** | **Review stage ported to `internal/stages/review/` with cycle loop kept in-stage; `internal/review/` parser package extracted; `stages/review.sh` + `stages/review_helpers.sh` deleted; `MAX_REVIEW_CYCLES` semantics preserved byte-for-byte; `REVIEWER_REPORT.md` format byte-for-byte preserved.** |

---

## Design

### Sequencing note

m37 is the fourth stage-port milestone. The two-child split is mandatory because the review-stage logic has a clean fault-line: pure parsing/classification (M37.1) vs. cycle orchestration + agent invocation + bash-file delete (M37.2). Trying to land both as a single milestone is a 460-LOC port with three different testing surfaces (parser unit tests, cycle integration tests, parity fixture replay) — historically those collapse into 10+ patch bumps. The M37.1 parser is independently dogfood-able: it ships with unit tests and is consumed by an interim bridge from the still-bash `run_stage_review` (or stays unused until M37.2 calls it). M37.2 is where the bash deletes happen and the `GoImpl` dispatch lands.

### Goal 1 — `internal/review/` package shape (M37.1)

The review-parser package is pure logic — no I/O beyond reading `REVIEWER_REPORT.md`, no agent invocation, no state mutation. It's a sibling to `internal/intake/` (M36.2) in spirit: a small classifier package the stage runner calls.

```
internal/review/
├── parser.go          # M37.1 — ParseReviewerReport(path) (*Report, error)
├── parser_test.go     # M37.1 — table-driven verdict + blocker-list tests
├── specialist.go      # M37.1 — port of _route_specialist_rework's classification helpers
├── specialist_test.go # M37.1
└── testdata/
    ├── approved.md                       # Verdict: APPROVED, no blockers
    ├── approved_with_notes.md            # Verdict: APPROVED_WITH_NOTES + non-blocking notes
    ├── changes_complex_only.md           # 2 complex, 0 simple
    ├── changes_simple_only.md            # 0 complex, 3 simple
    ├── changes_mixed.md                  # 2 complex, 2 simple
    ├── replan_required.md                # Verdict: REPLAN_REQUIRED + rationale
    ├── inline_verdict_fallback.md        # No heading; "Verdict: APPROVED" inline
    ├── acp_verdicts_present.md           # `## ACP Verdicts` slice with ACCEPT/REJECT/MODIFY
    ├── specialist_blockers_present.md    # SPECIALIST_BLOCKERS env present
    └── synthesized_at_max.md             # The minimal-synthesized format from review.sh:194-211
```

Public surface:

```go
// internal/review/parser.go
package review

type Verdict string

const (
    VerdictApproved          Verdict = "APPROVED"
    VerdictApprovedWithNotes Verdict = "APPROVED_WITH_NOTES"
    VerdictChangesRequired   Verdict = "CHANGES_REQUIRED"
    VerdictReplanRequired    Verdict = "REPLAN_REQUIRED"
    VerdictUnknown           Verdict = ""
)

type Report struct {
    Verdict           Verdict
    ComplexBlockers   []string  // lines from `## Complex Blockers` section (excluding "None")
    SimpleBlockers    []string  // lines from `## Simple Blockers` section (excluding "None")
    NonBlockingNotes  []string  // lines from `## Non-Blocking Notes` section
    CoverageGaps      []string  // lines from `## Coverage Gaps` section
    ACPVerdicts       []ACPVerdict  // parsed `## ACP Verdicts` rows; nil if absent
    DriftObservations []string
    RawBody           string    // for forensic logging; bash sees the whole file via `cat`
}

type ACPVerdict struct {
    Name     string
    Decision string // "ACCEPT" | "REJECT" | "MODIFY"
    Rationale string
}

// ParseReviewerReport reads the file at path, parses the four required sections,
// and returns a Report. Matches bash's `grep -m1 "^## Verdict" -A1` extraction
// AND the inline fallback (`grep -oi "REPLAN_REQUIRED\|APPROVED_WITH_NOTES\|..."`).
// Errors when the file does not exist OR is empty (the synthesize-and-trip-gate
// path is the caller's responsibility, not the parser's).
func ParseReviewerReport(path string) (*Report, error)

// HasComplexBlockers / HasSimpleBlockers mirror the bash HAS_COMPLEX / HAS_SIMPLE
// numeric counts. Replace the awk-between-headings + grep -c "^- " pipeline.
func (r *Report) HasComplexBlockers() int { return len(r.ComplexBlockers) }
func (r *Report) HasSimpleBlockers() int  { return len(r.SimpleBlockers) }

// IsApproved returns true for APPROVED or APPROVED_WITH_NOTES (matches the
// review.sh line 224 routing decision).
func (r *Report) IsApproved() bool {
    return r.Verdict == VerdictApproved || r.Verdict == VerdictApprovedWithNotes
}
```

The parser implementation is deterministic line-scan based — not regex-heavy. It walks the markdown once, switches state machines on `^## ` lines, accumulates lines until the next `^## `, and post-processes (drop "None" lines, strip leading `- `, trim whitespace). The "inline fallback" mode kicks in only when the heading-anchored verdict extraction returns empty: scan the entire body for the first occurrence of one of the four verdict tokens (priority order matches bash: `REPLAN_REQUIRED` > `APPROVED_WITH_NOTES` > `CHANGES_REQUIRED` > `APPROVED`).

**Specialist helpers** (`internal/review/specialist.go`) port the `has_specialist_blockers` predicate and the `SPECIALIST_BLOCKERS` env-tail-append logic from `stages/review_helpers.sh` lines 11-17. Pure string-formatting code; ~30 LOC.

### Goal 2 — Cycle bookkeeping helpers (M37.1)

The bash review loop tracks `REVIEW_CYCLE` (1-indexed, incremented at loop top) against `MAX_REVIEW_CYCLES` (default 3, configurable). The Go port exposes a tiny `CycleBudget` value type so the M37.2 main loop reads naturally:

```go
// internal/review/cycle.go (M37.1)
type CycleBudget struct {
    Current int  // 1-indexed; 0 means "no cycles run yet"
    Max     int
}

func (c CycleBudget) Increment()         // Current++
func (c CycleBudget) Remaining() int     // Max - Current
func (c CycleBudget) IsLastCycle() bool  // Current == Max (use at terminal-cycle synthesize-report decision)
func (c CycleBudget) IsExhausted() bool  // Current >= Max
func (c CycleBudget) BumpFromUsage(used, limit int) (newLimit int, bumped bool)
// BumpFromUsage encapsulates the >=85% usage → +25% / cap-at-REVIEWER_MAX_TURNS_CAP
// recalibration from review.sh lines 132-148. Returns the new limit and a bool
// indicating whether a bump was applied. Hands off the actual env-write to the
// M37.2 caller (BumpFromUsage is read-only — the caller decides whether to
// export ADJUSTED_REVIEWER_TURNS).
```

Why in M37.1: the parser package needs to know nothing about cycles, but the M37.2 cycle loop will compose `Report` + `CycleBudget` heavily. Both ship as small typed values from the M37.1 package; the M37.2 stage code is dominated by orchestration, not arithmetic.

### Goal 3 — `internal/stages/review/` package shape (M37.2)

Mirrors the M34-shipped per-stage layout. Five Go files plus a parity test fixture set.

```
internal/stages/review/
├── run.go             # M37.2 — RunStage(ctx, req) entry point; skip heuristics; loop top
├── run_test.go        # M37.2 — table-driven RunStage outcomes (one row per terminal state)
├── cycle.go           # M37.2 — single-cycle work: assemble context, invoke reviewer agent,
│                      #         consume parser, drive rework routing
├── cycle_test.go      # M37.2
├── rework.go          # M37.2 — RouteRework decides senior / jr / both, invokes agents, runs build gate
├── rework_test.go     # M37.2 — table-driven rework routing matrix
├── parity_test.go     # M37.2 — replay against testdata/fixtures_v4/<scenario>/, diff envelope
└── testdata/
    └── fixtures_v4/
        ├── approved-cycle-1/             # First-cycle APPROVED (no rework)
        ├── changes-then-approved/        # Cycle 1 CHANGES_REQUIRED, cycle 2 APPROVED
        ├── max-cycles-blockers-remain/   # All 3 cycles CHANGES_REQUIRED; expect blockers_remain exit
        ├── synthesized-at-max/           # Reviewer dies all 3 cycles; expect synthesized report + tripped gate
        ├── specialist-rework-then-approved/  # APPROVED then specialist re-route → APPROVED
        └── replan-user-continues/        # REPLAN_REQUIRED + user continues → verdict overridden to APPROVED_WITH_NOTES
```

Public entry point:

```go
// internal/stages/review/run.go
package review

import (
    "context"

    "github.com/geoffgodwin/tekhton/internal/proto"
    reviewparse "github.com/geoffgodwin/tekhton/internal/review"
)

// RunStage is the GoImpl entry registered with StageDef.GoImpl for the
// review stage. Owns the full cycle loop end-to-end: returns once with a
// terminal verdict + cycle count, NOT once per cycle.
func RunStage(ctx context.Context, req *proto.StageRequestV1) (*proto.StageResultV1, error)
```

Internal flow (mirrors `run_stage_review` line-by-line, side-by-side comments cite the bash line numbers):

```go
func RunStage(ctx context.Context, req *proto.StageRequestV1) (*proto.StageResultV1, error) {
    // Skip heuristics — bash lines 14-36.
    if shouldSkipPolish(req) { return approvedWithNotes(req, "polish"), nil }
    if reason, skip := shouldSkipBySize(req); skip { return approvedWithNotes(req, reason), nil }

    estimatePostCoderTurns(req)        // bash line 38
    budget := reviewparse.CycleBudget{Max: maxReviewCycles(req)}

    for budget.Current < budget.Max {
        budget.Increment()             // bash line 44
        report, decision, err := runOneCycle(ctx, req, budget)
        if err != nil {
            return nil, err            // upstream error / null run handling lives in runOneCycle
        }
        switch decision {
        case cycleAccept:
            return finalizeApproved(ctx, req, report, budget)
        case cycleReplanCanceled:
            return failResult(req, "replan_user_aborted"), nil  // bash line 232 exits 1
        case cycleReplanContinue:
            return finalizeApproved(ctx, req, &reviewparse.Report{Verdict: reviewparse.VerdictApprovedWithNotes}, budget)
        case cycleRework:
            if err := runRework(ctx, req, report, budget); err != nil {
                return reworkFailureResult(req, budget, err), nil  // bash lines 335-369 cover this
            }
            continue
        }
    }
    // Max cycles exhausted with blockers remaining — bash lines 354-368.
    return blockersRemainResult(req, budget), nil
}
```

`runOneCycle` encapsulates a single iteration: assemble context (`build_context_packet` + `_add_context_component`), render the reviewer prompt, invoke the agent, handle upstream / null-run / no-report fallbacks, parse the report via `internal/review`, route the replan/approved/changes decision. `runRework` consumes the M37.1 `Report` to decide senior vs. jr vs. both, invokes the relevant agent(s), runs the build gate, and (if the build gate fails) escalates through `build_fix_minimal`.

### Goal 4 — Cycle loop placement decision (state and revisit-window)

The prompt asks where the cycle loop should live. Recommendation, stated for the implementer:

**Decision: keep the cycle internal to `internal/stages/review/RunStage` for M37.** The loop is bash-shaped today — review → rework → reviewer → repeat — and the rework routing decision lives entirely inside the review stage's scope (it doesn't reach across to the runner). Hoisting the loop into `internal/orchestrate/` would require the orchestrator to learn three new concepts: the verdict taxonomy, the senior/jr/both rework matrix, and the build-gate escalation chain. Each of those is review-specific and adds surface area to the orchestrator that benefits no other stage.

**Revisit window: post-M39 (Phase 5 closeout).** Once all stages are Go-native, the orchestrator gains the option to drive cycles uniformly (review cycles, build-fix cycles, possibly intake-clarity cycles). At that point a refactor that lifts the loop into `internal/orchestrate/` becomes plausible without exporting bash-shaped concepts — the verdict taxonomy is already in `internal/proto`, and the routing matrix can be expressed as a small policy object. M37 leaves the seam clean for that future refactor by having `RunStage` return a `StageResult` with `CyclesUsed` populated (a new field on the envelope, or piggybacked on `Metadata`).

**What this milestone does NOT do:** does not touch `internal/orchestrate/`, does not add cycle awareness to the runner, does not change `StageRequestV1` shape beyond optional metadata. Implementer who feels otherwise should escalate via a Drift Observation rather than absorb the scope.

### Goal 5 — `StageResultV1` envelope shape from the review stage

The review stage's terminal outcomes map onto `proto.StageResultV1` as follows (the implementer extends the envelope only if absolutely necessary; preferred path is metadata fields).

| Terminal state | Verdict | ExitReason | Notes |
|----------------|---------|------------|-------|
| Skip — polish heuristic | `pass` | `skipped_polish_mode` | `Metadata["reviewer_skipped"] = "true"` |
| Skip — diff-size threshold | `pass` | `skipped_diff_threshold` | `Metadata["reviewer_skipped"] = "true"` |
| APPROVED on cycle N | `pass` | `approved` | `Metadata["review_cycle"] = "N"`, `Metadata["accepted_acps"]` |
| APPROVED_WITH_NOTES on cycle N | `pass` | `approved_with_notes` | same |
| Synthesized at last cycle | `pass` | `synthesized_at_max` | Commit gate tripped via `internal/gates` API call; `Metadata["commit_gate_tripped"] = "true"` |
| Max cycles, blockers remain | `fail` | `blockers_remain` | `Metadata["complex_blockers"]`, `Metadata["simple_blockers"]` |
| Upstream error at max cycles | `fail` | `upstream_error` | `Metadata["agent_error_subcategory"]` |
| Null run at max cycles | `fail` | `null_run` | |
| Build gate failure after rework | `fail` | `build_failure` | |
| Specialist blockers, no cycles left | `fail` | `specialist_blockers` | |
| REPLAN_REQUIRED, user aborts | `fail` | `replan_user_aborted` | |

The runner reads `Verdict` + `ExitReason` to write `PIPELINE_STATE.md` exactly as today. **The review stage does NOT mutate state files directly** — it only returns the envelope, and `internal/runner/` (or whichever runner-side code reads `StageResult`) calls into `internal/state/` to persist. The bash `write_pipeline_state` calls at lines 156, 171, 347, 360 become Go-side `state.Write(...)` calls dispatched by the runner based on `ExitReason`.

### Goal 6 — Skip-heuristic ports

Two skip heuristics live at the top of `run_stage_review`:

1. **Polish skip (M42).** `should_skip_review_for_polish` returns true if all changed files are non-logic (docs, comments, formatting). Currently a bash function; the M37.2 port either (a) imports the existing Go equivalent if one exists, or (b) inlines the predicate inside `internal/stages/review/run.go` as `shouldSkipPolish(req)` and ports the bash logic verbatim. Audit `lib/` and `internal/` for an existing implementation before re-inventing.

2. **Diff-size skip (M48).** `REVIEW_SKIP_THRESHOLD` (env-driven, default 0 = disabled). When > 0 and `MILESTONE_MODE != "true"`, run `git diff --stat HEAD`, sum insertions+deletions, and skip review if total < threshold. The Go port uses `os/exec` to call git and parses the `--stat` output. Milestone mode is read from `req.Metadata["milestone_mode"]` (set by the runner from env).

Both skips end the stage with `Verdict = pass`, `ExitReason = "skipped_polish_mode"` or `"skipped_diff_threshold"`, and `Metadata["reviewer_skipped"] = "true"`. They never engage the cycle loop.

### Goal 7 — Reviewer agent invocation seam

The bash `run_agent` call (review.sh lines 113-121, 280-289, 300-311, 323-330) is the single biggest dependency the Go port has on the bash world. Each `run_agent` invocation: renders the agent's prompt context, exec's Claude with a turn budget, captures `LAST_AGENT_TURNS` / `AGENT_ERROR_CATEGORY` / `AGENT_ERROR_SUBCATEGORY` / `AGENT_ERROR_MESSAGE`, writes a per-cycle row to `_STAGE_DURATION` and `_STAGE_TURNS`. The Go side already has `internal/supervisor/` (m05-m10) for agent exec; the M37.2 port wires the reviewer/coder-rework/jr-coder calls through that. Audit `internal/runner/` (the wrapper M34 introduced for stage-driven agent calls) for an existing helper before re-inventing.

The invocation seam should expose a typed result the cycle loop reads:

```go
type AgentResult struct {
    TurnsUsed         int
    ExitCode          int
    ErrorCategory     string  // "UPSTREAM" | "" — drives bash line 151 branch
    ErrorSubcategory  string
    ErrorMessage      string
    LastReportPath    string  // resolved path the agent wrote to (REVIEWER_REPORT_FILE)
    NullRun           bool    // matches was_null_run() helper at bash line 165
}
```

The reviewer-recalibration logic (`if usage_pct >= 85 then bump`) lives in `internal/review/cycle.go` (M37.1) via `CycleBudget.BumpFromUsage`. The M37.2 `runOneCycle` calls it and applies the bumped value to the next iteration's turn budget.

### Goal 8 — Build-gate escalation

After every senior/jr rework run, the bash flow runs `run_build_gate "post-fix-pass"`. If that fails, it escalates: render `build_fix_minimal` prompt, invoke a coder agent with `CODER_MAX_TURNS / 3` turns, re-run `run_build_gate "post-fix-pass-retry"`. If THAT fails too, the loop exits with `build_failure` state. The Go port preserves this chain in `runRework`:

```go
if err := runBuildGate(ctx, req, "post-fix-pass"); err != nil {
    if err := invokeBuildFixMinimal(ctx, req); err != nil {
        return fmt.Errorf("build_fix_minimal: %w", err)
    }
    if err := runBuildGate(ctx, req, "post-fix-pass-retry"); err != nil {
        return fmt.Errorf("build_failure_after_retry: %w", err)
    }
}
```

The build gate is already Go-native (m31). The reviewer's `runBuildGate` is a thin wrapper around `internal/gates/build.go` — no new bash subprocess hops are introduced.

### Goal 9 — Terminal-cycle synthesis + commit gate

When the reviewer fails to produce `REVIEWER_REPORT.md` at the last cycle (bash lines 192-213), the stage:

1. Calls `trip_commit_gate "reviewer_did_not_produce_report"`.
2. Synthesizes a minimal report at `REVIEWER_REPORT_FILE` with verdict `APPROVED_WITH_NOTES`.
3. Logs the synthesis.
4. Returns the cycle as if `VERDICT=APPROVED_WITH_NOTES` so the pipeline proceeds to the tester (the tester will catch what the reviewer missed).

The Go port preserves this byte-for-byte (`approved-cycle-1`'s skip path and the `synthesized-at-max` fixture cover both branches). `trip_commit_gate` is currently bash (lives in `lib/gates_completion.sh` shimmed); m31's port may have already moved it Go-side. The M37.2 implementer audits and either calls the Go equivalent or execs `tekhton gate trip --reason ...`.

### Goal 10 — `_route_specialist_rework` port (M37.1 logic, M37.2 wiring)

`stages/review_helpers.sh` runs after the main cycle loop exits APPROVED — if `has_specialist_blockers` returns true, it appends `SPECIALIST_BLOCKERS` to the reviewer report, sets `VERDICT="CHANGES_REQUIRED"`, runs one more senior-coder rework + build gate (with the build-fix-minimal escalation), and runs one more reviewer pass to re-parse the verdict. The bookkeeping piece (decide whether to run, append the section) ports as `internal/review/specialist.go::RouteSpecialistRework(report, budget)` returning a `SpecialistDecision`. The action piece (invoke senior coder + build gate + reviewer) lives in `internal/stages/review/specialist.go` because it needs the same agent-invocation seam the cycle loop uses.

The bash `_route_specialist_rework` exits the process on specialist-blockers-but-no-cycles-left (line 22-27). The Go port returns a `StageResult` with `Verdict=fail, ExitReason="specialist_blockers"` instead — the runner handles the exit. This is consistent with the "stage does not mutate state files directly" rule.

### Goal 11 — Parity testing strategy

`internal/stages/review/parity_test.go` replays six fixtures (listed above) against the Go `RunStage` and asserts the resulting `StageResultV1` envelope matches a pre-captured expected envelope per fixture. Each fixture directory contains:

- `request.json` — the inbound `proto.StageRequestV1`.
- `agent_responses/` — pre-recorded reviewer/coder/jr-coder outputs the test harness replays through a stub `AgentInvoker` (no live Claude exec).
- `expected_result.json` — the `proto.StageResultV1` the Go port should produce.
- `expected_reviewer_report.md` — the final state of `REVIEWER_REPORT.md` after the stage runs (byte-for-byte assertion).

The fixture capture step happens BEFORE the bash deletes land: M37.2's first deliverable is `internal/stages/review/testdata/fixtures_v4/` populated from current bash runs. Once captured, the bash files can delete, and the parity test runs against the Go implementation only.

### Goal 12 — `StageDef.GoImpl` registration + bash file deletion (M37.2)

`internal/stagerunner/helpers.go` (lines 167-170 area) gets:

```go
proto.StageReview: {
    Script:  "stages/review.sh",       // kept as fallback path declaration; never sourced once GoImpl is set
    Helpers: []string{},                // was: []string{"stages/review_helpers.sh"} — removed once helper deletes
    GoImpl:  review.RunStage,           // M37.2 — engages GoAdapter dispatch
},
```

Then:

```
git rm stages/review.sh
git rm stages/review_helpers.sh
```

The `Script` field can stay populated (it's harmless — `GoImpl != nil` short-circuits the bash path in `GoAdapter`) or it can clear. Match what M34-M36 chose for consistency. The implementer audits a prior stage-port milestone's helper.go diff before deciding.

`scripts/wedge-audit.sh` extends in M37.2 to ban re-introduction of `stages/review.sh` and `stages/review_helpers.sh` (same pattern M32.3 used).

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `.claude/milestones/m37.1-review-helpers-and-parser.md` | Create | Child milestone — `internal/review/` parser + specialist helpers + cycle bookkeeping. |
| `.claude/milestones/m37.2-review-stage-port.md` | Create | Child milestone — `internal/stages/review/` port, bash file deletes, `GoImpl` registration, parity test. |
| `.claude/milestones/MANIFEST.cfg` | Modify (by human at review pass) | Add three rows for m37 / m37.1 / m37.2. Not authored by this milestone — the human owns it. |

---

## Acceptance Criteria

- [ ] Both child milestone files (`m37.1-review-helpers-and-parser.md`, `m37.2-review-stage-port.md`) exist under `.claude/milestones/` and pass the m85 acceptance-criteria linter.
- [ ] Each child's `Depends on` row in `## Overview` matches the corresponding `depends_on` column in `MANIFEST.cfg` (m37.1 depends on m36.3; m37.2 depends on m37.1).
- [ ] No bash files under `stages/review*.sh` are deleted by this parent milestone — deletions live in M37.2.
- [ ] No `VERSION` bump happens at the parent level — the bump lives in M37.2 on close.
- [ ] `internal/review/` and `internal/stages/review/` do not yet exist on disk when this parent is filed (the children create them); the parent only authors the design.
- [ ] The parent's status in `MANIFEST.cfg` is `split` (not `todo` / `in_progress` / `done`); the runtime treats split-status parents as descriptive-only and does not schedule them for execution.
- [ ] The parent file states explicitly that the cycle loop stays inside `internal/stages/review/RunStage` for M37 (no `internal/orchestrate/` changes in this arc), and that the post-M39 hoist is a Seeds-Forward candidate, not a wedge concern.

## Watch For

- **`MAX_REVIEW_CYCLES` must be respected exactly as today.** The bash loop uses `${MAX_REVIEW_CYCLES:-3}` as both the loop bound (line 43) and the at-max sentinel (lines 154, 169, 182, 271, 354). Off-by-one errors here change pipeline behavior: stopping one cycle early skips the synthesize-and-trip-gate fallback; stopping one cycle late lets the agent loop forever. M37.1's `CycleBudget` and M37.2's `runOneCycle` must both consult the same value, sourced from `req.Metadata["max_review_cycles"]` (or a config helper). A unit test plants `Max=2` and asserts exactly two reviewer invocations occur before the blockers-remain return.
- **NEEDS_REWORK → coder routing path triggers `coder_rework.prompt.md`, NOT `coder.prompt.md`.** The initial coder uses `coder.prompt.md` (rendered by `stages/coder.sh`); the review-routed rework uses `coder_rework.prompt.md` (rendered at review.sh lines 275 and 29 of `review_helpers.sh`). The two prompts have different role guidance — rework knows about the prior reviewer report; the initial coder does not. The Go port MUST call `render_prompt("coder_rework")` for the rework path. Mixing them up will burn an entire dogfood cycle re-explaining the task to a re-initial coder.
- **`REVIEWER_REPORT.md` format byte-for-byte preservation.** The metrics subsystem (`internal/metrics/`) parses this file. Section headings (`## Verdict`, `## Complex Blockers`, `## Simple Blockers`, `## Non-Blocking Notes`, `## Coverage Gaps`, optionally `## ACP Verdicts`, `## Drift Observations`, `## Specialist Blockers`), the literal word "None" on its own line for empty sections, and the verdict tokens (`APPROVED` / `APPROVED_WITH_NOTES` / `CHANGES_REQUIRED` / `REPLAN_REQUIRED`) are operator vocabulary. The synthesize-at-max-cycles report (review.sh lines 194-211) is byte-for-byte preserved by M37.2 — capture the current bash output into `internal/stages/review/testdata/fixtures_v4/synthesized-at-max/expected_reviewer_report.md` and assert against it.
- **The review stage does NOT mutate state files directly.** Every `write_pipeline_state` call in the bash version (lines 156, 171, 347, 360, plus 23 in `review_helpers.sh`) maps onto a `StageResult` field (`Verdict` + `ExitReason` + `Metadata`). The runner reads the envelope and persists. This rule MUST hold — the M34-M36 pattern depends on it, and breaking it leaks side effects past the stage seam.
- **The reviewer turn-budget recalibration is in-loop.** The `if usage_pct >= 85 then bump 25%` logic (review.sh lines 132-148) applies BETWEEN cycles, not after the whole stage. The bumped `ADJUSTED_REVIEWER_TURNS` value affects the next iteration's `run_agent` call. The Go port preserves this: `CycleBudget.BumpFromUsage(used, limit)` returns a new limit; M37.2's `runOneCycle` passes it to the next iteration's `AgentInvoker.Invoke(...)`.
- **`_route_specialist_rework` exits cleanly only on success — its failure paths exit the process via `error + exit 1`.** The bash version (`review_helpers.sh` lines 22-27, 50-55) prefers `exit 1` over graceful return. The Go port converts these to `StageResult{Verdict: fail, ExitReason: ...}` returns. A test that runs the specialist-blockers-at-max-cycle fixture asserts the returned envelope (not a process exit code) carries `ExitReason = "specialist_blockers"`.
- **The skip heuristics (M42 polish, M48 diff-size) run BEFORE the cycle loop and bypass it entirely.** Both return `APPROVED_WITH_NOTES` and set `REVIEWER_SKIPPED=true`. The Go port surfaces both via `Metadata["reviewer_skipped"] = "true"` — downstream stages (tester, finalize) consume this flag to alter their behaviour. Audit the runner's StageResult-to-env propagation to confirm `Metadata` keys flow through correctly.
- **Cycle-loop placement is design-locked for M37.** Stating it explicitly: the implementer does not hoist the loop into `internal/orchestrate/` as part of this arc. If the implementer finds the in-stage loop produces an awkward `RunStage` signature, open a Drift Observation and continue — the post-M39 refactor window is the right time to revisit, not mid-port.
- **The bash `print_run_summary` calls (review.sh lines 127, 290-292 commentary, 308-310 commentary, 331-332 commentary, 380-381 commentary) implement M96 (IA1) suppression rules.** The Go port preserves the same suppress-after-sub-agent rule: a single cycle calls `printRunSummary` once after the reviewer pass, not after each rework sub-agent. The fixture `changes-then-approved` asserts exactly two summary lines in the captured stdout.

## Seeds Forward

- **M37.1 — Review helpers + parser:** Lands the pure-logic package `internal/review/`. Defines `Report`, `Verdict`, `ACPVerdict`, `CycleBudget`. Ports `stages/review_helpers.sh`'s classification helpers. The package is independently unit-tested with the 10 testdata fixtures and consumable from any future review-adjacent code (e.g. M37.2's stage, but also a future `tekhton review summarize` CLI surface).
- **M37.2 — Review stage port:** Lands `internal/stages/review/` consuming M37.1. Wires `StageDef.GoImpl = review.RunStage` in `internal/stagerunner/helpers.go`. Deletes `stages/review.sh` + `stages/review_helpers.sh`. Adds the six-scenario parity fixture set. Extends `scripts/wedge-audit.sh` to ban re-introduction of either bash file. Bumps `VERSION` on close.
- **Cycle-loop hoist (post-M39 candidate, NOT scope for M37):** Once all stages are Go-native (M39 closeout), the runner gains the option to drive review cycles uniformly with build-fix and clarity cycles. The hoist would lift the loop body of `RunStage` into a generic `cycler.Run(req, runOne)` helper in `internal/orchestrate/` or a new `internal/cycle/` package. M37's in-stage loop preserves bash parity TODAY without prejudicing this future refactor: the `CycleBudget` value type and the `runOneCycle` function are already the right shape to hoist.
- **`internal/review/` consumers beyond the stage:** the parser package is reusable by a future operator-facing `tekhton review parse <report.md>` CLI surface (useful for forensics / metrics drilldowns) and by `internal/metrics/` if metrics chooses to upgrade from awk-line-count to typed parsing.
- **Specialist-review subsystem cleanup:** the `_route_specialist_rework` path is currently a sidecar bolted onto the main loop. Once it ports to Go (M37.2), a future arc can consider absorbing the specialist re-route into the main cycle as an extra verdict (`APPROVED_PENDING_SPECIALISTS`) rather than a post-loop side branch. Not M37 scope.
- **Verdict-routing helper consolidation:** M36.2's `internal/intake/` verdict helpers and M37.1's `internal/review/` parser share token classification logic. A future cleanup arc could extract a shared `internal/verdict/` package both reuse. Watch for cycle-import hazards if either package grows to consume the other's types.
`

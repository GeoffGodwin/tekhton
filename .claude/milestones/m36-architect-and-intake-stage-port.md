<!-- milestone-meta
id: "36"
status: "split"
-->

# m36 — Architect + Intake Stage Port

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | Phase 5 — third stage-port milestone in the V4 sprint. M34 (coder + cleanup) established the `internal/stages/<name>/` adapter pattern; M35 (security + tester + docs) refined it. M36 ports the two pre-stage gates: the **architect** (drift audit + ADL remediation router) and the **intake** (PM clarity gate). These two stages bookend every other stage in `tekhton-legacy.sh`'s stage plan — intake runs every pipeline as the first gate; architect runs only when drift thresholds are exceeded. Until both are Go-native the V4 stage dispatcher still has bash-callable stage entries, the `internal/stages/` package is incomplete, and the wedge-audit cannot promise zero pre-stage bash. |
| **Gap** | `stages/architect.sh` (414 LOC) and `stages/intake.sh` (377 LOC) are still bash. They sit alongside `lib/intake_helpers.sh` (267 LOC) and `lib/intake_verdict_handlers.sh` (204 LOC), a four-file pre-stage subsystem totalling ~1,262 LOC. The architect already reads its drift / ADL inputs through the M25-shipped `internal/drift/` package — but the orchestration (prompt rendering, agent invocation, plan parsing, sr/jr coder dispatch, expedited reviewer, resolve-all + Out-of-Scope re-add, design-doc HUMAN_ACTION append, audit-counter reset) is bash. The intake sits on top of two helper files that hash content, parse the verdict / confidence / questions / tweaks sections of `INTAKE_REPORT.md`, apply tweaks to a milestone file (with backup + size-guard), and route to `_intake_handle_tweaked` / `_intake_handle_split_recommended` / `_intake_handle_needs_clarity`. The verdict-handler text — especially the NEEDS_CLARITY message and the questions file format — is operator-facing and email-filtered. |
| **m36 fills** | The four bash files port to `internal/stages/architect/`, `internal/stages/intake/`, and a shared `internal/intake/` package across three sequenced child milestones, each independently dogfood-able. **M36.1 — Architect stage:** Port `stages/architect.sh` to `internal/stages/architect/` (RunStage entry, sr/jr router, expedited-review caller, drift-resolve flow). Architect already calls `internal/drift/` for reads; the port keeps that boundary clean. `prompts/architect*.prompt.md` (four files) stay on disk — only the renderer caller moves. Delete `stages/architect.sh`. **M36.2 — Intake helpers:** Port `lib/intake_helpers.sh` + `lib/intake_verdict_handlers.sh` to `internal/intake/{helpers.go, verdict.go}`. Add Go unit tests. The bash `stages/intake.sh` keeps running via shim functions in the deleted files' place that exec back into the Go binary — no caller breaks until M36.3. **M36.3 — Intake stage:** Port `stages/intake.sh` to `internal/stages/intake/` using the M34 pattern and the M36.2 helpers. Delete `stages/intake.sh` AND the two helper bash files (now caller-less). All three preserve operator-visible text (rejection message, NEEDS_CLARITY questions format, sr/jr rework routing) byte-for-byte against frozen baselines captured at the parent. |
| **Depends on** | m35 |
| **Files changed** | `internal/stages/architect/` (new package — M36.1, ~450 Go LOC), `internal/stages/intake/` (new package — M36.3, ~420 Go LOC), `internal/intake/` (new package — M36.2, ~500 Go LOC across helpers.go + verdict.go + tests), `internal/stagerunner/helpers.go` (modify each child — register `GoImpl` for architect / intake on the matching `StageDef`), `stages/architect.sh` (delete in M36.1), `stages/intake.sh` (delete in M36.3), `lib/intake_helpers.sh` (delete in M36.3 after M36.2 ports the body), `lib/intake_verdict_handlers.sh` (delete in M36.3), `internal/stagerunner/helpers.go` `DefaultStageDefs` entries for intake (remove `Helpers` array as bash helpers are gone), `scripts/wedge-audit.sh` (modify per child — extend forbid lists), parity gates `tests/test_architect_parity.sh` + `tests/test_intake_parity.sh` (new), `cmd/tekhton/intake.go` (new — `tekhton intake helpers <subcmd>` for M36.2 temporary shim). |

### Prior arc context

| Milestone | Concern addressed |
|-----------|------------------|
| m25 | Drift subsystem ported to `internal/drift/`. Architect (M36.1) consumes drift state via that package — no direct file IO. |
| m34 | First stage-port milestone — established `internal/stages/<name>/` layout, `RunStage(ctx, req) (result, error)` signature, `StageDef.GoImpl` field, `GoAdapter` dispatch. |
| m35 | Refined the pattern across security + tester + docs (three same-shape stages with helpers ports). Validated the rule "helpers port first, stage second, bash file deletion lives with the porting milestone." |
| **m36** | **Pre-stage gates (architect + intake) ported; the four bash files delete; the `internal/stages/` package now contains every stage except the orchestrator (coder is m34, security/tester/docs is m35, architect/intake is m36; review is m37; cleanup is the m34 trailing piece).** |

---

## Design

### Sequencing note

The three children must run in order: helpers → stage. M36.1 ports the architect (whose own "helpers" — the drift reads — already live in `internal/drift/`). M36.2 ports the intake helpers but leaves `stages/intake.sh` calling them via temporary CLI shims (`tekhton intake helpers ...`) so the bash stage keeps working until M36.3. M36.3 then ports the intake stage and deletes the two helper bash files (`lib/intake_helpers.sh`, `lib/intake_verdict_handlers.sh`) along with `stages/intake.sh`. This three-step shape — helpers-first, with the bash stage delegating to the Go helpers for one milestone in the middle — matches the M35 tester arc.

The order matters because:

1. Reversing helpers/stage would mean porting the stage against a still-bash helper surface, which forces the Go stage to exec back into bash to call `_intake_parse_verdict` etc. — a regression of the M34 inversion.
2. Deleting the helper bash files in M36.2 (before stage port) would break `stages/intake.sh`, which sources them via the stagerunner's per-stage `Helpers` list.
3. The architect (M36.1) ports first because it has zero coupling to the intake helper surface, validates the pre-stage gate pattern at a thinner port, and unblocks the M36.2/M36.3 sequence to ship without waiting on architect work.

### Goal 1 — `internal/stages/architect/` package shape (M36.1)

```
internal/stages/architect/
├── architect.go           # RunStage entry, sr/jr router, drift-resolve flow
├── architect_test.go
├── plan_parser.go         # Parse ARCHITECT_PLAN.md: Simplification / Staleness Fixes / Dead Code / Naming / Out of Scope / Design Doc Observations
├── plan_parser_test.go
├── remediation.go         # Sr coder + Jr coder dispatch + build gate + expedited review
├── remediation_test.go
└── testdata/
    ├── plan_baseline.md   # Frozen v3-format architect plan
    └── plan_no_action.md  # Architect-found-nothing variant
```

The package depends on:

- `internal/drift/` — `drift.Count`, `drift.ResolveAll`, `drift.AddEntries`, `drift.AppendHumanAction`, `drift.ResetAudit`. M25 already wraps these as CLI subcommands; the M36.1 port calls them as Go functions (no subprocess), eliminating six `tekhton drift ...` execs per architect run.
- `internal/prompt/` — `prompt.Render("architect")` / `"architect_sr_rework"` / `"architect_jr_rework"` / `"architect_review"`. The four `prompts/architect*.prompt.md` files stay on disk.
- `internal/stagerunner/` — `RunStage(ctx, req) (*proto.StageResultV1, error)` is the entry; the `architect` stage gets `GoImpl: architect.RunStage` in `DefaultStageDefs`.

The plan parser is the bulk of new logic. The bash code uses `awk` per section, then per-bullet handling with multi-line continuation, then a long grep filter chain that excludes placeholder/meta entries (lines 295-303 for Out of Scope; lines 360-377 for Design Doc Observations). Port these as a single Go function `parseSections(reader io.Reader) parsedPlan` that returns the parsed bullet lists per section. The filter chain ports as a slice of `regexp.MustCompile` patterns matched per bullet.

The sr/jr router (lines 152-194) checks two section emptiness flags and routes via `agent.Run`. The expedited review (lines 229-251) runs only when remediation actually ran. Build gate uses the existing `internal/gates/` package (already Go since m31).

### Goal 2 — `internal/intake/` package shape (M36.2)

```
internal/intake/
├── helpers.go             # MilestoneContent, ContentHash, ShouldSkip, SaveHash, ParseVerdict, ParseConfidence, ParseTweaks, ParseQuestions, ApplyTweakMilestone, ApplyTweakTask, AddPMMetadata
├── helpers_test.go
├── verdict.go             # HandleTweaked, HandleSplitRecommended, HandleNeedsClarity
├── verdict_test.go
└── testdata/
    ├── report_pass.md
    ├── report_tweaked.md
    ├── report_split.md
    ├── report_needs_clarity.md
    └── milestone_long.md  # 100-line milestone for shrinkage-guard regression test
```

API surface (consumed by M36.3):

```go
// helpers.go
type Helpers struct {
    ProjectDir          string
    TekhtonHome         string
    SessionDir          string
    MilestoneDir        string
    ClarificationsFile  string
}

func (h *Helpers) MilestoneContent(milestoneMode bool, current string) (string, error)
func (h *Helpers) ContentHash(content string) string
func (h *Helpers) ShouldSkip(hash string) bool
func (h *Helpers) SaveHash(hash string) error
func (h *Helpers) ParseVerdict(reportPath string) string  // PASS|TWEAKED|SPLIT_RECOMMENDED|NEEDS_CLARITY
func (h *Helpers) ParseConfidence(reportPath string) int
func (h *Helpers) ParseTweaks(reportPath string) string
func (h *Helpers) ParseQuestions(reportPath string) string
func (h *Helpers) ApplyTweakMilestone(content, msNum string, minPct int) error  // 50% shrinkage guard
func (h *Helpers) ApplyTweakTask(content string) (newTask string, err error)
func (h *Helpers) AddPMMetadata(msFile string) error

// verdict.go
type VerdictHandler struct {
    H                 *Helpers
    AutoSplit         bool
    ConfirmTweaks     bool
    CompleteMode      bool
    PipelineStateFn   func(stage, reason, args, task, msg, ms string) error  // injected from state package
    TekhtonBin        string
}

func (v *VerdictHandler) HandleTweaked(reportPath string) error
func (v *VerdictHandler) HandleSplitRecommended(reportPath string) error
func (v *VerdictHandler) HandleNeedsClarity(reportPath string) error
```

**Critical byte-for-byte preservation:** The rejection message at `lib/intake_verdict_handlers.sh:53-60` (the "Tweaks rejected by user. Saving state." line) and the `## Clarification Required` block written to `CLARIFICATIONS.md` (line 146-160) are operator vocabulary. Operators have email filters keyed off these strings. The Go port must emit them with no whitespace / punctuation drift.

The size-guard logic (`_intake_apply_tweak_milestone` lines 124-139) — reject the tweak if the new content is < `INTAKE_TWEAK_MIN_SIZE_PCT` (default 50%) of the original line count — ports as a unit-tested branch in `ApplyTweakMilestone`. A regression test feeds a 100-line milestone + a 10-line tweak and asserts the result file is unchanged and `<SessionDir>/REJECTED_TWEAK.md` contains the rejected tweak.

The temporary CLI shim during the M36.2-only window:

```go
// cmd/tekhton/intake.go (M36.2)
// `tekhton intake helpers parse-verdict --report <path>`
// `tekhton intake helpers parse-confidence --report <path>`
// `tekhton intake helpers parse-questions --report <path>`
// `tekhton intake helpers parse-tweaks --report <path>`
// `tekhton intake helpers content-hash --content <stdin>`
// `tekhton intake verdict tweaked --report <path>`
// `tekhton intake verdict split-recommended --report <path>`
// `tekhton intake verdict needs-clarity --report <path>`
```

These subcommands stay hidden. They exist solely so `stages/intake.sh` can call the Go helpers during the M36.2 → M36.3 window. M36.3 deletes the shim subcommands when it deletes `stages/intake.sh`.

### Goal 3 — `internal/stages/intake/` package shape (M36.3)

```
internal/stages/intake/
├── intake.go              # RunStage entry, banner + skip + cache + render + verdict route
├── intake_test.go
├── context.go             # ProjectIndex + HistoryBlock + HealthSummary + NotesContext builders
├── context_test.go
└── testdata/
    ├── milestone_pass.md
    └── milestone_needs_clarity.md
```

The stage logic ports verbatim from `stages/intake.sh` but consumes the M36.2 `internal/intake/` helpers in-process. The cached-run branch (lines 65-82) becomes a single Go conditional. The history block (lines 116-130) becomes a call into `internal/causal/` (already Go), eliminating two `verdict_history` / `events_by_type` bash function calls.

The notes-context filter (lines 145-179) — the keyword-overlap match between task words and human-note text — ports as a Go function with the same 4-char minimum and case-insensitive match. The result feeds the `NOTES_CONTEXT_BLOCK` prompt variable identically.

The `run_intake_create` mode (lines 244-377) — the `--add-milestone` entry — does NOT port in M36.3. It is invoked from `tekhton-legacy.sh` outside the stage runner and has its own scope (manifest mutation, milestone-id allocation). M36.3 leaves it as bash residue, addressed by a later milestone. A note lands in `docs/v4-phase5-stub.md`.

### Goal 4 — `StageDef.GoImpl` registration

Each child registers its Go-native entry on the `DefaultStageDefs` entry. The M34 pattern:

```go
// internal/stagerunner/helpers.go
var DefaultStageDefs = map[string]StageDef{
    proto.StageIntake: {
        Script: "stages/intake.sh",  // kept for fallback during transition
        Helpers: []string{
            "lib/intake_helpers.sh",        // M36.2 -> deleted in M36.3
            "lib/intake_verdict_handlers.sh", // M36.2 -> deleted in M36.3
        },
        GoImpl: intake.RunStage,  // M36.3 sets this; until then nil
    },
    // architect appears here only when promoted by get_run_stage_plan;
    // M36.1 registers it as a Go-native entry with no bash fallback.
    proto.StageArchitect: {
        GoImpl: architect.RunStage,  // M36.1
    },
}
```

The `GoAdapter` dispatch at the top of `BashAdapter.Run` checks `def.GoImpl != nil` and routes to Go. M34/M35 established this; M36 only adds rows.

### Goal 5 — Parity gates

Two parity gates land, one per stage:

- `tests/test_architect_parity.sh` (M36.1) — runs the Go architect against a frozen v3 baseline (mock drift log + ARCHITECT_PLAN.md) and asserts: drift count call sequence, sr/jr agent dispatch when each section is non-empty, post-resolve drift count, Out-of-Scope re-add count, HUMAN_ACTION_REQUIRED.md byte-identical append, audit-counter reset.

- `tests/test_intake_parity.sh` (M36.3) — runs the Go intake against frozen v3 baselines for each verdict path (PASS, TWEAKED, SPLIT_RECOMMENDED, NEEDS_CLARITY). Asserts: `INTAKE_VERDICT` / `INTAKE_CONFIDENCE` exports match, the `_INTAKE_PASS_EMIT` flag flips on PASS, `CLARIFICATIONS.md` is byte-identical for the NEEDS_CLARITY path, and the rejection-message text is byte-identical for the user-rejected-tweak path.

Both gates wire into `make dogfood` and the m20 "before-merge" CI check.

### Goal 6 — Drift writes stay through `internal/drift/`

The architect stage writes to the drift log, the HUMAN_ACTION_REQUIRED.md file, and the audit-counter file. Every one of those writes must go through `internal/drift/` (the M25-shipped package) — never direct `os.WriteFile` from `internal/stages/architect/`. This is a parity invariant: M25 owns the file format and lock semantics for drift state. M36.1 calls `drift.ResolveAll`, `drift.AddEntries`, `drift.AppendHumanAction`, `drift.ResetAudit`. The wedge-audit (m32 pattern) extends to ban direct writes from `internal/stages/architect/` to `ARCHITECTURE_LOG.md` / `DRIFT_LOG.md` / `HUMAN_ACTION_REQUIRED.md`.

### Goal 7 — INTAKE_CLARITY_THRESHOLD respect

The intake stage today does **not** itself enforce the `INTAKE_CLARITY_THRESHOLD` — the threshold is consulted by the **agent prompt template** (`prompts/intake_scan.prompt.md`) and the agent decides the verdict. The Go port preserves this: `internal/stages/intake/` renders the prompt with `INTAKE_CLARITY_THRESHOLD` injected as a template variable (m15 prompt engine handles this already). The stage Go code does NOT short-circuit on confidence < threshold — the verdict from the report file is authoritative. This matches bash behavior at `stages/intake.sh:201-205`. The internal config validator (`internal/config/validate.go:122-127`) continues to clamp the threshold to 0-100.

### Goal 8 — Bash file deletion sequencing

| Milestone | Deletes |
|-----------|---------|
| M36.1 | `stages/architect.sh` |
| M36.2 | (none — bash stages still call helpers via shim) |
| M36.3 | `stages/intake.sh`, `lib/intake_helpers.sh`, `lib/intake_verdict_handlers.sh` |

The wedge-audit extends per milestone:

- M36.1: forbid `stages/architect.sh` re-introduction.
- M36.3: forbid `stages/intake.sh`, `lib/intake_helpers.sh`, `lib/intake_verdict_handlers.sh` re-introduction; remove the `Helpers` entries for `proto.StageIntake` from `DefaultStageDefs`.

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `.claude/milestones/m36.1-architect-stage-port.md` | Create | Child — architect stage port. |
| `.claude/milestones/m36.2-intake-helpers-port.md` | Create | Child — intake helpers port (helpers.go + verdict.go). |
| `.claude/milestones/m36.3-intake-stage-port.md` | Create | Child — intake stage port + helper bash deletes + stage-helpers cleanup. |
| `.claude/milestones/MANIFEST.cfg` | Modify (by human at review pass) | Add four rows for m36 / m36.1 / m36.2 / m36.3. Not authored by this milestone. |

---

## Acceptance Criteria

- [ ] All three child milestone files (`m36.1-architect-stage-port.md`, `m36.2-intake-helpers-port.md`, `m36.3-intake-stage-port.md`) exist under `.claude/milestones/` and pass the m85 acceptance-criteria linter.
- [ ] Each child's `Depends on` row matches MANIFEST.cfg (`m36.1` → m35.3; `m36.2` → m36.1; `m36.3` → m36.2). Parent `m36` depends on `m35`.
- [ ] No bash files under `stages/` or `lib/intake*` are deleted by this parent milestone — deletions live in the children.
- [ ] `internal/stages/architect/`, `internal/stages/intake/`, and `internal/intake/` do NOT yet exist on disk when this parent is filed; the children create them.
- [ ] The parent's status in `MANIFEST.cfg` is `split`; the runtime treats split-status parents as descriptive-only and does not schedule them for execution.
- [ ] No `VERSION` bump at the parent level — bumps happen on each child close (M36.1, M36.2, M36.3 each ship a minor bump).

## Watch For

- **The architect routes to FOUR distinct rework prompts.** `architect.prompt.md` drives the audit; `architect_review.prompt.md` drives the expedited reviewer; `architect_sr_rework.prompt.md` is the senior-coder rework; `architect_jr_rework.prompt.md` is the junior-coder rework. The senior/junior split (sr handles Simplification; jr handles Staleness + Dead Code + Naming) is preserved in the Go port — same model + max-turns dispatch per branch. Do not collapse the four prompts into a single conditional template — operators tune per-prompt frontmatter (model, tools) and the four-file shape is the contract.
- **Drift writes must go through `internal/drift/`, never direct file IO.** The architect stage produces three side effects: drift-log resolution (`drift.ResolveAll` + `drift.AddEntries` for Out-of-Scope re-add), HUMAN_ACTION_REQUIRED.md append (`drift.AppendHumanAction`), and audit counter reset (`drift.ResetAudit`). M25 owns the file formats; M36.1 must NOT bypass with direct writes. The wedge-audit gains a check that `internal/stages/architect/` does not import `os` writes against any drift-owned path.
- **`INTAKE_CLARITY_THRESHOLD` is respected by the intake agent prompt, NOT by the Go stage code.** The threshold injects as a prompt variable (m15 engine handles); the verdict from `INTAKE_REPORT.md` is authoritative. Do not introduce a Go-side `if confidence < threshold { verdict = NEEDS_CLARITY }` — that would double-gate and break the agent contract.
- **The intake rejection-message text is byte-for-byte operator-facing.** Lines `Intake: tweaks applied. Review required (INTAKE_CONFIRM_TWEAKS=true).` and `Tweaks rejected by user. Saving state.` and the `## Clarification Required` / `## Q: ...` format written to `CLARIFICATIONS.md` are operator vocabulary. Operators have email filters keyed off these strings. M36.2 ports them as Go string constants with no whitespace / punctuation drift; M36.3's parity gate diff-tests them.
- **The architect runs ONLY when triggered (uncommon path); the intake runs every pipeline.** M36.1's parity gate must capture both the "audit ran" branch and the "audit skipped" branch (the pre-stage plan does not promote architect by default). M36.3's parity gate captures four branches (PASS, TWEAKED, SPLIT_RECOMMENDED, NEEDS_CLARITY) + the cached-run branch (line 65-82) + the disabled / HUMAN_MODE skip branches.
- **`run_intake_create` (--add-milestone) is OUT of scope for M36.3.** It runs outside the stage runner (invoked directly from `tekhton-legacy.sh`) and has its own scope (manifest mutation, ID allocation). M36.3 only ports `run_stage_intake`. A note in `docs/v4-phase5-stub.md` defers `run_intake_create` to a later milestone.
- **The helpers-first ordering matters.** Porting `stages/intake.sh` before `lib/intake_helpers.sh` would force the Go stage to exec back into bash for parsing — a regression of the M34 inversion. M36.2 strictly precedes M36.3; M36.2 also keeps the bash files alive (via a temporary `tekhton intake helpers ...` shim) so `stages/intake.sh` keeps working in the middle window.
- **Stage-helpers entry in `DefaultStageDefs`.** M36.3 must remove the two `Helpers` entries for `proto.StageIntake` when the bash helpers delete. Leaving them in causes `BashAdapter` to attempt sourcing missing files and exit 127 if a stage somehow falls back to bash (which it shouldn't post-M36.3, but the wedge-audit catches the dead entry too).

## Seeds Forward

- **M36.1 — Architect stage port:** Lands the architect stage Go-native. Validates the "stage that's already Go-adjacent thanks to internal/drift/" port pattern. Deletes `stages/architect.sh`. Parity gate `tests/test_architect_parity.sh` captures the drift-resolve flow.
- **M36.2 — Intake helpers port:** Ports the two-file helper subsystem to `internal/intake/`. Establishes the operator-vocabulary preservation pattern (rejection message, NEEDS_CLARITY format, sr/jr text constants). Adds a temporary `tekhton intake helpers ...` CLI shim so `stages/intake.sh` keeps working until M36.3.
- **M36.3 — Intake stage port:** Closes the arc. Ports `stages/intake.sh` consuming the M36.2 helpers in-process. Deletes the three remaining bash files. Removes the M36.2 CLI shim. Parity gate `tests/test_intake_parity.sh` validates four verdict paths.
- **M37 — Review stage port (next arc):** Follows the same decimal pattern (helpers first, stage second, bash delete last). The `internal/intake/` package's verdict-routing helpers will be reused by the review stage's rework router in M37 — review has a near-identical ACCEPT / NEEDS_REWORK / BLOCKED verdict shape, and the M36.2 `VerdictHandler` pattern is the template.
- **Pre-stage gate framework consolidation:** After M36 closes, both pre-stage gates live in `internal/stages/` with shared helpers in `internal/intake/`. A future arc (V5 candidate) could extract a `internal/prestage/` interface that the dispatcher consults to decide which gates to run — replacing `get_run_stage_plan`'s bash conditional. Designed in M36.3 as a comment in `internal/stages/intake/intake.go`.
- **`run_intake_create` (--add-milestone) port:** The create-mode entry from `stages/intake.sh:244-377` is deferred from M36.3. A future milestone (m36.4 candidate) ports it to `cmd/tekhton/milestone.go add-milestone ...` reusing M36.2's helpers. Tracked in `docs/v4-phase5-stub.md` as a Phase 5 follow-up.

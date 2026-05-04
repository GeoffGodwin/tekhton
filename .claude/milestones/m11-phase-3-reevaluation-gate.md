<!-- milestone-meta
id: "11"
status: "todo"
-->

# m11 — Phase 3 Re-evaluation Gate: Ship of Theseus vs Parallel Spine

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | Phase 3 — single-milestone retro and formal go/no-go on the next-phase path. After Phase 1 (data wedges) and Phase 2 (supervisor wedge), the spine is at a fork: continue wedging `lib/orchestrate.sh` → manifest → milestones → diagnose with bash as the shrinking outer shell (Path A — Ship of Theseus continued), OR start a parallel `tekhton run` Go entry point that re-implements orchestration natively while bash continues for unported features (Path B — parallel spine). The decision shapes the rest of V4 and was deliberately deferred to this point. |
| **Gap** | DESIGN_v4.md lays out both paths but explicitly defers the choice to "this milestone." Phase 4–5 placeholders cannot be authored in detail until the path is chosen. |
| **m11 fills** | (1) Read `docs/go-migration.md` Phase 1 + Phase 2 retros and quantify the friction points (seam count, wedge size variance, parity-test cost, cross-language debugging incidents). (2) Spike Path B in a throwaway branch: a 1-day prototype `tekhton run` that calls `internal/supervisor` and re-implements one stage. (3) Compare against Path A's projected cost (estimate per-wedge milestone size based on Phase 2 actuals). (4) Author the decision document with a 30-day reversal window. (5) If Path A: author Phase 4 milestones in `.claude/milestones/m12+`. If Path B: author the parallel-spine milestone set instead. |
| **Depends on** | m10 |
| **Files changed** | `docs/go-migration.md` (Phase 3 section), `docs/v4-phase-3-decision.md` (new), `.claude/milestones/m12-*.md` through `m??-*.md` (drafted but not committed in this milestone — milestones get their own follow-up landing) |
| **Stability after this milestone** | Stable. m11 produces no code change to the Tekhton runtime; it produces a decision artifact and a milestone plan. The Go binary and bash supervisor flip from m10 stay exactly as they are. |
| **Dogfooding stance** | N/A — no runtime change. Working copy unaffected. |

---

## Design

### Decision criteria

The decision must be evidence-based, not preference-based. The following inputs are required before the decision is made:

| Input | Source | Form |
|-------|--------|------|
| Phase 1 friction count | `docs/go-migration.md` Phase 1 retro | Bug count per category × severity |
| Phase 2 friction count | `docs/go-migration.md` Phase 2 retro | Same |
| Wedge size variance | git history, m02–m10 | Lines added/removed per milestone, turn budgets actual vs planned |
| Parity-test cost | CI minutes for `supervisor-parity-check.sh` | Wall-clock + flake rate |
| Cross-language debugging incidents | Causal log scan for events with `lang_origin: ambiguous` | Count + severity sample |
| Path B prototype | 1-day spike on a throwaway branch | Working `tekhton run --stage intake` calling `internal/supervisor` |

The Path B spike is mandatory — without it the comparison is theoretical. Time-box: 1 day. Scope: re-implement intake in Go (smallest stage, lowest behavior risk), measure how much of the orchestrate.sh + state.sh integration falls out for free.

### The decision document

`docs/v4-phase-3-decision.md` (~200 lines) records:

1. **Inputs.** Quantified data above.
2. **Path A characterization.** Continue wedging. Bash as shrinking outer shell. Estimated remaining milestones, estimated wall-clock based on Phase 2 actuals × scale.
3. **Path B characterization.** Parallel `tekhton run` entry point. Bash continues for unported features. Path B spike findings.
4. **Trade-off matrix.** Speed, risk, total cost, end-state cleanliness, contributor cognitive load, ability to roll back.
5. **Decision.** One sentence + ≤3 paragraphs of reasoning.
6. **Trigger to revisit.** Concrete; e.g. "If Path A's m12 turns out > 200 lines or > 150 turns, revisit."
7. **30-day reversal window.** If new evidence emerges within 30 days, the decision can be reverted with no political cost. After 30 days, reversal requires a new design milestone.

### Path-specific outputs

**If Path A (recommended default):** Author Phase 4 milestone files draft set covering the next 4–6 wedges (orchestrate, manifest, milestone DAG, prompt engine if not yet, then config + error). Each is a `.claude/milestones/m12-*.md` through `m17-*.md` (or similar) draft. They are NOT committed in m11 — m11 produces the drafts as artifacts; a follow-up milestone-batch commit lands them after review.

**If Path B:** Author the parallel-spine milestone set instead. Stage-by-stage Go re-implementation; bash entry point retained as a deprecated path. Different shape — fewer wedges, bigger each, but a clearer end-state.

### What this milestone explicitly does NOT do

- **No code changes to `internal/`, `cmd/`, `lib/`, or `stages/` runtime files.** m11 is a decision milestone.
- **No commit of the Phase 4 milestone drafts.** Drafts produced; landing them is a separate milestone-authoring batch.
- **No revision of m05–m10.** Those landed; their decisions stand.
- **No re-litigation of the language choice.** Per DESIGN_v4.md "Why TS/Bun was the runner-up," Go is settled. m11 chooses HOW to continue, not WHETHER to continue.

### Scope discipline

The Path B spike must NOT grow into "while we're here, let's port intake for real." If Path A wins, the spike branch is deleted. If Path B wins, the spike informs but does not become Phase 4's first milestone — that gets its own design.

### CI / runtime impact

Zero. m11 produces markdown only. No CI job changes. No binary changes. No bash file changes.

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `docs/go-migration.md` | Modify | Add Phase 3 section: decision summary + link to the decision doc. |
| `docs/v4-phase-3-decision.md` | Create | The decision document. ~200 lines. |
| `.claude/milestones/m12-*.md` through `m??-*.md` (drafts) | Author (not commit) | Phase 4 milestone drafts — produced as deliverables, landed in a separate milestone-authoring batch. |
| (No code files modified.) | — | — |

---

## Acceptance Criteria

- [ ] All six decision-criteria inputs are quantified and recorded in `docs/v4-phase-3-decision.md`.
- [ ] Path B spike branch exists, contains a working `tekhton run --stage intake` prototype, and is referenced from the decision doc with a measured-friction summary.
- [ ] `docs/v4-phase-3-decision.md` exists and contains all seven required sections (inputs, Path A, Path B, matrix, decision, trigger, reversal window).
- [ ] The decision (Path A or Path B) is unambiguous — one sentence in the decision doc, mirrored in `docs/go-migration.md` Phase 3 section.
- [ ] Phase 4 milestone drafts exist as files (Path A: orchestrate/manifest/etc. wedges; Path B: parallel-spine stages). Drafts use `.tekhton/MILESTONE_TEMPLATE.md` format. Not committed in this milestone — produced as artifacts.
- [ ] No file under `internal/`, `cmd/`, `lib/`, or `stages/` is modified by this milestone (`git diff --name-only HEAD~1 HEAD` shows only `docs/`).
- [ ] m01–m10 acceptance criteria still pass; self-host check still passes; supervisor parity gate still green.

## Watch For

- **Path B spike scope creep.** 1 day, hard cap. If the spike isn't producing data in 1 day, the data point is "Path B is harder than expected" — that's a valid input. Don't extend.
- **The decision must be evidence-based.** "I prefer Path A" is not a valid reason. The matrix should make the choice obvious; if it doesn't, the inputs aren't complete enough yet.
- **30-day reversal window is real.** Don't treat the decision as locked. If m12 (Path A) immediately runs into trouble that the Path B prototype suggested would be fine, reverse. Reversing in week 1 is cheap; reversing in month 6 is not.
- **Don't pre-author Phase 4 too aggressively.** The drafts should cover 4–6 milestones (the near-term horizon). Phase 4 might be 15+ milestones total; the late ones can't be designed sensibly until the early ones land.
- **Don't ship the decision doc without the trigger.** "Trigger to revisit" is the most important section. Without it, the document is just a snapshot in time.
- **`docs/go-migration.md` Phase 3 section is the public summary.** Keep it ≤ 30 lines: decision sentence + link to the full doc. Long-form belongs in the dedicated decision doc.

## Seeds Forward

- **Phase 4 (m12+):** authoring lands in a dedicated batch after m11. The shape depends on the m11 decision.
- **Future re-evaluation gates:** if Phase 4 takes more than 8 milestones or stretches beyond a similar friction threshold, a Phase 4.5 re-evaluation milestone may be inserted. The pattern m11 establishes (single-milestone decision retro) is reusable.
- **Decision Register §5 (numbering):** the design doc's deferred decision was resolved in the document reorganization (V4 = Go). m11 is the second formal V4 decision-point; future ones inherit this format (`docs/v4-phase-N-decision.md`).
- **`docs/go-migration.md` becomes the V4 institutional memory.** By the end of V4 it should contain a phase summary for each phase, a decision summary for each decision-point, and an "if I were starting over" section that informs V5 planning.

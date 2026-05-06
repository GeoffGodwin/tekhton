# Phase 4 Milestone Drafts (m11 deliverable)

This directory holds the Phase 4 first-batch milestone drafts authored as
the m11 (Phase 3 re-evaluation gate) deliverable.

The m11 decision (`docs/v4-phase-3-decision.md`) picked **Path A — Ship
of Theseus continues.** These drafts cover the next 4–6 wedges per
the milestone's "Phase-specific outputs" section. They are **not
committed to `.claude/milestones/`** in the m11 commit; landing them is
a separate milestone-authoring batch after review.

## Drafts

| File | Wedge | Notes |
|------|-------|-------|
| `m12-orchestrate-loop-wedge.md` | `lib/orchestrate.sh` → `internal/orchestrate` | First Phase 4 wedge. Captures the in-process advantage. |
| `m13-manifest-parser-wedge.md` | `lib/milestone_dag_io.sh` → `internal/manifest` | Small, well-scoped. Sequenced before the DAG state machine. |
| `m14-milestone-dag-wedge.md` | `lib/milestone_dag*.sh` → `internal/dag` | Depends on m13. State machine + frontier + migration. |
| `m15-prompt-engine-wedge.md` | `lib/prompts.sh` → `internal/prompt` | Closes the m11 spike's port-or-bridge friction point. |
| `m16-config-loader-wedge.md` | `lib/config*.sh` → `internal/config` | Typed config struct; `pipeline.conf` format unchanged. |
| `m17-error-taxonomy-wedge.md` | `lib/errors*.sh` + `lib/error_patterns*.sh` → `internal/errors` | Unifies typed errors across all m12-m16 packages. |

## Process

1. Review the drafts inline (in this directory).
2. When approved, run a milestone-authoring batch commit that:
   - Moves the drafts to `.claude/milestones/m12-*.md` etc.
   - Appends rows to `.claude/milestones/MANIFEST.cfg`.
   - Deletes this directory in the same commit.
3. m12 begins after the Phase 4 entry checklist
   (`docs/go-migration.md` §"Phase 4 entry checklist") is green.

## Why "drafts" and not direct commits

The m11 milestone spec is explicit:

> They are NOT committed in m11 — m11 produces the drafts as artifacts;
> a follow-up milestone-batch commit lands them after review.

The reason: m11 is a decision milestone, and authoring 6 milestone files
in the same commit blurs the decision artifact with the next-phase
plan. Splitting keeps each commit's purpose legible.

## Drafts cover the near-term horizon only

Phase 4 might be 10+ wedges total (see `DESIGN_v4.md` §Phase Plan). The
drafts above cover the first 6 — the "first batch." Later wedges
(dashboard emitters, TUI status writer, stage ports) get their own
design pass after the early ones land. From the m11 milestone's
"Watch For":

> Don't pre-author Phase 4 too aggressively. The drafts should cover
> 4–6 milestones (the near-term horizon).

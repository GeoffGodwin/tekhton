# Architecture Decision Log

Accepted Architecture Change Proposals are recorded here for institutional memory.
Each entry captures why a structural change was made, preventing future developers
(or agents) from reverting to the old approach without understanding the context.

## ADL-1: agent.sh now sourced in --plan early-exit block (Task: "Implement Milestone 4: CLAUDE.md Generation Agent")
- **Date**: 2026-03-10
- **Rationale**: - ACP: agent.sh now sourced in --plan early-exit block — **ACCEPT** — `run_agent()`
- **Source**: Accepted ACP from pipeline run

## ADL-2: lib/plan_state.sh extraction (Task: "Implement Milestone 6: Planning State Persistence + Config Integration")
- **Date**: 2026-03-11
- **Rationale**: Extraction is necessary and correct. plan.sh would be ~440 lines inline, well over the 300-line limit. The file follows the same precedent as `lib/plan_completeness.sh`. `set -euo pipefail` is now pre
- **Source**: Accepted ACP from pipeline run

## ADL-3: load_plan_config() sourcing pipeline.conf (Task: "Implement Milestone 6: Planning State Persistence + Config Integration")
- **Date**: 2026-03-11
- **Rationale**: Pattern is consistent with `lib/config.sh`, all planning keys have safe defaults when absent, and the `[[ -f "$conf_file" ]]` guard makes it safe for fresh projects with no conf yet.
- **Source**: Accepted ACP from pipeline run

## ADL-4: lib/clarify.sh sourced in execution pipeline (Task: "Implement Milestone 4: Mid-Run Clarification And Replanning")
- **Date**: 2026-03-16
- **Rationale**: - ACP: lib/clarify.sh sourced in execution pipeline — **ACCEPT** — Milestone 4 is part of v2.0 Adaptive Pipeline, not the planning initiative. Backward compatible: zero behavioral change when no a
- **Source**: Accepted ACP from pipeline run

## ADL-5: Split `lib/context.sh` into `context.sh` + `context_compiler.sh` (Task: "Continue working your way through the NON_BLOCKING_LOG.md file and begin by implementing the first 2 items.")
- **Date**: 2026-03-16
- **Rationale**: - ACP: Split `lib/context.sh` into `context.sh` + `context_compiler.sh` — **ACCEPT** — The 300-line Non-Negotiable Rule supersedes the historical Milestone 2 "no new files" note. The split is clea
- **Source**: Accepted ACP from pipeline run

## ADL-6: Mid-run replan function renaming (Task: "Continue working your way through the NON_BLOCKING_LOG.md file and implement the next 2 items.")
- **Date**: 2026-03-17
- **Rationale**: Renaming `_run_replan` → `_run_midrun_replan` and `_apply_replan_delta` → `_apply_midrun_delta` is necessary to avoid collision with the brownfield `run_replan()` and `_apply_brownfield_delta()` n
- **Source**: Accepted ACP from pipeline run

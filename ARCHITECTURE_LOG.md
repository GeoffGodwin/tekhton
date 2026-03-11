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

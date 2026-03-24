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

## ADL-7: Add lib/detect.sh, lib/detect_commands.sh, and lib/detect_report.sh to ARCHITECT (Task: "Implement Milestone 17: Tech Stack Detection Engine")
- **Date**: 2026-03-20
- **Rationale**: - ACP: Add lib/detect.sh, lib/detect_commands.sh, and lib/detect_report.sh to ARCHITECTURE.md Layer 3 — **ACCEPT** — Legitimate documentation update. Three new library entries should be added with
- **Source**: Accepted ACP from pipeline run

## ADL-8: - ACP-1: detect_project_type accepts optional pre-computed detection data (Task: "Implement Milestone 17: Tech Stack Detection Engine")
- **Date**: 2026-03-20
- **Rationale**: - ACP-1: detect_project_type accepts optional pre-computed detection data — **ACCEPT** — Backward compatible, eliminates redundant detection calls in `format_detection_report()`; confirmed clean i
- **Source**: Accepted ACP from pipeline run

## ADL-9: Crawler Companion File Architecture (Task: "Implement Milestone 18: Project Crawler & Index Generator")
- **Date**: 2026-03-20
- **Rationale**: adding `lib/crawler.sh`, `lib/crawler_inventory.sh`, `lib/crawler_content.sh`, `lib/crawler_deps.sh` to ARCHITECTURE.md Layer 3 is a purely additive and accurate documentation update. No code changes 
- **Source**: Accepted ACP from pipeline run

## ADL-10: Rescan sources detect/crawler in early-exit block (Task: "Implement Milestone 20: Incremental Rescan & Index Maintenance")
- **Date**: 2026-03-21
- **Rationale**: Follows the exact same minimal-source pattern as the existing `--init` and `--replan` early-exit blocks. Backward compatible; no existing behavior changed. ARCHITECTURE.md update note is correct.
- **Source**: Accepted ACP from pipeline run

## ADL-11: `--plan-from-index` as early-exit command (Task: "Implement Milestone 21: Agent-Assisted Project Synthesis")
- **Date**: 2026-03-21
- **Rationale**: Follows the established `--plan` / `--replan` / `--rescan` pattern exactly. Backward-compatible new flag. ARCHITECTURE.md update is needed (noted by coder).
- **Source**: Accepted ACP from pipeline run

## ADL-12: `--init --full` chaining (Task: "Implement Milestone 21: Agent-Assisted Project Synthesis")
- **Date**: 2026-03-21
- **Rationale**: Clean, backward-compatible extension; `--init` alone is unchanged. ARCHITECTURE.md update is needed (noted by coder).
- **Source**: Accepted ACP from pipeline run

## ADL-13: Extract DAG helpers from milestones.sh (Task: "Implement Milestone 2: Sliding Window & Plan Generation Integration")
- **Date**: 2026-03-22
- **Rationale**: Previously accepted; no new concerns.
- **Source**: Accepted ACP from pipeline run

## ADL-14: Extract init_synthesize helpers (Task: "Implement Milestone 2: Sliding Window & Plan Generation Integration")
- **Date**: 2026-03-22
- **Rationale**: Original extraction triggered the MODIFY verdict due to the 342-line helpers file. That concern is now resolved: `init_synthesize_helpers.sh` is 242 lines and `init_synthesize_ui.sh` is 121 lines, bot
- **Source**: Accepted ACP from pipeline run

## ADL-15: REPO_MAP_VENV_DIR as configurable path (Task: "Implement Indexer Infrastructure & Setup Command then carry on to future milestones.")
- **Date**: 2026-03-22
- **Rationale**: Reasonable extension; custom venv location is a valid operational need.
- **Source**: Accepted ACP from pipeline run

## ADL-16: Per-grammar installation (not bundle) (Task: "Implement Indexer Infrastructure & Setup Command then carry on to future milestones.")
- **Date**: 2026-03-22
- **Rationale**: Graceful degradation on platform failures is preferable to all-or-nothing.
- **Source**: Accepted ACP from pipeline run

## ADL-17: Claude CLI MCP Server Management (Task: "Implement Milestone 6: Serena MCP Integration then continue onto more milestones.")
- **Date**: 2026-03-22
- **Rationale**: - ACP: Claude CLI MCP Server Management — **ACCEPT** — Delegating server process lifecycle to Claude CLI via `--mcp-config` is architecturally correct: avoids orphan process risk, is compatible wi
- **Source**: Accepted ACP from pipeline run

## ADL-18: Source new libraries in init.sh (Task: "Implement Milestone 11: Brownfield AI Artifact Detection & Handling")
- **Date**: 2026-03-23
- **Rationale**: - ACP: Source new libraries in init.sh — **ACCEPT** — Backward compatible; follows the established pattern of sourcing companion files in `init.sh`. ARCHITECTURE.md update needed to add `lib/detec
- **Source**: Accepted ACP from pipeline run

## ADL-19: New `migrations/` directory (Task: "Implement Milestone 21: Version Migration Framework & Project Upgrade")
- **Date**: 2026-03-24
- **Rationale**: - ACP: New `migrations/` directory — **ACCEPT** — Dedicated directory with a stable four-function interface (`migration_version`, `migration_description`, `migration_check`, `migration_apply`) and
- **Source**: Accepted ACP from pipeline run

## ADL-20: Startup version check injection (Task: "Implement Milestone 21: Version Migration Framework & Project Upgrade")
- **Date**: 2026-03-24
- **Rationale**: - ACP: Startup version check injection — **ACCEPT** — Placement after config load and before pre-flight is exactly right. Backward compatible: matching-version projects see zero behavior change; p
- **Source**: Accepted ACP from pipeline run

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

## ADL-21: Role file fallbacks live in `express.sh`, not `agent.sh` (Task: "Implement Milestone 26: Express Mode (Zero-Config Execution)")
- **Date**: 2026-03-25
- **Rationale**: - ACP: Role file fallbacks live in `express.sh`, not `agent.sh` — **ACCEPT** — Keeps `agent.sh` clean; role-fallback logic is conceptually part of the zero-config story and the placement is well-j
- **Source**: Accepted ACP from pipeline run

## ADL-22: `apply_role_file_fallbacks()` runs for configured projects too (Task: "Implement Milestone 26: Express Mode (Zero-Config Execution)")
- **Date**: 2026-03-25
- **Rationale**: - ACP: `apply_role_file_fallbacks()` runs for configured projects too — **ACCEPT** — Strictly additive; the log message makes the fallback visible when it fires. The change in failure mode (hard e
- **Source**: Accepted ACP from pipeline run

## ADL-23: UI validation gate integration in run_build_gate() (Task: "Implement Milestone 29: UI Validation Gate & Headless Smoke Testing")
- **Date**: 2026-03-25
- **Rationale**: Guard-checking with `command -v run_ui_validation` is consistent with the existing project pattern. Placement after UI_TEST_CMD is architecturally correct. The two new library files sourced between ga
- **Source**: Accepted ACP from pipeline run

## ADL-24: Watchtower Inbox Directory (Task: "M36")
- **Date**: 2026-03-28
- **Rationale**: - ACP: Watchtower Inbox Directory — **ACCEPT** — The `.claude/watchtower_inbox/` convention is well-motivated, backward compatible (no-op when absent), and follows the existing `.claude/` staging 
- **Source**: Accepted ACP from pipeline run

## ADL-25: New `lib/inbox.sh` Library (Task: "M36")
- **Date**: 2026-03-28
- **Rationale**: - ACP: New `lib/inbox.sh` Library — **ACCEPT** — Correctly scoped single-entry-point library. Source order in `tekhton.sh` is correct (`notes_cli.sh` at line 699, `inbox.sh` at line 749), so `add_
- **Source**: Accepted ACP from pipeline run

## ADL-26: Watchtower Inbox Directory (Task: "M37")
- **Date**: 2026-03-28
- **Rationale**: - ACP: Watchtower Inbox Directory — **ACCEPT** — The `.claude/watchtower_inbox/` convention is well-motivated, backward compatible (no-op when absent), and follows the existing `.claude/` staging 
- **Source**: Accepted ACP from pipeline run

## ADL-27: New `lib/inbox.sh` Library (Task: "M37")
- **Date**: 2026-03-28
- **Rationale**: - ACP: New `lib/inbox.sh` Library — **ACCEPT** — Correctly scoped single-entry-point library. Source order in `tekhton.sh` is correct (`notes_cli.sh` at line 699, `inbox.sh` at line 749), so `add_
- **Source**: Accepted ACP from pipeline run

## ADL-28: Extract build gate phases to separate file (Task: "M54")
- **Date**: 2026-04-03
- **Rationale**: gates.sh was approaching the 300-line ceiling; per-phase re-runability is a direct M54 requirement; backward-compatible (run_build_gate() behavior unchanged).
- **Source**: Accepted ACP from pipeline run

## ADL-29: New remediation engine file (Task: "M54")
- **Date**: 2026-04-03
- **Rationale**: remediation logic (~250 lines) would have pushed error_patterns.sh over the ceiling; clean separation of classification (error_patterns.sh) from execution (error_patterns_remediation.sh); sourcing ord
- **Source**: Accepted ACP from pipeline run

## ADL-30: Extract service logic to `lib/preflight_services.sh` (Task: "M56")
- **Date**: 2026-04-03
- **Rationale**: `preflight.sh` was already 607 lines; extraction follows the established module-splitting pattern used by `agent_monitor_helpers.sh`, `drift_artifacts.sh`, etc. Backward-compatible via `command -v` gu
- **Source**: Accepted ACP from pipeline run

## ADL-31: ldflags injection instead of `//go:embed ../../VERSION` (Task: "M01")
- **Date**: 2026-05-04
- **Rationale**: The embed package's explicit prohibition of `..` in patterns makes the design-doc sketch uncompilable. ldflags injection is the canonical Go idiom for binary version stamping; the `var Version = "dev"
- **Source**: Accepted ACP from pipeline run

## ADL-32: Bash fallback inside `lib/causality.sh` (Task: "Implement Milestone 2: Causal Log Wedge")
- **Date**: 2026-05-04
- **Rationale**: `_json_escape` serves 20+ callers that predate m02; moving it to `lib/common.sh` is the correct canonical home, and the transitional fallback is necessary until the Go binary is universally installed.
- **Source**: Accepted ACP from pipeline run

## ADL-33: `tekhton causal init` does not truncate (Task: "Implement Milestone 2: Causal Log Wedge")
- **Date**: 2026-05-04
- **Rationale**: Resume-friendly no-op semantics are the only correct choice; truncating on init would destroy resumed-run events. The milestone AC #1 wording is what is wrong, not the implementation. The design obser
- **Source**: Accepted ACP from pipeline run

## ADL-34: rename lib/error_patterns_remediation.sh to lib/remediation.sh -- ACCEPT -- Sati (Task: "Implement Milestone 17: Error Taxonomy Wedge")
- **Date**: 2026-05-07
- **Rationale**: - ACP: rename lib/error_patterns_remediation.sh to lib/remediation.sh -- ACCEPT -- Satisfies the glob-based acceptance criterion (git ls-files lib/error_patterns*.sh returns nothing) without orphaning
- **Source**: Accepted ACP from pipeline run

## ADL-35: - ACP-1: AC #3 / AC #4 (Task: "M18")
- **Date**: 2026-05-08
- **Rationale**: - ACP-1: AC #3 / AC #4 — bash deletions deferred to m19 + m20 — **ACCEPT** — The deferral argument is technically sound on all five dependency axes: (1) `lib/gates.sh::run_build_gate` is a 5-pha
- **Source**: Accepted ACP from pipeline run

## ADL-36: - ACP-1 (`BashAdapter` recreates legacy global source environment) (Task: "[BUG] **Go BashAdapter does not source per-stage helper libraries.** The Go `BashAdapter.Run` in `internal/stagerunner/adapter.go:169-182` builds a bash wrapper that sources only `lib/common.sh` and `lib/stage_envelope.sh` before sourcing the stage script and calling `run_stage_<name>`. Every stage script under `stages/` declares its required helpers in an `Expects:` header — e.g. `stages/intake.sh:18` says `Expects: _intake_* helpers from lib/intake_helpers.sh`. Those helpers are not sourced, so the moment a stage call hits one (e.g. `stages/intake.sh:73` calling `_intake_get_milestone_content`) bash prints `command not found` and exits 127. Repro: `RUN_RESULT.json` from the m20 auto-advance run shows `"error_message": "stagerunner: subprocess failed\nexit status 127"` with `"error_class": "intake"`; `.claude/logs/intake.log` contains 147 copies of `stages/intake.sh: line 73: _intake_get_milestone_content: command not found`. The legacy `tekhton-legacy.sh` works because it sources `lib/intake_helpers.sh` (line 962) and friends globally before sourcing the stage script. Architect needs to choose between two designs: **(a) source-all** — have the bash wrapper glob `lib/*.sh` (or a pinned subset matching what tekhton-legacy.sh sources) so stages run in the same env they always have; matches V3 parity but couples every stage to every helper and risks source-time side effects from libs like `quota.sh`, `tui_ops.sh`. **(b) per-stage allowlist** — extend `DefaultStageScripts` in `adapter.go:90` to a struct `{Script string; Helpers []string}` populated from each stage script's `Expects:` header; cleaner but requires upkeep when helpers move and a one-time audit of every `stages/*.sh`. Recommend (b) — the `Expects:` headers already exist and document the contract. Per-stage helper lists at minimum: intake → `intake_helpers.sh`, `intake_verdict_handlers.sh`; coder → `coder_buildfix.sh`, `coder_buildfix_helpers.sh`; tester → `tester_tdd.sh`, `tester_continuation.sh`, `tester_fix.sh`, `tester_validation.sh`, `tester_timing.sh`; review → (none beyond common); security → (none beyond common); cleanup → (none beyond common); docs → `docs_agent.sh`. The fix needs a parity test that runs each stage under the Go BashAdapter against a fixture and asserts the same envelope as a legacy invocation. Without that, the next missing-helper bug (likely coder, since it has the biggest helper surface) ships silently.")
- **Date**: 2026-05-09
- **Rationale**: - ACP-1 (`BashAdapter` recreates legacy global source environment) — ACCEPT. The change is necessary and correct: the m18-as-shipped behaviour of sourcing only `common.sh` + `stage_envelope.sh` was 
- **Source**: Accepted ACP from pipeline run

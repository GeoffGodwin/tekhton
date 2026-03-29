# Tekhton — Architecture

## System Map

Tekhton is structured as a three-layer shell pipeline with a shared library core.

### Layer 1: Entry Point (`tekhton.sh`)
- Resolves `TEKHTON_HOME` and `PROJECT_DIR`
- Handles `--init`, `--status`, `--init-notes`, `--seed-contracts` early-exit commands
- Handles `--plan` as an early-exit command — sources `common.sh`, `prompts.sh`, `agent.sh`, `plan.sh`, `plan_completeness.sh`, `plan_state.sh`, `plan_interview.sh`, `plan_followup_interview.sh`, and `plan_generate.sh` (bypasses config loading)
- Sources all libraries and stage files (for execution pipeline)
- Loads config via `load_config()`
- Parses arguments, validates prerequisites, drives the three-stage pipeline
- Handles resume detection when invoked with no arguments
- Manages the commit prompt at the end

### Layer 2: Stages (`stages/*.sh`)
Each stage is a single function sourced by `tekhton.sh`:

- **`stages/architect.sh`** → `run_stage_architect()`
  - Conditional pre-stage: runs before the main task when drift thresholds are exceeded or `--force-audit` is passed
  - Loads drift log, architecture log, and architecture doc into prompt context
  - Invokes architect agent to produce `ARCHITECT_PLAN.md`
  - Parses plan sections and routes: Simplification → senior coder, Staleness/Dead Code/Naming → jr coder
  - Runs build gate after remediation coders
  - Runs expedited single-pass review (no rework loop)
  - Marks addressed observations as RESOLVED in drift log
  - Surfaces Design Doc Observations to `HUMAN_ACTION_REQUIRED.md`
  - Resets runs-since-audit counter
  - Skipped entirely when `--skip-audit` is passed

- **`stages/coder.sh`** → `run_stage_coder()`
  - Runs scout agent if HUMAN_NOTES.md has unchecked items
  - Injects architecture, glossary, milestone, prior context into coder prompt
  - Invokes senior coder agent
  - Turn exhaustion continuation: auto-continues if IN PROGRESS with substantive work
  - Runs build gate → escalates to build-fix agents on failure
  - Runs analyze cleanup as a completion gate
  - Archives human notes on success

- **`stages/review.sh`** → `run_stage_review()`
  - Iterates up to `MAX_REVIEW_CYCLES`
  - Invokes reviewer agent, parses verdict from `REVIEWER_REPORT.md`
  - Routes complex blockers → senior coder rework
  - Routes simple blockers → jr coder
  - Post-fix build gate after each rework pass
  - Saves state on max-cycle exhaustion

- **`stages/tester.sh`** → `run_stage_tester()`
  - Selects fresh vs resume prompt
  - Invokes tester agent
  - Detects compilation failures in log, resets affected items in report
  - Turn exhaustion continuation: auto-continues if partial tests remain with substantive work
  - Saves state on partial completion for turn-limit resume

- **`stages/plan_interview.sh`** → `run_plan_interview()`
  - Planning phase only (sourced via `--plan`, not the execution pipeline)
  - Runs Claude in conversational mode (not batch `-p` mode)
  - Walks user through design doc template section-by-section
  - Writes DESIGN.md progressively as sections are filled
  - Logs conversation to `.claude/logs/`

- **`stages/plan_generate.sh`** → `run_plan_generate()`
  - Planning phase only (sourced via `--plan`)
  - Reads completed DESIGN.md and generates CLAUDE.md
  - Output contains: project identity, non-negotiable rules, milestone plan, architecture guidelines, testing strategy
  - Supports re-generation when user selects `[r]` in review UI

- **`stages/cleanup.sh`** → `run_stage_cleanup()`
  - Post-success debt sweep stage (Milestone 5)
  - Selects non-blocking items from NON_BLOCKING_LOG.md and addresses them with jr coder
  - Runs after successful pipeline completion when cleanup conditions are met
  - Marks resolved items in NON_BLOCKING_LOG.md and defers items requiring architectural changes

- **`stages/plan_followup_interview.sh`** → `run_plan_followup_interview()`
  - Planning phase follow-up interview (Milestone 4)
  - Probes for missing depth in incomplete DESIGN.md sections
  - Expands shallow sections with sub-sections, tables, config examples, edge cases
  - Supports resume from interruption

### Layer 3: Libraries (`lib/*.sh`)

- **`lib/common.sh`** — Colors, `log()`, `warn()`, `error()`, `success()`, `header()`, `require_cmd()`
- **`lib/config.sh`** — `load_config()` reads `PROJECT_DIR/.claude/pipeline.conf`, validates required fields, applies milestone overrides via `apply_milestone_overrides()`
- **`lib/agent.sh`** — `run_agent(name, model, turns, prompt, logfile)` wraps claude CLI invocation with JSON output parsing, turn counting, timing, and error classification. Sources `agent_monitor_platform.sh`, `agent_monitor.sh`, `agent_monitor_helpers.sh`, `agent_retry.sh`, and `agent_helpers.sh`.
- **`lib/agent_monitor_platform.sh`** — Platform detection (Windows/WSL interop, GNU timeout flags) and `_kill_agent_windows()`. Sourced by `agent.sh` before `agent_monitor.sh`.
- **`lib/agent_monitor.sh`** — Agent monitoring, FIFO-based and polling-based activity detection, process management. `_invoke_and_monitor()` handles agent process lifecycle and timeout management.
- **`lib/agent_monitor_helpers.sh`** — Post-invocation monitoring helpers: `_reset_monitoring_state()`, `_detect_file_changes()`, `_count_changed_files_since()`. Sourced by `agent.sh` after `agent_monitor.sh`.
- **`lib/agent_retry.sh`** — Transient error retry envelope (Milestone 13.2.1). Wraps `_invoke_and_monitor()` in a retry loop with exponential backoff. Sourced by `agent.sh`.
- **`lib/config_defaults.sh`** — Default values and hard upper-bound clamps for all pipeline config keys. Sourced by `config.sh` at the end of `load_config()`.
- **`lib/agent_helpers.sh`** — `print_run_summary()`, `_append_agent_summary()`, `was_null_run()`, `check_agent_output()`, `build_continuation_context()`, `is_substantive_work()`. Extracted from `agent.sh` to keep it under the 300-line ceiling.
- **`lib/gates.sh`** — `run_build_gate(label)` runs `ANALYZE_CMD`, `BUILD_CHECK_CMD`, and optionally a dependency constraint `validation_command` from the configured `architecture_constraints.yaml`. Captures all errors to `BUILD_ERRORS.md`. `run_completion_gate()` checks coder self-reported status from `CODER_SUMMARY.md`.
- **`lib/hooks.sh`** — `archive_reports(dir, timestamp)`, `generate_commit_message(task)`, `run_final_checks(logfile)`.
- **`lib/drift.sh`** — Drift log, Architecture Decision Log, and Human Action management. `append_drift_observations()` reads reviewer report and accumulates to `DRIFT_LOG.md`. `append_architecture_decision()` records accepted ACPs to `ARCHITECTURE_LOG.md` with sequential ADL-NNN IDs. `append_human_action(source, desc)` adds items to `HUMAN_ACTION_REQUIRED.md`. `process_drift_artifacts()` is the main post-pipeline integration point. `should_trigger_audit()` checks thresholds. Counter management via `increment_runs_since_audit()` / `reset_runs_since_audit()`.
- **`lib/drift_artifacts.sh`** — Architecture Decision Log, Human Action, and post-pipeline drift processing. Extracted from `drift.sh` for size management. Sourced by `tekhton.sh`.
- **`lib/detect.sh`** — Tech stack detection: language identification via manifest files and source file extension counting. `detect_languages()` scans top 2 directory levels, returns `LANG|CONFIDENCE|MANIFEST` lines. `detect_frameworks()` reads manifests for framework signatures. Sourced by `tekhton.sh`.
- **`lib/detect_commands.sh`** — Command inference, entry point detection, and project type classification. `detect_commands()` returns `CMD_TYPE|COMMAND|SOURCE|CONFIDENCE` lines. `detect_entry_points()` finds likely app entry files. `detect_project_type()` classifies into plan template categories. Sourced by `tekhton.sh`.
- **`lib/detect_report.sh`** — Detection report formatting. `format_detection_report()` renders all detection results as structured markdown for PROJECT_INDEX.md and agent prompts. Sourced by `tekhton.sh`.
- **`lib/drift_cleanup.sh`** — Non-blocking notes management and drift cleanup helpers. Extracted from `drift.sh` for size management. Sourced by `tekhton.sh` after `drift.sh`.
- **`lib/errors_helpers.sh`** — Recovery suggestions and sensitive data redaction. Sourced by `errors.sh` — do not run directly.
- **`lib/metrics.sh`** — Run metrics collection and dashboard. `record_run_metrics()` appends JSONL records. `summarize_metrics()` reads history and prints a dashboard. Sourced by `tekhton.sh`.
- **`lib/metrics_calibration.sh`** — Adaptive turn calibration from historical metrics. `calibrate_turn_estimate(recommendation, stage)` adjusts scout estimates using a clamped multiplier [0.5x–2.0x]. Extracted from `metrics.sh` for size management. Sourced by `tekhton.sh` after `metrics.sh`.
- **`lib/notes.sh`** — Three-state human notes tracking (`[ ]` → `[~]` → `[x]`). `count_human_notes()` and `extract_human_notes()` read unchecked items. `claim_human_notes()` marks filtered items `[~]` before coder runs. `resolve_human_notes()` parses CODER_SUMMARY.md structured reporting to selectively mark `[x]` or reset `[ ]`. Respects `NOTES_FILTER` global. `[~]` is transient — never persists between runs.
- **`lib/plan.sh`** — Planning phase orchestration. `run_plan()` drives the full `--plan` flow: project type selection menu, template resolution, interview, completeness check, generation, milestone review, and file output. `select_project_type()` presents the 7-option menu. `load_plan_config()` reads planning keys from `pipeline.conf`. Config defaults: `PLAN_INTERVIEW_MODEL`, `PLAN_INTERVIEW_MAX_TURNS`, `PLAN_GENERATION_MODEL`, `PLAN_GENERATION_MAX_TURNS`.
- **`lib/plan_completeness.sh`** — Design document structural validation. `_extract_required_sections()` parses `<!-- REQUIRED -->` markers from templates. `_is_section_incomplete()` detects empty/placeholder/comment-only content. `check_design_completeness()` validates DESIGN.md against required sections. `run_plan_completeness_loop()` orchestrates multi-pass follow-up interviews for incomplete sections.
- **`lib/plan_state.sh`** — Planning state persistence for resume support. `write_plan_state(stage, project_type, template_file)` saves session state to `PLAN_STATE_FILE`. `read_plan_state()` restores state variables. `clear_plan_state()` removes the state file. `offer_plan_resume()` detects interrupted sessions and prompts the user to resume or start fresh.
- **`lib/turns.sh`** — Scout turn-limit recommendation parsing and application. `apply_scout_turn_limits()` reads scout output and calibrates agent turn limits per stage.
- **`lib/context.sh`** — Token accounting and context budget measurement (Milestone 1). `measure_context_size()`, `check_context_budget()`, `log_context_report()` provide measurement infrastructure.
- **`lib/context_budget.sh`** — Context budget enforcement (Milestone 2). Sourced by `context_compiler.sh` — do not run directly.
- **`lib/context_compiler.sh`** — Task-scoped context assembly (Milestone 2). `extract_relevant_sections()`, `build_context_packet()`, `compress_context()` enable keyword-based section filtering and budget-driven compression. Depends on `check_context_budget()` from `context.sh`.
- **`lib/milestones.sh`** — Milestone state machine and auto-advance (Milestone 3). `parse_milestones()`, `check_milestone_acceptance()`, `advance_milestone()`, `write_milestone_disposition()` orchestrate multi-milestone progression with acceptance checking. Archival functions live in `milestone_archival.sh`.
- **`lib/milestone_archival.sh`** — Milestone archival (Milestone 10). `archive_completed_milestone()`, `archive_all_completed_milestones()` move completed milestone definitions from CLAUDE.md to MILESTONE_ARCHIVE.md.
- **`lib/milestone_ops.sh`** — Milestone acceptance checking, commit signatures, and auto-advance orchestration. Sourced by `tekhton.sh`.
- **`lib/milestone_split.sh`** — Pre-flight milestone sizing and null-run auto-split (Milestone 11). Sourced by `tekhton.sh`.
- **`lib/clarify.sh`** — Clarification protocol and replan trigger (Milestone 4). `detect_clarifications()`, `handle_clarifications()`, `trigger_replan()` enable mid-run pauses for blocking questions and scope corrections.
- **`lib/replan.sh`** — Thin shim that sources `replan_midrun.sh` and `replan_brownfield.sh`. Holds shared config defaults (`REPLAN_MODEL`, `REPLAN_MAX_TURNS`).
- **`lib/replan_midrun.sh`** — Mid-run replanning triggered by reviewer `REPLAN_REQUIRED` verdict. `detect_replan_required()`, `trigger_replan()`, `_run_midrun_replan()`, `_apply_midrun_delta()`.
- **`lib/replan_brownfield.sh`** — Brownfield replan orchestration (`--replan` CLI command). `run_replan()`, `_generate_codebase_summary()`, `_brownfield_approval_menu()`, `_apply_brownfield_delta()`, `_archive_replan_delta()`.
- **`lib/prompts.sh`** — `render_prompt(template_name)` reads `TEKHTON_HOME/prompts/<name>.prompt.md`, substitutes `{{VAR}}` from shell globals, strips `{{IF:VAR}}...{{ENDIF:VAR}}` blocks when VAR is empty.
- **`lib/state.sh`** — `write_pipeline_state(stage, reason, resume_flag, task, detail)`, `clear_pipeline_state()`. Persists to `PIPELINE_STATE_FILE` for resume.
- **`lib/milestone_dag.sh`** — Milestone DAG infrastructure and manifest parser (v3 Milestone 1). Sources `milestone_dag_io.sh` (I/O: `_dag_manifest_path`, `_dag_milestone_dir`, `has_milestone_manifest`, `load_manifest`, `save_manifest`), `milestone_dag_validate.sh`, and `milestone_dag_migrate.sh`. Provides: `dag_get_frontier()`, `dag_deps_satisfied()`, `dag_set_status()`, and query functions (`dag_get_status`, `dag_get_active`, `dag_find_next`).
- **`lib/milestone_dag_migrate.sh`** — Inline-to-file milestone migration (v3). `migrate_inline_milestones()` extracts milestones from CLAUDE.md into individual files with a MANIFEST.cfg.
- **`lib/milestone_window.sh`** — Character-budgeted milestone sliding window (v3 Milestone 2). `build_milestone_window()` selects active + frontier + on-deck milestones within a character budget.
- **`lib/indexer.sh`** — Repo map orchestration and Python tool invocation (v3). `check_indexer_available()`, `run_repo_map()`, `get_repo_map_slice()`. Gracefully degrades when Python/tree-sitter is unavailable. Sources `indexer_helpers.sh`.
- **`lib/mcp.sh`** — MCP server lifecycle management for Serena LSP integration (v3 Milestone 6). `start_mcp_server()`, `stop_mcp_server()`, `check_mcp_health()`, `get_mcp_config_path()`. Claude CLI manages the actual server process; this module handles config generation and availability tracking. Consumed by `agent.sh` to add `--mcp-config` flag.

### Layer 4: Prompt Templates (`prompts/*.prompt.md`)
Declarative agent instructions with `{{VAR}}` placeholders. Rendered by `lib/prompts.sh`.
Templates never contain project-specific content — all specifics come from config and shell globals.

### Layer 5: Agent Role Templates (`templates/*.md`)
Copied into target projects by `--init`. Customized per-project under `.claude/agents/`.
Define each agent's personality, rules, and output format requirements.

## Data Flow

```
tekhton.sh (entry)
  │
  ├─ load_config() ← PROJECT_DIR/.claude/pipeline.conf
  │
  ├─ Pre-flight: should_trigger_audit() → drift threshold warning
  │
  ├─ Pre-stage 2: run_stage_architect()  [conditional — threshold or --force-audit]
  │    ├─ render_prompt("architect") → run_agent("Architect")
  │    ├─ parse ARCHITECT_PLAN.md sections
  │    ├─ [if Simplification] → render_prompt("architect_sr_rework") → run_agent("Coder")
  │    ├─ [if Staleness/Dead Code/Naming] → render_prompt("architect_jr_rework") → run_agent("Jr Coder")
  │    ├─ run_build_gate()
  │    ├─ render_prompt("architect_review") → run_agent("Reviewer expedited")
  │    ├─ resolve_drift_observations() → DRIFT_LOG.md
  │    ├─ append_human_action() → HUMAN_ACTION_REQUIRED.md
  │    └─ reset_runs_since_audit()
  │
  ├─ Stage 1: run_stage_coder()
  │    ├─ render_prompt("scout") → run_agent("Scout")
  │    ├─ render_prompt("coder") → run_agent("Coder")
  │    ├─ run_build_gate() → [render_prompt("build_fix") → run_agent("Build Fix")]
  │    └─ run_completion_gate() → [render_prompt("analyze_cleanup") → run_agent("Cleanup")]
  │
  ├─ Stage 2: run_stage_review()  [loops up to MAX_REVIEW_CYCLES]
  │    ├─ render_prompt("reviewer") → run_agent("Reviewer")
  │    ├─ [parse ACP Verdicts → ACCEPTED_ACPS]
  │    ├─ [if CHANGES_REQUIRED + complex] → render_prompt("coder_rework") → run_agent("Coder rework")
  │    ├─ [if CHANGES_REQUIRED + simple]  → render_prompt("jr_coder") → run_agent("Jr Coder")
  │    └─ run_build_gate()
  │
  ├─ Stage 3: run_stage_tester()
  │    └─ render_prompt("tester"|"tester_resume") → run_agent("Tester")
  │
  ├─ Finalize
  │    ├─ run_final_checks()
  │    ├─ process_drift_artifacts()
  │    │    ├─ append_drift_observations() → DRIFT_LOG.md
  │    │    ├─ append_architecture_decision() → ARCHITECTURE_LOG.md
  │    │    ├─ _process_design_observations() → HUMAN_ACTION_REQUIRED.md
  │    │    └─ increment_runs_since_audit()
  │    ├─ archive_reports()
  │    ├─ generate_commit_message()
  │    ├─ human action banner (if items pending)
  │    └─ interactive commit prompt
```

### Planning Phase Data Flow (`--plan`)

```
tekhton.sh --plan (early exit — bypasses config loading)
  │
  ├─ Source: common.sh, prompts.sh, agent.sh, plan.sh,
  │          plan_completeness.sh, plan_state.sh,
  │          plan_interview.sh, plan_generate.sh
  │
  ├─ offer_plan_resume()  [if PLAN_STATE.md exists]
  │    └─ Resume or start fresh
  │
  ├─ select_project_type()
  │    └─ User picks from 7 project types → resolves template path
  │
  ├─ run_plan_interview()  [conversational mode]
  │    ├─ Claude walks through template sections one at a time
  │    ├─ Writes DESIGN.md progressively
  │    └─ write_plan_state("interview") on interruption
  │
  ├─ run_plan_completeness_loop()
  │    ├─ check_design_completeness() — grep/awk structural validation
  │    └─ [if incomplete] → follow-up interview for missing sections
  │
  ├─ run_plan_followup_interview()  [conversational mode, iterative]
  │    ├─ Probes for depth in incomplete sections
  │    ├─ Expands with sub-sections, tables, config examples, edge cases
  │    └─ Writes updated DESIGN.md progressively
  │
  ├─ run_plan_generate()  [batch mode]
  │    ├─ Reads DESIGN.md → generates CLAUDE.md
  │    └─ write_plan_state("generate") on interruption
  │
  ├─ Milestone Review UI
  │    ├─ [y] Write DESIGN.md + CLAUDE.md to project directory
  │    ├─ [e] Open CLAUDE.md in $EDITOR before writing
  │    ├─ [r] Re-run generation agent
  │    └─ [n] Abort
  │
  └─ clear_plan_state() + print next-steps
```

## File Ownership

| File | Lives in | Purpose |
|------|----------|---------|
| `tekhton.sh` | TEKHTON_HOME | Entry point |
| `lib/*.sh` | TEKHTON_HOME | Shared libraries |
| `stages/*.sh` | TEKHTON_HOME | Stage implementations |
| `prompts/*.prompt.md` | TEKHTON_HOME | Prompt templates |
| `templates/*.md` | TEKHTON_HOME | Agent role templates (copied by --init) |
| `.claude/pipeline.conf` | PROJECT_DIR | Project-specific config |
| `.claude/agents/*.md` | PROJECT_DIR | Project-specific agent roles |
| `.claude/logs/` | PROJECT_DIR | Run logs and archives |
| `.claude/PIPELINE_STATE.md` | PROJECT_DIR | Resume state |
| `CODER_SUMMARY.md` | PROJECT_DIR | Coder output (per-run) |
| `REVIEWER_REPORT.md` | PROJECT_DIR | Reviewer output (per-run) |
| `TESTER_REPORT.md` | PROJECT_DIR | Tester output (per-run) |
| `JR_CODER_SUMMARY.md` | PROJECT_DIR | Jr coder output (per-run) |
| `ARCHITECT_PLAN.md` | PROJECT_DIR | Architect audit output (per-audit) |
| `HUMAN_NOTES.md` | PROJECT_DIR | Human-written notes for next run |
| `NON_BLOCKING_LOG.md` | PROJECT_DIR | Non-blocking notes accumulated across runs |
| `CLARIFICATIONS.md` | PROJECT_DIR | Human answers to blocking agent questions (Milestone 4) |
| `ARCHITECTURE_LOG.md` | PROJECT_DIR | Architecture Decision Log (accepted ACPs across runs) |
| `DRIFT_LOG.md` | PROJECT_DIR | Drift observations accumulated across runs |
| `HUMAN_ACTION_REQUIRED.md` | PROJECT_DIR | Items needing human attention (design doc updates) |
| `architecture_constraints.yaml` | PROJECT_DIR | Optional dependency constraint manifest (layer rules + validation command) |
| `templates/plans/*.md` | TEKHTON_HOME | Design doc templates by project type |
| `DESIGN.md` | PROJECT_DIR | Design document (output of `--plan` interview) |
| `.claude/PLAN_STATE.md` | PROJECT_DIR | Planning session resume state |

## Dependency Constraint System (P5)

Optional, language-agnostic enforcement of layer boundaries. When configured:

1. **Constraint manifest** (`architecture_constraints.yaml`) defines layer rules and a `validation_command`
2. **Build gate** runs the `validation_command` after analyze + compile checks. Nonzero exit = build failure.
3. **Architect agent** reads the manifest during audits to verify drift observations against declared rules
4. **Sample scripts** in `examples/` provide starting points for Dart, Python, and TypeScript projects

The system is fully opt-in: when `DEPENDENCY_CONSTRAINTS_FILE` is empty (default), build gate skips validation and architect operates without layer context.

## Extension Points

New capabilities should be added as:
1. **New prompt template** in `prompts/` — for new agent tasks
2. **New library** in `lib/` — for new shared functionality
3. **New stage** in `stages/` — for new pipeline phases (require sourcing in tekhton.sh)
4. **New config key** in `pipeline.conf.example` — for new project-level settings

Never add project-specific logic to any file in TEKHTON_HOME.

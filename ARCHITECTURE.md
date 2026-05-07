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
  - Runs pre-coder clean sweep (M92) — restores pristine test state before agent work
  - Runs scout agent if HUMAN_NOTES.md has unchecked items
  - Injects architecture, glossary, milestone, prior context into coder prompt
  - Invokes senior coder agent
  - Turn exhaustion continuation: auto-continues if IN PROGRESS with substantive work
  - Runs build gate → escalates to build-fix agents on failure
  - Runs analyze cleanup as a completion gate
  - Archives human notes on success
  - Sources sub-stages: `coder_prerun.sh`, `coder_buildfix.sh` (sources `coder_buildfix_helpers.sh`)
  - Resets the four `BUILD_FIX_*` Goal-7 env vars (M128) at stage entry so M132's `_collect_build_fix_stats_json` always sees a stable shape

- **`stages/coder_prerun.sh`** — Pre-coder clean sweep (M92)
  - Sourced by `coder.sh` — do not run directly
  - Provides: `run_prerun_clean_sweep()` and `_run_prerun_fix_agent()` — spawns restricted fix agent when tests fail before the coder runs; re-captures baseline on success, warns and proceeds on failure

- **`stages/coder_buildfix.sh`** — M127 routing + M128 build-fix continuation loop
  - Sourced by `coder.sh` — do not run directly
  - Provides: `run_build_fix_loop()` (M128 top-level entry), `_bf_read_raw_errors()`, `_bf_invoke_build_fix()`. Routes via the four M127 tokens (`code_dominant`, `noncode_dominant`, `mixed_uncertain`, `unknown_only`) emitted by `lib/error_patterns_classify.sh`. The M128 loop wraps dispatch in an attempt-bounded retry (default 3) with adaptive turn budgets (1.0× / 1.5× / 2.0× of `EFFECTIVE_CODER_MAX_TURNS / BUILD_FIX_BASE_TURN_DIVISOR`), a cumulative turn cap (`BUILD_FIX_TOTAL_TURN_CAP`), and a progress gate (error-count delta + last-20-line tail). Always exports the four Goal-7 stats vars (`BUILD_FIX_OUTCOME`, `BUILD_FIX_ATTEMPTS`, `BUILD_FIX_TURN_BUDGET_USED`, `BUILD_FIX_PROGRESS_GATE_FAILURES`). On terminal failure paths exports `SECONDARY_ERROR_*` (or calls `set_secondary_cause` if M129 is deployed) for M129 cause-context integration. Re-exports `LAST_BUILD_CLASSIFICATION` after capturing the routing token so M130 consumers see it.

- **`stages/coder_buildfix_helpers.sh`** — Pure helpers for the M128 build-fix loop
  - Sourced by `coder_buildfix.sh` — do not run directly
  - Provides: `_compute_build_fix_budget()` (adaptive schedule + clamps + cumulative-cap math), `_build_fix_progress_signal()` (improved/unchanged/worsened truth table), `_bf_count_errors()`, `_bf_get_error_tail()`, `_append_build_fix_report()` (writes `BUILD_FIX_REPORT_FILE`), `_export_build_fix_stats()`, `_build_fix_set_secondary_cause()`, `_build_fix_terminal_class()`, plus the M127 helpers `_bf_emit_routing_diagnosis()` and `_bf_extra_context_for_decision()`. All functions are pure (or write a single artifact file) so they can be unit-tested without stubbing the agent or pipeline state.

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
  - Sources sub-stages: `tester_tdd.sh`, `tester_continuation.sh`, `tester_fix.sh`, `tester_timing.sh`, `tester_validation.sh`

- **`stages/tester_tdd.sh`** — TDD phase orchestration
  - Sourced by `tester.sh` — do not run directly
  - Provides: TDD phase detection and routing logic

- **`stages/tester_continuation.sh`** — Turn-exhaustion continuation logic
  - Sourced by `tester.sh` — do not run directly
  - Provides: continuation prompt rendering and resume handling for partial test runs

- **`stages/tester_fix.sh`** — Test failure fix orchestration
  - Sourced by `tester.sh` — do not run directly
  - Provides: test failure detection, fix routing, and recursive fix attempt limits

- **`stages/tester_timing.sh`** — Tester timing and duration estimation
  - Sourced by `tester.sh` — do not run directly
  - Provides: stage timing utilities for progress tracking and turn estimation

- **`stages/tester_validation.sh`** — Post-tester output validation and routing
  - Sourced by `tester.sh` — do not run directly
  - Provides: `_validate_tester_output()` for report validation, missing output synthesis, and test file discovery

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

- **`lib/common.sh`** — Colors, `log()`, `warn()`, `error()`, `success()`, `header()`, `require_cmd()`. Sources `common_box.sh` and `common_timing.sh`.
- **`lib/common_box.sh`** — Box-drawing helpers and structured error/retry reporting. `_is_utf8_terminal`, `_build_box_hline`, `_print_box_line`, `_setup_box_chars`, `_print_box_frame`, `report_error`, `report_retry`. Sourced by `common.sh` — do not source directly.
- **`lib/common_timing.sh`** — Phase timing helpers (M46). `_get_epoch_secs`, `_phase_start`, `_phase_end`, `_get_phase_duration`, `_format_duration_human`. Exposes `_PHASE_STARTS` and `_PHASE_TIMINGS`. Sourced by `common.sh` — do not source directly.
- **`lib/config.sh`** — `load_config()` reads `PROJECT_DIR/.claude/pipeline.conf`, validates required fields, applies milestone overrides via `apply_milestone_overrides()`
- **`lib/agent.sh`** — `run_agent(name, model, turns, prompt, logfile)` wraps claude CLI invocation with JSON output parsing, turn counting, timing, and error classification. Sources `agent_monitor_platform.sh`, `agent_monitor.sh`, `agent_monitor_helpers.sh`, `agent_retry.sh`, and `agent_helpers.sh`.
- **`lib/agent_monitor_platform.sh`** — Platform detection (Windows/WSL interop, GNU timeout flags) and `_kill_agent_windows()`. Sourced by `agent.sh` before `agent_monitor.sh`.
- **`lib/agent_monitor.sh`** — Agent monitoring, FIFO-based and polling-based activity detection, process management. `_invoke_and_monitor()` handles agent process lifecycle and timeout management.
- **`lib/agent_monitor_helpers.sh`** — Post-invocation monitoring helpers: `_reset_monitoring_state()`, `_detect_file_changes()`, `_count_changed_files_since()`. Sourced by `agent.sh` after `agent_monitor.sh`.
- **`lib/agent_retry.sh`** — Transient error retry envelope (Milestone 13.2.1). Wraps `_invoke_and_monitor()` in a retry loop with exponential backoff. Sourced by `agent.sh`.
- **`lib/config_defaults.sh`** — Default values and hard upper-bound clamps for all pipeline config keys. Sourced by `config.sh` at the end of `load_config()`. Chains into `config_defaults_ci.sh` (M138) before applying the m136 arc defaults.
- **`lib/config_defaults_ci.sh`** — M138 runtime CI environment auto-detection. `_detect_runtime_ci_environment()` (pure-bash CI signal probe), `_get_ci_platform_name()` (human-readable platform), `_apply_ci_ui_gate_defaults()` (source-time defaulter that elevates `TEKHTON_UI_GATE_FORCE_NONINTERACTIVE` to `1` inside CI when the key is absent from `pipeline.conf`). Sourced by `config_defaults.sh` — do not run directly.
- **`lib/agent_helpers.sh`** — `print_run_summary()`, `_append_agent_summary()`, `was_null_run()`, `check_agent_output()`, `build_continuation_context()`, `is_substantive_work()`. Extracted from `agent.sh` to keep it under the 300-line ceiling.
- **`lib/gates.sh`** — `run_build_gate(label)` runs `ANALYZE_CMD`, `BUILD_CHECK_CMD`, and optionally a dependency constraint `validation_command` from the configured `architecture_constraints.yaml`. Captures all errors to `BUILD_ERRORS.md`. `run_completion_gate()` checks coder self-reported status from `CODER_SUMMARY.md`.
- **`lib/hooks.sh`** — `archive_reports(dir, timestamp)`, `generate_commit_message(task)`, `run_final_checks(logfile)`.
- **`lib/drift.sh`** — Drift log, Architecture Decision Log, and Human Action management. `append_drift_observations()` reads reviewer report and accumulates to `DRIFT_LOG.md`. `append_architecture_decision()` records accepted ACPs to `ARCHITECTURE_LOG.md` with sequential ADL-NNN IDs. `append_human_action(source, desc)` adds items to `HUMAN_ACTION_REQUIRED.md`. `process_drift_artifacts()` is the main post-pipeline integration point. `should_trigger_audit()` checks thresholds. Counter management via `increment_runs_since_audit()` / `reset_runs_since_audit()`.
- **`lib/drift_artifacts.sh`** — Architecture Decision Log, Human Action, and post-pipeline drift processing. Extracted from `drift.sh` for size management. Sourced by `tekhton.sh`.
- **`lib/detect.sh`** — Tech stack detection: language identification via manifest files and source file extension counting. `detect_languages()` scans top 2 directory levels, returns `LANG|CONFIDENCE|MANIFEST` lines. `detect_frameworks()` reads manifests for framework signatures. Sourced by `tekhton.sh`.
- **`lib/detect_commands.sh`** — Command inference, entry point detection, and project type classification. `detect_commands()` returns `CMD_TYPE|COMMAND|SOURCE|CONFIDENCE` lines. `detect_entry_points()` finds likely app entry files. `detect_project_type()` classifies into plan template categories. Sourced by `tekhton.sh`.
- **`lib/detect_report.sh`** — Detection report formatting. `format_detection_report()` renders all detection results as structured markdown for PROJECT_INDEX.md and agent prompts. Sourced by `tekhton.sh`.
- **`lib/dashboard.sh`** — Dashboard lifecycle and run-state emission. `is_dashboard_enabled()`, `init_dashboard()`, `sync_dashboard_static_files()`, `cleanup_dashboard()`, `emit_dashboard_run_state()`, `emit_dashboard_team_state()`. Sourced by `tekhton.sh`.
- **`lib/dashboard_emitters.sh`** — Dashboard data emitter functions. `emit_dashboard_milestones()`, `emit_dashboard_security()`, `emit_dashboard_reports()`, `emit_dashboard_metrics()`, `emit_dashboard_health()`, `emit_dashboard_init()`, `emit_dashboard_inbox()`, `emit_dashboard_action_items()`, `emit_dashboard_notes()`. Sourced by `tekhton.sh` after `dashboard.sh`.
- **`lib/dashboard_parsers.sh`** — Report parsing for individual stage reports (security, intake, coder, reviewer) and JS file emission utilities. `_to_js_timestamp()`, `_to_js_string()`, `_write_js_file()`, `_parse_security_report()`, `_parse_intake_report()`, `_parse_coder_summary()`, `_parse_reviewer_report()`. Sources `dashboard_parsers_runs.sh`. Sourced by `dashboard.sh`.
- **`lib/dashboard_parsers_runs.sh`** — Run summary parsing from `metrics.jsonl` (primary) and `RUN_SUMMARY_*.json` files (fallback). `_parse_run_summaries()`, `_parse_run_summaries_from_jsonl()`, `_parse_run_summaries_from_files()`. Sourced by `dashboard_parsers.sh` — do not run directly.
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
- **`lib/milestone_acceptance_lint.sh`** — Acceptance criteria quality linter (Milestone 85). `lint_acceptance_criteria()` checks milestone files for structural weaknesses: missing behavioral criteria, refactor milestones without completeness greps, config milestones without self-referential checks. Warning-only, not blocking. Invoked from `draft_milestones_validate_output()` at authoring time so warnings are actionable before a milestone runs. Sourced by `tekhton.sh`.
- **`lib/milestone_split.sh`** — Pre-flight milestone sizing and null-run auto-split (Milestone 11). Sources `milestone_split_dag.sh` and `milestone_split_nullrun.sh`. Sourced by `tekhton.sh`.
- **`lib/milestone_split_dag.sh`** — DAG-mode splitting helpers (Milestone 111). `_split_read_dag_milestone()` reads a milestone definition from its DAG file instead of CLAUDE.md; `_split_apply_dag()` parses sub-milestones, writes their files, and splices the new entries into the manifest arrays immediately after the parent's position (so they run next, not last). Marks parent status as `split`. Sourced by `milestone_split.sh` — do not run directly.
- **`lib/milestone_split_nullrun.sh`** — Null-run auto-split handler (Milestone 11). `handle_null_run_split()` guards against splitting when the coder has already produced substantive partial work (git diff + CODER_SUMMARY > 20 lines) and preserves progress for resume. Sourced by `milestone_split.sh` — do not run directly.
- **`lib/clarify.sh`** — Clarification protocol and replan trigger (Milestone 4). `detect_clarifications()`, `handle_clarifications()`, `trigger_replan()` enable mid-run pauses for blocking questions and scope corrections.
- **`lib/pipeline_order.sh`** — Configurable pipeline stage ordering. `validate_pipeline_order()`, `get_pipeline_order()`, `get_stage_count()`, `get_stage_display_label()`. Sources `pipeline_order_policy.sh`.
- **`lib/pipeline_order_policy.sh`** — M110 extraction. `get_stage_metrics_key()`, `get_stage_array_key()`, `get_stage_policy()`, `get_run_stage_plan()`. Sourced by `pipeline_order.sh` — do not source directly.
- **`lib/replan.sh`** — Thin shim that sources `replan_midrun.sh` and `replan_brownfield.sh`. Holds shared config defaults (`REPLAN_MODEL`, `REPLAN_MAX_TURNS`).
- **`lib/replan_midrun.sh`** — Mid-run replanning triggered by reviewer `REPLAN_REQUIRED` verdict. `detect_replan_required()`, `trigger_replan()`, `_run_midrun_replan()`, `_apply_midrun_delta()`.
- **`lib/replan_brownfield.sh`** — Brownfield replan orchestration (`--replan` CLI command). `run_replan()`, `_generate_codebase_summary()`. Sources `replan_brownfield_apply.sh`.
- **`lib/replan_brownfield_apply.sh`** — Approval menu, delta merge, archive helpers for `--replan`. `_brownfield_approval_menu()`, `_apply_brownfield_delta()`, `_archive_replan_delta()`. Sourced by `replan_brownfield.sh` — do not source directly.
- **`lib/prompts.sh`** — `render_prompt(template_name)` reads `TEKHTON_HOME/prompts/<name>.prompt.md`, substitutes `{{VAR}}` from shell globals, strips `{{IF:VAR}}...{{ENDIF:VAR}}` blocks when VAR is empty.
- **`lib/state.sh`** — m03 wedge shim (50-line public API). `_build_resume_flag()`, `write_pipeline_state(stage, reason, resume_flag, task, [notes], [milestone])`, `read_pipeline_state_field([path], field)`, `clear_pipeline_state()`, `load_intake_tweaked_task()`. On-disk format is `tekhton.state.v1` JSON; the writer execs `tekhton state update` when the Go binary is on `$PATH` and falls back to a pure-bash JSON writer otherwise. Sources `state_helpers.sh`.
- **`lib/state_helpers.sh`** — m03 writer + bash-fallback reader. `_state_write_snapshot()` (positional → `--field K=V` mapping with auxiliary env capture), `_state_bash_write_fields()` (atomic tmpfile + mv), `_state_bash_read_field()` (pure-bash JSON field lookup with legacy V3 markdown fallback for cutover-window state files). Sourced by `state.sh` — do not run directly.
- **`lib/milestone_dag.sh`** — m14 wedge shim (≤100 lines). Keeps the in-memory `_DAG_*` array query API (`dag_get_count`, `dag_get_status`, `dag_set_status`, `dag_get_file`, `dag_get_title`, `dag_get_active`, `dag_get_frontier`, `dag_deps_satisfied`, `dag_find_next`, `dag_id_to_number`, `dag_number_to_id`) plus cross-process shims (`validate_manifest`, `migrate_inline_milestones`, `_insert_milestone_pointer`) that exec `tekhton dag <subcommand>`. Sources `milestone_dag_io.sh` (m13 wedge: I/O via `tekhton manifest list`).
- **`lib/milestone_query.sh`** — m14. DAG-aware milestone query wrappers extracted from the deleted `milestone_dag_helpers.sh`. `parse_milestones_auto()`, `get_milestone_count()`, `get_milestone_title()`, `is_milestone_done()` — each prefers the manifest path when DAG mode is on, falls back to inline `parse_milestones` otherwise. Sourced by `tekhton.sh` after `milestone_dag.sh`.
- **`lib/milestone_dag_io.sh`** — m13 wedge shim (≤60 lines). Path/presence helpers stay bash; `load_manifest` execs `tekhton manifest list` when the Go binary is on PATH and falls back to `_dag_bash_load_arrays`. `save_manifest` writes the in-memory `_DAG_*` arrays through the bash helper; comment-preserving single-row updates go through `tekhton manifest set-status` directly. Sources `milestone_dag_io_bash.sh`. Sourced by `milestone_dag.sh` — do not source directly.
- **`lib/milestone_dag_io_bash.sh`** — m13 pure-bash fallback for the manifest shim. `_dag_bash_load_arrays` (port of the legacy `load_manifest` body) and `_dag_bash_save_arrays` (atomic tmpfile + mv writer with the legacy two-line header). Used when the Go binary is not on PATH. Sourced by `milestone_dag_io.sh` — do not source directly.
- **`internal/manifest/`** — m13 Go owner of MANIFEST.cfg. `Load(path)`, `Save()`, `Get(id)`, `SetStatus(id, status)`, `Frontier()`. Sentinel errors: `ErrNotFound`, `ErrEmpty`, `ErrUnknownID`, `ErrInvalidField`. Round-trips comment lines and blank lines unchanged through Load → Save. Atomic writes via tmpfile + os.Rename match the m03 state-wedge pattern.
- **`internal/dag/`** — m14 Go state machine. `State.Frontier()`, `State.Active()`, `State.DepsSatisfied(id)`, `State.Advance(id, status)` (validates the m14 transition table), `State.Validate(milestoneDir)` (cycles, missing deps, unknown statuses, duplicate IDs, missing files). `Migrate(MigrateOptions)` ports `migrate_inline_milestones` (idempotent on existing MANIFEST.cfg). `RewritePointer(claudeMD)` ports `_insert_milestone_pointer`. Sentinels: `ErrUnknownStatus`, `ErrInvalidTransition`, `ErrNotFound`, `ErrCycle`, `ErrMissingDep`, `ErrDuplicateID`, `ErrMissingFile`, `ErrMigrateAlreadyDone`, `ErrNoMilestonesFound`.
- **`internal/proto/manifest_v1.go`** — m13 in-memory proto (`tekhton.manifest.v1`). `ManifestV1` (envelope) and `ManifestEntryV1` (per-row JSON shape). Disk format stays the legacy CSV-with-#comments shape — this proto describes only `tekhton manifest list --json` output and library consumers.
- **`cmd/tekhton/manifest.go`** — m13 Cobra subcommands: `manifest list [--json]`, `manifest get <id> [--field …]`, `manifest set-status <id> <status>`, `manifest frontier`. Bash callers reach these via `lib/milestone_dag_io.sh` and `lib/milestone_ops.sh`.
- **`cmd/tekhton/dag.go`** — m14 Cobra subcommands: `dag frontier`, `dag active`, `dag advance <id> <status>` (validated transition + atomic save), `dag validate` (exits non-zero on cycle / missing-dep / missing-file / unknown-status), `dag migrate --inline-claude-md PATH --milestone-dir DIR [--rewrite-pointer]`, `dag rewrite-pointer --inline-claude-md PATH`. Bash callers reach these via `lib/milestone_dag.sh`'s `validate_manifest` / `migrate_inline_milestones` / `_insert_milestone_pointer` shims.
- **`lib/milestone_window.sh`** — Character-budgeted milestone sliding window (v3 Milestone 2). `build_milestone_window()` selects active + frontier + on-deck milestones within a character budget.
- **`lib/draft_milestones.sh`** — Interactive milestone authoring flow (Milestone 80). `run_draft_milestones()` drives the `--draft-milestones` CLI command: builds prompt context, invokes agent, discovers generated files, validates, and writes manifest entries. `draft_milestones_next_id()` scans MANIFEST.cfg + milestone files for the next free ID. `draft_milestones_build_exemplars()` extracts recent milestones as format examples. Sources `draft_milestones_write.sh`.
- **`lib/draft_milestones_write.sh`** — Validation and manifest writing for draft milestones (Milestone 80). `draft_milestones_validate_output()` checks generated milestone files for required structure (H1, meta block, required sections, minimum 5 acceptance criteria). `draft_milestones_write_manifest()` appends rows to MANIFEST.cfg with linear dependency chaining. Sourced by `draft_milestones.sh`.
- **`lib/milestone_progress.sh`** — Milestone progress CLI and next-action guidance (Milestone 82). `_render_milestone_progress()` renders `--progress` output with progress bar and status markers. `_compute_next_action()` generates post-run "What's next" guidance. `_diagnose_recovery_command()` maps failure state to a concrete recovery CLI command. Sources `milestone_progress_helpers.sh`.
- **`lib/milestone_progress_helpers.sh`** — Rendering helpers for milestone progress (Milestone 82). `_render_progress_dag()`, `_render_progress_inline()`, `_render_progress_bar()`, `_render_milestone_line()`. Sourced by `tekhton.sh` before `milestone_progress.sh`.
- **`lib/indexer.sh`** — Repo map orchestration and Python tool invocation (v3). `check_indexer_available()`, `run_repo_map()`, `get_repo_map_slice()`. Gracefully degrades when Python/tree-sitter is unavailable. Sources `indexer_helpers.sh`.
- **`lib/indexer_audit.sh`** — Startup grammar audit (Milestone 123). `_indexer_run_startup_audit()` invokes `audit_grammars()` from the Python loader, classifies each declared extension as LOADED / MISSING / MISMATCH, and emits `warn` for API-mismatch extensions (the #181 bug class). Gated by `INDEXER_STARTUP_AUDIT`. Sourced by `tekhton.sh` after `indexer.sh` — do not run directly.
- **`lib/error_patterns_remediation.sh`** — Auto-remediation engine for classified build/test errors (Milestone 54). `attempt_remediation()` executes safe-rated remediation commands from the error pattern registry, with blocklist enforcement, deduplication, and max-attempt limits. Routes non-automatable issues to `HUMAN_ACTION_REQUIRED.md`. All actions logged to causal event log. Sourced by `tekhton.sh` after `error_patterns.sh`.
- **`lib/error_patterns_classify.sh`** — Confidence-based mixed-log classifier (Milestone 127). `_is_non_diagnostic_line()` filters npm warnings, progress lines, ANSI/whitespace-only, and report-serving banners with allow-list-first failure-term precedence. `classify_build_errors_with_stats()` emits per-record category counts plus `total_matched`/`total_lines`/`unmatched_lines` summaries — unmatched lines are explicitly unknown, never silently coerced to `code`. `has_explicit_code_errors()` returns true only when a code-category pattern matches. `classify_routing_decision()` emits one of `code_dominant | noncode_dominant | mixed_uncertain | unknown_only` and exports `LAST_BUILD_CLASSIFICATION` (cross-milestone contract — read by M128 build-fix continuation loop and M130 causal-context recovery routing). Sourced by `error_patterns.sh`.
- **`lib/gates_phases.sh`** — Extracted build gate phase functions with remediation loops (Milestone 54). `_gate_phase_analyze()` and `_gate_phase_compile()` run static analysis and compile checks respectively, each with auto-remediation retry on failure. Sourced by `tekhton.sh` after `gates.sh`.
- **`lib/gates_ui_helpers.sh`** — Deterministic UI gate execution helpers (Milestone 126). `_ui_detect_framework()` resolves the framework via `UI_FRAMEWORK`, a word-boundary regex on `UI_TEST_CMD`, or a `playwright.config.{ts,js,mjs,cjs}` file. `_ui_deterministic_env_list HARDENED?` and the owner-hook `_normalize_ui_gate_env HARDENED?` emit the env list applied at the `env(1)` boundary on every UI subprocess invocation. `_ui_timeout_signature EXIT_CODE OUTPUT` is a pure classifier (`interactive_report` | `generic_timeout` | `none`). `_ui_hardened_timeout BASE FACTOR` and `_ui_write_gate_diagnosis` round out the helpers consumed by `gates_ui.sh`. Sourced by `tekhton.sh` after `gates_phases.sh` and before `gates_ui.sh`.
- **`lib/preflight_services.sh`** — Service readiness probing for pre-flight validation (Milestone 56). `_preflight_check_services()` orchestrates service detection and port probing. `_preflight_check_docker()` validates Docker daemon availability. `_preflight_check_dev_server()` detects dev server dependencies from Playwright config. `_pf_emit_services_report()` renders the services section of `PREFLIGHT_REPORT.md`. Sourced by `tekhton.sh` after `preflight.sh`.
- **`lib/preflight_services_infer.sh`** — Service inference from project manifests. `_pf_infer_from_compose()` parses docker-compose for service images and port mappings. `_pf_infer_from_packages()` checks package manifests (Node, Python, Go) for database client libraries. `_pf_infer_from_env()` scans `.env.example` for service-related variable patterns. Sourced by `tekhton.sh` after `preflight_services.sh`.
- **`lib/mcp.sh`** — MCP server lifecycle management for Serena LSP integration (v3 Milestone 6). `start_mcp_server()`, `stop_mcp_server()`, `check_mcp_health()`, `get_mcp_config_path()`. Claude CLI manages the actual server process; this module handles config generation and availability tracking. Consumed by `agent.sh` to add `--mcp-config` flag.
- **`lib/orchestrate_main.sh`** — `run_complete_loop` body extracted from `orchestrate.sh` as part of the m12 wedge cutover. Owns the orchestration globals (`_ORCH_ATTEMPT`, `_ORCH_AGENT_CALLS`, `_ORCH_REVIEW_BUMPED`, `_ORCH_BUILD_RETRIED`, `_ORCH_NO_PROGRESS_COUNT`, `_ORCH_*_MAX_TURNS_*`) and drives the safety-bound + recovery-dispatch outer frame. Sourced by `orchestrate.sh` last so its dependencies (classify/aux/preflight/iteration) are loaded.
- **`lib/orchestrate_iteration.sh`** — Per-iteration outcome handlers (`_handle_pipeline_success`, `_handle_pipeline_failure`, `_run_preflight_test_gate`). Renamed from `orchestrate_loop.sh` in m12; sourced by `orchestrate.sh`.
- **`lib/orchestrate_aux.sh`** — Auto-advance chain, adaptive turn escalation, smart resume routing. Renamed from `orchestrate_helpers.sh` in m12; sources `orchestrate_state.sh`.
- **`lib/orchestrate_state.sh`** — `_save_orchestration_state` (finalize on failure, smart resume target, recovery-block printer). Renamed from `orchestrate_state_save.sh` in m12.
- **`lib/orchestrate_classify.sh`** — `_classify_failure` decision tree, `_check_progress`, `_compute_diff_hash`. Renamed from `orchestrate_recovery.sh` in m12; mirrored in `internal/orchestrate/recovery.go` with parity gate.
- **`lib/orchestrate_cause.sh`** — M130 causal-context loader (`_load_failure_cause_context`, `_reset_orch_recovery_state`). Renamed from `orchestrate_recovery_causal.sh` in m12; sourced by `orchestrate_classify.sh`.
- **`lib/orchestrate_diagnose.sh`** — Inline recovery block printer (`_print_recovery_block`). Renamed from `orchestrate_recovery_print.sh` in m12; sourced by `orchestrate_classify.sh`.
- **`lib/orchestrate_preflight.sh`** — Pre-finalization preflight fix retry. `_try_preflight_fix()` spawns a Jr Coder pass when TEST_CMD fails before the main pipeline runs. Sourced by `orchestrate.sh` after `orchestrate_aux.sh`.
- **`lib/test_audit.sh`** — Test integrity audit orchestration. `run_test_audit()` is the main pipeline integration entry point; `run_standalone_test_audit()` powers `--audit-tests`. Detection, verdict, and context helpers live in companion modules (see below). Sourced by `tekhton.sh` after its companion modules.
- **`lib/test_audit_helpers.sh`** — Pre-audit file collection and context assembly (Milestone 95). `_collect_audit_context()`, `_discover_all_test_files()`, `_build_test_audit_context()`. Sourced by `tekhton.sh` before `test_audit.sh`.
- **`lib/test_audit_detection.sh`** — Shell-based orphan and weakening detection (Milestone 95). `_detect_orphaned_tests()`, `_detect_test_weakening()`. Sourced by `tekhton.sh` before `test_audit.sh`.
- **`lib/test_audit_verdict.sh`** — Test audit verdict parsing and routing (Milestone 95). `_parse_audit_verdict()`, `_route_audit_verdict()`. Sourced by `tekhton.sh` before `test_audit.sh`.
- **`lib/test_dedup.sh`** — Test run deduplication via working-tree fingerprint (Milestone 105). `_test_dedup_fingerprint()` hashes `git status --porcelain` + `TEST_CMD`; `test_dedup_record_pass()` caches the hash after a successful run; `test_dedup_can_skip()` returns 0 when the cached hash matches the current state; `test_dedup_reset()` clears the cache at pipeline entry. Call sites: milestone acceptance, completion gate, pre-finalization gate, preflight-fix verification, final checks. Sourced by `tekhton.sh` after `gates_completion.sh`.
- **`lib/tui.sh`** — TUI sidecar lifecycle (Milestone 97). `tui_start()` spawns `tools/tui.py` as a background process; `tui_stop()` / `tui_complete()` tear it down. Update functions `tui_update_stage()`, `tui_finish_stage()`, `tui_update_agent()`, `tui_append_event()` are no-ops unless the sidecar is active. Sources `tui_helpers.sh`.
- **`lib/tui_helpers.sh`** — JSON builders for `tui_status.json` (Milestone 97). `_tui_json_build_status()` emits the full status object; `_tui_json_stage()`, `_tui_recent_events_json()`, `_tui_stages_json()`, `_tui_escape()` are internal helpers. Sourced by `tui.sh` — do not run directly.
- **`lib/tui_ops.sh`** — TUI state update operations (Milestone 104). `tui_update_stage()`, `tui_finish_stage()`, `tui_update_agent()`, `tui_append_event()` are the public update API called from `agent.sh` and stage files. `run_op()` is a long-running-command wrapper that registers a substage breadcrumb via the M113 API (M115). `tui_reset_for_next_milestone()` clears per-milestone completion + progress state (called by `_run_auto_advance_chain` so milestone 2+ start with grey pills, not the prior milestone's green row). Sourced by `tui.sh` — do not run directly.
- **`lib/tui_ops_substage.sh`** — Hierarchical substage API (Milestone 113). `tui_substage_begin()` / `tui_substage_end()` declare a transient substage active inside the currently open pipeline stage without mutating the parent stage's label, start ts, lifecycle id, or `_TUI_STAGES_COMPLETE`. `_tui_autoclose_substage_if_open()` is called from `tui_stage_end` to emit a single `warn` event and clear substage globals if a substage is still open when the parent closes. All functions no-op under `TUI_LIFECYCLE_V2=false`. Sourced by `tui.sh` after `tui_ops.sh`.
- **`lib/tui_liveness.sh`** — Atomic status-file writer + sampled sidecar liveness probe. `_tui_write_status()` is the hot status-file write path; `_tui_check_sidecar_liveness()` is invoked from it once per `_TUI_LIVENESS_INTERVAL` writes (default 20) to `kill -0` the sidecar — when the probe detects death it flips `_TUI_ACTIVE=false`, clears `_TUI_PID`, removes the pidfile, and emits one `warn` line so the TUI→CLI transition is observable. Sourced by `tui.sh` after `tui_ops_substage.sh`.

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

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
- **`lib/config.sh`** — m16 wedge shim (≤50 lines). `load_config()` execs `tekhton config load --emit shell` and sources the resulting environment; `apply_milestone_overrides()` does the same with `--milestone-mode`. The loader, defaulter, validator, clamper, and CI auto-detector live in Go under `internal/config`.
- **`lib/agent.sh`** — `run_agent(name, model, turns, prompt, logfile)` wraps claude CLI invocation with JSON output parsing, turn counting, timing, and error classification. Sources `agent_monitor_platform.sh`, `agent_monitor.sh`, `agent_monitor_helpers.sh`, `agent_retry.sh`, and `agent_helpers.sh`.
- **`lib/agent_monitor_platform.sh`** — Platform detection (Windows/WSL interop, GNU timeout flags) and `_kill_agent_windows()`. Sourced by `agent.sh` before `agent_monitor.sh`.
- **`lib/agent_monitor.sh`** — Agent monitoring, FIFO-based and polling-based activity detection, process management. `_invoke_and_monitor()` handles agent process lifecycle and timeout management.
- **`lib/agent_monitor_helpers.sh`** — Post-invocation monitoring helpers: `_reset_monitoring_state()`, `_detect_file_changes()`, `_count_changed_files_since()`. Sourced by `agent.sh` after `agent_monitor.sh`.
- **`lib/agent_retry.sh`** — Transient error retry envelope (Milestone 13.2.1). Wraps `_invoke_and_monitor()` in a retry loop with exponential backoff. Sourced by `agent.sh`.
- **`lib/config_defaults.sh`** — m16 wedge shim. Execs `tekhton config defaults --emit shell` and evals the result. Sourced by `lib/express.sh` and a few `tekhton.sh` early-stage paths that need the canonical defaults environment without going through `load_config`. Path resolution is intentionally NOT applied here (the Go side is invoked without `--project-dir`); resolution belongs to `load_config`.
- **`internal/config/`** — m16 Go owner of pipeline.conf parsing, defaulting, validation, clamping, CI auto-detection, and emit. `Load(path, opts)` returns `*Config` with `Values`, `KeysSet`, `Warnings`, `Errors`, `CIDetected`, `CIPlatform`. `LoadDefaultsOnly(opts)` populates a Config with just defaults+CI+clamps (no pipeline.conf). `EmitShell(w)` writes sourceable bash; `EmitJSON(w, indent)` writes a `tekhton.config.v1` envelope. Defaults table (`baseDefaults`) mirrors `lib/config_defaults.sh` line-for-line; `intClamps` and `floatClamps` mirror the `_clamp_config_value`/`_clamp_config_float` calls. CI auto-detection (`DetectCI`, `applyCIGateDefault`) ports the m138 contract.
- **`cmd/tekhton/config.go`** — m16 Cobra subcommands. `config load --emit shell|json [--project-dir DIR] [--milestone-mode] [--no-warn]` is the bash shim's entry point. `config show` is `load --emit json --indent`. `config validate [--strict]` exits non-zero on error (and on warnings under `--strict`). `config defaults --emit shell|json` emits just the defaults environment — used by `lib/config_defaults.sh`.
- **`lib/agent_helpers.sh`** — `print_run_summary()`, `_append_agent_summary()`, `was_null_run()`, `check_agent_output()`, `build_continuation_context()`, `is_substantive_work()`. Extracted from `agent.sh` to keep it under the 300-line ceiling.
- **`internal/gates/`** — m31.1 Go owner of the build gate + completion gate. `BuildGate.Run(ctx, stageLabel)` walks the five canonical phases (`analyze`, `compile`, `constraints`, `ui_test`, `ui_validation`) under an omnibus `BUILD_GATE_TIMEOUT` budget. `AnalyzePhase` and `CompilePhase` port `_gate_phase_analyze` and `_gate_phase_compile` from the deleted `lib/gates_phases.sh` including M54 remediation re-runs (bounded to one retry per phase). `ConstraintsPhase` ports the `validation_command` block (dependency-constraint enforcement). `UIBashShim` is the m31.1 placeholder for the UI test phase — Skip when `UI_TEST_CMD` is unset, otherwise execs back into the still-bash `lib/gates_ui.sh::_run_ui_test_phase` via `cmd/tekhton/gate_ui_shim.go`; m31.2 replaces with a native `ui.go`. `UIValidationPhase` is the m31.1 stub for the headless-browser smoke phase. `CompletionGate.Run(ctx)` ports `lib/gates_completion.sh::run_completion_gate` — parses CODER_SUMMARY.md status, runs TEST_CMD with `cmd.Stdin = nil` (M27.2 hang guard), applies M92 baseline comparison via the `BaselineComparator` interface, fires SummaryDriftHook on COMPLETE, and supports M105 test-dedup via `TestDedup`. `FSErrorsWriter` owns BUILD_ERRORS.md + BUILD_RAW_ERRORS.txt writes (truncate on analyze, append on compile — preserving the bash `>` vs `>>` parity). `BashRemediator` shells out to bash `attempt_remediation` from `lib/remediation.sh` (still bash post-m31.1).
- **`cmd/tekhton/gate.go`** — m31.1 Cobra subcommand tree. Parent `tekhton gate` is Hidden so end users browsing `tekhton --help` don't see it; the three children (`build`, `completion`, `ui`) are visible under `tekhton gate --help`. `tekhton gate build --stage-label <label>` is the entry point bash callers reach via the `run_build_gate` shim in `tekhton-legacy.sh`. `tekhton gate completion` is the entry point for `run_completion_gate`. `tekhton gate ui` is the m31.1 stub — returns exit 64 with "implemented in m31.2" until the native UI phase lands. `buildGateFromEnv` assembles a `gates.BuildGate` from the m26 env contract (ANALYZE_CMD, BUILD_CHECK_CMD, DEPENDENCY_CONSTRAINTS_FILE, UI_TEST_CMD, BUILD_GATE_*_TIMEOUT, BUILD_ERRORS_FILE, BUILD_RAW_ERRORS_FILE); `completionGateFromEnv` assembles a `gates.CompletionGate` (CODER_SUMMARY_FILE, TEST_CMD, COMPLETION_GATE_TEST_ENABLED, TEST_BASELINE_PASS_ON_PREEXISTING). `resolveUnder` joins relative paths under `PROJECT_DIR` so artifacts land under the target project root, not the binary's CWD.
- **`tekhton-legacy.sh::run_build_gate` / `::run_completion_gate`** — m31.1 inline shim functions that exec `tekhton gate {build,completion}`. Replace the now-deleted `source lib/gates.sh` / `source lib/gates_phases.sh` / `source lib/gates_completion.sh` block. `lib/gates_ui.sh` and `lib/gates_ui_helpers.sh` are still sourced for the bash UI phase until m31.2.
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
- **`lib/errors.sh`** — m17 wedge shim (~90 lines). Bash function names callers depend on (`classify_error`, `is_transient`, `suggest_recovery`, `redact_sensitive`, `classify_routing_decision`, `classify_build_errors_with_stats`, `classify_build_errors_all`, `classify_build_error`, `filter_code_errors`, `annotate_build_errors`, `has_explicit_code_errors`, `has_only_noncode_errors`, `load_error_patterns` no-op, `get_pattern_count`); each shells out to `tekhton diagnose …` (internal/errors). `_is_non_diagnostic_line` is retained inline as a pure-bash per-line filter so per-line tests don't fork the binary.
- **`internal/errors/`** — m17 Go owner of the cross-cutting error vocabulary. `errors.go` declares the common sentinels (`ErrTransient`, `ErrFatal`, `ErrUserActionRequired`, `ErrConfigInvalid`, `ErrUpstreamLimit`); subsystem errors wrap them via custom `Is` methods (`state.ErrCorrupt`, `state.ErrLegacyFormat`, `dag.ValidationError`, `config.ErrValidation`, `supervisor.AgentError`). `patterns.go` carries the build-error regex registry ported from `lib/error_patterns_registry.sh`. `classify.go` ports `classify_build_errors_with_stats`, `classify_routing_decision`, `has_explicit_code_errors`, `has_only_noncode_errors`, `filter_code_errors`, `annotate_build_errors`, plus `IsNonDiagnosticLine` and the M127 four-token routing (`code_dominant | noncode_dominant | mixed_uncertain | unknown_only`). `agent.go` ports `classify_error` (V3 wire-format CATEGORY|SUBCATEGORY|TRANSIENT|MESSAGE). `recovery.go` ports `suggest_recovery`. `redact.go` ports `redact_sensitive`.
- **`cmd/tekhton/diagnose.go`** — m17 Cobra subcommands: `diagnose classify [--mode routing|stats|all|filter-code|annotate] [--has-code|--has-only-noncode]`, `diagnose classify-agent`, `diagnose recovery`, `diagnose redact`, `diagnose is-transient`. Bash callers reach these via `lib/errors.sh`'s shell shims.
- **`lib/remediation.sh`** — Auto-remediation engine for classified build/test errors (M54 logic, m17 rename: was `lib/error_patterns_remediation.sh`). `attempt_remediation()` consumes the four-field `CAT|SAFETY|REMED|DIAG` records emitted by `classify_build_errors_all` (Go-backed) and executes safe-rated commands with blocklist + dedup + max-attempt limits. Sourced by `tekhton.sh` after `lib/errors.sh`.
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
- **`lib/milestones.sh`** — Milestone state machine and auto-advance (Milestone 3). `parse_milestones()`, `check_milestone_acceptance()`, `advance_milestone()`, `write_milestone_disposition()` orchestrate multi-milestone progression with acceptance checking. Cleanup-on-complete is owned by the Go finalize orchestrator (`internal/finalize/cleanup_milestone.go`) — it removes the milestone file from `.claude/milestones/` after `mark_done` flips the manifest entry. Git history is the canonical record.
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
- **`lib/prompts.sh`** — m15 wedge shim (≤60 lines). `render_prompt(template_name)` execs `tekhton prompt render --template <name> --prompts-dir "$PROMPTS_DIR"`; the Go engine in `internal/prompt` is the canonical template substituter. The shim's only bash work is locating the template, exporting every `{{VAR}}` / `{{IF:VAR}}` placeholder name found in the file (so the subprocess can read it via `os.Environ`), and resolving the `tekhton` binary path. Sources `lib/prompts_io.sh` for the file-content helpers (`_safe_read_file`, `_wrap_file_content`, `load_intake_template_vars`) used by callers like `lib/context_cache.sh`, `lib/replan_brownfield.sh`, and `lib/clarify.sh`.
- **`lib/prompts_io.sh`** — m15. File-content helpers extracted from `lib/prompts.sh` so the engine shim stays under the wedge ceiling. `_safe_read_file(path, label)` reads with a 1MB cap and label-prefixed warning on overflow; `_wrap_file_content(label, content)` brackets the bytes in `--- BEGIN/END FILE CONTENT: <label> ---` delimiters for prompt-injection mitigation; `load_intake_template_vars()` populates `INTAKE_*` shell globals before render. Sourced by `lib/prompts.sh` — do not source directly.
- **`internal/prompt/`** — m15 Go engine. `Render(promptsDir, name, vars)` reads `<name>.prompt.md` and resolves `{{VAR}}` substitutions plus `{{IF:VAR}}…{{ENDIF:VAR}}` conditional blocks; `RenderString(template, vars)` is the in-memory entry point used by tests. Block semantics are line-based (mirroring `sed /IF/d` and `sed /IF/,/ENDIF/d`) so a single-line marker takes its body line with it. The `TASK` placeholder is special-cased: non-empty values are wrapped in `--- BEGIN/END USER TASK ---` delimiters to mark agent input as untrusted. `EnvVars()` returns a `map[string]string` view of `os.Environ()` so the CLI can pass the calling shell's variables straight through. Sentinel: `ErrTemplateNotFound`.
- **`cmd/tekhton/prompt.go`** — m15 Cobra subcommand. `tekhton prompt render --template <name> [--prompts-dir DIR] [--vars-file vars.json]` reads the template, resolves variables (from `--vars-file` JSON when supplied, otherwise from the process environment), and writes the rendered template to stdout. Exit codes: `0` success, `exitNotFound` (1) when the template file is missing, `exitUsage` (64) on flag/parse errors. The bash shim in `lib/prompts.sh` is the primary caller; in-process Go callers (e.g. `internal/orchestrate` once Phase 5 lands) skip the CLI hop and use `prompt.Render` directly.
- **`scripts/prompt-parity-check.sh`** — m15 acceptance gate. Embeds a frozen copy of the pre-m15 bash `render_prompt` and diffs it against `tekhton prompt render` for every template in `prompts/` across three variants (all-empty, all-set, mixed) plus four edge-case fixtures (empty-var, missing-var, nested-block via distinct vars, trim-newline). Exit code is the merge gate; any byte-level divergence fails the run. Pass `--use-fallback` to skip the Go build and exercise only the legacy bash path as a smoke check.
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
- **`internal/stagerunner/`** — m18 bash↔Go seam at the *stage* boundary. `Adapter` interface; `BashAdapter.Run(ctx, *proto.StageRequestV1)` exec's `bash -c "source lib/common.sh; source lib/stage_envelope.sh; source stages/<name>.sh; run_stage_<name>"` with `TEKHTON_STAGE_REQUEST_FILE` / `TEKHTON_STAGE_RESULT_FILE` / `TEKHTON_STAGE_NAME` / per-request `EnvOverrides` populated, streams stdout/stderr to the configured `LogFile`, then reads and validates the result envelope. SIGINT and parent-context cancellation propagate via `exec.CommandContext`. On missing-result-file or invalid-envelope paths the adapter synthesizes a `verdict=fail` envelope so the runner never sees nil. `DefaultStageScripts` maps stage names to relative script paths. Sentinels: `ErrUnknownStage`, `ErrMissingResultFile`, `ErrInvalidResult`, `ErrSubprocess`.
- **`internal/pipeline/`** — m18 per-attempt scheduler (port of `_run_pipeline_stages`). `Runner.RunAttempt(ctx, *proto.PipelineAttemptRequestV1)` walks `req.Order` once: coder runs under a build-gate retry envelope (`runCoderWithGate`); review enters a rework loop (`runReviewLoop`); tester optionally runs through the completion gate; cleanup/docs/security/intake are single-invocation. Failure short-circuits — verdicts `fail` and `block` stop downstream work and populate `BlockingStage` in the result envelope. `BuildGate.Run` ports `lib/gates.sh::run_build_gate` (analyze + compile phases via `CommandRunner`); `CompletionGate.Run` ports `run_completion_gate` (test-cmd execution + `TEST_BASELINE_PASS_ON_PREEXISTING` semantics via the `IsPreexistingFailure` hook). `ExecRunner` is the production `CommandRunner`; tests substitute fakes. Sentinels: `ErrInvalidConfig`, `ErrNoAdapter`, `ErrGateTimeout`. **Scope discipline (m18 vs M128):** the build *gate* is in this package; the build-fix *continuation loop* (M128) inside `stages/coder.sh` stays bash — gate decides pass/fail, fix loop decides how many attempts inside coder.
- **`internal/proto/stage_v1.go`** — m18 envelope contract. `StageRequestV1` (proto `tekhton.stage.request.v1`) carries `Stage`, `Task`, `Milestone`, `ReviewCycle`, `BuildAttempt`, `EnvOverrides`, `ResultFile`, `LogFile`. `StageResultV1` (proto `tekhton.stage.result.v1`) carries `Verdict`, `ExitReason`, `AgentCalls`, `FilesTouched`, `NextAction`, `DurationSec`, `HumanAction`, `Error`. Verdict vocabulary: `pass | fail | rework | block | skip`. `IsKnownStage` / `IsKnownVerdict` gate validation. `Validate()` enforces both contracts; `EnsureProto()` stamps the tag on field-by-field constructions. Sentinels: `ErrInvalidStageRequest`, `ErrInvalidStageResult`.
- **`internal/proto/pipeline_v1.go`** — m18 per-attempt extension. `PipelineAttemptRequestV1` (proto `tekhton.pipeline.attempt.request.v1`) carries `Order` (resolved from `PIPELINE_ORDER`), `ReviewCycle`, `BuildAttempt`, `MaxReviewCycles`, `MaxBuildRetries`, `StageEnv` (per-stage env overrides). `PipelineAttemptResultV1` (proto `tekhton.pipeline.attempt.result.v1`) carries the ordered `[]StageBreakdown`, aggregate `AgentCalls`, total `DurationSec`, `BlockingStage` on failure, and a verdict from the same vocabulary as `stage_v1`. Distinct from m12's outer-loop envelopes: m18 is per-attempt, m12 is per-iteration of the outer loop.
- **`cmd/tekhton/stage.go`** — m18 Cobra subcommand. `tekhton stage emit --stage NAME --verdict V --exit-reason ... [--to-result-file]` writes a `tekhton.stage.result.v1` envelope. With `--to-result-file` writes to `$TEKHTON_STAGE_RESULT_FILE`; without, prints to stdout. Used by `lib/stage_envelope.sh::emit_stage_envelope` so bash stages don't hand-roll JSON.
- **`cmd/tekhton/run_stage.go`** — m18 Cobra subcommand. `tekhton run-stage <name> --request-file PATH` invokes a single stage via the `BashAdapter` and prints the resulting `stage.result.v1` envelope to stdout. Used for parity testing and one-off stage runs.
- **`cmd/tekhton/pipeline.go`** — m18 Cobra subcommand. `tekhton pipeline run-attempt --request-file PATH [--analyze-cmd CMD] [--compile-cmd CMD] [--test-cmd CMD]` is the per-attempt scheduler entry point. Loads a `pipeline.attempt.request.v1` envelope, builds a `BashAdapter` and `Runner`, drives one attempt, and prints the `pipeline.attempt.result.v1` envelope. `resolveTekhtonBin()` resolves the binary path from `$TEKHTON_BIN` or `os.Args[0]` so subprocesses can shell back to the same binary.
- **`internal/finalize/`** — m21 Go owner of the post-pipeline finalize chain. `Orchestrator` owns the canonical 26-hook registration (mirrors `lib/finalize.sh:218-243` byte-for-byte; an order-mismatch test in `orchestrator_test.go` fails red if the bash and Go sides drift). `HookOrder()` exposes the registration list for parity tooling. Six pure-Go hook bodies live alongside: `ClearState`, `ArchiveReports`, `MarkDone`, `ArchiveMilestone`, `EmitRunMemory`, `CausalLogFinalize` — chosen because their underlying subsystems (state/dag/manifest/causal) are already Go-owned. The remaining 20 hooks dispatch through `BashShimHook`, which exec's `lib/finalize_shim.sh <hook_name>` once per hook (one bash process per hook so follow-up milestones m22–m25 can swap shim cases for Go bodies one at a time). Chain is continue-on-error — failing hooks log and chain proceeds, matching bash `finalize_run` semantics.
- **`cmd/tekhton/finalize.go`** — m21 Cobra subcommand. `tekhton finalize --exit-code N --project-dir DIR --home DIR [--result PATH] [--milestone ID]` constructs `finalize.Orchestrator` and drives the chain. Used as the legacy compatibility entry point for `lib/finalize.sh::finalize_run` (so `tekhton-legacy.sh` callers still have a working `finalize_run`) and as the parity-gate replay tool. Flagged `Hidden` — developer tool, not a user feature.
- **`lib/finalize.sh`** — m21 reduced to a 46-line legacy compatibility shim. Sources `lib/finalize_display.sh` and `lib/finalize_core_hooks.sh` so the still-bash hook bodies remain callable, and defines a one-function `finalize_run` that execs `tekhton finalize` so V3 legacy callers (`tekhton-legacy.sh`, `lib/orchestrate_iteration.sh`, `lib/orchestrate_save.sh`) still find a working name. The bash `register_finalize_hook` function, `FINALIZE_HOOKS` array, and the source-time registration calls are deleted — the Go orchestrator is now the sole source of registration truth.
- **`lib/finalize_core_hooks.sh`** — m21 extraction. Contains the five bash hook bodies that previously lived directly in `lib/finalize.sh`: `_hook_final_checks`, `_hook_drift_artifacts`, `_hook_record_metrics`, `_hook_cleanup_resolved`, `_hook_resolve_notes`. Sourced by `lib/finalize.sh` and `lib/finalize_shim.sh`. Each function ports to Go as its underlying subsystem migrates (m22–m25).
- **`lib/finalize_shim.sh`** — m21 single-hook bash dispatcher. Invoked by `internal/finalize.BashShimHook` once per hook with the hook name as `$1`. Sources the bash libraries the named hook needs (one `case` per hook), then calls the function. One bash process per hook is intentional — follow-up milestones can swap a `BashShimHook` for a pure-Go body without touching the orchestrator or other shim cases. When the `case` list is empty, the file deletes.
- **`lib/stage_envelope.sh`** — m18 stage envelope emission helpers. `emit_stage_envelope STAGE VERDICT EXIT_REASON [AGENT_CALLS] [DURATION] [NEXT_ACTION] [FILES_TOUCHED]` is a no-op when `TEKHTON_STAGE_RESULT_FILE` is unset; otherwise execs `tekhton stage emit --to-result-file`. Falls back to bash-only JSON writing when the binary is unavailable. `stage_envelope_wrap STAGE` rebinds `run_stage_<stage>` so its tail emits an envelope mapped from the original exit code (0→pass, otherwise→fail), with override knobs `_STAGE_ENVELOPE_<NAME>_VERDICT`, `_STAGE_ENVELOPE_NEXT_ACTION`, `_STAGE_ENVELOPE_EXIT_REASON`, `_STAGE_ENVELOPE_AGENT_CALLS`. `stage_envelope_install_all` wraps every known stage idempotently. Sourced by `tekhton.sh` after all stage files load.
- **`lib/milestone_window.sh`** — Character-budgeted milestone sliding window (v3 Milestone 2). `build_milestone_window()` selects active + frontier + on-deck milestones within a character budget.
- **`lib/draft_milestones.sh`** — Interactive milestone authoring flow (Milestone 80). `run_draft_milestones()` drives the `--draft-milestones` CLI command: builds prompt context, invokes agent, discovers generated files, validates, and writes manifest entries. `draft_milestones_next_id()` scans MANIFEST.cfg + milestone files for the next free ID. `draft_milestones_build_exemplars()` extracts recent milestones as format examples. Sources `draft_milestones_write.sh`.
- **`lib/draft_milestones_write.sh`** — Validation and manifest writing for draft milestones (Milestone 80). `draft_milestones_validate_output()` checks generated milestone files for required structure (H1, meta block, required sections, minimum 5 acceptance criteria). `draft_milestones_write_manifest()` appends rows to MANIFEST.cfg with linear dependency chaining. Sourced by `draft_milestones.sh`.
- **`lib/milestone_progress.sh`** — Milestone progress CLI and next-action guidance (Milestone 82). `_render_milestone_progress()` renders `--progress` output with progress bar and status markers. `_compute_next_action()` generates post-run "What's next" guidance. `_diagnose_recovery_command()` maps failure state to a concrete recovery CLI command. Sources `milestone_progress_helpers.sh`.
- **`lib/milestone_progress_helpers.sh`** — Rendering helpers for milestone progress (Milestone 82). `_render_progress_dag()`, `_render_progress_inline()`, `_render_progress_bar()`, `_render_milestone_line()`. Sourced by `tekhton.sh` before `milestone_progress.sh`.
- **`lib/indexer.sh`** — Repo map orchestration and Python tool invocation (v3). `check_indexer_available()`, `run_repo_map()`, `get_repo_map_slice()`. Gracefully degrades when Python/tree-sitter is unavailable. Sources `indexer_helpers.sh`.
- **`lib/indexer_audit.sh`** — Startup grammar audit (Milestone 123). `_indexer_run_startup_audit()` invokes `audit_grammars()` from the Python loader, classifies each declared extension as LOADED / MISSING / MISMATCH, and emits `warn` for API-mismatch extensions (the #181 bug class). Gated by `INDEXER_STARTUP_AUDIT`. Sourced by `tekhton.sh` after `indexer.sh` — do not run directly.
<!-- m17: lib/error_patterns*.sh deleted; classifier ported to internal/errors. See lib/errors.sh and internal/errors/ entries above. -->
<!-- m17: lib/error_patterns_classify.sh deleted; M127 routing decision lives in internal/errors/classify.go. -->
<!-- m17: lib/errors_helpers.sh deleted; suggest_recovery + redact_sensitive + is_transient ported to internal/errors. -->
<!-- m17: lib/error_patterns_registry.sh deleted; pattern registry ported to internal/errors/patterns.go. -->
<!-- m17: lib/error_patterns_remediation.sh renamed to lib/remediation.sh — see entry above. -->


<!-- m31.1: lib/gates_phases.sh deleted; build gate phases ported to internal/gates/phases.go. -->
- **`lib/gates_ui_helpers.sh`** — Deterministic UI gate execution helpers (Milestone 126). `_ui_detect_framework()` resolves the framework via `UI_FRAMEWORK`, a word-boundary regex on `UI_TEST_CMD`, or a `playwright.config.{ts,js,mjs,cjs}` file. `_ui_deterministic_env_list HARDENED?` and the owner-hook `_normalize_ui_gate_env HARDENED?` emit the env list applied at the `env(1)` boundary on every UI subprocess invocation. `_ui_timeout_signature EXIT_CODE OUTPUT` is a pure classifier (`interactive_report` | `generic_timeout` | `none`). `_ui_hardened_timeout BASE FACTOR` and `_ui_write_gate_diagnosis` round out the helpers consumed by `gates_ui.sh`. Sourced by `tekhton.sh` after `gates_ui.sh` neighbours (m31.1: was previously sourced after the now-deleted `lib/gates_phases.sh`).
- **`internal/preflight/`** — m22 Go owner of the pre-flight check chain. `Orchestrator` registers five Check families in `checkOrder` (`foundation`, `ui_audit`, `env`, `services_infer`, `services`); an order-mismatch test in `orchestrator_test.go` fails red if the slice drifts. `Run(ctx)` walks the registered checks, accumulates `Finding`s + `ServiceRow`s, writes `PREFLIGHT_REPORT.md` in the bash-compatible markdown shape (header timestamp + Summary glyph line + per-finding `### ⟨glyph⟩ Name` blocks + optional `## Services` table). `HasBlockers()` is the runner-facing gate (fail count or warn+`PREFLIGHT_FAIL_ON_WARN=true`). `SummaryLine()` returns the bash-format "Pre-flight: P passed, W warned, F failed, X auto-fixed" line. Six bash files deleted at m22 close (`lib/preflight.sh`, `lib/preflight_checks.sh`, `lib/preflight_checks_env.sh`, `lib/preflight_checks_ui.sh`, `lib/preflight_services.sh`, `lib/preflight_services_infer.sh`).
- **`cmd/tekhton/preflight.go`** — m22 Cobra subcommand. `tekhton preflight --project-dir DIR [--home DIR]` constructs `preflight.Orchestrator` and drives the chain. Exits non-zero when `HasBlockers()` returns true. Flagged `Hidden` — developer/debug tool, not a user feature. Used by `tekhton-legacy.sh::run_preflight_checks` (legacy compatibility shim) and `tests/test_preflight_parity.sh` (m22 Goal 7 byte-identical-output gate across three frozen scenarios).
- **`internal/detect/`** — m29.1 Go owner of the in-progress detect subsystem port. `Engine` orchestrates registered `Detector`s with a load-bearing languages-first invariant (the languages detector always runs first; `Engine.Run` returns `ErrLanguagesDetectorMissing` otherwise; downstream detectors consume `Input.Languages` and `Input.Frameworks` to disambiguate). m29.1 ships one production detector (`LanguagesDetector`) porting `detect_languages` + `detect_frameworks` + `detect_ui_framework` from `lib/detect.sh`, the markdown report formatter (port of `lib/detect_report.sh::format_detection_report`), and the read-only contract test (`readonly_test.go` grep-scans the package for forbidden write APIs). The `Summary` struct carries fields for every m29.2 detector domain (`Commands`, `Workspaces`, `Services`, `CI`, `Infrastructure`, `TestFrameworks`, `DocQuality`, `AIArtifacts`); they are stub-empty until m29.2 lands the corresponding detectors. No bash files modified at m29.1 — every existing caller still sources `lib/detect*.sh`.
- **`cmd/tekhton/detect.go`** — m29.1 Cobra subcommand. `tekhton detect summary --markdown|--json [--project-dir DIR]` constructs `detect.Engine`, registers `LanguagesDetector`, runs the chain, and emits either markdown (default — matching the bash report shape) or pretty-printed JSON (a `tekhton.detect.summary.v1` envelope candidate). Flagged `Hidden` — developer/debug tool, not yet a user-facing entry point. The parity gate (`tests/test_detect_parity.sh`) drives this subcommand against three frozen fixtures (`monorepo-pnpm`, `polyglot-services`, `ai-heavy-mess` under `tests/testdata/detect/`) and asserts byte-identical `### Project Type / ### Languages / ### Frameworks` sections against the captured bash baselines under `tests/testdata/detect/baselines/`. m29.2 will register the eight remaining domain detectors here and atomically cut every bash caller over.
- **`internal/crawler/`** — m30 Go owner of the project crawler + rescan. `Crawl(ctx, Options)` writes the `.claude/index/` artifact set (tree, inventory, deps, configs, tests, samples, meta) consumed by init, scout, rescan, and downstream agents. `Rescan(ctx, RescanOptions)` adds the incremental update path: an eight-branch decision tree (force-full, no index, no meta.json, not a git repo, no scan commit, rebased-away commit, no changes, major change set) that falls back to a full `Crawl` on every legacy branch and runs selective `updateIndexSections` on the incremental branch. The package enforces a read-only/write-only-to-`Options.IndexDir` safety invariant — every non-emit file is grep-scanned by `readonly_test.go` for forbidden write APIs. Files: `crawler.go` (full-crawl orchestrator), `tree.go` (BFS directory walker + bash-quirk-preserving annotation pass), `inventory.go` (file / config / tests inventory + `configPurpose` literal+glob lookup table), `content.go` (priority-ordered sampling, binary detection, UTF-8 char-budget truncation), `deps.go` (seven manifest parsers — npm / Cargo / pyproject / go.mod / Gemfile / Gradle / pom + monorepo sub-project sweep + bash-parity `extractWithHeader` that preserves the section-header line the m29 detect helper drops), `annotations.go` (23+-arm `_annotate_package` map plus `path.Match` glob arms), `emit.go` (hand-rolled JSON emitters for byte-identical bash parity, atomic `os.Rename`-based writes scoped to `IndexDir`), `api.go` (exported wrappers consumed by `cmd/tekhton/crawler.go`), `rescan.go` (m30.2 — the eight-branch decision tree + `newRegenSetWithIndexDir` selective-regen flag computation), `significance.go` (m30.2 — `ClassifyChanges` returning Trivial / Moderate / Major from the bash thresholds), `changes.go` (m30.2 — `DetectChangedFiles` merging `git diff --name-status` + `git status --porcelain` with working-tree-wins dedup), `metadata.go` (m30.2 — `ExtractScanMetadata` / `IsManifestFile` / `IsConfigFile` / `ExtractSampledFiles` with structured meta.json + legacy HTML-comment fallback). Importable detect APIs (`detect.ExtractJSONKeys`, `detect.AssessDocQuality`, `detect.DefaultExcludeDirs`) consumed via `internal/detect/exports.go`. Eight bash files deleted across the arc: m30.1 retired `lib/crawler.sh`, `lib/crawler_inventory.sh`, `lib/crawler_inventory_emitters.sh`, `lib/crawler_content.sh`, `lib/crawler_deps.sh`, `lib/crawler_emit.sh`; m30.2 retired `lib/rescan.sh` and `lib/rescan_helpers.sh`. `lib/index_view_budget.sh` extracted from the deleted `lib/crawler.sh` to host the `_budget_allocator` helper still consumed by the bash view generator.
- **`cmd/tekhton/crawler.go`** — m30 Cobra subcommands. `tekhton crawler crawl --project-dir DIR [--budget N] [--index-dir DIR] [--json]` is the bash shim's entry point (called from `lib/init.sh`). `tekhton crawler rescan --project-dir DIR [--budget N] [--full] [--index-file PATH] [--json]` is the m30.2 incremental rescan entry point (called from `tekhton-legacy.sh --rescan`). `tekhton crawler inventory|deps|content [--json]` are read-only inspection commands. Flagged `Hidden` — developer/debug tool, not yet a user-facing entry point. Parity gates: `tests/test_crawler_parity.sh` (m30.1, three frozen fixtures with byte-identical artifact assertions); `tests/test_rescan_parity.sh` (m30.2, four scenarios — `no_changes`, `trivial`, `moderate_manifest`, `major_manifest` — driving `--json` output and asserting (mode, significance, regenerated_sections) verdict per scenario; 17 assertions total).
- **`lib/mcp.sh`** — MCP server lifecycle management for Serena LSP integration (v3 Milestone 6). `start_mcp_server()`, `stop_mcp_server()`, `check_mcp_health()`, `get_mcp_config_path()`. Claude CLI manages the actual server process; this module handles config generation and availability tracking. Sources `mcp_resolve.sh` for the internal resolver/probe helpers so the file stays under the 300-line bash ceiling. Consumed by `agent.sh` to add `--mcp-config` flag.
- **`lib/mcp_resolve.sh`** — Serena path / probe / config-shape resolvers (m28.3 extraction from `mcp.sh`). `_resolve_serena_paths()`, `_probe_serena_startup()` (m28.2), `_is_stale_serena_config()` (m28.3 — detects pre-m28.1 `python -m serena` broken shape), `_resolve_mcp_config()` (m28.3 — auto-backs-up + regenerates stale configs), `_cli_supports_mcp_config()`. Sourced by `lib/mcp.sh` — do not source directly.
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
- **`lib/test_dedup.sh`** — Test run deduplication via working-tree fingerprint (Milestone 105). `_test_dedup_fingerprint()` hashes `git status --porcelain` + `TEST_CMD`; `test_dedup_record_pass()` caches the hash after a successful run; `test_dedup_can_skip()` returns 0 when the cached hash matches the current state; `test_dedup_reset()` clears the cache at pipeline entry. Call sites: milestone acceptance, completion gate (now `internal/gates/completion.go::CompletionGate.Dedup`), pre-finalization gate, preflight-fix verification, final checks. Sourced by `tekhton.sh` after the `gates_ui*.sh` block (m31.1: was previously sourced after the deleted `gates_completion.sh`).
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

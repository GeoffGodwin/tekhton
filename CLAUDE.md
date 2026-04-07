# Tekhton — Project Configuration

## What This Is

Tekhton is a standalone, project-agnostic multi-agent development pipeline built on
the Claude CLI. It orchestrates a Pre-flight → Intake → Scout → Coder → Security
→ Reviewer → Tester cycle with automatic rework routing, build gates, state
persistence, and resume support.

**One intent. Many hands.**

## Repository Layout

```
tekhton/
├── tekhton.sh              # Main entry point
├── lib/                    # Shared libraries (sourced by tekhton.sh)
│   ├── common.sh           # Colors, logging, prerequisite checks
│   ├── config.sh           # Config loader + validation
│   ├── config_defaults.sh  # Default values for all config keys
│   ├── agent.sh            # Agent wrapper, metrics, run_agent()
│   ├── agent_helpers.sh    # Agent invocation helpers
│   ├── agent_monitor.sh    # Agent monitoring, activity detection, process management
│   ├── agent_monitor_helpers.sh  # Monitor support functions
│   ├── agent_monitor_platform.sh # Platform-specific monitor code
│   ├── agent_retry.sh      # Transient error retry logic
│   ├── gates.sh            # Build gate + completion gate
│   ├── hooks.sh            # Archive, commit message, final checks
│   ├── finalize.sh         # Hook-based finalization sequence
│   ├── finalize_display.sh # Completion banner + action items
│   ├── finalize_summary.sh # RUN_SUMMARY.json emitter
│   ├── notes.sh            # Human notes management
│   ├── prompts.sh          # Template engine for .prompt.md files
│   ├── state.sh            # Pipeline state persistence + resume
│   ├── turns.sh            # Turn-exhaustion continuation logic
│   ├── drift.sh            # Drift log, ADL, human action management
│   ├── drift_artifacts.sh  # Drift artifact processing
│   ├── drift_cleanup.sh    # Non-blocking log cleanup
│   ├── detect.sh           # Tech stack detection engine
│   ├── detect_commands.sh  # Build/test/lint command detection
│   ├── detect_report.sh    # Detection report formatter
│   ├── plan.sh             # Planning phase orchestration + config
│   ├── plan_completeness.sh # Design doc structural validation
│   ├── plan_state.sh       # Planning state persistence + resume
│   ├── replan.sh           # Replan orchestration
│   ├── replan_brownfield.sh # Brownfield replan with codebase summary
│   ├── replan_midrun.sh    # Mid-run replan trigger
│   ├── context.sh          # Token accounting + context compiler
│   ├── context_budget.sh   # Context budget checking
│   ├── context_compiler.sh # Task-scoped context assembly
│   ├── milestones.sh       # Milestone state machine + acceptance checking
│   ├── milestone_ops.sh    # Milestone marking + disposition
│   ├── milestone_acceptance.sh # Milestone acceptance criteria checking
│   ├── milestone_archival.sh   # Milestone archival to MILESTONE_ARCHIVE.md
│   ├── milestone_metadata.sh   # Milestone metadata HTML comments
│   ├── milestone_split.sh  # Pre-flight milestone splitting
│   ├── orchestrate.sh      # Outer orchestration loop (--complete)
│   ├── orchestrate_helpers.sh  # Orchestration support functions
│   ├── orchestrate_recovery.sh # Failure classification + recovery
│   ├── clarify.sh          # Clarification protocol + replan trigger
│   ├── specialists.sh      # Specialist review framework
│   ├── metrics.sh          # Run metrics collection + adaptive calibration
│   ├── metrics_calibration.sh  # Adaptive turn calibration
│   ├── errors.sh           # Error taxonomy, classification + reporting
│   ├── errors_helpers.sh   # Error classification helpers
│   ├── milestone_dag.sh    # Milestone DAG infrastructure + manifest parser
│   ├── milestone_dag_migrate.sh # Inline→file milestone migration
│   ├── milestone_window.sh # Character-budgeted milestone sliding window
│   ├── indexer.sh          # Repo map orchestration + Python tool invocation
│   ├── indexer_helpers.sh  # Language detection, config validation, file extraction
│   ├── indexer_history.sh  # Task→file association tracking (JSONL)
│   ├── causality.sh        # Causal event log infrastructure + query layer
│   ├── causality_query.sh  # Causal log query helpers
│   ├── test_baseline.sh    # Test baseline capture + pre-existing failure detection
│   ├── mcp.sh              # MCP server lifecycle management (Serena)
│   ├── health.sh           # Project health scoring orchestration
│   ├── health_checks.sh    # Health check implementations
│   ├── health_checks_infra.sh # Infrastructure health checks
│   ├── dashboard.sh        # Watchtower dashboard data emission
│   ├── dashboard_emitters.sh  # Dashboard data file writers
│   ├── dashboard_parsers.sh   # Dashboard data parsers
│   ├── diagnose.sh         # Pipeline diagnostics engine
│   ├── diagnose_helpers.sh # Diagnostic helper functions
│   ├── diagnose_output.sh  # Diagnostic output formatting
│   ├── diagnose_rules.sh   # Diagnostic rule definitions
│   ├── express.sh          # Express mode (zero-config execution)
│   ├── express_persist.sh  # Express mode configuration persistence
│   ├── dry_run.sh          # Dry-run preview mode
│   ├── init.sh             # Init orchestration
│   ├── init_config.sh      # Init config generation
│   ├── init_config_emitters.sh # Init config section emitters
│   ├── init_config_sections.sh # Init config section builders
│   ├── init_helpers.sh     # Init helper functions
│   ├── init_report.sh      # Init report generation
│   ├── init_synthesize_helpers.sh # Init synthesis helpers
│   ├── init_synthesize_ui.sh # Init synthesis UI
│   ├── intake_helpers.sh   # Intake agent helpers
│   ├── intake_verdict_handlers.sh # Intake verdict routing
│   ├── migrate.sh          # Version migration framework
│   ├── migrate_cli.sh      # Migration CLI interface
│   ├── notes_core.sh       # Notes core rewrite
│   ├── notes_cli.sh        # Notes CLI subcommand
│   ├── notes_cli_write.sh  # Notes CLI write operations
│   ├── notes_cleanup.sh    # Notes cleanup operations
│   ├── notes_acceptance.sh # Notes acceptance checking
│   ├── notes_acceptance_helpers.sh # Notes acceptance helpers
│   ├── notes_migrate.sh    # Notes format migration
│   ├── notes_rollback.sh   # Notes rollback support
│   ├── context_cache.sh    # Intra-run context cache
│   ├── checkpoint.sh       # Progress checkpoint management
│   ├── checkpoint_display.sh # Checkpoint display formatting
│   ├── crawler.sh          # Project crawler orchestration
│   ├── crawler_content.sh  # Crawler content sampling
│   ├── crawler_inventory.sh # Crawler file inventory
│   ├── crawler_deps.sh     # Crawler dependency analysis
│   ├── rescan.sh           # Incremental rescan
│   ├── rescan_helpers.sh   # Rescan helper functions
│   ├── artifact_handler.sh # AI artifact detection handler
│   ├── artifact_handler_ops.sh # Artifact handler operations
│   ├── detect_services.sh  # Service detection
│   ├── detect_workspaces.sh # Workspace detection
│   ├── detect_ci.sh        # CI/CD detection
│   ├── detect_infrastructure.sh # Infrastructure detection
│   ├── detect_test_frameworks.sh # Test framework detection
│   ├── detect_doc_quality.sh # Documentation quality assessment
│   ├── detect_ai_artifacts.sh # AI artifact detection
│   ├── inbox.sh            # Inbox management
│   ├── plan_answers.sh     # Planning answer file import
│   ├── plan_browser.sh     # Browser-based planning
│   ├── plan_review.sh      # Planning review UI
│   ├── safety_net.sh       # Run safety net + rollback
│   ├── run_memory.sh       # Structured cross-run memory (JSONL)
│   ├── timing.sh           # Stage timing and duration estimation
│   ├── milestone_dag_helpers.sh # DAG helper functions
│   ├── milestone_dag_io.sh # DAG I/O operations
│   ├── milestone_dag_validate.sh # DAG validation
│   ├── milestone_archival_helpers.sh # Archival helper functions
│   ├── metrics_dashboard.sh # Metrics dashboard formatting
│   ├── drift_prune.sh      # Drift log pruning
│   ├── quota.sh            # API quota management
│   ├── error_patterns.sh   # Error pattern registry + classification engine
│   └── preflight.sh        # Pre-flight environment validation
├── stages/                 # Stage implementations (sourced by tekhton.sh)
│   ├── architect.sh        # Pre-stage: Architect audit (conditional)
│   ├── intake.sh           # Task intake / PM gate
│   ├── coder.sh            # Scout + Coder + build gate
│   ├── security.sh         # Security review stage
│   ├── review.sh           # Review loop + rework routing
│   ├── tester.sh           # Test writing + validation
│   ├── tester_tdd.sh       # TDD phase orchestration
│   ├── tester_continuation.sh # Turn-exhaustion continuation logic
│   ├── tester_fix.sh       # Test failure fix orchestration
│   ├── tester_timing.sh    # Tester timing and duration estimation
│   ├── tester_validation.sh # Post-tester output validation and routing
│   ├── cleanup.sh          # Post-success debt sweep stage
│   ├── init_synthesize.sh  # Init synthesis stage
│   ├── plan_interview.sh   # Planning: interactive interview agent
│   ├── plan_followup_interview.sh # Planning: follow-up interview agent
│   └── plan_generate.sh    # Planning: CLAUDE.md generation agent
├── prompts/                # Prompt templates with {{VAR}} substitution
│   ├── architect.prompt.md
│   ├── architect_sr_rework.prompt.md
│   ├── architect_jr_rework.prompt.md
│   ├── architect_review.prompt.md
│   ├── coder.prompt.md
│   ├── coder_rework.prompt.md
│   ├── jr_coder.prompt.md
│   ├── reviewer.prompt.md
│   ├── scout.prompt.md
│   ├── tester.prompt.md
│   ├── tester_resume.prompt.md
│   ├── build_fix.prompt.md
│   ├── build_fix_minimal.prompt.md
│   ├── analyze_cleanup.prompt.md
│   ├── seed_contracts.prompt.md
│   ├── milestone_split.prompt.md         # Milestone splitting prompt
│   ├── plan_interview.prompt.md          # Planning interview system prompt
│   ├── plan_interview_followup.prompt.md # Planning follow-up interview prompt
│   ├── plan_generate.prompt.md           # CLAUDE.md generation prompt
│   ├── cleanup.prompt.md                 # Debt sweep agent prompt
│   ├── replan.prompt.md                  # Brownfield replan prompt
│   ├── clarification.prompt.md           # Clarification integration prompt
│   ├── specialist_security.prompt.md     # Security review prompt
│   ├── specialist_performance.prompt.md  # Performance review prompt
│   └── specialist_api.prompt.md          # API contract review prompt
├── templates/              # Templates copied into target projects by --init
│   ├── pipeline.conf.example
│   ├── coder.md
│   ├── reviewer.md
│   ├── tester.md
│   ├── jr-coder.md
│   └── architect.md
├── templates/plans/        # Design doc templates by project type
│   ├── web-app.md
│   ├── web-game.md
│   ├── cli-tool.md
│   ├── api-service.md
│   ├── mobile-app.md
│   ├── library.md
│   └── custom.md
├── tools/                  # Python tooling (optional dependency)
│   ├── repo_map.py         # Tree-sitter repo map generator + PageRank
│   ├── tag_cache.py        # Disk-based tag cache with mtime tracking
│   ├── tree_sitter_languages.py  # Language detection + grammar loading
│   ├── requirements.txt    # Pinned Python dependencies
│   ├── setup_indexer.sh    # Indexer virtualenv setup script
│   ├── setup_serena.sh     # Serena MCP server setup script
│   ├── serena_config_template.json  # MCP config template
│   └── tests/              # Python unit tests
│       ├── conftest.py
│       ├── test_repo_map.py
│       ├── test_tag_cache.py
│       ├── test_history.py
│       ├── test_tree_sitter_languages.py
│       └── test_extract_tags_integration.py
├── platforms/              # Platform-specific UI knowledge (M57–M60)
│   ├── _base.sh            # Platform resolution + universal helpers
│   ├── _universal/         # Cross-platform UI guidance (always included)
│   ├── web/                # Web: React, Vue, Svelte, Angular, HTML
│   ├── mobile_flutter/     # Flutter/Dart
│   ├── mobile_native_ios/  # Swift/SwiftUI/UIKit
│   ├── mobile_native_android/ # Kotlin/Jetpack Compose
│   └── game_web/           # Phaser, PixiJS, Three.js, Babylon.js
├── tests/                  # Self-tests
│   └── fixtures/indexer_project/  # Multi-language fixture project
└── examples/               # Sample dependency constraint validation scripts
    ├── architecture_constraints.yaml  # Sample constraint manifest
    ├── check_imports_dart.sh          # Dart/Flutter import validator
    ├── check_imports_python.sh        # Python import validator
    └── check_imports_typescript.sh    # TypeScript/JS import validator
```

## How It Works

Tekhton is invoked from a target project's root directory. It reads configuration
from `<project>/.claude/pipeline.conf` and agent role definitions from
`<project>/.claude/agents/*.md`. All pipeline logic (lib, stages, prompts) lives
in the Tekhton repo — nothing is copied into target projects except config and
agent roles.

### Two-directory model:
- `TEKHTON_HOME` — where `tekhton.sh` lives (this repo)
- `PROJECT_DIR` — the target project (caller's CWD)

## Non-Negotiable Rules

1. **Project-agnostic.** Tekhton must never contain project-specific logic.
   All project configuration is in `pipeline.conf` and agent role files.
2. **Bash 4.3+.** All scripts use `set -euo pipefail`. No bashisms beyond bash 4.3.
3. **Shellcheck clean.** All `.sh` files pass `shellcheck` with zero warnings.
4. **Deterministic.** Given the same config.conf and task, pipeline behavior is identical.
5. **Resumable.** Pipeline state is saved on interruption. Re-running resumes.
6. **Template engine.** Prompts use `{{VAR}}` substitution and `{{IF:VAR}}...{{ENDIF:VAR}}`
   conditionals. No other templating system.
7. **Python is optional.** The `tools/` directory requires Python 3.8+ and tree-sitter
   for intelligent indexing (repo map, tag cache). Tekhton remains fully functional
   without Python — the pipeline gracefully falls back to v2 context injection.

## Versioning

`TEKHTON_VERSION` in `tekhton.sh` uses **MAJOR.MINOR.PATCH**:
- **MAJOR** = initiative version (2 for V2, 3 for V3, etc.)
- **MINOR** = last completed milestone number within this initiative (resets to 0 each major)
- **PATCH** = hotfixes between milestones

Milestone numbering restarts with each major version. When a milestone is completed,
update the `TEKHTON_VERSION` line in `tekhton.sh` to bump MINOR to the milestone
number. Example: completing V3 Milestone 4 → `3.4.0`.

## Template Variables (Prompt Engine)

Available variables in prompt templates — set by the pipeline before rendering:

| Variable | Source |
|----------|--------|
| `PROJECT_DIR` | `pwd` at tekhton.sh startup |
| `PROJECT_NAME` | pipeline.conf |
| `TASK` | CLI argument |
| `CODER_ROLE_FILE` | pipeline.conf |
| `REVIEWER_ROLE_FILE` | pipeline.conf |
| `TESTER_ROLE_FILE` | pipeline.conf |
| `JR_CODER_ROLE_FILE` | pipeline.conf |
| `PROJECT_RULES_FILE` | pipeline.conf |
| `ARCHITECTURE_FILE` | pipeline.conf |
| `ARCHITECTURE_CONTENT` | File contents of ARCHITECTURE_FILE |
| `ANALYZE_CMD` | pipeline.conf |
| `TEST_CMD` | pipeline.conf |
| `REVIEW_CYCLE` | Current review iteration |
| `MAX_REVIEW_CYCLES` | pipeline.conf |
| `HUMAN_NOTES_BLOCK` | Extracted unchecked items from HUMAN_NOTES.md |
| `HUMAN_NOTES_CONTENT` | Raw filtered notes content |
| `INLINE_CONTRACT_PATTERN` | pipeline.conf (optional) |
| `BUILD_ERRORS_CONTENT` | Contents of BUILD_ERRORS.md |
| `ANALYZE_ISSUES` | Output of ANALYZE_CMD |
| `DESIGN_FILE` | pipeline.conf (optional — design doc path) |
| `ARCHITECTURE_LOG_FILE` | pipeline.conf (default: ARCHITECTURE_LOG.md) |
| `DRIFT_LOG_FILE` | pipeline.conf (default: DRIFT_LOG.md) |
| `HUMAN_ACTION_FILE` | pipeline.conf (default: HUMAN_ACTION_REQUIRED.md) |
| `DRIFT_OBSERVATION_THRESHOLD` | pipeline.conf (default: 8) |
| `DRIFT_RUNS_SINCE_AUDIT_THRESHOLD` | pipeline.conf (default: 5) |
| `ARCHITECT_ROLE_FILE` | pipeline.conf (default: .claude/agents/architect.md) |
| `ARCHITECT_MAX_TURNS` | pipeline.conf (default: 25) |
| `CLAUDE_ARCHITECT_MODEL` | pipeline.conf (default: CLAUDE_STANDARD_MODEL) |
| `ARCHITECTURE_LOG_CONTENT` | File contents of ARCHITECTURE_LOG_FILE |
| `DRIFT_LOG_CONTENT` | File contents of DRIFT_LOG_FILE |
| `DRIFT_OBSERVATION_COUNT` | Count of unresolved observations |
| `DEPENDENCY_CONSTRAINTS_CONTENT` | File contents of dependency constraints (optional) |
| `PLAN_TEMPLATE_CONTENT` | Contents of selected design doc template (planning) |
| `DESIGN_CONTENT` | Contents of DESIGN.md during generation (planning) |
| `PLAN_INCOMPLETE_SECTIONS` | List of incomplete sections for follow-up (planning) |
| `PLAN_INTERVIEW_MODEL` | Model for interview agent (default: opus) |
| `PLAN_INTERVIEW_MAX_TURNS` | Turn limit for interview (default: 50) |
| `PLAN_GENERATION_MODEL` | Model for generation agent (default: opus) |
| `PLAN_GENERATION_MAX_TURNS` | Turn limit for generation (default: 50) |
| `CONTEXT_BUDGET_PCT` | Max % of context window for prompt (default: 50) |
| `CONTEXT_BUDGET_ENABLED` | Toggle context budgeting (default: true) |
| `CHARS_PER_TOKEN` | Conservative char-to-token ratio (default: 4) |
| `CONTEXT_COMPILER_ENABLED` | Toggle task-scoped context assembly (default: false) |
| `AUTO_ADVANCE_ENABLED` | Require --auto-advance flag (default: false) |
| `AUTO_ADVANCE_LIMIT` | Max milestones per invocation (default: 3) |
| `AUTO_ADVANCE_CONFIRM` | Prompt between milestones (default: true) |
| `CLARIFICATION_ENABLED` | Allow agents to pause for questions (default: true) |
| `CLARIFICATIONS_CONTENT` | Human answers from CLARIFICATIONS.md |
| `REPLAN_ENABLED` | Allow mid-run replan triggers (default: true) |
| `CLEANUP_ENABLED` | Enable autonomous debt sweeps (default: false) |
| `CLEANUP_BATCH_SIZE` | Max items per sweep (default: 5) |
| `CLEANUP_MAX_TURNS` | Turn budget for cleanup agent (default: 15) |
| `CLEANUP_TRIGGER_THRESHOLD` | Min items before triggering (default: 5) |
| `REPLAN_MODEL` | Model for --replan (default: PLAN_GENERATION_MODEL) |
| `REPLAN_MAX_TURNS` | Turn limit for --replan (default: PLAN_GENERATION_MAX_TURNS) |
| `CODEBASE_SUMMARY` | Directory tree + git log for --replan |
| `SPECIALIST_*_ENABLED` | Toggle per specialist (default: false each) |
| `SPECIALIST_*_MODEL` | Model per specialist (default: CLAUDE_STANDARD_MODEL) |
| `SPECIALIST_UI_ENABLED` | Toggle UI/UX specialist (default: auto — enabled when UI_PROJECT_DETECTED) |
| `SPECIALIST_UI_MODEL` | Model for UI specialist (default: CLAUDE_STANDARD_MODEL) |
| `SPECIALIST_UI_MAX_TURNS` | Turn limit for UI specialist (default: 8) |
| `UI_PLATFORM` | Override auto-detected UI platform (default: auto) |
| `DESIGN_SYSTEM` | Detected design system name (detected at runtime) |
| `DESIGN_SYSTEM_CONFIG` | Path to design system config file (detected at runtime) |
| `COMPONENT_LIBRARY_DIR` | Path to reusable component directory (detected at runtime) |
| `UI_CODER_GUIDANCE` | Assembled UI guidance for coder prompt (computed at runtime) |
| `UI_SPECIALIST_CHECKLIST` | Platform-specific specialist checklist (computed at runtime) |
| `UI_TESTER_PATTERNS` | Platform-specific tester patterns (computed at runtime) |
| `SPECIALIST_*_MAX_TURNS` | Turn limit per specialist (default: 8) |
| `METRICS_ENABLED` | Enable run metrics collection (default: true) |
| `METRICS_MIN_RUNS` | Min runs before adaptive calibration (default: 5) |
| `METRICS_ADAPTIVE_TURNS` | Use history for turn calibration (default: true) |
| `MILESTONE_ACTIVITY_TIMEOUT_MULTIPLIER` | Multiplier for AGENT_ACTIVITY_TIMEOUT in milestone mode (default: 3) |
| `MILESTONE_TAG_ON_COMPLETE` | Create git tag on milestone completion (default: false) |
| `MILESTONE_ARCHIVE_FILE` | Path to milestone archive (default: MILESTONE_ARCHIVE.md) |
| `MILESTONE_SPLIT_ENABLED` | Enable pre-flight milestone splitting (default: true) |
| `MILESTONE_SPLIT_MODEL` | Model for splitting agent (default: CLAUDE_CODER_MODEL) |
| `MILESTONE_SPLIT_MAX_TURNS` | Turn limit for splitting agent (default: 15) |
| `MILESTONE_SPLIT_THRESHOLD_PCT` | Split when scout estimate exceeds cap by this % (default: 120) |
| `MILESTONE_AUTO_RETRY` | Auto-split and retry on null-run (default: true) |
| `MILESTONE_MAX_SPLIT_DEPTH` | Max recursive split depth (default: 3) |
| `MAX_TRANSIENT_RETRIES` | Max retries on transient errors per agent call (default: 3) |
| `TRANSIENT_RETRY_BASE_DELAY` | Initial backoff delay in seconds (default: 30) |
| `TRANSIENT_RETRY_MAX_DELAY` | Max backoff delay in seconds (default: 120) |
| `TRANSIENT_RETRY_ENABLED` | Toggle transient error retry (default: true) |
| `MAX_CONTINUATION_ATTEMPTS` | Max turn-exhaustion continuations per stage (default: 3) |
| `CONTINUATION_ENABLED` | Toggle turn-exhaustion continuation (default: true) |
| `COMPLETE_MODE_ENABLED` | Toggle --complete outer loop (default: true) |
| `MAX_PIPELINE_ATTEMPTS` | Max full pipeline cycles in --complete mode (default: 5) |
| `AUTONOMOUS_TIMEOUT` | Wall-clock timeout for --complete in seconds (default: 7200) |
| `MAX_AUTONOMOUS_AGENT_CALLS` | Max total agent invocations in --complete mode (default: 20) |
| `AUTONOMOUS_PROGRESS_CHECK` | Enable stuck-detection between loop iterations (default: true) |
| `HUMAN_MODE` | Set by `--human` flag (default: false) |
| `HUMAN_NOTES_TAG` | Optional tag filter for `--human` (BUG, FEAT, POLISH) |
| `MILESTONE_DAG_ENABLED` | Use manifest+files vs inline CLAUDE.md (default: true) |
| `MILESTONE_DIR` | Directory for milestone files (default: .claude/milestones) |
| `MILESTONE_MANIFEST` | Manifest filename within MILESTONE_DIR (default: MANIFEST.cfg) |
| `MILESTONE_WINDOW_PCT` | % of context budget allocated to milestones (default: 30) |
| `MILESTONE_WINDOW_MAX_CHARS` | Hard cap on milestone window chars (default: 20000) |
| `MILESTONE_AUTO_MIGRATE` | Auto-extract inline milestones on first run (default: true) |
| `REPO_MAP_ENABLED` | Enable tree-sitter repo map generation (default: false) |
| `REPO_MAP_TOKEN_BUDGET` | Max tokens for repo map output (default: 2048) |
| `REPO_MAP_CACHE_DIR` | Index cache directory (default: .claude/index) |
| `REPO_MAP_LANGUAGES` | Languages to index, or "auto" (default: auto) |
| `REPO_MAP_VENV_DIR` | Indexer virtualenv location (default: .claude/indexer-venv) |
| `REPO_MAP_CONTENT` | Generated repo map markdown (injected by lib/indexer.sh) |
| `REPO_MAP_SLICE` | Task-relevant subset of repo map (per-stage) |
| `REPO_MAP_HISTORY_ENABLED` | Track task→file associations (default: true) |
| `REPO_MAP_HISTORY_MAX_RECORDS` | Max history entries before pruning (default: 200) |
| `SERENA_ENABLED` | Enable Serena LSP via MCP (default: false) |
| `SERENA_PATH` | Serena installation directory (default: .claude/serena) |
| `SERENA_CONFIG_PATH` | Path to generated MCP config (auto-generated) |
| `SERENA_LANGUAGE_SERVERS` | LSP servers to use, or "auto" (default: auto) |
| `SERENA_STARTUP_TIMEOUT` | Seconds to wait for Serena startup (default: 30) |
| `SERENA_MAX_RETRIES` | Retry attempts for Serena health check (default: 2) |
| `CAUSAL_LOG_ENABLED` | Enable causal event log (default: true) |
| `CAUSAL_LOG_FILE` | Path to causal event log (default: .claude/logs/CAUSAL_LOG.jsonl) |
| `CAUSAL_LOG_RETENTION_RUNS` | Archived logs to retain (default: 50) |
| `CAUSAL_LOG_MAX_EVENTS` | Max events per run before eviction (default: 2000) |
| `INTAKE_HISTORY_BLOCK` | Historical verdict/rework data from causal log (injected by lib/prompts.sh) |
| `TEST_BASELINE_ENABLED` | Enable pre-existing test failure detection (default: true) |
| `TEST_BASELINE_PASS_ON_PREEXISTING` | Auto-pass acceptance when all failures are pre-existing (default: true) |
| `TEST_BASELINE_STUCK_THRESHOLD` | Consecutive identical acceptance failures before stuck detection (default: 2) |
| `TEST_BASELINE_PASS_ON_STUCK` | Auto-pass on stuck detection vs exit with diagnosis (default: false) |
| `FINAL_FIX_ENABLED` | Spawn fix agent when TEST_CMD fails in final checks (default: true) |
| `FINAL_FIX_MAX_ATTEMPTS` | Max fix attempts in final checks before giving up (default: 2) |
| `FINAL_FIX_MAX_TURNS` | Turn budget per fix attempt in final checks (default: CODER_MAX_TURNS/3) |
| `TESTER_FIX_ENABLED` | Auto-seed fix run when tester stage tests fail (default: false) |
| `TESTER_FIX_MAX_DEPTH` | Max recursive fix attempts in tester stage (default: 1) |
| `TESTER_FIX_OUTPUT_LIMIT` | Max chars of test output in tester fix task string (default: 4000) |
| `SECURITY_AGENT_ENABLED` | Toggle security review stage (default: true) |
| `SECURITY_MAX_TURNS` | Max turns for security agent (default: 15) |
| `SECURITY_BLOCK_SEVERITY` | Minimum severity to block pipeline (default: HIGH) |
| `INTAKE_AGENT_ENABLED` | Toggle intake/PM stage (default: true) |
| `INTAKE_MAX_TURNS` | Max turns for intake agent (default: 10) |
| `INTAKE_CLARITY_THRESHOLD` | Clarity score below which tasks are rejected (default: 40) |
| `DASHBOARD_ENABLED` | Toggle Watchtower dashboard (default: true) |
| `DASHBOARD_REFRESH_INTERVAL` | Seconds between data refreshes (default: 10) |
| `HEALTH_ENABLED` | Toggle health scoring (default: true) |
| `PIPELINE_ORDER` | Stage order: standard or test_first (default: standard) |
| `DRY_RUN_CACHE_TTL` | Dry-run cache validity in seconds (default: 3600) |
| `RUN_MEMORY_MAX_ENTRIES` | Max entries in structured run memory (default: 50) |
| `PREFLIGHT_ENABLED` | Toggle pre-flight environment checks (default: true) |
| `PREFLIGHT_AUTO_FIX` | Allow auto-remediation of safe issues in pre-flight (default: true) |
| `PREFLIGHT_FAIL_ON_WARN` | Treat pre-flight warnings as failures (default: false) |

## Testing

```bash
# Run self-tests
cd tekhton && bash tests/run_tests.sh

# Verify shellcheck
shellcheck tekhton.sh lib/*.sh stages/*.sh
```

## Adding Tekhton to a New Project

```bash
cd /path/to/your/project
/path/to/tekhton/tekhton.sh --init
# Edit .claude/pipeline.conf
# Edit .claude/agents/*.md
/path/to/tekhton/tekhton.sh "Your first task"
```

## Completed Initiatives

All prior initiatives are complete. V3 is feature complete as of v3.66.0
(M01–M66 all done). See design docs for full details and `MILESTONE_ARCHIVE.md`
for individual milestone records.

| Initiative | Version | Milestones | Design Doc |
|-----------|---------|-----------|------------|
| Planning Phase Quality Overhaul | 1.x | Multi-phase interview, depth-scored completeness, 12-section CLAUDE.md generation | — |
| Adaptive Pipeline 2.0 | 2.x | Context economics, milestone progression, clarification protocol, specialist reviews, run metrics | `DESIGN_v2.md` |
| Brownfield Intelligence (Smart Init) | 2.x | Shell-driven crawler, tech stack detection, agent-assisted synthesis, incremental rescan | — |
| Tekhton 3.0 — DAG, Indexing & Cost Reduction | 3.0–3.51 | 51 milestones: Milestone DAG, tree-sitter repo maps, Serena MCP, Watchtower, security agent, intake agent, express mode, TDD, browser planning, dry-run, rollback, health scoring, notes pipeline rewrite, pipeline acceleration & transparency | `DESIGN_v3.md` |
| Environment Intelligence | 3.52–3.56 | Onboarding flow fix, error pattern registry, auto-remediation engine, pre-flight validation, service readiness probing | `DESIGN_v3.md` |
| UI/UX Design Intelligence | 3.57–3.60 | Platform adapter framework, web adapter (Tailwind/MUI/shadcn/Chakra/Bootstrap), UI/UX specialist reviewer (auto-on for UI projects), mobile (Flutter/SwiftUI/Compose) and game engine (Phaser/PixiJS/Three.js/Babylon.js) adapters | `DESIGN_v3.md` |
| V3 Final Polish | 3.61–3.66 | Repo map cross-stage cache, tester timing instrumentation, test baseline hygiene & completion gate hardening, tester fix surgical mode, prompt tool awareness, Watchtower full-stage metrics | `DESIGN_v3.md` |

### Milestone Management

Milestones are managed as individual files in `.claude/milestones/`.
See `MANIFEST.cfg` for ordering, dependencies, and status. Completed milestones
are archived to `MILESTONE_ARCHIVE.md`.

## Next Initiative: Tekhton 4.0

V4 is in design (`DESIGN_v4.md`). Milestone numbering will restart with V4 and
the `.claude/milestones/` directory will be reset when V4 work begins.


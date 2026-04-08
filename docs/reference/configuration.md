# Configuration Reference

All configuration is in `.claude/pipeline.conf` in your project directory.
This file is sourced as bash, so values follow bash syntax.

## Core Settings

| Key | Default | Description |
|-----|---------|-------------|
| `PROJECT_NAME` | *(required)* | Your project's name |
| `PROJECT_DESCRIPTION` | `multi-agent development pipeline` | Brief project description |
| `PROJECT_RULES_FILE` | `CLAUDE.md` | Project rules and guidelines file |
| `DESIGN_FILE` | *(empty)* | Design document file path |
| `ARCHITECTURE_FILE` | *(empty)* | Architecture document file path |
| `GLOSSARY_FILE` | *(empty)* | Glossary file path |
| `PROJECT_STRUCTURE` | `single` | Project type: `single`, `mono`, or `multi` |

## Build & Test Commands

| Key | Default | Description |
|-----|---------|-------------|
| `TEST_CMD` | `true` | Test command. Defaults to no-op; set this if your project has tests. |
| `BUILD_CHECK_CMD` | *(empty)* | Build/compile command. Leave empty if no build step. |
| `ANALYZE_CMD` | *(empty)* | Linter/static analysis command. |
| `ANALYZE_ERROR_PATTERN` | `error` | Pattern to match in analyze output for errors |
| `BUILD_ERROR_PATTERN` | `ERROR` | Pattern to match in build output for errors |
| `REQUIRED_TOOLS` | `git claude` | Space-separated list of required CLI tools |

## Pipeline Order

| Key | Default | Description |
|-----|---------|-------------|
| `PIPELINE_ORDER` | `standard` | Stage execution order: `standard` or `test_first` (TDD mode) |
| `TDD_PREFLIGHT_FILE` | `TESTER_PREFLIGHT.md` | Output file for TDD write-failing tester |
| `CODER_TDD_TURN_MULTIPLIER` | `1.2` | Coder turn multiplier in `test_first` mode |

## Agent Models

| Key | Default | Description |
|-----|---------|-------------|
| `CLAUDE_CODER_MODEL` | `claude-sonnet-4-6` | Model for the coder agent |
| `CLAUDE_JR_CODER_MODEL` | `claude-sonnet-4-6` | Model for the junior coder |
| `CLAUDE_REVIEWER_MODEL` | `claude-sonnet-4-6` | Model for the reviewer |
| `CLAUDE_TESTER_MODEL` | `claude-sonnet-4-6` | Model for the tester |
| `CLAUDE_SCOUT_MODEL` | *(same as jr coder)* | Model for the scout agent |
| `CLAUDE_ARCHITECT_MODEL` | *(same as standard)* | Model for the architect |
| `CLAUDE_SECURITY_MODEL` | *(same as standard)* | Model for the security agent |
| `CLAUDE_INTAKE_MODEL` | `sonnet` | Model for the intake/PM agent |

## Turn Limits

| Key | Default | Description |
|-----|---------|-------------|
| `CODER_MAX_TURNS` | `50` | Max turns for the coder agent |
| `JR_CODER_MAX_TURNS` | `25` | Max turns for the junior coder |
| `REVIEWER_MAX_TURNS` | `15` | Max turns for the reviewer |
| `TESTER_MAX_TURNS` | `30` | Max turns for the tester |
| `SCOUT_MAX_TURNS` | `20` | Max turns for the scout |
| `ARCHITECT_MAX_TURNS` | `25` | Max turns for the architect |
| `MAX_REVIEW_CYCLES` | `3` | Max review-rework iterations |

### Dynamic Turn Limits

| Key | Default | Description |
|-----|---------|-------------|
| `DYNAMIC_TURNS_ENABLED` | `true` | Allow scout to adjust turn limits based on task complexity |
| `CODER_MIN_TURNS` | `15` | Minimum turns for coder (floor) |
| `CODER_MAX_TURNS_CAP` | `200` | Maximum turns for coder (ceiling) |
| `REVIEWER_MIN_TURNS` | `10` | Minimum turns for reviewer |
| `REVIEWER_MAX_TURNS_CAP` | `30` | Maximum turns for reviewer |
| `TESTER_MIN_TURNS` | `10` | Minimum turns for tester |
| `TESTER_MAX_TURNS_CAP` | `100` | Maximum turns for tester |

### Milestone Mode Overrides

When running in `--milestone` mode, these values override the base turn limits:

| Key | Default | Description |
|-----|---------|-------------|
| `MILESTONE_CODER_MAX_TURNS` | `CODER_MAX_TURNS * 2` | Coder turns in milestone mode |
| `MILESTONE_JR_CODER_MAX_TURNS` | `JR_CODER_MAX_TURNS * 2` | Jr coder turns in milestone mode |
| `MILESTONE_REVIEWER_MAX_TURNS` | `REVIEWER_MAX_TURNS + 5` | Reviewer turns in milestone mode |
| `MILESTONE_TESTER_MAX_TURNS` | `TESTER_MAX_TURNS * 2` | Tester turns in milestone mode |
| `MILESTONE_ARCHITECT_MAX_TURNS` | `ARCHITECT_MAX_TURNS * 2` | Architect turns in milestone mode |
| `MILESTONE_SECURITY_MAX_TURNS` | `SECURITY_MAX_TURNS * 2` | Security turns in milestone mode |
| `MILESTONE_MAX_REVIEW_CYCLES` | `MAX_REVIEW_CYCLES * 2` | Review cycles in milestone mode |
| `MILESTONE_TESTER_MODEL` | *(same as standard)* | Tester model in milestone mode |
| `MILESTONE_ACTIVITY_TIMEOUT_MULTIPLIER` | `3` | Multiplier for activity timeout |

## Agent Role Files

| Key | Default | Description |
|-----|---------|-------------|
| `CODER_ROLE_FILE` | `.claude/agents/coder.md` | Coder agent role definition |
| `REVIEWER_ROLE_FILE` | `.claude/agents/reviewer.md` | Reviewer role definition |
| `TESTER_ROLE_FILE` | `.claude/agents/tester.md` | Tester role definition |
| `JR_CODER_ROLE_FILE` | `.claude/agents/jr-coder.md` | Junior coder role definition |
| `ARCHITECT_ROLE_FILE` | `.claude/agents/architect.md` | Architect role definition |
| `SECURITY_ROLE_FILE` | `.claude/agents/security.md` | Security agent role definition |
| `INTAKE_ROLE_FILE` | `.claude/agents/intake.md` | Intake/PM agent role definition |

## Security Agent

| Key | Default | Description |
|-----|---------|-------------|
| `SECURITY_AGENT_ENABLED` | `true` | Toggle the security review stage |
| `SECURITY_MAX_TURNS` | `15` | Max turns for the security agent |
| `SECURITY_MIN_TURNS` | `8` | Min turns for security agent |
| `SECURITY_MAX_TURNS_CAP` | `30` | Maximum turn cap for security |
| `SECURITY_MAX_REWORK_CYCLES` | `2` | Max rework cycles for security fixes |
| `SECURITY_BLOCK_SEVERITY` | `HIGH` | Minimum severity to block pipeline (`CRITICAL`, `HIGH`, `MEDIUM`, `LOW`) |
| `SECURITY_UNFIXABLE_POLICY` | `escalate` | What to do with unfixable issues: `escalate`, `warn`, `pass` |
| `SECURITY_OFFLINE_MODE` | `auto` | Offline vulnerability checking: `auto`, `true`, `false` |
| `SECURITY_ONLINE_SOURCES` | *(empty)* | Online vulnerability database sources |
| `SECURITY_NOTES_FILE` | `SECURITY_NOTES.md` | Security notes file |
| `SECURITY_REPORT_FILE` | `SECURITY_REPORT.md` | Security report output |
| `SECURITY_WAIVER_FILE` | *(empty)* | Security waiver file for accepted risks |

## Intake Agent (PM Gate)

| Key | Default | Description |
|-----|---------|-------------|
| `INTAKE_AGENT_ENABLED` | `true` | Toggle the intake/PM stage |
| `INTAKE_MAX_TURNS` | `10` | Max turns for the intake agent |
| `INTAKE_CLARITY_THRESHOLD` | `40` | Clarity score below which tasks are rejected (0-100) |
| `INTAKE_TWEAK_THRESHOLD` | `70` | Score below which tweaks are recommended (0-100) |
| `INTAKE_CONFIRM_TWEAKS` | `false` | Require human confirmation before applying tweaks |
| `INTAKE_AUTO_SPLIT` | `false` | Auto-split overly broad tasks |
| `INTAKE_REPORT_FILE` | `INTAKE_REPORT.md` | Intake report output |

## Context Budget

| Key | Default | Description |
|-----|---------|-------------|
| `CONTEXT_BUDGET_PCT` | `50` | Max % of the context window for prompts |
| `CONTEXT_BUDGET_ENABLED` | `true` | Toggle context budget enforcement |
| `CONTEXT_COMPILER_ENABLED` | `false` | Toggle task-scoped context assembly |
| `CHARS_PER_TOKEN` | `4` | Character-to-token ratio for budget calculations |

## Milestones

| Key | Default | Description |
|-----|---------|-------------|
| `MILESTONE_DAG_ENABLED` | `true` | Use file-based milestones (DAG) vs inline in CLAUDE.md |
| `MILESTONE_DIR` | `.claude/milestones` | Directory for milestone files |
| `MILESTONE_MANIFEST` | `MANIFEST.cfg` | Manifest filename within milestone directory |
| `MILESTONE_AUTO_MIGRATE` | `true` | Auto-extract inline milestones to files on first run |
| `MILESTONE_WINDOW_PCT` | `30` | % of context budget allocated to milestone content |
| `MILESTONE_WINDOW_MAX_CHARS` | `20000` | Hard cap on milestone content in prompts |
| `MILESTONE_TAG_ON_COMPLETE` | `false` | Create a git tag on milestone completion |
| `MILESTONE_ARCHIVE_FILE` | `MILESTONE_ARCHIVE.md` | Where completed milestones are archived |

### Milestone Splitting

| Key | Default | Description |
|-----|---------|-------------|
| `MILESTONE_SPLIT_ENABLED` | `true` | Enable pre-flight milestone splitting |
| `MILESTONE_SPLIT_MODEL` | *(same as coder)* | Model for the splitting agent |
| `MILESTONE_SPLIT_MAX_TURNS` | `15` | Max turns for the splitting agent |
| `MILESTONE_SPLIT_THRESHOLD_PCT` | `120` | Split when estimate exceeds cap by this % |
| `MILESTONE_AUTO_RETRY` | `true` | Auto-split and retry on null-run |
| `MILESTONE_MAX_SPLIT_DEPTH` | `6` | Max recursive split depth |

## Auto-Advance

| Key | Default | Description |
|-----|---------|-------------|
| `AUTO_ADVANCE_ENABLED` | `false` | Require `--auto-advance` flag to enable |
| `AUTO_ADVANCE_LIMIT` | `3` | Max milestones per invocation |
| `AUTO_ADVANCE_CONFIRM` | `true` | Prompt for confirmation between milestones |

## Orchestration (`--complete` Mode)

| Key | Default | Description |
|-----|---------|-------------|
| `COMPLETE_MODE_ENABLED` | `true` | Toggle `--complete` outer loop |
| `MAX_PIPELINE_ATTEMPTS` | `5` | Max full pipeline cycles |
| `AUTONOMOUS_TIMEOUT` | `7200` | Wall-clock timeout in seconds (default: 2 hours) |
| `MAX_AUTONOMOUS_AGENT_CALLS` | `200` | Safety valve: max total agent invocations |
| `AUTONOMOUS_PROGRESS_CHECK` | `true` | Enable stuck-detection between iterations |

## Error Handling

### Turn Exhaustion Continuation

| Key | Default | Description |
|-----|---------|-------------|
| `CONTINUATION_ENABLED` | `true` | Auto-continue when agent runs out of turns |
| `MAX_CONTINUATION_ATTEMPTS` | `3` | Max continuations per stage |

### Transient Error Retry

| Key | Default | Description |
|-----|---------|-------------|
| `TRANSIENT_RETRY_ENABLED` | `true` | Retry on transient errors (network, API) |
| `MAX_TRANSIENT_RETRIES` | `3` | Max retries per agent call |
| `TRANSIENT_RETRY_BASE_DELAY` | `30` | Initial backoff delay in seconds |
| `TRANSIENT_RETRY_MAX_DELAY` | `120` | Max backoff delay in seconds |

## Drift Detection

| Key | Default | Description |
|-----|---------|-------------|
| `ARCHITECTURE_LOG_FILE` | `ARCHITECTURE_LOG.md` | Architecture decision log |
| `DRIFT_LOG_FILE` | `DRIFT_LOG.md` | Drift observations log |
| `HUMAN_ACTION_FILE` | `HUMAN_ACTION_REQUIRED.md` | Items needing human attention |
| `NON_BLOCKING_LOG_FILE` | `NON_BLOCKING_LOG.md` | Non-blocking notes log |
| `DRIFT_OBSERVATION_THRESHOLD` | `8` | Observation count that triggers an audit |
| `DRIFT_RUNS_SINCE_AUDIT_THRESHOLD` | `5` | Runs since last audit before triggering |
| `NON_BLOCKING_INJECTION_THRESHOLD` | `8` | Non-blocking items before injection |

## Cleanup (Debt Sweep)

| Key | Default | Description |
|-----|---------|-------------|
| `CLEANUP_ENABLED` | `false` | Toggle autonomous cleanup stage |
| `CLEANUP_BATCH_SIZE` | `5` | Max items per cleanup batch |
| `CLEANUP_MAX_TURNS` | `15` | Max turns for cleanup agent |
| `CLEANUP_TRIGGER_THRESHOLD` | `5` | Min items before triggering cleanup |

## Clarification & Replan

| Key | Default | Description |
|-----|---------|-------------|
| `CLARIFICATION_ENABLED` | `true` | Allow agents to pause for blocking questions |
| `REPLAN_ENABLED` | `true` | Allow mid-run replan triggers |
| `REPLAN_MODEL` | *(same as plan model)* | Model for `--replan` |
| `REPLAN_MAX_TURNS` | *(same as plan turns)* | Turn limit for `--replan` |

## Metrics

| Key | Default | Description |
|-----|---------|-------------|
| `METRICS_ENABLED` | `true` | Toggle run metrics collection |
| `METRICS_MIN_RUNS` | `5` | Min runs before adaptive turn calibration kicks in |
| `METRICS_ADAPTIVE_TURNS` | `true` | Use run history for turn calibration |

## Quota Management

| Key | Default | Description |
|-----|---------|-------------|
| `USAGE_THRESHOLD_PCT` | `0` | Pause pipeline at this API usage % (0 = disabled) |
| `QUOTA_RETRY_INTERVAL` | `300` | Seconds between quota refresh checks |
| `QUOTA_RESERVE_PCT` | `10` | Proactive pause threshold |
| `CLAUDE_QUOTA_CHECK_CMD` | *(empty)* | Optional external quota check script |
| `QUOTA_MAX_PAUSE_DURATION` | `14400` | Max seconds to wait in quota pause (4 hours) |

## Health Scoring

| Key | Default | Description |
|-----|---------|-------------|
| `HEALTH_ENABLED` | `true` | Toggle health scoring |
| `HEALTH_REASSESS_ON_COMPLETE` | `false` | Re-assess health after milestone completion |
| `HEALTH_RUN_TESTS` | `false` | Run tests as part of health assessment |
| `HEALTH_SAMPLE_SIZE` | `20` | Sample size for quality assessment |
| `HEALTH_WEIGHT_TESTS` | `30` | Weight for test coverage score (%) |
| `HEALTH_WEIGHT_QUALITY` | `25` | Weight for code quality score (%) |
| `HEALTH_WEIGHT_DEPS` | `15` | Weight for dependency health score (%) |
| `HEALTH_WEIGHT_DOCS` | `15` | Weight for documentation score (%) |
| `HEALTH_WEIGHT_HYGIENE` | `15` | Weight for code hygiene score (%) |
| `HEALTH_SHOW_BELT` | `true` | Show belt rating in health output |
| `HEALTH_BASELINE_FILE` | `.claude/HEALTH_BASELINE.json` | Health baseline file |
| `HEALTH_REPORT_FILE` | `HEALTH_REPORT.md` | Health report output |

## Watchtower Dashboard

| Key | Default | Description |
|-----|---------|-------------|
| `DASHBOARD_ENABLED` | `true` | Toggle the Watchtower dashboard |
| `DASHBOARD_VERBOSITY` | `normal` | Verbosity: `minimal`, `normal`, `verbose` |
| `DASHBOARD_HISTORY_DEPTH` | `50` | Past runs to display |
| `DASHBOARD_REFRESH_INTERVAL` | `10` | Seconds between data refreshes during a run |
| `DASHBOARD_DIR` | `.claude/dashboard` | Dashboard directory |
| `DASHBOARD_MAX_TIMELINE_EVENTS` | `500` | Max timeline events to track |

## Repo Map (Indexer)

| Key | Default | Description |
|-----|---------|-------------|
| `REPO_MAP_ENABLED` | `false` | Toggle tree-sitter repo map generation |
| `REPO_MAP_TOKEN_BUDGET` | `2048` | Max tokens for repo map output |
| `REPO_MAP_CACHE_DIR` | `.claude/index` | Index cache directory |
| `REPO_MAP_LANGUAGES` | `auto` | Languages to index (or `auto` for detection) |
| `REPO_MAP_VENV_DIR` | `.claude/indexer-venv` | Indexer virtualenv location |
| `REPO_MAP_HISTORY_ENABLED` | `true` | Track task-to-file associations |
| `REPO_MAP_HISTORY_MAX_RECORDS` | `200` | Max history entries before pruning |

## Serena LSP (MCP)

| Key | Default | Description |
|-----|---------|-------------|
| `SERENA_ENABLED` | `false` | Toggle Serena LSP via MCP |
| `SERENA_PATH` | `.claude/serena` | Serena installation directory |
| `SERENA_CONFIG_PATH` | *(empty)* | Path to MCP config (auto-generated) |
| `SERENA_LANGUAGE_SERVERS` | `auto` | LSP servers to use |
| `SERENA_STARTUP_TIMEOUT` | `30` | Seconds to wait for Serena startup |
| `SERENA_MAX_RETRIES` | `2` | Retry attempts for Serena health check |

## Specialist Reviewers

| Key | Default | Description |
|-----|---------|-------------|
| `SPECIALIST_SKIP_IRRELEVANT` | `true` | Skip specialists when the diff doesn't touch relevant files |
| `REVIEW_SKIP_THRESHOLD` | `0` | Lines-changed below which review is skipped (`0` = always review) |
| `SPECIALIST_SECURITY_ENABLED` | `false` | Toggle security specialist review |
| `SPECIALIST_SECURITY_MODEL` | *(same as standard)* | Model for security specialist |
| `SPECIALIST_SECURITY_MAX_TURNS` | `8` | Max turns for security specialist |
| `SPECIALIST_PERFORMANCE_ENABLED` | `false` | Toggle performance specialist review |
| `SPECIALIST_PERFORMANCE_MODEL` | *(same as standard)* | Model for performance specialist |
| `SPECIALIST_PERFORMANCE_MAX_TURNS` | `8` | Max turns for performance specialist |
| `SPECIALIST_API_ENABLED` | `false` | Toggle API specialist review |
| `SPECIALIST_API_MODEL` | *(same as standard)* | Model for API specialist |
| `SPECIALIST_API_MAX_TURNS` | `8` | Max turns for API specialist |
| `SPECIALIST_UI_ENABLED` | `auto` | Toggle UI/UX specialist review (`auto` enables when a UI platform is detected) |
| `SPECIALIST_UI_MODEL` | *(same as standard)* | Model for UI/UX specialist |
| `SPECIALIST_UI_MAX_TURNS` | `8` | Max turns for UI/UX specialist |

## UI Platform Adapters

When a UI project is detected, Tekhton selects a platform adapter that supplies
detection logic, coder guidance, specialist checklists, and tester patterns. Each
adapter lives in `${TEKHTON_HOME}/platforms/<name>/`.

| Key | Default | Description |
|-----|---------|-------------|
| `UI_PLATFORM` | `auto` | Platform: `auto`, `web`, `mobile_flutter`, `mobile_native_ios`, `mobile_native_android`, `game_web` |

## Pre-flight Validation

Pre-flight runs after config loading but BEFORE any agent invocation. It validates
toolchain availability, dependency freshness, and service readiness, then
auto-remediates safe issues via the M54 engine.

| Key | Default | Description |
|-----|---------|-------------|
| `PREFLIGHT_ENABLED` | `true` | Toggle pre-flight environment checks |
| `PREFLIGHT_AUTO_FIX` | `true` | Allow auto-remediation of safe issues during pre-flight |
| `PREFLIGHT_FAIL_ON_WARN` | `false` | Treat warnings as failures (strict mode) |
| `PREFLIGHT_FIX_ENABLED` | `true` | Try a Jr Coder fix before falling through to a full pipeline retry |
| `PREFLIGHT_FIX_MAX_ATTEMPTS` | `2` | Max fix attempts before giving up |
| `PREFLIGHT_FIX_MODEL` | *(same as jr coder)* | Model for the pre-flight fix agent |
| `PREFLIGHT_FIX_MAX_TURNS` | *(same as jr coder turns)* | Turn budget per fix attempt |

### Auto-Remediation Engine

The error pattern registry classifies build/test failures and runs `safe`-rated
remediation commands automatically. These keys are environment overrides — the
defaults are conservative.

| Key | Default | Description |
|-----|---------|-------------|
| `REMEDIATION_MAX_ATTEMPTS` | `2` | Max remediation attempts per build gate run |
| `REMEDIATION_TIMEOUT` | `60` | Seconds before a single remediation command times out |

## Tester & Final Fix

| Key | Default | Description |
|-----|---------|-------------|
| `FINAL_FIX_ENABLED` | `true` | Spawn a fix agent when `TEST_CMD` fails in final checks |
| `FINAL_FIX_MAX_ATTEMPTS` | `2` | Max fix attempts in final checks |
| `FINAL_FIX_MAX_TURNS` | `CODER_MAX_TURNS / 3` | Turn budget per final-fix attempt |
| `TESTER_FIX_ENABLED` | `false` | Auto-fix on test failure inside the tester stage (M64 surgical mode) |
| `TESTER_FIX_MAX_DEPTH` | `1` | Max inline fix attempts per tester stage |
| `TESTER_FIX_MAX_TURNS` | `CODER_MAX_TURNS / 3` | Turn budget per inline fix |
| `TESTER_FIX_OUTPUT_LIMIT` | `4000` | Max chars of test output passed to the fix agent |
| `COMPLETION_GATE_TEST_ENABLED` | `true` | Run `TEST_CMD` inside the completion gate (M63) instead of trusting the coder's "COMPLETE" claim |

## AI Artifact Detection

| Key | Default | Description |
|-----|---------|-------------|
| `ARTIFACT_DETECTION_ENABLED` | `true` | Toggle AI artifact detection during init |
| `ARTIFACT_HANDLING_DEFAULT` | *(empty)* | Handling mode: empty=interactive, `archive`, `tidy`, `ignore` |
| `ARTIFACT_ARCHIVE_DIR` | `.claude/archived-ai-config` | Archive directory for AI artifacts |
| `ARTIFACT_MERGE_MODEL` | `claude-sonnet-4-6` | Model for artifact merge agent |
| `ARTIFACT_MERGE_MAX_TURNS` | `10` | Max turns for artifact merge |

## Causal Event Log

| Key | Default | Description |
|-----|---------|-------------|
| `CAUSAL_LOG_ENABLED` | `true` | Toggle causal event log |
| `CAUSAL_LOG_FILE` | `.claude/logs/CAUSAL_LOG.jsonl` | Event log file path |
| `CAUSAL_LOG_RETENTION_RUNS` | `50` | Archived logs to retain |
| `CAUSAL_LOG_MAX_EVENTS` | `2000` | Max events per run before eviction |

## Test Baseline

| Key | Default | Description |
|-----|---------|-------------|
| `TEST_BASELINE_ENABLED` | `true` | Toggle pre-existing failure detection |
| `TEST_BASELINE_PASS_ON_PREEXISTING` | `true` | Auto-pass when all failures are pre-existing |
| `TEST_BASELINE_STUCK_THRESHOLD` | `2` | Consecutive identical failures before stuck detection |
| `TEST_BASELINE_PASS_ON_STUCK` | `false` | Auto-pass on stuck vs exit with diagnosis |

## Structured Run Memory

| Key | Default | Description |
|-----|---------|-------------|
| `RUN_MEMORY_MAX_ENTRIES` | `50` | Max entries in the run memory store |

## Dry-Run Preview

| Key | Default | Description |
|-----|---------|-------------|
| `DRY_RUN_CACHE_TTL` | `3600` | Cache validity in seconds (default: 1 hour) |
| `DRY_RUN_CACHE_DIR` | `.claude/dry_run_cache` | Cache directory for preview results |

## Brownfield Detection

| Key | Default | Description |
|-----|---------|-------------|
| `DETECT_WORKSPACES_ENABLED` | `true` | Enable workspace detection |
| `DETECT_SERVICES_ENABLED` | `true` | Enable service detection |
| `DETECT_CI_ENABLED` | `true` | Enable CI/CD detection |
| `DETECT_INFRASTRUCTURE_ENABLED` | `true` | Enable infrastructure detection |
| `DETECT_TEST_FRAMEWORKS_ENABLED` | `true` | Enable test framework detection |
| `DOC_QUALITY_ASSESSMENT_ENABLED` | `true` | Enable doc quality assessment |
| `WORKSPACE_ENUM_LIMIT` | `50` | Max sub-projects to enumerate |

## Other Settings

| Key | Default | Description |
|-----|---------|-------------|
| `PIPELINE_STATE_FILE` | `.claude/PIPELINE_STATE.md` | Pipeline state persistence file |
| `LOG_DIR` | `.claude/logs` | Log directory |
| `AGENT_NULL_RUN_THRESHOLD` | `2` | Turns below this + non-zero exit = null run |
| `AGENT_SKIP_PERMISSIONS` | `false` | Skip permission checks for agents |
| `AUTO_COMMIT` | `false` | Auto-commit mode (auto-enabled in milestone mode) |
| `INLINE_CONTRACT_PATTERN` | *(empty)* | Pattern for inline system contracts |
| `INLINE_CONTRACT_SEARCH_CMD` | *(empty)* | Command to search for contracts |
| `SEED_CONTRACTS_ENABLED` | `false` | Toggle seed contracts feature |
| `SEED_CONTRACTS_MAX_TURNS` | `20` | Max turns for seed contracts agent |
| `NOTES_FILTER_CATEGORIES` | `BUG\|FEAT\|POLISH` | Categories for human notes |
| `DEPENDENCY_CONSTRAINTS_FILE` | *(empty)* | Dependency constraint manifest |

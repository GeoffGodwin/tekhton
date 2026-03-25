#!/usr/bin/env bash
# =============================================================================
# config_defaults.sh — Default values and hard upper-bound clamps for pipeline config
#
# Sourced by config.sh at the end of load_config(), AFTER _parse_config_file()
# has run. Project-supplied values take precedence — these are fallback defaults.
# =============================================================================
set -euo pipefail

# --- Express mode defaults ---
: "${TEKHTON_EXPRESS_ENABLED:=true}"     # Auto-detect config when no pipeline.conf
: "${EXPRESS_PERSIST_CONFIG:=true}"      # Write pipeline.conf on successful completion
: "${EXPRESS_PERSIST_ROLES:=false}"      # Copy role templates to project on completion

# --- Context budget defaults (set early — used by planning + execution) ---
: "${CONTEXT_BUDGET_PCT:=50}"            # Max % of context window for prompt
: "${CHARS_PER_TOKEN:=4}"                # Conservative char-to-token ratio
: "${CONTEXT_BUDGET_ENABLED:=true}"      # Toggle context budgeting
: "${CONTEXT_COMPILER_ENABLED:=false}"   # Toggle task-scoped context assembly

# --- Execution pipeline defaults (derivable from CLAUDE_STANDARD_MODEL) ---
: "${REQUIRED_TOOLS:=git claude}"
: "${CLAUDE_CODER_MODEL:=${CLAUDE_STANDARD_MODEL:-claude-sonnet-4-6}}"
: "${CLAUDE_JR_CODER_MODEL:=${CLAUDE_STANDARD_MODEL:-claude-sonnet-4-6}}"
: "${CLAUDE_REVIEWER_MODEL:=${CLAUDE_STANDARD_MODEL:-claude-sonnet-4-6}}"
: "${CLAUDE_TESTER_MODEL:=${CLAUDE_STANDARD_MODEL:-claude-sonnet-4-6}}"
: "${CODER_MAX_TURNS:=50}"
: "${JR_CODER_MAX_TURNS:=25}"
: "${REVIEWER_MAX_TURNS:=15}"
: "${TESTER_MAX_TURNS:=30}"
: "${MAX_REVIEW_CYCLES:=3}"
# Defaults to `true` (no-op) — intentional for projects without a test suite.
# Projects with tests MUST set TEST_CMD in pipeline.conf.
: "${TEST_CMD:=true}"
: "${PIPELINE_STATE_FILE:=.claude/PIPELINE_STATE.md}"
: "${LOG_DIR:=.claude/logs}"
: "${CODER_ROLE_FILE:=.claude/agents/coder.md}"
: "${REVIEWER_ROLE_FILE:=.claude/agents/reviewer.md}"
: "${TESTER_ROLE_FILE:=.claude/agents/tester.md}"
: "${JR_CODER_ROLE_FILE:=.claude/agents/jr-coder.md}"
: "${PROJECT_RULES_FILE:=CLAUDE.md}"

# --- Optional keys ---
: "${PROJECT_DESCRIPTION:=multi-agent development pipeline}"
: "${SCOUT_MAX_TURNS:=20}"
: "${CLAUDE_SCOUT_MODEL:=${CLAUDE_JR_CODER_MODEL}}"
: "${SEED_CONTRACTS_MAX_TURNS:=20}"
: "${BUILD_CHECK_CMD:=}"
: "${ANALYZE_ERROR_PATTERN:=error}"
: "${BUILD_ERROR_PATTERN:=ERROR}"
: "${ARCHITECTURE_FILE:=}"
: "${GLOSSARY_FILE:=}"
: "${NOTES_FILTER_CATEGORIES:=BUG|FEAT|POLISH}"
: "${INLINE_CONTRACT_PATTERN:=}"
: "${INLINE_CONTRACT_SEARCH_CMD:=}"
: "${SEED_CONTRACTS_ENABLED:=false}"
: "${DESIGN_FILE:=}"

# --- Drift detection defaults ---
: "${ARCHITECTURE_LOG_FILE:=ARCHITECTURE_LOG.md}"
: "${DRIFT_LOG_FILE:=DRIFT_LOG.md}"
: "${HUMAN_ACTION_FILE:=HUMAN_ACTION_REQUIRED.md}"
: "${DRIFT_OBSERVATION_THRESHOLD:=8}"
: "${DRIFT_RUNS_SINCE_AUDIT_THRESHOLD:=5}"
: "${NON_BLOCKING_LOG_FILE:=NON_BLOCKING_LOG.md}"
: "${NON_BLOCKING_INJECTION_THRESHOLD:=8}"

# --- Architect agent defaults ---
: "${ARCHITECT_ROLE_FILE:=.claude/agents/architect.md}"
: "${ARCHITECT_MAX_TURNS:=25}"
: "${MILESTONE_ARCHITECT_MAX_TURNS:=$(( ARCHITECT_MAX_TURNS * 2 ))}"
: "${CLAUDE_ARCHITECT_MODEL:=${CLAUDE_STANDARD_MODEL}}"
: "${DEPENDENCY_CONSTRAINTS_FILE:=}"

# --- Agent exit detection defaults ---
: "${AGENT_NULL_RUN_THRESHOLD:=2}"       # Turns ≤ this + non-zero exit = null run

# --- Agent permission defaults ---
: "${AGENT_SKIP_PERMISSIONS:=false}"

# --- Dynamic turn limit defaults ---
: "${DYNAMIC_TURNS_ENABLED:=true}"
: "${CODER_MIN_TURNS:=15}"
: "${CODER_MAX_TURNS_CAP:=200}"
: "${REVIEWER_MIN_TURNS:=10}"
: "${REVIEWER_MAX_TURNS_CAP:=30}"
: "${TESTER_MIN_TURNS:=10}"
: "${TESTER_MAX_TURNS_CAP:=100}"

# --- Clarification and replan defaults ---
: "${CLARIFICATION_ENABLED:=true}"
: "${REPLAN_ENABLED:=true}"

# --- Brownfield replan defaults (--replan command) ---
: "${REPLAN_MODEL:=${PLAN_GENERATION_MODEL:-${CLAUDE_PLAN_MODEL:-opus}}}"
: "${REPLAN_MAX_TURNS:=${PLAN_GENERATION_MAX_TURNS:-50}}"

# --- Auto-advance defaults ---
: "${AUTO_ADVANCE_ENABLED:=false}"
: "${AUTO_ADVANCE_LIMIT:=3}"
: "${AUTO_ADVANCE_CONFIRM:=true}"

# --- Milestone commit signatures ---
: "${MILESTONE_TAG_ON_COMPLETE:=false}"
: "${MILESTONE_ARCHIVE_FILE:=MILESTONE_ARCHIVE.md}"

# --- Milestone DAG (file-based milestones with dependency tracking) ---
: "${MILESTONE_DAG_ENABLED:=true}"
: "${MILESTONE_DIR:=.claude/milestones}"
: "${MILESTONE_MANIFEST:=MANIFEST.cfg}"
: "${MILESTONE_AUTO_MIGRATE:=true}"
: "${MILESTONE_WINDOW_PCT:=30}"
: "${MILESTONE_WINDOW_MAX_CHARS:=20000}"

# --- Repo map / indexer defaults (tree-sitter based code intelligence) ---
: "${REPO_MAP_ENABLED:=false}"
: "${REPO_MAP_TOKEN_BUDGET:=2048}"
: "${REPO_MAP_CACHE_DIR:=.claude/index}"
: "${REPO_MAP_LANGUAGES:=auto}"
: "${REPO_MAP_VENV_DIR:=.claude/indexer-venv}"
: "${REPO_MAP_HISTORY_ENABLED:=true}"
: "${REPO_MAP_HISTORY_MAX_RECORDS:=200}"

# --- Serena LSP / MCP defaults (optional, future Milestone 6) ---
: "${SERENA_ENABLED:=false}"
: "${SERENA_PATH:=.claude/serena}"
: "${SERENA_CONFIG_PATH:=}"
: "${SERENA_LANGUAGE_SERVERS:=auto}"
: "${SERENA_STARTUP_TIMEOUT:=30}"
: "${SERENA_MAX_RETRIES:=2}"

# --- Milestone pre-flight sizing and auto-split ---
: "${MILESTONE_SPLIT_ENABLED:=true}"
: "${MILESTONE_SPLIT_MODEL:=${CLAUDE_CODER_MODEL}}"
: "${MILESTONE_SPLIT_MAX_TURNS:=15}"
: "${MILESTONE_SPLIT_THRESHOLD_PCT:=120}"
: "${MILESTONE_AUTO_RETRY:=true}"
: "${MILESTONE_MAX_SPLIT_DEPTH:=6}"

# --- Cleanup (autonomous debt sweep) defaults ---
: "${CLEANUP_ENABLED:=false}"
: "${CLEANUP_BATCH_SIZE:=5}"
: "${CLEANUP_MAX_TURNS:=15}"
: "${CLEANUP_TRIGGER_THRESHOLD:=5}"

# --- Turn exhaustion continuation defaults ---
: "${CONTINUATION_ENABLED:=true}"
: "${MAX_CONTINUATION_ATTEMPTS:=3}"

# --- Transient error retry defaults ---
: "${TRANSIENT_RETRY_ENABLED:=true}"
: "${MAX_TRANSIENT_RETRIES:=3}"
: "${TRANSIENT_RETRY_BASE_DELAY:=30}"
: "${TRANSIENT_RETRY_MAX_DELAY:=120}"

# --- Usage threshold defaults ---
: "${USAGE_THRESHOLD_PCT:=0}"              # 0 = disabled; set to e.g. 90 to pause at 90% of session usage
# AUTO_COMMIT conditional default: true in milestone mode, false otherwise.
# The conditional is applied AFTER flag parsing in tekhton.sh (MILESTONE_MODE
# is not yet known when config_defaults.sh is sourced). This line sets the
# fallback for non-milestone mode; tekhton.sh overrides for milestone mode.
# Explicit AUTO_COMMIT in pipeline.conf always takes precedence via :=.
: "${AUTO_COMMIT:=false}"

# --- Outer orchestration loop (--complete) defaults ---
: "${COMPLETE_MODE_ENABLED:=true}"        # Toggle --complete outer loop
: "${MAX_PIPELINE_ATTEMPTS:=5}"           # Max full pipeline cycles in --complete mode
: "${AUTONOMOUS_TIMEOUT:=7200}"           # Wall-clock timeout for --complete in seconds (2h)
: "${MAX_AUTONOMOUS_AGENT_CALLS:=200}"    # Safety valve for --complete mode (effectively unlimited for normal use)
: "${AUTONOMOUS_PROGRESS_CHECK:=true}"    # Enable stuck-detection between loop iterations

# --- Quota management defaults (Milestone 16) ---
: "${QUOTA_RETRY_INTERVAL:=300}"          # Seconds between quota refresh checks (5 min)
: "${QUOTA_RESERVE_PCT:=10}"              # Proactive pause threshold (Tier 2 only)
: "${CLAUDE_QUOTA_CHECK_CMD:=}"           # Optional external script for proactive checking
: "${QUOTA_MAX_PAUSE_DURATION:=14400}"    # Max seconds to wait in pause (4 hours)

# --- Metrics defaults ---
: "${METRICS_ENABLED:=true}"
: "${METRICS_MIN_RUNS:=5}"
: "${METRICS_ADAPTIVE_TURNS:=true}"

# --- Security agent stage defaults ---
: "${SECURITY_AGENT_ENABLED:=true}"
: "${CLAUDE_SECURITY_MODEL:=${CLAUDE_STANDARD_MODEL}}"
: "${SECURITY_MAX_TURNS:=15}"
: "${SECURITY_MIN_TURNS:=8}"
: "${SECURITY_MAX_TURNS_CAP:=30}"
: "${SECURITY_MAX_REWORK_CYCLES:=2}"
: "${MILESTONE_SECURITY_MAX_TURNS:=$(( SECURITY_MAX_TURNS * 2 ))}"
: "${SECURITY_BLOCK_SEVERITY:=HIGH}"
: "${SECURITY_UNFIXABLE_POLICY:=escalate}"
: "${SECURITY_OFFLINE_MODE:=auto}"
: "${SECURITY_ONLINE_SOURCES:=}"
: "${SECURITY_ROLE_FILE:=.claude/agents/security.md}"
: "${SECURITY_NOTES_FILE:=SECURITY_NOTES.md}"
: "${SECURITY_REPORT_FILE:=SECURITY_REPORT.md}"
: "${SECURITY_WAIVER_FILE:=}"

# --- Intake agent defaults (PM pre-stage gate) ---
: "${INTAKE_AGENT_ENABLED:=true}"
: "${CLAUDE_INTAKE_MODEL:=${CLAUDE_STANDARD_MODEL:-sonnet}}"  # Sonnet for eval; Opus reserved for NEEDS_CLARITY
: "${INTAKE_MAX_TURNS:=10}"
: "${INTAKE_CLARITY_THRESHOLD:=40}"
: "${INTAKE_TWEAK_THRESHOLD:=70}"
: "${INTAKE_CONFIRM_TWEAKS:=false}"
: "${INTAKE_AUTO_SPLIT:=false}"
: "${INTAKE_ROLE_FILE:=.claude/agents/intake.md}"
: "${INTAKE_REPORT_FILE:=INTAKE_REPORT.md}"

# --- Brownfield deep analysis defaults (Milestone 12) ---
: "${DETECT_WORKSPACES_ENABLED:=true}"
: "${DETECT_SERVICES_ENABLED:=true}"
: "${DETECT_CI_ENABLED:=true}"
: "${DETECT_INFRASTRUCTURE_ENABLED:=true}"
: "${DETECT_TEST_FRAMEWORKS_ENABLED:=true}"
: "${DOC_QUALITY_ASSESSMENT_ENABLED:=true}"
: "${WORKSPACE_ENUM_LIMIT:=50}"            # Max subprojects to enumerate per workspace
: "${PROJECT_STRUCTURE:=single}"

# --- AI artifact detection defaults (Milestone 11) ---
: "${ARTIFACT_DETECTION_ENABLED:=true}"
: "${ARTIFACT_HANDLING_DEFAULT:=}"              # Empty = interactive; set archive|tidy|ignore for headless
: "${ARTIFACT_ARCHIVE_DIR:=.claude/archived-ai-config}"
: "${ARTIFACT_MERGE_MODEL:=${CLAUDE_STANDARD_MODEL:-claude-sonnet-4-6}}"
: "${ARTIFACT_MERGE_MAX_TURNS:=10}"

# --- UI testing defaults (Milestone 28: UI Test Awareness) ---
: "${UI_TEST_CMD:=}"                                    # E2E test command (e.g., "npx playwright test")
: "${UI_FRAMEWORK:=}"                                   # auto|playwright|cypress|selenium|puppeteer|testing-library|detox|""
: "${UI_PROJECT_DETECTED:=false}"                       # Set by detection engine at startup
: "${UI_VALIDATION_ENABLED:=true}"                      # Enable UI validation gate when UI detected
: "${UI_TEST_TIMEOUT:=120}"                             # Seconds before UI test gate times out

# --- Pipeline order defaults (Milestone 27: TDD support) ---
: "${PIPELINE_ORDER:=standard}"                    # standard|test_first|auto (auto reserved for V4)
: "${TDD_PREFLIGHT_FILE:=TESTER_PREFLIGHT.md}"    # Output file for TDD write-failing tester
: "${TESTER_WRITE_FAILING_MAX_TURNS:=15}"          # Turn limit for write-failing tester (less than full tester)
: "${CODER_TDD_TURN_MULTIPLIER:=1.2}"             # Multiplier for coder turns in test_first mode

# --- Dry-run / preview defaults (Milestone 23) ---
: "${DRY_RUN_CACHE_TTL:=3600}"                    # Cache validity in seconds (default: 1 hour)
: "${DRY_RUN_CACHE_DIR:=${PROJECT_DIR:-.}/.claude/dry_run_cache}"

# --- Checkpoint / rollback defaults (Milestone 24) ---
: "${CHECKPOINT_ENABLED:=true}"
: "${CHECKPOINT_FILE:=.claude/CHECKPOINT_META.json}"

# --- Causal event log defaults (Milestone 13) ---
: "${CAUSAL_LOG_ENABLED:=true}"
: "${CAUSAL_LOG_FILE:=.claude/logs/CAUSAL_LOG.jsonl}"
: "${CAUSAL_LOG_RETENTION_RUNS:=50}"
: "${CAUSAL_LOG_MAX_EVENTS:=2000}"

# --- Test baseline defaults (pre-existing failure detection) ---
: "${TEST_BASELINE_ENABLED:=true}"
: "${TEST_BASELINE_PASS_ON_PREEXISTING:=true}"
: "${TEST_BASELINE_STUCK_THRESHOLD:=2}"
: "${TEST_BASELINE_PASS_ON_STUCK:=false}"

# --- Test audit defaults (Milestone 20) ---
: "${TEST_AUDIT_ENABLED:=true}"
: "${TEST_AUDIT_MAX_TURNS:=8}"
: "${TEST_AUDIT_MAX_REWORK_CYCLES:=1}"
: "${TEST_AUDIT_ORPHAN_DETECTION:=true}"
: "${TEST_AUDIT_WEAKENING_DETECTION:=true}"
: "${TEST_AUDIT_REPORT_FILE:=TEST_AUDIT_REPORT.md}"

# --- Health scoring defaults (Milestone 15) ---
: "${HEALTH_ENABLED:=true}"
: "${HEALTH_REASSESS_ON_COMPLETE:=false}"
: "${HEALTH_RUN_TESTS:=false}"
: "${HEALTH_SAMPLE_SIZE:=20}"
: "${HEALTH_WEIGHT_TESTS:=30}"
: "${HEALTH_WEIGHT_QUALITY:=25}"
: "${HEALTH_WEIGHT_DEPS:=15}"
: "${HEALTH_WEIGHT_DOCS:=15}"
: "${HEALTH_WEIGHT_HYGIENE:=15}"
: "${HEALTH_SHOW_BELT:=true}"
: "${HEALTH_BASELINE_FILE:=.claude/HEALTH_BASELINE.json}"
: "${HEALTH_REPORT_FILE:=HEALTH_REPORT.md}"

# --- Dashboard / Watchtower defaults (Milestone 13) ---
: "${DASHBOARD_ENABLED:=true}"
: "${DASHBOARD_VERBOSITY:=normal}"          # minimal|normal|verbose
: "${DASHBOARD_HISTORY_DEPTH:=50}"
: "${DASHBOARD_REFRESH_INTERVAL:=10}"       # seconds between run_state.js refreshes
: "${DASHBOARD_DIR:=.claude/dashboard}"
: "${DASHBOARD_MAX_TIMELINE_EVENTS:=500}"

# --- Update check defaults ---
: "${TEKHTON_UPDATE_CHECK:=true}"      # Check for updates (set false to disable all network calls)
: "${TEKHTON_PIN_VERSION:=}"           # Empty = no pin; set to X.Y.Z to prevent upgrade past that version

# --- Migration defaults ---
: "${TEKHTON_CONFIG_VERSION:=}"        # Set by --init and migration; empty = pre-watermark project
: "${MIGRATION_AUTO:=true}"            # Auto-prompt for migration on version mismatch
: "${MIGRATION_BACKUP_DIR:=.claude/migration-backups}"  # Relative path within .claude/

# --- Specialist reviewer defaults ---
: "${SPECIALIST_SECURITY_ENABLED:=false}"
: "${SPECIALIST_SECURITY_MODEL:=${CLAUDE_STANDARD_MODEL}}"
: "${SPECIALIST_SECURITY_MAX_TURNS:=8}"
: "${SPECIALIST_PERFORMANCE_ENABLED:=false}"
: "${SPECIALIST_PERFORMANCE_MODEL:=${CLAUDE_STANDARD_MODEL}}"
: "${SPECIALIST_PERFORMANCE_MAX_TURNS:=8}"
: "${SPECIALIST_API_ENABLED:=false}"
: "${SPECIALIST_API_MODEL:=${CLAUDE_STANDARD_MODEL}}"
: "${SPECIALIST_API_MAX_TURNS:=8}"

# Milestone overrides — defaults to 2x normal if not specified
: "${MILESTONE_MAX_REVIEW_CYCLES:=$(( MAX_REVIEW_CYCLES * 2 ))}"
: "${MILESTONE_CODER_MAX_TURNS:=$(( CODER_MAX_TURNS * 2 ))}"
: "${MILESTONE_JR_CODER_MAX_TURNS:=$(( JR_CODER_MAX_TURNS * 2 ))}"
: "${MILESTONE_REVIEWER_MAX_TURNS:=$(( REVIEWER_MAX_TURNS + 5 ))}"
: "${MILESTONE_TESTER_MAX_TURNS:=$(( TESTER_MAX_TURNS * 2 ))}"
: "${MILESTONE_TESTER_MODEL:=${CLAUDE_STANDARD_MODEL}}"

# Milestone activity timeout — multiplier applied to AGENT_ACTIVITY_TIMEOUT
: "${MILESTONE_ACTIVITY_TIMEOUT_MULTIPLIER:=3}"

# --- Clamp values to hard upper bounds ---
_clamp_config_value MAX_REVIEW_CYCLES 20
_clamp_config_value CODER_MAX_TURNS 500
_clamp_config_value JR_CODER_MAX_TURNS 500
_clamp_config_value REVIEWER_MAX_TURNS 500
_clamp_config_value TESTER_MAX_TURNS 500
_clamp_config_value SCOUT_MAX_TURNS 500
_clamp_config_value ARCHITECT_MAX_TURNS 500
_clamp_config_value CODER_MAX_TURNS_CAP 500
_clamp_config_value REVIEWER_MAX_TURNS_CAP 500
_clamp_config_value TESTER_MAX_TURNS_CAP 500
_clamp_config_value MILESTONE_MAX_REVIEW_CYCLES 40
_clamp_config_value MILESTONE_CODER_MAX_TURNS 500
_clamp_config_value MILESTONE_JR_CODER_MAX_TURNS 500
_clamp_config_value MILESTONE_REVIEWER_MAX_TURNS 500
_clamp_config_value MILESTONE_TESTER_MAX_TURNS 500
_clamp_config_value MILESTONE_ACTIVITY_TIMEOUT_MULTIPLIER 10
_clamp_config_value MILESTONE_SPLIT_MAX_TURNS 50
_clamp_config_value MILESTONE_SPLIT_THRESHOLD_PCT 500
_clamp_config_value MILESTONE_MAX_SPLIT_DEPTH 10
_clamp_config_value CLEANUP_BATCH_SIZE 50
_clamp_config_value CLEANUP_MAX_TURNS 500
_clamp_config_value CLEANUP_TRIGGER_THRESHOLD 100
_clamp_config_value SECURITY_MAX_TURNS 500
_clamp_config_value SECURITY_MIN_TURNS 500
_clamp_config_value SECURITY_MAX_TURNS_CAP 500
_clamp_config_value SECURITY_MAX_REWORK_CYCLES 10
_clamp_config_value MILESTONE_SECURITY_MAX_TURNS 500
_clamp_config_value INTAKE_MAX_TURNS 50
_clamp_config_value INTAKE_CLARITY_THRESHOLD 100
_clamp_config_value INTAKE_TWEAK_THRESHOLD 100
_clamp_config_value ARTIFACT_MERGE_MAX_TURNS 50
_clamp_config_value SPECIALIST_SECURITY_MAX_TURNS 50
_clamp_config_value SPECIALIST_PERFORMANCE_MAX_TURNS 50
_clamp_config_value SPECIALIST_API_MAX_TURNS 50
_clamp_config_value MAX_PIPELINE_ATTEMPTS 20
_clamp_config_value AUTONOMOUS_TIMEOUT 14400
_clamp_config_value MAX_AUTONOMOUS_AGENT_CALLS 500
_clamp_config_value METRICS_MIN_RUNS 100
_clamp_config_value MAX_CONTINUATION_ATTEMPTS 10
_clamp_config_value MAX_TRANSIENT_RETRIES 10
_clamp_config_value TRANSIENT_RETRY_BASE_DELAY 300
_clamp_config_value TRANSIENT_RETRY_MAX_DELAY 600
_clamp_config_value MILESTONE_WINDOW_PCT 80
_clamp_config_value MILESTONE_WINDOW_MAX_CHARS 100000
_clamp_config_value REPO_MAP_TOKEN_BUDGET 16384
_clamp_config_value REPO_MAP_HISTORY_MAX_RECORDS 1000
_clamp_config_value SERENA_STARTUP_TIMEOUT 120
_clamp_config_value SERENA_MAX_RETRIES 10
_clamp_config_value CAUSAL_LOG_RETENTION_RUNS 200
_clamp_config_value CAUSAL_LOG_MAX_EVENTS 10000
_clamp_config_value TEST_AUDIT_MAX_TURNS 50
_clamp_config_value TEST_AUDIT_MAX_REWORK_CYCLES 5
_clamp_config_value TEST_BASELINE_STUCK_THRESHOLD 10
_clamp_config_value UI_TEST_TIMEOUT 600
_clamp_config_value TESTER_WRITE_FAILING_MAX_TURNS 100
_clamp_config_float CODER_TDD_TURN_MULTIPLIER 0.5 3.0
_clamp_config_value DASHBOARD_HISTORY_DEPTH 100
_clamp_config_value DASHBOARD_REFRESH_INTERVAL 300
_clamp_config_value DASHBOARD_MAX_TIMELINE_EVENTS 2000
_clamp_config_value HEALTH_SAMPLE_SIZE 100
_clamp_config_value QUOTA_RETRY_INTERVAL 3600
_clamp_config_value QUOTA_RESERVE_PCT 50
_clamp_config_value QUOTA_MAX_PAUSE_DURATION 86400

#!/usr/bin/env bash
# =============================================================================
# config_defaults.sh — Default values and hard upper-bound clamps for pipeline config
#
# Sourced by config.sh at the end of load_config(), AFTER _parse_config_file()
# has run. Project-supplied values take precedence — these are fallback defaults.
# =============================================================================
set -euo pipefail

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

# --- Milestone pre-flight sizing and auto-split ---
: "${MILESTONE_SPLIT_ENABLED:=true}"
: "${MILESTONE_SPLIT_MODEL:=${CLAUDE_CODER_MODEL}}"
: "${MILESTONE_SPLIT_MAX_TURNS:=15}"
: "${MILESTONE_SPLIT_THRESHOLD_PCT:=120}"
: "${MILESTONE_AUTO_RETRY:=true}"
: "${MILESTONE_MAX_SPLIT_DEPTH:=3}"

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
: "${MAX_AUTONOMOUS_AGENT_CALLS:=20}"     # Max total agent invocations in --complete mode
: "${AUTONOMOUS_PROGRESS_CHECK:=true}"    # Enable stuck-detection between loop iterations

# --- Metrics defaults ---
: "${METRICS_ENABLED:=true}"
: "${METRICS_MIN_RUNS:=5}"
: "${METRICS_ADAPTIVE_TURNS:=true}"

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
_clamp_config_value MILESTONE_MAX_SPLIT_DEPTH 5
_clamp_config_value CLEANUP_BATCH_SIZE 50
_clamp_config_value CLEANUP_MAX_TURNS 500
_clamp_config_value CLEANUP_TRIGGER_THRESHOLD 100
_clamp_config_value SPECIALIST_SECURITY_MAX_TURNS 50
_clamp_config_value SPECIALIST_PERFORMANCE_MAX_TURNS 50
_clamp_config_value SPECIALIST_API_MAX_TURNS 50
_clamp_config_value MAX_PIPELINE_ATTEMPTS 20
_clamp_config_value AUTONOMOUS_TIMEOUT 14400
_clamp_config_value MAX_AUTONOMOUS_AGENT_CALLS 100
_clamp_config_value METRICS_MIN_RUNS 100
_clamp_config_value MAX_CONTINUATION_ATTEMPTS 10
_clamp_config_value MAX_TRANSIENT_RETRIES 10
_clamp_config_value TRANSIENT_RETRY_BASE_DELAY 300
_clamp_config_value TRANSIENT_RETRY_MAX_DELAY 600

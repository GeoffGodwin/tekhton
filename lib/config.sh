#!/usr/bin/env bash
# =============================================================================
# config.sh — Load and validate pipeline.conf
#
# Sourced by tekhton.sh — do not run directly.
# Expects: TEKHTON_HOME (set by caller, points to tekhton repo root)
#          PROJECT_DIR (set by caller, points to target project repo root)
# Provides: all variables defined in pipeline.conf, plus load_config(),
#           apply_milestone_overrides()
# =============================================================================

# --- Locate config file ------------------------------------------------------

# Config lives in the target project: .claude/pipeline.conf
_CONF_FILE="${PROJECT_DIR}/.claude/pipeline.conf"

# --- Loader ------------------------------------------------------------------

load_config() {
    if [ ! -f "$_CONF_FILE" ]; then
        echo "[✗] pipeline.conf not found at: $_CONF_FILE" >&2
        echo "    Run 'tekhton --init' from your project root to create one." >&2
        exit 1
    fi

    # Source the conf file — strip \r in case VS Code saved with CRLF on Windows
    # shellcheck source=/dev/null
    source <(sed 's/\r$//' "$_CONF_FILE")

    # --- Validate required keys ---
    local missing=()
    for key in PROJECT_NAME REQUIRED_TOOLS \
               CLAUDE_CODER_MODEL CLAUDE_JR_CODER_MODEL CLAUDE_STANDARD_MODEL CLAUDE_TESTER_MODEL \
               CODER_MAX_TURNS JR_CODER_MAX_TURNS REVIEWER_MAX_TURNS TESTER_MAX_TURNS \
               MAX_REVIEW_CYCLES ANALYZE_CMD TEST_CMD \
               PIPELINE_STATE_FILE LOG_DIR \
               CODER_ROLE_FILE REVIEWER_ROLE_FILE TESTER_ROLE_FILE JR_CODER_ROLE_FILE \
               PROJECT_RULES_FILE; do
        if [ -z "${!key:-}" ]; then
            missing+=("$key")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        echo "[✗] pipeline.conf is missing required keys:" >&2
        for k in "${missing[@]}"; do
            echo "    - $k" >&2
        done
        exit 1
    fi

    # --- Set defaults for optional keys ---
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

    # --- Dynamic turn limit defaults ---
    # Bounds for scout-recommended turn adjustments. The scout suggests a value;
    # the pipeline clamps it to [min, max]. Set to 0 to disable dynamic limits.
    : "${DYNAMIC_TURNS_ENABLED:=true}"
    : "${CODER_MIN_TURNS:=15}"
    : "${CODER_MAX_TURNS_CAP:=200}"
    : "${REVIEWER_MIN_TURNS:=5}"
    : "${REVIEWER_MAX_TURNS_CAP:=30}"
    : "${TESTER_MIN_TURNS:=10}"
    : "${TESTER_MAX_TURNS_CAP:=100}"

    # Milestone overrides — defaults to 2x normal if not specified
    : "${MILESTONE_MAX_REVIEW_CYCLES:=$(( MAX_REVIEW_CYCLES * 2 ))}"
    : "${MILESTONE_CODER_MAX_TURNS:=$(( CODER_MAX_TURNS * 2 ))}"
    : "${MILESTONE_JR_CODER_MAX_TURNS:=$(( JR_CODER_MAX_TURNS * 2 ))}"
    : "${MILESTONE_REVIEWER_MAX_TURNS:=$(( REVIEWER_MAX_TURNS + 5 ))}"
    : "${MILESTONE_TESTER_MAX_TURNS:=$(( TESTER_MAX_TURNS * 2 ))}"
    : "${MILESTONE_TESTER_MODEL:=${CLAUDE_STANDARD_MODEL}}"

    # --- Resolve relative paths to absolute from PROJECT_DIR ---
    [[ "$PIPELINE_STATE_FILE" != /* ]] && PIPELINE_STATE_FILE="${PROJECT_DIR}/${PIPELINE_STATE_FILE}"
    [[ "$LOG_DIR" != /* ]] && LOG_DIR="${PROJECT_DIR}/${LOG_DIR}"
}

# --- Milestone mode overrides ------------------------------------------------

apply_milestone_overrides() {
    MAX_REVIEW_CYCLES="$MILESTONE_MAX_REVIEW_CYCLES"
    CODER_MAX_TURNS="$MILESTONE_CODER_MAX_TURNS"
    JR_CODER_MAX_TURNS="$MILESTONE_JR_CODER_MAX_TURNS"
    REVIEWER_MAX_TURNS="$MILESTONE_REVIEWER_MAX_TURNS"
    TESTER_MAX_TURNS="$MILESTONE_TESTER_MAX_TURNS"
    export CLAUDE_TESTER_MODEL="$MILESTONE_TESTER_MODEL"
}

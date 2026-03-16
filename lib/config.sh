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

# --- Safe config file parser -------------------------------------------------
# Reads key=value lines from a config file without executing arbitrary code.
# Handles: bare values, double-quoted, single-quoted, values with = signs, spaces.
# Rejects values containing dangerous shell metacharacters.

_parse_config_file() {
    local conf_file="$1"
    local line_num=0

    while IFS= read -r line || [[ -n "$line" ]]; do
        line_num=$((line_num + 1))

        # Strip \r (CRLF from Windows editors)
        line="${line//$'\r'/}"

        # Skip empty lines and comments
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue

        # Must match KEY=VALUE pattern (key starts with letter or underscore)
        if ! [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*) ]]; then
            continue
        fi

        local key="${BASH_REMATCH[1]}"
        local raw_value="${BASH_REMATCH[2]}"

        # Strip leading/trailing whitespace from the value
        raw_value="${raw_value#"${raw_value%%[![:space:]]*}"}"
        raw_value="${raw_value%"${raw_value##*[![:space:]]}"}"

        # Strip surrounding quotes (double or single) if present
        if [[ "$raw_value" =~ ^\"(.*)\"$ ]]; then
            raw_value="${BASH_REMATCH[1]}"
        elif [[ "$raw_value" =~ ^\'(.*)\'$ ]]; then
            raw_value="${BASH_REMATCH[1]}"
        fi

        # Strip inline comments: only if preceded by space+# outside quotes
        # (simple heuristic: strip " #..." suffix)
        if [[ "$raw_value" =~ ^([^#]*[^[:space:]])[[:space:]]+#.*$ ]]; then
            raw_value="${BASH_REMATCH[1]}"
        fi

        # Reject command substitution universally (never legitimate in config values)
        if [[ "$raw_value" == *"\$("* ]] || [[ "$raw_value" == *"\`"* ]]; then
            echo "[✗] pipeline.conf:${line_num}: REJECTED — value for '${key}' contains command substitution." >&2
            echo "    Dangerous patterns: \$( \`" >&2
            echo "    Line: ${line}" >&2
            exit 1
        fi

        # Reject shell metacharacters in non-command, non-pattern keys.
        # Command keys (ANALYZE_CMD, TEST_CMD, etc.) may legitimately contain
        # pipes or redirects. Pattern keys (NOTES_FILTER_CATEGORIES, etc.) may
        # contain pipes for alternation. All other keys must be clean.
        case "$key" in
            *_CMD|*_PATTERN|*_CATEGORIES) ;;  # Allow shell metacharacters
            *)
                if [[ "$raw_value" == *';'* ]] || [[ "$raw_value" == *'|'* ]] || \
                   [[ "$raw_value" == *'&'* ]] || [[ "$raw_value" == *'>'* ]] || \
                   [[ "$raw_value" == *'<'* ]]; then
                    echo "[✗] pipeline.conf:${line_num}: REJECTED — value for '${key}' contains shell metacharacters." >&2
                    echo "    Dangerous characters: ; | & > <" >&2
                    echo "    Line: ${line}" >&2
                    exit 1
                fi
                ;;
        esac

        # Safe assignment via declare -gx (global + export)
        declare -gx "$key=$raw_value"
    done < "$conf_file"
}

# --- Loader ------------------------------------------------------------------

load_config() {
    if [ ! -f "$_CONF_FILE" ]; then
        echo "[✗] pipeline.conf not found at: $_CONF_FILE" >&2
        echo "    Run 'tekhton --init' from your project root to create one." >&2
        exit 1
    fi

    # Safe config parser — reads key=value lines without executing arbitrary code.
    # Rejects values containing dangerous shell metacharacters: $( ` ; | & > <
    _parse_config_file "$_CONF_FILE"

    # --- Context budget defaults (set early — used by planning + execution) ---
    : "${CONTEXT_BUDGET_PCT:=50}"            # Max % of context window for prompt
    : "${CHARS_PER_TOKEN:=4}"                # Conservative char-to-token ratio
    : "${CONTEXT_BUDGET_ENABLED:=true}"      # Toggle context budgeting

    # --- Execution pipeline defaults (derivable from CLAUDE_STANDARD_MODEL) ---
    : "${REQUIRED_TOOLS:=git claude}"
    : "${CLAUDE_CODER_MODEL:=${CLAUDE_STANDARD_MODEL:-claude-sonnet-4-6}}"
    : "${CLAUDE_JR_CODER_MODEL:=${CLAUDE_STANDARD_MODEL:-claude-sonnet-4-6}}"
    : "${CLAUDE_TESTER_MODEL:=${CLAUDE_STANDARD_MODEL:-claude-sonnet-4-6}}"
    : "${CODER_MAX_TURNS:=50}"
    : "${JR_CODER_MAX_TURNS:=25}"
    : "${REVIEWER_MAX_TURNS:=15}"
    : "${TESTER_MAX_TURNS:=30}"
    : "${MAX_REVIEW_CYCLES:=3}"
    : "${TEST_CMD:=true}"
    : "${PIPELINE_STATE_FILE:=.claude/PIPELINE_STATE.md}"
    : "${LOG_DIR:=.claude/logs}"
    : "${CODER_ROLE_FILE:=.claude/agents/coder.md}"
    : "${REVIEWER_ROLE_FILE:=.claude/agents/reviewer.md}"
    : "${TESTER_ROLE_FILE:=.claude/agents/tester.md}"
    : "${JR_CODER_ROLE_FILE:=.claude/agents/jr-coder.md}"
    : "${PROJECT_RULES_FILE:=CLAUDE.md}"

    # --- Validate required keys ---
    local missing=()
    for key in PROJECT_NAME CLAUDE_STANDARD_MODEL ANALYZE_CMD; do
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

    # --- Agent permission defaults ---
    # Set to true to use --dangerously-skip-permissions (NOT recommended).
    # When false (default), agents use --allowedTools with least-privilege profiles.
    : "${AGENT_SKIP_PERMISSIONS:=false}"

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

    # Milestone activity timeout — multiplier applied to AGENT_ACTIVITY_TIMEOUT
    # in milestone mode. Large milestones may need longer silent periods
    # (especially with --output-format json which produces no streaming output).
    : "${MILESTONE_ACTIVITY_TIMEOUT_MULTIPLIER:=3}"

    # --- Hard upper bounds (defense-in-depth) ---
    # Prevent runaway loops or excessive API costs from misconfigured values.
    _clamp_config_value() {
        local key="$1" max="$2"
        local val="${!key:-0}"
        if [[ "$val" =~ ^[0-9]+$ ]] && [ "$val" -gt "$max" ] 2>/dev/null; then
            warn "[config] ${key}=${val} exceeds hard cap (${max}). Clamped to ${max}."
            declare -gx "$key=$max"
        fi
    }
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

    # Scale activity timeout for milestone mode (long-running agent calls)
    local base_timeout="${AGENT_ACTIVITY_TIMEOUT:-600}"
    AGENT_ACTIVITY_TIMEOUT=$(( base_timeout * MILESTONE_ACTIVITY_TIMEOUT_MULTIPLIER ))
}

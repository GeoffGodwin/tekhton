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
# Populates _CONF_KEYS_SET (space-separated list of keys parsed from the file).

_CONF_KEYS_SET=""

_parse_config_file() {
    local conf_file="$1"
    local line_num=0
    _CONF_KEYS_SET=""

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
        _CONF_KEYS_SET="${_CONF_KEYS_SET} ${key}"
    done < "$conf_file"
}

# --- Hard upper bounds (defense-in-depth) ------------------------------------
# Prevent runaway loops or excessive API costs from misconfigured values.
# Defined at module scope so load_config() can call it without nesting.

_clamp_config_value() {
    local key="$1" max="$2"
    local val="${!key:-0}"
    if [[ "$val" =~ ^[0-9]+$ ]] && [ "$val" -gt "$max" ] 2>/dev/null; then
        warn "[config] ${key}=${val} exceeds hard cap (${max}). Clamped to ${max}."
        declare -gx "$key=$max"
    fi
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

    # --- Validate required keys ---
    # Check against keys actually parsed from pipeline.conf, not shell variables.
    # Environment-inherited values must not satisfy this check.
    local missing=()
    for key in PROJECT_NAME CLAUDE_STANDARD_MODEL ANALYZE_CMD; do
        if [[ " ${_CONF_KEYS_SET} " != *" ${key} "* ]]; then
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

    # Apply defaults and hard upper-bound clamps (extracted to keep config.sh < 300 lines)
    # shellcheck source=lib/config_defaults.sh
    source "${TEKHTON_HOME}/lib/config_defaults.sh"

    # --- Validate security agent config ---
    if [[ -n "${SECURITY_UNFIXABLE_POLICY:-}" ]]; then
        case "$SECURITY_UNFIXABLE_POLICY" in
            escalate|halt|waiver) ;;
            *) warn "[config] SECURITY_UNFIXABLE_POLICY must be escalate|halt|waiver (got: ${SECURITY_UNFIXABLE_POLICY}). Using 'escalate'."
               SECURITY_UNFIXABLE_POLICY="escalate" ;;
        esac
    fi
    if [[ -n "${SECURITY_BLOCK_SEVERITY:-}" ]]; then
        case "$SECURITY_BLOCK_SEVERITY" in
            CRITICAL|HIGH|MEDIUM|LOW) ;;
            *) warn "[config] SECURITY_BLOCK_SEVERITY must be CRITICAL|HIGH|MEDIUM|LOW (got: ${SECURITY_BLOCK_SEVERITY}). Using 'HIGH'."
               SECURITY_BLOCK_SEVERITY="HIGH" ;;
        esac
    fi

    # --- Validate intake agent config ---
    if [[ -n "${INTAKE_CLARITY_THRESHOLD:-}" ]] && [[ "${INTAKE_CLARITY_THRESHOLD}" =~ ^[0-9]+$ ]]; then
        if [[ "$INTAKE_CLARITY_THRESHOLD" -gt 100 ]]; then
            warn "[config] INTAKE_CLARITY_THRESHOLD must be 0-100 (got: ${INTAKE_CLARITY_THRESHOLD}). Using 40."
            INTAKE_CLARITY_THRESHOLD=40
        fi
    fi
    if [[ -n "${INTAKE_TWEAK_THRESHOLD:-}" ]] && [[ "${INTAKE_TWEAK_THRESHOLD}" =~ ^[0-9]+$ ]]; then
        if [[ "$INTAKE_TWEAK_THRESHOLD" -gt 100 ]]; then
            warn "[config] INTAKE_TWEAK_THRESHOLD must be 0-100 (got: ${INTAKE_TWEAK_THRESHOLD}). Using 70."
            INTAKE_TWEAK_THRESHOLD=70
        fi
        if [[ -n "${INTAKE_CLARITY_THRESHOLD:-}" ]] && [[ "${INTAKE_CLARITY_THRESHOLD}" =~ ^[0-9]+$ ]]; then
            if [[ "$INTAKE_TWEAK_THRESHOLD" -le "$INTAKE_CLARITY_THRESHOLD" ]]; then
                warn "[config] INTAKE_TWEAK_THRESHOLD (${INTAKE_TWEAK_THRESHOLD}) must be greater than INTAKE_CLARITY_THRESHOLD (${INTAKE_CLARITY_THRESHOLD}). Using defaults."
                INTAKE_CLARITY_THRESHOLD=40
                INTAKE_TWEAK_THRESHOLD=70
            fi
        fi
    fi

    # --- Validate dashboard / causal log config (Milestone 13) ---
    if [[ -n "${DASHBOARD_VERBOSITY:-}" ]]; then
        case "$DASHBOARD_VERBOSITY" in
            minimal|normal|verbose) ;;
            *) warn "[config] DASHBOARD_VERBOSITY must be minimal|normal|verbose (got: ${DASHBOARD_VERBOSITY}). Using 'normal'."
               DASHBOARD_VERBOSITY="normal" ;;
        esac
    fi
    if [[ -n "${DASHBOARD_HISTORY_DEPTH:-}" ]] && [[ "${DASHBOARD_HISTORY_DEPTH}" =~ ^[0-9]+$ ]]; then
        if [[ "$DASHBOARD_HISTORY_DEPTH" -lt 1 ]] || [[ "$DASHBOARD_HISTORY_DEPTH" -gt 100 ]]; then
            warn "[config] DASHBOARD_HISTORY_DEPTH must be 1-100 (got: ${DASHBOARD_HISTORY_DEPTH}). Using 50."
            DASHBOARD_HISTORY_DEPTH=50
        fi
    fi
    if [[ -n "${CAUSAL_LOG_RETENTION_RUNS:-}" ]] && [[ "${CAUSAL_LOG_RETENTION_RUNS}" =~ ^[0-9]+$ ]]; then
        if [[ "$CAUSAL_LOG_RETENTION_RUNS" -lt 1 ]] || [[ "$CAUSAL_LOG_RETENTION_RUNS" -gt 200 ]]; then
            warn "[config] CAUSAL_LOG_RETENTION_RUNS must be 1-200 (got: ${CAUSAL_LOG_RETENTION_RUNS}). Using 50."
            CAUSAL_LOG_RETENTION_RUNS=50
        fi
    fi
    if [[ -n "${CAUSAL_LOG_MAX_EVENTS:-}" ]] && [[ "${CAUSAL_LOG_MAX_EVENTS}" =~ ^[0-9]+$ ]]; then
        if [[ "$CAUSAL_LOG_MAX_EVENTS" -lt 1 ]] || [[ "$CAUSAL_LOG_MAX_EVENTS" -gt 10000 ]]; then
            warn "[config] CAUSAL_LOG_MAX_EVENTS must be 1-10000 (got: ${CAUSAL_LOG_MAX_EVENTS}). Using 2000."
            CAUSAL_LOG_MAX_EVENTS=2000
        fi
    fi
    if [[ -n "${DASHBOARD_MAX_TIMELINE_EVENTS:-}" ]] && [[ "${DASHBOARD_MAX_TIMELINE_EVENTS}" =~ ^[0-9]+$ ]]; then
        if [[ "$DASHBOARD_MAX_TIMELINE_EVENTS" -lt 1 ]] || [[ "$DASHBOARD_MAX_TIMELINE_EVENTS" -gt 2000 ]]; then
            warn "[config] DASHBOARD_MAX_TIMELINE_EVENTS must be 1-2000 (got: ${DASHBOARD_MAX_TIMELINE_EVENTS}). Using 500."
            DASHBOARD_MAX_TIMELINE_EVENTS=500
        fi
    fi

    # --- Resolve relative paths to absolute from PROJECT_DIR ---
    if [[ "$PIPELINE_STATE_FILE" != /* ]]; then
        PIPELINE_STATE_FILE="${PROJECT_DIR}/${PIPELINE_STATE_FILE}"
    fi
    if [[ "$LOG_DIR" != /* ]]; then
        LOG_DIR="${PROJECT_DIR}/${LOG_DIR}"
    fi
    if [[ "$MILESTONE_ARCHIVE_FILE" != /* ]]; then
        MILESTONE_ARCHIVE_FILE="${PROJECT_DIR}/${MILESTONE_ARCHIVE_FILE}"
    fi
    if [[ "${MILESTONE_DIR:-}" != /* ]] && [[ -n "${MILESTONE_DIR:-}" ]]; then
        MILESTONE_DIR="${PROJECT_DIR}/${MILESTONE_DIR}"
    fi
    if [[ "${CAUSAL_LOG_FILE:-}" != /* ]] && [[ -n "${CAUSAL_LOG_FILE:-}" ]]; then
        CAUSAL_LOG_FILE="${PROJECT_DIR}/${CAUSAL_LOG_FILE}"
    fi
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

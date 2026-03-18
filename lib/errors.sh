#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# errors.sh — Error taxonomy, classification engine, and sensitive data redaction
#
# Sourced by tekhton.sh — do not run directly.
# Provides: classify_error(), is_transient(), suggest_recovery(),
#           redact_sensitive()
#
# Milestone 12.1: Pure library with no pipeline integration. All functions
# are independently testable.
# =============================================================================

# --- Error Taxonomy ---------------------------------------------------------
#
# Categories and subcategories:
#   UPSTREAM       — API provider failures (all transient)
#     api_500        HTTP 500/502/503
#     api_rate_limit HTTP 429
#     api_overloaded HTTP 529
#     api_auth       authentication_error
#     api_timeout    connection timeout
#     api_unknown    unrecognized API error
#
#   ENVIRONMENT    — Local system issues
#     disk_full      no space left on device
#     network        DNS/connection failures
#     missing_dep    required command not found
#     permissions    permission denied
#     oom            signal 9 / exit 137 with no prior API errors
#     env_unknown    unrecognized environment error
#
#   AGENT_SCOPE    — Expected agent-level failures (all permanent)
#     null_run       died before meaningful work
#     max_turns      exhausted turn budget
#     activity_timeout no output or file changes for timeout period
#     no_summary     completed but no CODER_SUMMARY.md
#     scope_unknown  unrecognized agent scope issue
#
#   PIPELINE       — Tekhton internal errors (all permanent)
#     state_corrupt  invalid PIPELINE_STATE.md
#     config_error   pipeline.conf parse failure
#     missing_file   required artifact not found
#     template_error prompt render failure
#     internal       unexpected shell error

# --- _match_pattern ---------------------------------------------------------
# Case-insensitive grep against a string. Returns 0 if matched.
# Uses grep -qiE for extended regex support.

_match_pattern() {
    local text="$1"
    local pattern="$2"
    echo "$text" | grep -qiE "$pattern" 2>/dev/null
}

# --- classify_error ---------------------------------------------------------
# Analyzes exit code, stderr content, and last output to produce a structured
# error record.
#
# Usage: classify_error EXIT_CODE [STDERR_FILE] [LAST_OUTPUT_FILE] [FILE_CHANGES] [TURNS]
# Output: CATEGORY|SUBCATEGORY|TRANSIENT|MESSAGE (printed to stdout)
#
# Parameters:
#   EXIT_CODE        - Process exit code (required)
#   STDERR_FILE      - Path to captured stderr (optional, "" to skip)
#   LAST_OUTPUT_FILE - Path to last agent output lines (optional, "" to skip)
#   FILE_CHANGES     - Count of files changed (optional, default 0)
#   TURNS            - Turn count from agent (optional, default 0)

classify_error() {
    local exit_code="${1:?classify_error requires exit_code}"
    local stderr_file="${2:-}"
    local last_output_file="${3:-}"
    local file_changes="${4:-0}"
    local turns="${5:-0}"

    # Ensure numeric defaults
    [[ "$file_changes" =~ ^[0-9]+$ ]] || file_changes=0
    [[ "$turns" =~ ^[0-9]+$ ]] || turns=0

    # Read stderr and output content for pattern matching
    local stderr_content=""
    if [[ -n "$stderr_file" ]] && [[ -f "$stderr_file" ]]; then
        stderr_content=$(head -c 65536 "$stderr_file" 2>/dev/null || true)
    fi

    local output_content=""
    if [[ -n "$last_output_file" ]] && [[ -f "$last_output_file" ]]; then
        output_content=$(head -c 65536 "$last_output_file" 2>/dev/null || true)
    fi

    local combined="${stderr_content}${output_content}"

    # --- UPSTREAM: API provider failures (check first — takes priority) ------

    # HTTP 429 — rate limit
    if _match_pattern "$combined" '"type"[[:space:]]*:[[:space:]]*"error"' \
        && _match_pattern "$combined" 'rate_limit'; then
        echo "UPSTREAM|api_rate_limit|true|API rate limit (HTTP 429)"
        return 0
    fi
    if _match_pattern "$combined" '"status"[[:space:]]*:[[:space:]]*429' \
        || _match_pattern "$combined" 'rate.limit'; then
        echo "UPSTREAM|api_rate_limit|true|API rate limit (HTTP 429)"
        return 0
    fi

    # HTTP 529 — overloaded
    if _match_pattern "$combined" '"type"[[:space:]]*:[[:space:]]*"error"' \
        && _match_pattern "$combined" 'overloaded'; then
        echo "UPSTREAM|api_overloaded|true|API overloaded (HTTP 529)"
        return 0
    fi
    if _match_pattern "$combined" '"status"[[:space:]]*:[[:space:]]*529' \
        || _match_pattern "$combined" 'overloaded_error'; then
        echo "UPSTREAM|api_overloaded|true|API overloaded (HTTP 529)"
        return 0
    fi

    # HTTP 500/502/503 — server error
    if _match_pattern "$combined" '"type"[[:space:]]*:[[:space:]]*"error"' \
        && _match_pattern "$combined" 'server_error'; then
        echo "UPSTREAM|api_500|true|API server error (HTTP 500)"
        return 0
    fi
    if _match_pattern "$combined" '"status"[[:space:]]*:[[:space:]]*50[023]'; then
        echo "UPSTREAM|api_500|true|API server error (HTTP 5xx)"
        return 0
    fi
    # Authentication error
    if _match_pattern "$combined" 'authentication_error' \
        || _match_pattern "$combined" 'invalid.api.key' \
        || _match_pattern "$combined" 'invalid.*x-api-key'; then
        echo "UPSTREAM|api_auth|true|API authentication error"
        return 0
    fi

    # Connection timeout
    if _match_pattern "$combined" 'connection.*timed?[[:space:]]*out' \
        || _match_pattern "$combined" 'ETIMEDOUT' \
        || _match_pattern "$combined" 'ECONNRESET' \
        || _match_pattern "$combined" 'request.*timeout'; then
        echo "UPSTREAM|api_timeout|true|API connection timeout"
        return 0
    fi

    # Generic API error (catch-all for unrecognized API errors)
    if _match_pattern "$combined" '"type"[[:space:]]*:[[:space:]]*"error"' \
        && _match_pattern "$combined" '"error"[[:space:]]*:[[:space:]]*\{'; then
        echo "UPSTREAM|api_unknown|true|Unrecognized API error"
        return 0
    fi

    # --- ENVIRONMENT: Local system issues ------------------------------------

    # OOM — exit 137 (SIGKILL / signal 9) with no API errors detected above
    if [[ "$exit_code" -eq 137 ]] || [[ "$exit_code" -eq 9 ]]; then
        echo "ENVIRONMENT|oom|true|Process killed (signal 9) — likely OOM"
        return 0
    fi

    # Disk full
    if _match_pattern "$combined" 'No space left on device' \
        || _match_pattern "$combined" 'ENOSPC'; then
        echo "ENVIRONMENT|disk_full|false|No space left on device"
        return 0
    fi

    # Network errors (non-API)
    if _match_pattern "$combined" 'ENOTFOUND' \
        || _match_pattern "$combined" 'EAI_AGAIN' \
        || _match_pattern "$combined" 'getaddrinfo.*failed' \
        || _match_pattern "$combined" 'DNS.*resolution.*failed' \
        || _match_pattern "$combined" 'network.*unreachable'; then
        echo "ENVIRONMENT|network|true|Network connectivity failure"
        return 0
    fi

    # Missing dependency
    if _match_pattern "$combined" 'command not found' \
        || _match_pattern "$combined" 'not found in PATH' \
        || _match_pattern "$combined" 'Required command not found'; then
        echo "ENVIRONMENT|missing_dep|false|Required command not found"
        return 0
    fi

    # Permission denied
    if _match_pattern "$combined" 'Permission denied' \
        || _match_pattern "$combined" 'EACCES'; then
        echo "ENVIRONMENT|permissions|false|Permission denied"
        return 0
    fi

    # --- PIPELINE: Tekhton internal errors -----------------------------------

    # State corruption
    if _match_pattern "$combined" 'PIPELINE_STATE' \
        && _match_pattern "$combined" 'corrupt|invalid|malformed'; then
        echo "PIPELINE|state_corrupt|false|Pipeline state file is corrupt or invalid"
        return 0
    fi

    # Config error
    if _match_pattern "$combined" 'pipeline.conf' \
        && _match_pattern "$combined" 'REJECTED|missing required|not found'; then
        echo "PIPELINE|config_error|false|Pipeline configuration error"
        return 0
    fi

    # Template render error
    if _match_pattern "$combined" 'render_prompt|template.*not found|\.prompt\.md'; then
        echo "PIPELINE|template_error|false|Prompt template render failure"
        return 0
    fi

    # Missing artifact file
    if _match_pattern "$combined" 'Expected output file.*not found' \
        || _match_pattern "$combined" 'Required.*file.*not found'; then
        echo "PIPELINE|missing_file|false|Required artifact file not found"
        return 0
    fi

    # --- AGENT_SCOPE: Expected agent-level failures --------------------------

    # Activity timeout (exit 124 with activity timeout marker)
    if [[ "$exit_code" -eq 124 ]]; then
        echo "AGENT_SCOPE|activity_timeout|false|Agent activity timeout — no output or file changes"
        return 0
    fi

    # Null run: low turns + no file changes (non-zero exit, or zero turns regardless)
    if [[ "$turns" -le 2 ]] && [[ "$file_changes" -eq 0 ]] \
        && { [[ "$exit_code" -ne 0 ]] || [[ "$turns" -eq 0 ]]; }; then
        echo "AGENT_SCOPE|null_run|false|Agent completed without meaningful work"
        return 0
    fi

    # Max turns exhausted (non-zero exit, turns > 0, files changed)
    if [[ "$exit_code" -ne 0 ]] && [[ "$turns" -gt 2 ]]; then
        echo "AGENT_SCOPE|max_turns|false|Agent exhausted turn budget (${turns} turns used)"
        return 0
    fi

    # Successful exit but no summary
    if [[ "$exit_code" -eq 0 ]] && [[ "$turns" -gt 0 ]] && [[ "$file_changes" -eq 0 ]]; then
        echo "AGENT_SCOPE|no_summary|false|Agent completed but produced no file changes"
        return 0
    fi

    # --- Fallback: unknown errors by category --------------------------------

    # Non-zero exit with no recognized pattern
    if [[ "$exit_code" -ne 0 ]]; then
        # SIGSEGV
        if [[ "$exit_code" -eq 139 ]]; then
            echo "ENVIRONMENT|env_unknown|false|Process crashed (SIGSEGV, exit 139)"
            return 0
        fi
        # Check for any API-like content we might have missed
        if _match_pattern "$combined" 'anthropic|claude|api\.anthropic'; then
            echo "UPSTREAM|api_unknown|true|Unrecognized API-related error (exit ${exit_code})"
            return 0
        fi
        echo "PIPELINE|internal|false|Unexpected error (exit ${exit_code})"
        return 0
    fi

    # Exit 0 with no issues — should not typically call classify_error for success
    echo "AGENT_SCOPE|scope_unknown|false|No error detected (exit 0)"
    return 0
}

# --- is_transient -----------------------------------------------------------
# Returns 0 if the error category/subcategory is transient (retryable).
# Returns 1 if permanent (requires human action or scope change).
#
# Usage: is_transient CATEGORY SUBCATEGORY

is_transient() {
    local category="${1:?is_transient requires category}"
    local subcategory="${2:-}"

    case "$category" in
        UPSTREAM)
            # All upstream errors are transient
            return 0
            ;;
        ENVIRONMENT)
            case "$subcategory" in
                network|oom)
                    return 0
                    ;;
                *)
                    return 1
                    ;;
            esac
            ;;
        AGENT_SCOPE|PIPELINE)
            return 1
            ;;
        *)
            # Unknown category — assume permanent
            return 1
            ;;
    esac
}

# --- suggest_recovery -------------------------------------------------------
# Returns a human-readable recovery suggestion for each error type.
#
# Usage: suggest_recovery CATEGORY SUBCATEGORY [CONTEXT]
# Output: Recovery string (printed to stdout)

suggest_recovery() {
    local category="${1:?suggest_recovery requires category}"
    local subcategory="${2:-unknown}"
    local context="${3:-}"

    case "${category}/${subcategory}" in
        UPSTREAM/api_500)
            echo "Anthropic API server error. Wait a few minutes and re-run the same command."
            ;;
        UPSTREAM/api_rate_limit)
            echo "API rate limit hit. Wait 60 seconds and re-run. Consider reducing concurrent API calls."
            ;;
        UPSTREAM/api_overloaded)
            echo "Anthropic API is overloaded. Wait a few minutes and re-run the same command."
            ;;
        UPSTREAM/api_auth)
            echo "API authentication failed. Check your ANTHROPIC_API_KEY and re-authenticate with 'claude auth'."
            ;;
        UPSTREAM/api_timeout)
            echo "API connection timed out. Check your network connection and re-run."
            ;;
        UPSTREAM/api_unknown)
            echo "Unrecognized API error. Check Anthropic status page and re-run."
            ;;
        ENVIRONMENT/disk_full)
            echo "Disk is full. Free up space and re-run."
            ;;
        ENVIRONMENT/network)
            echo "Network connectivity issue. Check your internet connection and DNS settings."
            ;;
        ENVIRONMENT/missing_dep)
            echo "A required command is not installed. Install the missing dependency and re-run."
            ;;
        ENVIRONMENT/permissions)
            echo "Permission denied. Check file/directory permissions and re-run."
            ;;
        ENVIRONMENT/oom)
            echo "Process was killed (likely OOM). Close other applications to free memory, or increase available RAM."
            ;;
        ENVIRONMENT/env_unknown)
            echo "Unexpected environment error. Check system logs for details."
            ;;
        AGENT_SCOPE/null_run)
            echo "Agent died before doing meaningful work. The prompt may be too large or the task too ambiguous. Try splitting the milestone or simplifying the task."
            ;;
        AGENT_SCOPE/max_turns)
            echo "Agent exhausted its turn budget. The task may be too large for the configured turn limit. Try splitting the milestone or increasing *_MAX_TURNS in pipeline.conf."
            ;;
        AGENT_SCOPE/activity_timeout)
            echo "Agent went silent (no output or file changes). Increase AGENT_ACTIVITY_TIMEOUT in pipeline.conf, or check if the agent is stuck in a retry loop."
            ;;
        AGENT_SCOPE/no_summary)
            echo "Agent completed but didn't produce expected output files. Re-run to retry."
            ;;
        AGENT_SCOPE/scope_unknown)
            echo "Agent completed without a clear outcome. Check the run log for details."
            ;;
        PIPELINE/state_corrupt)
            echo "Pipeline state file is corrupt. Delete ${context:-.claude/PIPELINE_STATE.md} and re-run from scratch."
            ;;
        PIPELINE/config_error)
            echo "Pipeline configuration error. Fix pipeline.conf and re-run."
            ;;
        PIPELINE/missing_file)
            echo "A required artifact file is missing. Re-run the pipeline from an earlier stage."
            ;;
        PIPELINE/template_error)
            echo "Prompt template failed to render. Check that the template exists in prompts/ and all required variables are set."
            ;;
        PIPELINE/internal)
            echo "Internal pipeline error. Check the run log for details. If this persists, file a bug."
            ;;
        *)
            echo "Unknown error. Check the run log for details."
            ;;
    esac
}

# --- redact_sensitive -------------------------------------------------------
# Strips sensitive patterns from text while preserving Anthropic request IDs.
#
# Usage: echo "$text" | redact_sensitive
#    or: redact_sensitive "$text"
#
# When called with an argument, redacts that string.
# When called with no argument, reads from stdin.

redact_sensitive() {
    local input=""
    if [[ $# -gt 0 ]]; then
        input="$1"
    else
        input=$(cat)
    fi

    # Preserve request IDs by temporarily replacing them
    # Anthropic request IDs: req_ followed by alphanumeric/hyphens
    local _req_placeholder="__TEKHTON_REQ_ID_PRESERVE__"

    # Multi-step sed pipeline for redaction
    echo "$input" | sed \
        -e "s/\(req_[A-Za-z0-9_-]\{8,\}\)/${_req_placeholder}\1${_req_placeholder}/g" \
        -e 's/[Xx]-[Aa][Pp][Ii]-[Kk][Ee][Yy][[:space:]]*:[[:space:]]*.*/x-api-key: [REDACTED]/g' \
        -e 's/[Aa]uthorization[[:space:]]*:[[:space:]]*.*/Authorization: [REDACTED]/g' \
        -e 's/sk-ant-[A-Za-z0-9_-]*/[REDACTED_API_KEY]/g' \
        -e 's/ANTHROPIC_API_KEY=[^ ]*/ANTHROPIC_API_KEY=[REDACTED]/g' \
        -e 's/api[_-]key[[:space:]]*=[[:space:]]*[^ ]*/api_key=[REDACTED]/g' \
        -e 's/[Bb][Ee][Aa][Rr][Ee][Rr] [A-Za-z0-9_.-]*/bearer [REDACTED]/g' \
        -e "s/${_req_placeholder}//g"
}

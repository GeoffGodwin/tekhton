#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# errors.sh — Error classification engine and taxonomy
#
# Sourced by tekhton.sh — do not run directly.
# Provides: classify_error(), is_transient()
# Also sources: lib/errors_helpers.sh (suggest_recovery, redact_sensitive)
#
# Milestone 12.1: Error taxonomy, classification, recovery, and redaction.
# =============================================================================

# Source helper functions (recovery suggestions and sensitive data redaction)
source "${TEKHTON_HOME:?}/lib/errors_helpers.sh"

# --- Error Taxonomy ---------------------------------------------------------
# For detailed taxonomy documentation, see lib/errors_helpers.sh header and
# the classify_error() implementation below.
#
# Summary:
#   UPSTREAM       — API provider failures (all transient): api_500, api_rate_limit,
#                    api_overloaded, api_auth, api_timeout, api_unknown
#   ENVIRONMENT    — Local system issues: disk_full, network, missing_dep,
#                    permissions, oom, env_unknown,
#                    env_setup (M53), service_dep (M53), toolchain (M53),
#                    resource (M53), test_infra (M53)
#   AGENT_SCOPE    — Expected agent failures (all permanent): null_run, max_turns,
#                    activity_timeout, no_summary, scope_unknown
#   PIPELINE       — Tekhton internal errors (all permanent): state_corrupt,
#                    config_error, missing_file, template_error, internal

# --- _match_pattern ---------------------------------------------------------
# Case-insensitive grep against a string. Returns 0 if matched.
# Uses grep -qiE for extended regex support.

_match_pattern() {
    local text="$1"
    local pattern="$2"
    printf '%s\n' "$text" | grep -qiE "$pattern" 2>/dev/null
}

# --- classify_error ---------------------------------------------------------
# Analyzes exit code, stderr content, and last output to produce a structured
# error record.
#
# Usage: classify_error EXIT_CODE [STDERR_FILE] [LAST_OUTPUT_FILE] [FILE_CHANGES] [TURNS] [HAS_SUMMARY]
# Output: CATEGORY|SUBCATEGORY|TRANSIENT|MESSAGE (printed to stdout)
#
# Parameters:
#   EXIT_CODE        - Process exit code (required)
#   STDERR_FILE      - Path to captured stderr (optional, "" to skip)
#   LAST_OUTPUT_FILE - Path to last agent output lines (optional, "" to skip)
#   FILE_CHANGES     - Count of files changed (optional, default 0)
#   TURNS            - Turn count from agent (optional, default 0)
#   HAS_SUMMARY      - Whether CODER_SUMMARY.md was produced (0=no, 1=yes, default 0)

classify_error() {
    local exit_code="${1:?classify_error requires exit_code}"
    local stderr_file="${2:-}"
    local last_output_file="${3:-}"
    local file_changes="${4:-0}"
    local turns="${5:-0}"
    local has_summary="${6:-0}"

    # Ensure numeric defaults
    [[ "$file_changes" =~ ^[0-9]+$ ]] || file_changes=0
    [[ "$turns" =~ ^[0-9]+$ ]] || turns=0
    [[ "$has_summary" =~ ^[01]$ ]] || has_summary=0

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
    # Authentication error — permanent: won't self-resolve on retry
    if _match_pattern "$combined" 'authentication_error' \
        || _match_pattern "$combined" 'invalid.api.key' \
        || _match_pattern "$combined" 'invalid.*x-api-key'; then
        echo "UPSTREAM|api_auth|false|API authentication error"
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

    # Successful exit but no summary file produced
    if [[ "$exit_code" -eq 0 ]] && [[ "$turns" -gt 0 ]] && [[ "$has_summary" -eq 0 ]]; then
        echo "AGENT_SCOPE|no_summary|false|Agent completed but produced no summary"
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

# --- is_transient() lives in errors_helpers.sh ---

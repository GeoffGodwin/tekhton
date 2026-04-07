#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# errors_helpers.sh — Recovery suggestions and sensitive data redaction
#
# Sourced by lib/errors.sh — do not run directly.
# Provides: suggest_recovery(), redact_sensitive()
#
# Milestone 12.1: Helper functions for error recovery and data safety.
# =============================================================================

# --- Error Recovery Suggestions -----------------------------------------------
# Reference the full error taxonomy in lib/errors.sh for categories/subcategories.
#
# Categories:
#   UPSTREAM       — API provider failures (all transient)
#   ENVIRONMENT    — Local system issues
#   AGENT_SCOPE    — Expected agent-level failures (all permanent)
#   PIPELINE       — Tekhton internal errors (all permanent)

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
        # M53: Pattern registry subcategories
        ENVIRONMENT/env_setup)
            echo "Missing tool or binary. Install the required dependency (check BUILD_ERRORS.md for the exact command)."
            ;;
        ENVIRONMENT/service_dep)
            echo "A required service is not running (database, cache, or queue). Start it and re-run."
            ;;
        ENVIRONMENT/toolchain)
            echo "Build toolchain issue (stale deps, missing codegen). Run the suggested install/generate command."
            ;;
        ENVIRONMENT/resource)
            echo "Machine resource constraint (port in use, OOM, disk full, permissions). Resolve the resource conflict and re-run."
            ;;
        ENVIRONMENT/test_infra)
            echo "Test infrastructure issue (stale snapshots, missing fixtures, timeout). Update test infrastructure and re-run."
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
    printf '%s\n' "$input" | sed \
        -e "s/\(req_[A-Za-z0-9_-]\{8,\}\)/${_req_placeholder}\1${_req_placeholder}/g" \
        -e 's/[Xx]-[Aa][Pp][Ii]-[Kk][Ee][Yy][[:space:]]*:[[:space:]]*.*/x-api-key: [REDACTED]/g' \
        -e 's/[Aa]uthorization[[:space:]]*:[[:space:]]*.*/Authorization: [REDACTED]/g' \
        -e 's/sk-ant-[A-Za-z0-9_-]*/[REDACTED_API_KEY]/g' \
        -e 's/ANTHROPIC_API_KEY=[^ ]*/ANTHROPIC_API_KEY=[REDACTED]/g' \
        -e 's/api[_-]key[[:space:]]*=[[:space:]]*[^ ]*/api_key=[REDACTED]/g' \
        -e 's/[Bb][Ee][Aa][Rr][Ee][Rr] [A-Za-z0-9_.-]*/bearer [REDACTED]/g' \
        -e "s/${_req_placeholder}//g"
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
            # Most upstream errors are transient — except auth failures,
            # which won't self-resolve on retry and need human action.
            if [[ "$subcategory" == "api_auth" ]]; then
                return 1
            fi
            return 0
            ;;
        ENVIRONMENT)
            case "$subcategory" in
                network|oom)
                    return 0
                    ;;
                # M53 subcategories — all permanent (require human/auto-remediation)
                env_setup|service_dep|toolchain|resource|test_infra)
                    return 1
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

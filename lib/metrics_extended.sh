#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# metrics_extended.sh — Extended stage metrics helpers
#
# Sourced by tekhton.sh after metrics.sh — do not run directly.
# Provides: _sanitize_numeric(), _collect_extended_stage_vars(),
#           _sanitize_all_metric_fields()
# =============================================================================

# _sanitize_numeric — Strip non-numeric content from a variable value.
# Usage: var=$(_sanitize_numeric "$var")
# Returns the last integer found in the string, or "0" if none.
_sanitize_numeric() {
    local val="$1"
    val=$(echo "$val" | grep -oE '[0-9]+' | tail -1)
    echo "${val:-0}"
}

# _collect_extended_stage_vars — Read extended stage turns/durations from
# _STAGE_TURNS and _STAGE_DURATION associative arrays.
# Sets caller-scoped variables (must be called with declare -n or eval).
# Args: output written to stdout as key=value pairs, one per line.
_collect_extended_stage_vars() {
    local security_turns=0 cleanup_turns=0
    local test_audit_turns=0 analyze_cleanup_turns=0
    local specialist_security_turns=0 specialist_perf_turns=0 specialist_api_turns=0
    local test_audit_duration_s=0 analyze_cleanup_duration_s=0

    if declare -p _STAGE_TURNS &>/dev/null; then
        security_turns="${_STAGE_TURNS[security]:-0}"
        cleanup_turns="${_STAGE_TURNS[cleanup]:-0}"
        test_audit_turns="${_STAGE_TURNS[test_audit]:-0}"
        analyze_cleanup_turns="${_STAGE_TURNS[analyze_cleanup]:-0}"
        specialist_security_turns="${_STAGE_TURNS[specialist_security]:-0}"
        specialist_perf_turns="${_STAGE_TURNS[specialist_perf]:-0}"
        specialist_api_turns="${_STAGE_TURNS[specialist_api]:-0}"
    fi

    if declare -p _STAGE_DURATION &>/dev/null; then
        test_audit_duration_s="${_STAGE_DURATION[test_audit]:-0}"
        analyze_cleanup_duration_s="${_STAGE_DURATION[analyze_cleanup]:-0}"
    fi

    local review_cycles="${REVIEW_CYCLE:-0}"
    local security_rework_cycles="${SECURITY_REWORK_CYCLES_DONE:-0}"

    # Sanitize
    security_turns=$(_sanitize_numeric "$security_turns")
    cleanup_turns=$(_sanitize_numeric "$cleanup_turns")
    test_audit_turns=$(_sanitize_numeric "$test_audit_turns")
    test_audit_duration_s=$(_sanitize_numeric "$test_audit_duration_s")
    analyze_cleanup_turns=$(_sanitize_numeric "$analyze_cleanup_turns")
    analyze_cleanup_duration_s=$(_sanitize_numeric "$analyze_cleanup_duration_s")
    specialist_security_turns=$(_sanitize_numeric "$specialist_security_turns")
    specialist_perf_turns=$(_sanitize_numeric "$specialist_perf_turns")
    specialist_api_turns=$(_sanitize_numeric "$specialist_api_turns")
    review_cycles=$(_sanitize_numeric "$review_cycles")
    security_rework_cycles=$(_sanitize_numeric "$security_rework_cycles")

    printf '%s\n' \
        "security_turns=${security_turns}" \
        "cleanup_turns=${cleanup_turns}" \
        "test_audit_turns=${test_audit_turns}" \
        "test_audit_duration_s=${test_audit_duration_s}" \
        "analyze_cleanup_turns=${analyze_cleanup_turns}" \
        "analyze_cleanup_duration_s=${analyze_cleanup_duration_s}" \
        "specialist_security_turns=${specialist_security_turns}" \
        "specialist_perf_turns=${specialist_perf_turns}" \
        "specialist_api_turns=${specialist_api_turns}" \
        "review_cycles=${review_cycles}" \
        "security_rework_cycles=${security_rework_cycles}"
}

# _append_extended_stage_record — Append extended stage fields to a JSONL record.
# Args: $1 = current record string (without closing brace)
# Reads variables from caller scope.
# Returns: updated record string on stdout.
_append_extended_stage_record() {
    local record="$1"
    local security_turns="$2" security_duration_s="$3"
    local cleanup_turns="$4" cleanup_duration_s="$5"
    local test_audit_turns="$6" test_audit_duration_s="$7"
    local analyze_cleanup_turns="$8" analyze_cleanup_duration_s="$9"
    local specialist_security_turns="${10}" specialist_perf_turns="${11}" specialist_api_turns="${12}"
    local review_cycles="${13}" security_rework_cycles="${14}"

    if [[ "$security_turns" -gt 0 ]]; then
        record="${record},\"security_turns\":${security_turns},\"security_duration_s\":${security_duration_s}"
    fi
    if [[ "$cleanup_turns" -gt 0 ]]; then
        record="${record},\"cleanup_turns\":${cleanup_turns},\"cleanup_duration_s\":${cleanup_duration_s}"
    fi
    if [[ "$test_audit_turns" -gt 0 ]]; then
        record="${record},\"test_audit_turns\":${test_audit_turns},\"test_audit_duration_s\":${test_audit_duration_s}"
    fi
    if [[ "$analyze_cleanup_turns" -gt 0 ]]; then
        record="${record},\"analyze_cleanup_turns\":${analyze_cleanup_turns},\"analyze_cleanup_duration_s\":${analyze_cleanup_duration_s}"
    fi
    if [[ "$specialist_security_turns" -gt 0 ]]; then
        record="${record},\"specialist_security_turns\":${specialist_security_turns}"
    fi
    if [[ "$specialist_perf_turns" -gt 0 ]]; then
        record="${record},\"specialist_perf_turns\":${specialist_perf_turns}"
    fi
    if [[ "$specialist_api_turns" -gt 0 ]]; then
        record="${record},\"specialist_api_turns\":${specialist_api_turns}"
    fi
    if [[ "$review_cycles" -gt 0 ]]; then
        record="${record},\"review_cycles\":${review_cycles}"
    fi
    if [[ "$security_rework_cycles" -gt 0 ]]; then
        record="${record},\"security_rework_cycles\":${security_rework_cycles}"
    fi

    printf '%s' "$record"
}

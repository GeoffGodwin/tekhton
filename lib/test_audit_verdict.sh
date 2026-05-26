#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# test_audit_verdict.sh — Test audit verdict parsing and routing
#
# Sourced by tekhton.sh — do not run directly.
# Expects: common.sh sourced first.
#
# Provides:
#   _parse_audit_verdict — Extract verdict from "${TEST_AUDIT_REPORT_FILE}"
#   _route_audit_verdict — Handle PASS/CONCERNS/NEEDS_WORK verdicts
# =============================================================================

# _parse_audit_verdict
# Extracts the verdict from "${TEST_AUDIT_REPORT_FILE}".
# Returns: PASS, CONCERNS, or NEEDS_WORK (defaults to PASS if unparseable)
_parse_audit_verdict() {
    local report_file="${TEST_AUDIT_REPORT_FILE:-}"
    if [[ ! -f "$report_file" ]]; then
        echo "PASS"
        return
    fi

    local verdict
    verdict=$(grep -oiE 'Verdict:\s*(NEEDS_WORK|PASS|CONCERNS)' "$report_file" 2>/dev/null \
        | head -1 | sed 's/.*:\s*//' | tr '[:lower:]' '[:upper:]' || true)

    case "$verdict" in
        NEEDS_WORK) echo "NEEDS_WORK" ;;
        CONCERNS)   echo "CONCERNS" ;;
        *)          echo "PASS" ;;
    esac
}

# _route_audit_verdict VERDICT
# Routes based on audit verdict:
#   PASS       → continue (no action)
#   CONCERNS   → log findings to "${NON_BLOCKING_LOG_FILE}", continue
#   NEEDS_WORK → tester rework (bounded by TEST_AUDIT_MAX_REWORK_CYCLES)
_route_audit_verdict() {
    local verdict="$1"
    local report_file="${TEST_AUDIT_REPORT_FILE:-}"

    case "$verdict" in
        PASS)
            success "Test audit passed — all tests meet integrity standards."
            return 0
            ;;
        CONCERNS)
            warn "Test audit raised concerns — logging to ${NON_BLOCKING_LOG_FILE:-.tekhton/NON_BLOCKING_LOG.md}."
            if [[ -f "$report_file" ]]; then
                local findings
                findings=$(grep -E '^\s*####\s+(INTEGRITY|SCOPE|COVERAGE|WEAKENING|NAMING)' "$report_file" 2>/dev/null || true)
                if [[ -n "$findings" ]] && command -v _ensure_nonblocking_log &>/dev/null; then
                    _ensure_nonblocking_log
                    local nb_file="${NON_BLOCKING_LOG_FILE:-}"
                    {
                        echo ""
                        echo "### Test Audit Concerns ($(date +%Y-%m-%d))"
                        echo "$findings"
                    } >> "$nb_file"
                fi
            fi
            return 0
            ;;
        NEEDS_WORK)
            warn "Test audit verdict: NEEDS_WORK — routing to tester for rework."
            return 1
            ;;
        *)
            warn "Unknown test audit verdict: '${verdict}' — treating as PASS."
            return 0
            ;;
    esac
}

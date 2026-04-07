#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# preflight.sh — Pre-flight environment validation
#
# Sourced by tekhton.sh — do not run directly.
# Provides: run_preflight_checks()
# Depends on: common.sh (log, warn, error, success), detect.sh, detect_test_frameworks.sh
#
# Milestone 55: Pre-flight Environment Validation.
#
# Runs fast, deterministic checks BEFORE agent invocation to catch environment
# issues (stale deps, missing tools, env vars, version mismatches) that would
# waste turns in the build gate. No network calls, no agent invocations.
#
# Check implementations live in extracted files:
#   - preflight_checks.sh     — Checks 1-4 (deps, tools, codegen, env vars)
#   - preflight_checks_env.sh — Checks 5-7 (runtime versions, ports, lock freshness)
# =============================================================================

# --- Preflight state ---------------------------------------------------------
_PF_PASS=0
_PF_WARN=0
_PF_FAIL=0
_PF_REMEDIATED=0
_PF_REPORT_LINES=()

# --- _pf_record --------------------------------------------------------------
# Records a check result and appends a report line.
# Args: $1=status (pass|warn|fail|fixed), $2=check_name, $3=detail
_pf_record() {
    local status="$1" name="$2" detail="$3"
    case "$status" in
        pass)  _PF_PASS=$((_PF_PASS + 1));  _PF_REPORT_LINES+=("### ✓ ${name}"); ;;
        warn)  _PF_WARN=$((_PF_WARN + 1));  _PF_REPORT_LINES+=("### ⚠ ${name}"); ;;
        fail)  _PF_FAIL=$((_PF_FAIL + 1));  _PF_REPORT_LINES+=("### ✗ ${name}"); ;;
        fixed) _PF_REMEDIATED=$((_PF_REMEDIATED + 1)); _PF_REPORT_LINES+=("### 🔧 ${name}"); ;;
    esac
    _PF_REPORT_LINES+=("${detail}")
    _PF_REPORT_LINES+=("")
}

# --- _pf_try_fix -------------------------------------------------------------
# Attempts auto-remediation of a safe issue. Returns 0 on success, 1 on failure.
# Args: $1=command, $2=check_name, $3=diagnosis
_pf_try_fix() {
    local cmd="$1" name="$2" diagnosis="$3"

    if [[ "${PREFLIGHT_AUTO_FIX:-true}" != "true" ]]; then
        _pf_record "fail" "$name" "${diagnosis} Auto-fix disabled."
        return 1
    fi

    if command -v _run_safe_remediation &>/dev/null; then
        local start_ts=$SECONDS
        _run_safe_remediation "$cmd" >/dev/null 2>&1 && {
            local dur=$(( SECONDS - start_ts ))
            _pf_record "fixed" "$name" "${diagnosis} Auto-fixed: \`${cmd}\` (${dur}s)"
            if command -v emit_event &>/dev/null; then
                emit_event "preflight_fix" "preflight" \
                    "check=${name} command=${cmd} duration_s=${dur}" "" "" "" > /dev/null 2>&1 || true
            fi
            return 0
        }
        _pf_record "fail" "$name" "${diagnosis} Auto-fix failed: \`${cmd}\`"
        return 1
    fi

    # No remediation engine available — report as failure
    _pf_record "fail" "$name" "${diagnosis} Fix: \`${cmd}\`"
    return 1
}

# --- _pf_detect_languages_cached ---------------------------------------------
# Calls detect_languages once and caches for this preflight run.
_PF_LANGUAGES=""
_pf_detect_languages() {
    if [[ -z "$_PF_LANGUAGES" ]]; then
        _PF_LANGUAGES=$(detect_languages "${PROJECT_DIR:-.}" 2>/dev/null || true)
    fi
    echo "$_PF_LANGUAGES"
}

# --- _pf_has_language --------------------------------------------------------
# Returns 0 if the given language was detected.
_pf_has_language() {
    local lang="$1"
    _pf_detect_languages | grep -qi "^${lang}|" 2>/dev/null
}

# --- _pf_detect_test_frameworks_cached ---------------------------------------
_PF_TEST_FWS=""
_pf_detect_test_frameworks() {
    if [[ -z "$_PF_TEST_FWS" ]]; then
        if command -v detect_test_frameworks &>/dev/null; then
            _PF_TEST_FWS=$(detect_test_frameworks "${PROJECT_DIR:-.}" 2>/dev/null || true)
        fi
    fi
    echo "$_PF_TEST_FWS"
}

# =============================================================================
# Report Emitter
# =============================================================================
_emit_preflight_report() {
    local proj="${PROJECT_DIR:-.}"
    local report_file="$proj/PREFLIGHT_REPORT.md"
    local timestamp
    timestamp=$(date +"%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "unknown")

    {
        echo "# Pre-flight Report — ${timestamp}"
        echo ""
        echo "## Summary"
        echo "✓ ${_PF_PASS} passed  ⚠ ${_PF_WARN} warned  ✗ ${_PF_FAIL} failed  🔧 ${_PF_REMEDIATED} auto-fixed"
        echo ""
        echo "## Checks"
        echo ""
        local line
        for line in "${_PF_REPORT_LINES[@]}"; do
            echo "$line"
        done

        # Emit services section if preflight_services.sh is loaded
        if command -v _pf_emit_services_report &>/dev/null; then
            _pf_emit_services_report
        fi
    } > "$report_file"
}

# =============================================================================
# Main Orchestrator
# =============================================================================
run_preflight_checks() {
    # Skip if disabled
    [[ "${PREFLIGHT_ENABLED:-true}" == "true" ]] || return 0

    log "Running pre-flight environment checks..."

    # Reset state
    _PF_PASS=0
    _PF_WARN=0
    _PF_FAIL=0
    _PF_REMEDIATED=0
    _PF_REPORT_LINES=()
    _PF_LANGUAGES=""
    _PF_TEST_FWS=""

    # Run all checks (implementations in preflight_checks.sh + preflight_checks_env.sh)
    _preflight_check_dependencies
    _preflight_check_tools
    _preflight_check_generated_code
    _preflight_check_env_vars
    _preflight_check_runtime_version
    _preflight_check_ports
    _preflight_check_lock_freshness

    # Service readiness probing (M56) — requires preflight_services.sh
    if command -v _preflight_check_docker &>/dev/null; then
        _preflight_check_docker
        _preflight_check_services
        _preflight_check_dev_server
    fi

    # Skip report if nothing was checked
    local total=$(( _PF_PASS + _PF_WARN + _PF_FAIL + _PF_REMEDIATED ))
    if [[ "$total" -eq 0 ]]; then
        log "Pre-flight: no checks applicable (no ecosystem markers found)."
        return 0
    fi

    # Emit report
    _emit_preflight_report

    # Log summary
    local summary="Pre-flight: ${_PF_PASS} passed, ${_PF_WARN} warned, ${_PF_FAIL} failed, ${_PF_REMEDIATED} auto-fixed"
    if [[ "$_PF_FAIL" -gt 0 ]]; then
        error "$summary"
        error "Pre-flight failed: ${_PF_FAIL} blocking issue(s). See PREFLIGHT_REPORT.md."
        return 1
    elif [[ "$_PF_WARN" -gt 0 ]] && [[ "${PREFLIGHT_FAIL_ON_WARN:-false}" == "true" ]]; then
        warn "$summary"
        error "Pre-flight failed: PREFLIGHT_FAIL_ON_WARN is set. See PREFLIGHT_REPORT.md."
        return 1
    elif [[ "$_PF_WARN" -gt 0 ]]; then
        warn "$summary"
    else
        success "$summary"
    fi

    # Emit causal event
    if command -v emit_event &>/dev/null; then
        emit_event "preflight_complete" "preflight" \
            "pass=${_PF_PASS} warn=${_PF_WARN} fail=${_PF_FAIL} fixed=${_PF_REMEDIATED}" \
            "" "" "" > /dev/null 2>&1 || true
    fi

    return 0
}

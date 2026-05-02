#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# validate_config_arc.sh — Resilience arc config sanity checks (M136)
#
# Sourced by lib/validate_config.sh — do not run directly.
# Provides: _vc_check_resilience_arc()
#
# All checks mutate validate_config()'s passes/warnings/errors counters via
# shell dynamic scope, matching the style of the other helpers in
# validate_config.sh (_vc_check_role_files, _vc_check_manifest, etc).
# =============================================================================

# _vc_check_resilience_arc — Validates resilience arc config values.
# Numeric/range errors fail the run; intent/compatibility issues warn.
_vc_check_resilience_arc() {
    echo ""
    echo "  [Resilience Arc]"

    # Check A: BUILD_FIX_MAX_ATTEMPTS — positive integer 1–20
    local bfa="${BUILD_FIX_MAX_ATTEMPTS:-3}"
    if [[ "$bfa" =~ ^[0-9]+$ ]] && (( bfa >= 1 && bfa <= 20 )); then
        _vc_pass "BUILD_FIX_MAX_ATTEMPTS=${bfa} (valid)"
        passes=$((passes + 1))
    else
        _vc_fail "BUILD_FIX_MAX_ATTEMPTS=${bfa} — must be integer 1–20"
        errors=$((errors + 1))
    fi

    # Check B: BUILD_FIX_BASE_TURN_DIVISOR — positive integer 1–20
    local bfd="${BUILD_FIX_BASE_TURN_DIVISOR:-3}"
    if [[ "$bfd" =~ ^[0-9]+$ ]] && (( bfd >= 1 && bfd <= 20 )); then
        _vc_pass "BUILD_FIX_BASE_TURN_DIVISOR=${bfd} (valid)"
        passes=$((passes + 1))
    else
        _vc_fail "BUILD_FIX_BASE_TURN_DIVISOR=${bfd} — must be integer 1–20"
        errors=$((errors + 1))
    fi

    # Check C: UI_GATE_ENV_RETRY_TIMEOUT_FACTOR — decimal in [0.1, 1.0]
    # Bash cannot compare floats; awk is universal and already used elsewhere.
    local rtf="${UI_GATE_ENV_RETRY_TIMEOUT_FACTOR:-0.5}"
    local rtf_ok
    rtf_ok=$(awk -v v="$rtf" 'BEGIN { print (v+0 >= 0.1 && v+0 <= 1.0) ? "ok" : "fail" }')
    if [[ "$rtf_ok" == "ok" ]]; then
        _vc_pass "UI_GATE_ENV_RETRY_TIMEOUT_FACTOR=${rtf} (valid, 0.1–1.0)"
        passes=$((passes + 1))
    else
        _vc_warn "UI_GATE_ENV_RETRY_TIMEOUT_FACTOR=${rtf} — expected decimal 0.1–1.0; using 0.5"
        warnings=$((warnings + 1))
    fi

    # Check D: TEKHTON_UI_GATE_FORCE_NONINTERACTIVE — binary flag (0 or 1)
    local fni="${TEKHTON_UI_GATE_FORCE_NONINTERACTIVE:-0}"
    if [[ "$fni" == "0" || "$fni" == "1" ]]; then
        _vc_pass "TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=${fni} (valid)"
        passes=$((passes + 1))
    else
        _vc_warn "TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=${fni} — expected 0 or 1"
        warnings=$((warnings + 1))
    fi

    # Check E: PREFLIGHT_BAK_RETAIN_COUNT — non-negative integer (0=keep all)
    local pbr="${PREFLIGHT_BAK_RETAIN_COUNT:-5}"
    if [[ "$pbr" =~ ^[0-9]+$ ]]; then
        _vc_pass "PREFLIGHT_BAK_RETAIN_COUNT=${pbr} (valid)"
        passes=$((passes + 1))
    else
        _vc_fail "PREFLIGHT_BAK_RETAIN_COUNT=${pbr} — must be non-negative integer (0 = keep all)"
        errors=$((errors + 1))
    fi

    # Check F: UI_TEST_CMD set + retry disabled = surfaced operator-intent mismatch.
    # Disabling retry is a valid choice (e.g. perf suites that always run full
    # timeout); the warning is informational, not blocking.
    if [[ -n "${UI_TEST_CMD:-}" ]] && [[ "${UI_GATE_ENV_RETRY_ENABLED:-true}" == "false" ]]; then
        _vc_warn "UI_GATE_ENV_RETRY_ENABLED=false with UI_TEST_CMD set — interactive reporter timeouts will not be auto-retried"
        warnings=$((warnings + 1))
    else
        _vc_pass "UI gate retry configuration consistent"
        passes=$((passes + 1))
    fi
}

#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# diagnose_rules_resilience_preflight.sh — M131/M133 preflight-config rule
#
# Sourced by lib/diagnose_rules_resilience.sh — do not run directly.
# Extracted to keep the parent file under the 300-line ceiling.
# Expects: _DIAG_* module state populated by _read_diagnostic_context()
# Expects: DIAG_CLASSIFICATION, DIAG_CONFIDENCE, DIAG_SUGGESTIONS (shared globals)
# Expects: PROJECT_DIR, TEKHTON_DIR (set by caller)
# =============================================================================

# _rule_preflight_interactive_config
# Diagnose the case where preflight already detected an interactive
# Playwright reporter configuration but the gate-level evidence isn't
# strong enough for _rule_ui_gate_interactive_reporter to fire. Fallback,
# not preferred match — must be ordered after the gate-level rule.
_rule_preflight_interactive_config() {
    local summary_file="${PROJECT_DIR:-.}/.claude/logs/RUN_SUMMARY.json"
    local preflight_report="${PROJECT_DIR:-.}/${TEKHTON_DIR:-.tekhton}/PREFLIGHT_REPORT.md"
    local failure_ctx="${PROJECT_DIR:-.}/.claude/LAST_FAILURE_CONTEXT.json"

    local matched=false
    local cfg_file=""

    # Source 1: RUN_SUMMARY.json preflight_ui section.
    if [[ -f "$summary_file" ]]; then
        local section
        section=$(awk '/"preflight_ui"[[:space:]]*:/{f=1} f{print; if(/\}/){exit}}' "$summary_file" 2>/dev/null || true)
        if [[ -n "$section" ]]; then
            local detected patched
            detected=$(printf '%s' "$section" | grep -oP '"interactive_config_detected"\s*:\s*\K(true|false)' | head -1 || true)
            patched=$(printf '%s' "$section" | grep -oP '"reporter_auto_patched"\s*:\s*\K(true|false)' | head -1 || true)
            cfg_file=$(printf '%s' "$section" | grep -oP '"interactive_config_file"\s*:\s*"\K[^"]*' | head -1 || true)
            if [[ "$detected" = "true" ]] && [[ "$patched" = "false" ]]; then
                matched=true
            fi
        fi
    fi

    # Source 2: PREFLIGHT_REPORT.md fail entry (m131 frozen heading).
    if [[ "$matched" != true ]] && [[ -f "$preflight_report" ]]; then
        if grep -qF 'UI Config (Playwright) — html reporter' "$preflight_report" 2>/dev/null \
           && grep -qiE '(^|[^a-z])(fail|FAIL)([^a-z]|$)' "$preflight_report" 2>/dev/null; then
            matched=true
        fi
    fi

    # Source 3: LAST_FAILURE_CONTEXT.json explicit preflight-config signal.
    if [[ "$matched" != true ]] && [[ "${_DIAG_PRIMARY_SIGNAL:-}" = "ui_interactive_config_preflight" ]]; then
        matched=true
    fi
    if [[ "$matched" != true ]] && [[ -f "$failure_ctx" ]]; then
        if grep -q '"classification"\s*:\s*"PREFLIGHT_INTERACTIVE_CONFIG"' "$failure_ctx" 2>/dev/null; then
            matched=true
        fi
    fi

    [[ "$matched" = true ]] || return 1
    local _task="${_DIAG_PIPELINE_TASK:-${TASK:-<task not recorded>}}"
    local cfg_label="${cfg_file:-playwright.config.ts}"
    # shellcheck disable=SC2034
    DIAG_CLASSIFICATION="PREFLIGHT_INTERACTIVE_CONFIG"
    # shellcheck disable=SC2034
    DIAG_CONFIDENCE="high"
    # shellcheck disable=SC2034
    DIAG_SUGGESTIONS=(
        "Preflight detected an interactive Playwright reporter configuration."
        "${cfg_label} sets reporter: 'html', which would hang the UI gate."
        "Manual fix in ${cfg_label}:"
        "  Change:  reporter: 'html'"
        "  To:      reporter: process.env.CI ? 'dot' : 'html'"
        "Or enable auto-fix (pipeline.conf):"
        "  PREFLIGHT_UI_CONFIG_AUTO_FIX=true"
        "Then re-run:"
        "  tekhton --complete --milestone \"${_task}\""
    )
    return 0
}

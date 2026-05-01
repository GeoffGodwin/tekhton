#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# diagnose_rules_resilience.sh — M133 resilience-arc diagnose rules
#
# Sourced by lib/diagnose_rules.sh — do not run directly.
# Expects: _DIAG_* module state populated by _read_diagnostic_context()
# Expects: DIAG_CLASSIFICATION, DIAG_CONFIDENCE, DIAG_SUGGESTIONS (shared globals)
# Expects: PROJECT_DIR, BUILD_ERRORS_FILE, BUILD_RAW_ERRORS_FILE,
#          BUILD_FIX_REPORT_FILE, TEKHTON_DIR (set by caller)
#
# Provides three primary rules consumed by the resilience arc (m126–m132):
#   _rule_ui_gate_interactive_reporter — Playwright html-reporter timeout
#   _rule_build_fix_exhausted          — m128 build-fix loop give-up
#   _rule_preflight_interactive_config — m131 preflight detected interactive cfg
#
# Output classifications are public diagnose vocabulary (seeds-forward to m134
# integration tests, m138 CI auto-detect, future dashboard summarisation):
#   UI_GATE_INTERACTIVE_REPORTER, BUILD_FIX_EXHAUSTED, PREFLIGHT_INTERACTIVE_CONFIG
# =============================================================================

# _rule_ui_gate_interactive_reporter
# Detect UI gate timeout caused by Playwright opening an interactive HTML
# reporter (`reporter: 'html'`). Sources (highest-confidence first):
#   1. LAST_FAILURE_CONTEXT.json primary_cause.signal
#      `ui_timeout_interactive_report`                                  → high
#   2. LAST_FAILURE_CONTEXT.json classification UI_INTERACTIVE_REPORTER → high
#   3. Raw log evidence in BUILD_RAW_ERRORS_FILE or .claude/logs/       → medium
#   4. RUN_SUMMARY.json primary_signal+route_taken correlation          → medium
_rule_ui_gate_interactive_reporter() {
    local failure_ctx="${PROJECT_DIR:-.}/.claude/LAST_FAILURE_CONTEXT.json"
    local raw_errors="${PROJECT_DIR:-.}/${BUILD_RAW_ERRORS_FILE:-${TEKHTON_DIR:-.tekhton}/BUILD_RAW_ERRORS.txt}"
    local summary_file="${PROJECT_DIR:-.}/.claude/logs/RUN_SUMMARY.json"
    local logs_dir="${PROJECT_DIR:-.}/.claude/logs"

    local matched=false
    local confidence="medium"

    # Source 1: v2 primary signal
    if [[ "${_DIAG_PRIMARY_SIGNAL:-}" = "ui_timeout_interactive_report" ]]; then
        matched=true
        confidence="high"
    fi

    # Source 2: classification field
    if [[ "$matched" != true ]] && [[ "${_DIAG_LAST_CLASSIFICATION:-}" = "UI_INTERACTIVE_REPORTER" ]]; then
        matched=true
        confidence="high"
    fi

    # Source 3: raw log evidence — current run only
    if [[ "$matched" != true ]]; then
        if [[ -s "$raw_errors" ]] && grep -qE 'Serving HTML report at|Press Ctrl\+C to quit' "$raw_errors" 2>/dev/null; then
            matched=true
            confidence="medium"
        fi
    fi
    if [[ "$matched" != true ]] && [[ -d "$logs_dir" ]]; then
        # Recursive scan with no depth/file-count cap: acceptable because
        # diagnose is a manually-invoked tool. Large log archives may incur
        # a one-time cost; rotation is the operator's responsibility.
        if grep -rqlE 'Serving HTML report at|Press Ctrl\+C to quit' "$logs_dir" 2>/dev/null; then
            matched=true
            confidence="medium"
        fi
    fi

    # Source 4: RUN_SUMMARY.json correlation
    if [[ "$matched" != true ]] && [[ -f "$summary_file" ]]; then
        local sig route
        sig=$(grep -oP '"primary_signal"\s*:\s*"\K[^"]+' "$summary_file" 2>/dev/null | head -1 || true)
        route=$(grep -oP '"route_taken"\s*:\s*"\K[^"]+' "$summary_file" 2>/dev/null | head -1 || true)
        if [[ "$sig" = "ui_timeout_interactive_report" ]] && [[ "$route" = "retry_ui_gate_env" ]]; then
            matched=true
            confidence="medium"
        fi
    fi

    [[ "$matched" = true ]] || return 1

    local _task="${_DIAG_PIPELINE_TASK:-${TASK:-<task not recorded>}}"

    # Locate Playwright config in priority order. Detect whether it is already
    # CI-guarded so we don't tell the user to re-apply a fix that's already there.
    local cfg=""
    local f
    for f in playwright.config.ts playwright.config.js playwright.config.mjs playwright.config.cjs; do
        if [[ -f "${PROJECT_DIR:-.}/$f" ]]; then
            cfg="$f"
            break
        fi
    done

    local ci_guarded=false
    if [[ -n "$cfg" ]] && [[ -f "${PROJECT_DIR:-.}/$cfg" ]]; then
        if grep -qE "process\.env\.CI[^?]*\?[^:]*:[^,}]*['\"]html['\"]" "${PROJECT_DIR:-.}/$cfg" 2>/dev/null; then
            ci_guarded=true
        fi
    fi

    # shellcheck disable=SC2034
    DIAG_CLASSIFICATION="UI_GATE_INTERACTIVE_REPORTER"
    # shellcheck disable=SC2034
    DIAG_CONFIDENCE="$confidence"
    # shellcheck disable=SC2034
    DIAG_SUGGESTIONS=(
        "The UI gate timed out because Playwright opened an interactive HTML reporter."
        "Reporter 'html' starts a serve-and-wait loop that never returns to the gate."
    )
    if [[ "$ci_guarded" = true ]] && [[ -n "$cfg" ]]; then
        DIAG_SUGGESTIONS+=(
            "Note: ${cfg} already appears CI-guarded (process.env.CI ? ... : 'html')."
            "The failure may have come from stale artifacts or an alternate config surface."
        )
    elif [[ -n "$cfg" ]]; then
        DIAG_SUGGESTIONS+=(
            "Fix in ${cfg}:"
            "  Change:  reporter: 'html'"
            "  To:      reporter: process.env.CI ? 'dot' : 'html'"
        )
    else
        DIAG_SUGGESTIONS+=(
            "No playwright.config.{ts,js,mjs,cjs} found at the repo root."
            "Search the test runner config and replace reporter: 'html' with a CI-guarded form."
        )
    fi
    DIAG_SUGGESTIONS+=(
        "Workaround without source edits:"
        "  CI=1 tekhton --complete --milestone \"${_task}\""
        "Then re-run normally:"
        "  tekhton --complete --milestone \"${_task}\""
    )
    return 0
}

# _rule_build_fix_exhausted
# Detect "build failed and the m128 build-fix continuation loop already spent
# its budget". More specific than generic BUILD_FAILURE — must be ordered
# before _rule_build_failure.
#
# Detection sources, listed in evaluation order (highest-confidence first):
#   1. RUN_SUMMARY.json build_fix_stats.outcome = exhausted|no_progress
#      AND build_fix_stats.attempts >= 2 — most reliable when present.
#   2. ${BUILD_FIX_REPORT_FILE} exists with multi-attempt evidence
#      (counts ## Attempt headings; falls back when RUN_SUMMARY is absent).
#   3. LAST_FAILURE_CONTEXT.json secondary signal `build_fix_budget_exhausted`.
#
# Required guard: at least one build-error artifact (BUILD_ERRORS_FILE or
# BUILD_RAW_ERRORS_FILE) must be non-empty so a stale historical report does
# not produce a false positive on a successful run.
_rule_build_fix_exhausted() {
    local report="${PROJECT_DIR:-.}/${BUILD_FIX_REPORT_FILE:-${TEKHTON_DIR:-.tekhton}/BUILD_FIX_REPORT.md}"
    local errors_file="${PROJECT_DIR:-.}/${BUILD_ERRORS_FILE:-${TEKHTON_DIR:-.tekhton}/BUILD_ERRORS.md}"
    local raw_errors="${PROJECT_DIR:-.}/${BUILD_RAW_ERRORS_FILE:-${TEKHTON_DIR:-.tekhton}/BUILD_RAW_ERRORS.txt}"
    local summary_file="${PROJECT_DIR:-.}/.claude/logs/RUN_SUMMARY.json"

    # Required guard: current run must still have build-failure artifacts.
    local has_artifacts=false
    [[ -s "$errors_file" ]] && has_artifacts=true
    [[ -s "$raw_errors" ]] && has_artifacts=true
    [[ "$has_artifacts" = true ]] || return 1

    local outcome=""
    local attempts=0

    # Source 1: RUN_SUMMARY.json build_fix_stats — most reliable when present.
    if [[ -f "$summary_file" ]]; then
        local section
        section=$(awk '/"build_fix_stats"[[:space:]]*:/{f=1} f{print; if(/\}/){exit}}' "$summary_file" 2>/dev/null || true)
        if [[ -n "$section" ]]; then
            local s_oc s_att
            s_oc=$(printf '%s' "$section" | grep -oP '"outcome"\s*:\s*"\K[^"]+' | head -1 || true)
            s_att=$(printf '%s' "$section" | grep -oP '"attempts"\s*:\s*\K[0-9]+' | head -1 || true)
            s_att="${s_att//[!0-9]/}"
            : "${s_att:=0}"
            if [[ "$s_oc" = "exhausted" || "$s_oc" = "no_progress" ]] && [[ "$s_att" -ge 2 ]]; then
                outcome="$s_oc"
                attempts="$s_att"
            fi
        fi
    fi

    # Source 2: BUILD_FIX_REPORT.md — count attempts and infer no_progress.
    if [[ -z "$outcome" ]] && [[ -f "$report" ]]; then
        local rep_attempts
        rep_attempts=$(grep -c '^## Attempt ' "$report" 2>/dev/null || true)
        rep_attempts="${rep_attempts//[!0-9]/}"
        : "${rep_attempts:=0}"
        if [[ "$rep_attempts" -ge 2 ]]; then
            attempts="$rep_attempts"
            local last_progress
            last_progress=$(grep -E '^- Progress signal:' "$report" 2>/dev/null | tail -1 || true)
            if [[ "$last_progress" == *unchanged* || "$last_progress" == *worsened* ]]; then
                outcome="no_progress"
            else
                outcome="exhausted"
            fi
        fi
    fi

    # Source 3: LAST_FAILURE_CONTEXT.json secondary signal.
    if [[ -z "$outcome" ]] && [[ "${_DIAG_SECONDARY_SIGNAL:-}" = "build_fix_budget_exhausted" ]]; then
        outcome="exhausted"
        [[ "$attempts" -gt 0 ]] || attempts="${BUILD_FIX_MAX_ATTEMPTS:-3}"
    fi

    [[ -n "$outcome" ]] || return 1

    local _task="${_DIAG_PIPELINE_TASK:-${TASK:-<task not recorded>}}"
    local errors_path="${BUILD_ERRORS_FILE:-${TEKHTON_DIR:-.tekhton}/BUILD_ERRORS.md}"
    local report_path="${BUILD_FIX_REPORT_FILE:-${TEKHTON_DIR:-.tekhton}/BUILD_FIX_REPORT.md}"

    # shellcheck disable=SC2034
    DIAG_CLASSIFICATION="BUILD_FIX_EXHAUSTED"
    # shellcheck disable=SC2034
    DIAG_CONFIDENCE="high"
    # shellcheck disable=SC2034
    if [[ "$outcome" = "no_progress" ]]; then
        DIAG_SUGGESTIONS=(
            "Build-fix loop halted after ${attempts} attempt(s) with no measurable progress."
            "The agent's edits did not reduce the build-error count between attempts."
        )
    else
        DIAG_SUGGESTIONS=(
            "Build-fix loop exhausted its budget after ${attempts} attempt(s)."
            "The continuation loop reached BUILD_FIX_MAX_ATTEMPTS without a passing gate."
        )
    fi
    DIAG_SUGGESTIONS+=(
        "Read the per-attempt postmortem: cat ${report_path}"
        "Read the underlying errors: cat ${errors_path}"
        "Options:"
        "  1. Fix manually then resume from coder:"
        "     tekhton --complete --milestone --start-at coder \"${_task}\""
        "  2. Allow more attempts (pipeline.conf: BUILD_FIX_MAX_ATTEMPTS=N) and retry:"
        "     tekhton --complete --milestone \"${_task}\""
        "  3. Raise the cumulative cap (pipeline.conf: BUILD_FIX_TOTAL_TURN_CAP) for harder bugs."
    )
    return 0
}

# _rule_preflight_interactive_config lives in a sibling file to keep this
# file under the 300-line ceiling.
# shellcheck source=lib/diagnose_rules_resilience_preflight.sh
source "${TEKHTON_HOME:?}/lib/diagnose_rules_resilience_preflight.sh"

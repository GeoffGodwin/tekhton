#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# gates_ui_helpers.sh — Helpers for deterministic UI gate execution (M126)
#
# Sourced by tekhton.sh after gates_ui.sh — do not run directly.
# Provides:
#   _ui_detect_framework
#   _ui_deterministic_env_list
#   _normalize_ui_gate_env
#   _ui_timeout_signature
#   _ui_hardened_timeout
#   _ui_write_gate_diagnosis
# =============================================================================

# _ui_detect_framework
# Echoes one of: playwright | none
# Priority 0 (M130): TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=1 forces playwright
#   regardless of detected framework, so the M130 retry_ui_gate_env recovery
#   branch reliably triggers the hardened env profile on the next gate run.
# Priority 1+: UI_FRAMEWORK config → UI_TEST_CMD word-boundary regex →
#              playwright.config.{ts,js,mjs,cjs} in PROJECT_DIR
# M126 only branches on `playwright`; other values short-circuit to "none".
_ui_detect_framework() {
    if [[ "${TEKHTON_UI_GATE_FORCE_NONINTERACTIVE:-}" = "1" ]]; then
        echo "playwright"
        return 0
    fi

    if [[ "${UI_FRAMEWORK:-}" == "playwright" ]]; then
        echo "playwright"
        return 0
    fi

    if [[ -n "${UI_TEST_CMD:-}" ]] \
       && [[ "$UI_TEST_CMD" =~ (^|[[:space:]/])playwright([[:space:]]|$) ]]; then
        echo "playwright"
        return 0
    fi

    local _pd="${PROJECT_DIR:-.}"
    local _ext
    for _ext in ts js mjs cjs; do
        if [[ -f "${_pd}/playwright.config.${_ext}" ]]; then
            echo "playwright"
            return 0
        fi
    done

    echo "none"
}

# _ui_deterministic_env_list HARDENED?
# Echoes zero or more KEY=VALUE lines (one per line) for `env` to consume.
# HARDENED=1 forces the most aggressive non-interactive profile. M131:
# preflight detection (PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED=1) escalates
# to the hardened profile on the *first* gate run, not just retry — so a
# project with a known-bad reporter config never burns a UI_TEST_TIMEOUT.
# Pure helper — no side effects.
_ui_deterministic_env_list() {
    local hardened="${1:-0}"
    local framework
    framework=$(_ui_detect_framework)

    if [[ "${PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED:-}" == "1" ]]; then
        hardened=1
    fi

    case "$framework" in
        playwright)
            echo "PLAYWRIGHT_HTML_OPEN=never"
            if [[ "$hardened" == "1" ]]; then
                echo "CI=1"
            fi
            ;;
        *)
            : # no env injection for unknown/other frameworks
            ;;
    esac
}

# _normalize_ui_gate_env HARDENED?
# Owner hook that materializes the subprocess env list. Later milestones
# (m57 adapter framework) extend this to dispatch to per-framework env
# functions; for now it delegates to the Playwright-aware helper.
_normalize_ui_gate_env() {
    _ui_deterministic_env_list "${1:-0}"
}

# _ui_timeout_signature EXIT_CODE OUTPUT
# Pure function — no side effects, no logging.
# Prints one of: interactive_report | generic_timeout | none
_ui_timeout_signature() {
    local exit_code="$1"
    local output="$2"

    if [[ "$exit_code" == "124" ]]; then
        if [[ "$output" == *"Serving HTML report at"* ]] \
           || [[ "$output" == *"Press Ctrl+C to quit"* ]]; then
            echo "interactive_report"
            return 0
        fi
        echo "generic_timeout"
        return 0
    fi

    echo "none"
}

# _ui_hardened_timeout BASE_TIMEOUT FACTOR
# Computes the hardened-rerun timeout using a float factor; clamped to
# [1, BASE_TIMEOUT]. Falls back to BASE_TIMEOUT when awk is unavailable.
_ui_hardened_timeout() {
    local base="$1"
    local factor="$2"
    local computed

    if ! computed=$(awk -v b="$base" -v f="$factor" 'BEGIN{ printf "%d", b * f }' 2>/dev/null); then
        computed="$base"
    fi

    if [[ -z "$computed" ]] || [[ "$computed" -lt 1 ]]; then
        computed=1
    fi
    if [[ "$computed" -gt "$base" ]]; then
        computed="$base"
    fi
    echo "$computed"
}

# _ui_write_gate_diagnosis SIGNATURE NORMAL_APPLIED HARDENED_APPLIED HARDENED_ATTEMPTED
# Appends a structured `## UI Gate Diagnosis` block to UI_TEST_ERRORS_FILE
# and BUILD_ERRORS_FILE. Caller writes the raw output sections first; this
# helper only adds the diagnosis section.
_ui_write_gate_diagnosis() {
    local signature="$1"
    local normal_applied="$2"
    local hardened_applied="$3"
    local hardened_attempted="$4"

    local env_label="no"
    if [[ "$hardened_applied" == "yes" ]]; then
        env_label="yes (hardened)"
    elif [[ "$normal_applied" == "yes" ]]; then
        env_label="yes (normal)"
    fi

    local action
    case "$signature" in
        interactive_report)
            action="Command stays alive serving the HTML report; configure the gate to disable report serving (PLAYWRIGHT_HTML_OPEN=never) or pass --reporter=line to UI_TEST_CMD."
            ;;
        generic_timeout)
            action="Increase UI_TEST_TIMEOUT only after confirming the command is non-interactive and any required dev server is healthy."
            ;;
        *)
            action="UI tests failed without a recognized timeout signature; inspect the captured output for the underlying assertion or runtime error."
            ;;
    esac

    local block
    block=$(cat << DIAGEOF

## UI Gate Diagnosis
- Timeout class: ${signature}
- Deterministic env applied: ${env_label}
- Hardened rerun attempted: ${hardened_attempted}
- Suggested action: ${action}
DIAGEOF
)

    if [[ -n "${UI_TEST_ERRORS_FILE:-}" ]] && [[ -f "${UI_TEST_ERRORS_FILE}" ]]; then
        printf '%s\n' "$block" >> "${UI_TEST_ERRORS_FILE}"
    fi
    if [[ -n "${BUILD_ERRORS_FILE:-}" ]] && [[ -f "${BUILD_ERRORS_FILE}" ]]; then
        printf '%s\n' "$block" >> "${BUILD_ERRORS_FILE}"
    fi
}

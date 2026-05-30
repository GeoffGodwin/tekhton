#!/usr/bin/env bash
# =============================================================================
# common_detect.sh — Bash wrappers around `tekhton detect summary --json`.
#
# Sourced by common.sh — do not run directly.
#
# Replaces the M12-era bash detect surface (lib/detect*.sh) at m29.2. Every
# function here calls the Go engine via the tekhton binary and reshapes the
# JSON back into the pipe-delimited form the bash callers historically
# consumed. Bash callers that already parse pipe-delimited rows continue to
# work without change.
#
# Depends on: tekhton binary on PATH (or $TEKHTON_BIN / $TEKHTON_HOME/bin/tekhton),
# jq for JSON extraction.
# =============================================================================

# Resolve the tekhton binary. Honour explicit TEKHTON_BIN, then look in
# TEKHTON_HOME/bin/, then fall back to PATH lookup so callers in unusual
# environments still work.
_tk_resolve_bin() {
    if [[ -n "${TEKHTON_BIN:-}" ]] && [[ -x "$TEKHTON_BIN" ]]; then
        printf '%s\n' "$TEKHTON_BIN"
        return 0
    fi
    local th="${TEKHTON_HOME:-}"
    if [[ -n "$th" ]] && [[ -x "$th/bin/tekhton" ]]; then
        printf '%s\n' "$th/bin/tekhton"
        return 0
    fi
    if command -v tekhton >/dev/null 2>&1; then
        command -v tekhton
        return 0
    fi
    return 1
}

# _tk_detect_summary — Run the Go detect engine and emit JSON to stdout.
# Args: $1 = project directory (defaults to PROJECT_DIR or cwd)
# Output: JSON Summary on stdout; non-zero exit on detect failure.
_tk_detect_summary() {
    local proj_dir="${1:-${PROJECT_DIR:-.}}"
    local bin
    if ! bin=$(_tk_resolve_bin); then
        return 1
    fi
    "$bin" detect summary --json --project-dir "$proj_dir"
}

# Per-domain accessors: each one runs _tk_detect_summary once and reshapes
# the JSON back to the bash pipe-delimited format the historical callers
# consume. Caching across multiple accessors is intentionally NOT done here
# — the engine internals already cache per-Run; callers that need every
# section should grab the JSON once and parse it themselves.

_tk_detect_languages() {
    _tk_detect_summary "$@" | jq -r '.languages[]? | "\(.name)|\(.confidence)|\(.manifest)"'
}

_tk_detect_frameworks() {
    _tk_detect_summary "$@" | jq -r '.frameworks[]? | select((.kind // "") != "ui") | "\(.name)|\(.language)|\(.evidence)"'
}

_tk_detect_commands() {
    _tk_detect_summary "$@" | jq -r '.commands[]? | "\(.type)|\(.command)|\(.source)|\(.confidence)"'
}

_tk_detect_entry_points() {
    _tk_detect_summary "$@" | jq -r '.entry_points[]? | .path'
}

_tk_detect_project_type() {
    _tk_detect_summary "$@" | jq -r '.project_type // "custom"'
}

_tk_detect_workspaces() {
    _tk_detect_summary "$@" | jq -r '.workspaces[]? | "\(.type)|\(.manifest)|\(.subprojects | join(","))"'
}

_tk_detect_services() {
    _tk_detect_summary "$@" | jq -r '.services[]? | "\(.name)|\(.directory)|\(.tech_stack)|\(.source)"'
}

_tk_detect_ci() {
    _tk_detect_summary "$@" | jq -r '.ci[]? | "\(.system)|\(.build)|\(.test)|\(.lint)|\(.deploy)|\(.language)|\(.confidence)"'
}

_tk_detect_infrastructure() {
    _tk_detect_summary "$@" | jq -r '.infrastructure[]? | "\(.tool)|\(.path)|\(.provider)|\(.confidence)"'
}

_tk_detect_test_frameworks() {
    _tk_detect_summary "$@" | jq -r '.test_frameworks[]? | "\(.name)|\(.config)|\(.confidence)"'
}

_tk_detect_doc_quality() {
    _tk_detect_summary "$@" | jq -r 'if .doc_quality then "\(.doc_quality.score)|\(.doc_quality.details | join(";"))" else empty end'
}

_tk_detect_ai_artifacts() {
    _tk_detect_summary "$@" | jq -r '.ai_artifacts[]? | "\(.tool)|\(.path)|\(.type)|\(.confidence)"'
}

# _tk_detect_ui_framework — Detect the E2E test framework and export the
# globals (UI_PROJECT_DETECTED, UI_FRAMEWORK) that the bash side relies on.
# Mirrors the side-effects of the deleted detect_ui_framework function.
# Args: $1 = project directory (defaults to PROJECT_DIR)
# Stdout: framework name on detection, empty otherwise.
_tk_detect_ui_framework() {
    local proj_dir="${1:-${PROJECT_DIR:-.}}"
    local fw
    fw=$(_tk_detect_summary "$proj_dir" 2>/dev/null \
        | jq -r '(.frameworks[]? | select(.kind == "ui") | .name) // ""' \
        | head -1)
    [[ -z "$fw" ]] && return 0
    UI_PROJECT_DETECTED="true"
    export UI_PROJECT_DETECTED
    if [[ -z "${UI_FRAMEWORK:-}" ]] || [[ "${UI_FRAMEWORK:-}" == "auto" ]]; then
        if [[ "$fw" != "generic" ]]; then
            UI_FRAMEWORK="$fw"
        else
            UI_FRAMEWORK=""
        fi
        export UI_FRAMEWORK
    fi
    printf '%s\n' "$fw"
}

# _tk_detect_ui_test_cmd — Infer the E2E test command. Mirrors the
# bash detect_ui_test_cmd: CI > package.json scripts > framework convention.
# Args: $1 = project directory, $2 = framework override (defaults to $UI_FRAMEWORK)
_tk_detect_ui_test_cmd() {
    local proj_dir="${1:-${PROJECT_DIR:-.}}"
    local framework="${2:-${UI_FRAMEWORK:-}}"
    local json
    json=$(_tk_detect_summary "$proj_dir" 2>/dev/null) || return 0

    # 1. CI test commands that look like E2E.
    local ci_cmd
    ci_cmd=$(printf '%s\n' "$json" \
        | jq -r '.ci[]? | .test // empty' \
        | grep -iE 'playwright|cypress|e2e|selenium|detox' \
        | head -1 || true)
    if [[ -n "$ci_cmd" ]]; then
        printf '%s\n' "$ci_cmd"
        return 0
    fi

    # 2. package.json e2e-related scripts (preserve discovery order).
    if [[ -f "$proj_dir/package.json" ]]; then
        local sn
        for sn in "test:e2e" "e2e" "test:ui" "test:integration"; do
            if grep -q "\"${sn}\"" "$proj_dir/package.json" 2>/dev/null; then
                printf 'npm run %s\n' "$sn"
                return 0
            fi
        done
    fi

    # 3. Framework convention.
    case "$framework" in
        playwright)  echo "npx playwright test" ;;
        cypress)     echo "npx cypress run" ;;
        detox)       echo "npx detox test" ;;
        selenium)
            if [[ -f "$proj_dir/requirements.txt" ]]; then
                echo "pytest tests/ -k e2e"
            fi
            ;;
    esac
}

# _tk_format_detection_report — Render the bash-compatible Markdown
# report. Drop-in replacement for format_detection_report.
_tk_format_detection_report() {
    local proj_dir="${1:-${PROJECT_DIR:-.}}"
    local bin
    if ! bin=$(_tk_resolve_bin); then
        return 1
    fi
    "$bin" detect summary --markdown --project-dir "$proj_dir"
}

# _tk_format_detection_summary — KEY|VALUE|CONFIDENCE|SOURCE rows for
# init synthesis. Drop-in replacement for format_detection_summary.
_tk_format_detection_summary() {
    local proj_dir="${1:-${PROJECT_DIR:-.}}"
    local json
    json=$(_tk_detect_summary "$proj_dir" 2>/dev/null) || return 0
    printf '%s\n' "$json" \
        | jq -r '.languages[]? | "LANGUAGE|\(.name)|\(.confidence)|\(.manifest)"'
    printf '%s\n' "$json" \
        | jq -r '.commands[]? | "COMMAND_\(.type)|\(.command)|\(.confidence)|\(.source)"'
}

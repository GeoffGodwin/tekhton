#!/usr/bin/env bash
# =============================================================================
# common.sh — Shared color codes, logging utilities, and prerequisite checks
#
# Sourced by tekhton.sh — do not run directly.
# =============================================================================

set -euo pipefail

# --- M84: Transient artifact file path defaults -------------------------------
# config_defaults.sh provides authoritative defaults via load_config(); these
# fallbacks protect tests and scripts that source common.sh directly.
: "${TEKHTON_DIR:=.tekhton}"
: "${DESIGN_FILE:=${TEKHTON_DIR}/DESIGN.md}"
: "${CODER_SUMMARY_FILE:=${TEKHTON_DIR}/CODER_SUMMARY.md}"
: "${REVIEWER_REPORT_FILE:=${TEKHTON_DIR}/REVIEWER_REPORT.md}"
: "${TESTER_REPORT_FILE:=${TEKHTON_DIR}/TESTER_REPORT.md}"
: "${JR_CODER_SUMMARY_FILE:=${TEKHTON_DIR}/JR_CODER_SUMMARY.md}"
: "${BUILD_ERRORS_FILE:=${TEKHTON_DIR}/BUILD_ERRORS.md}"
: "${BUILD_RAW_ERRORS_FILE:=${TEKHTON_DIR}/BUILD_RAW_ERRORS.txt}"
: "${UI_TEST_ERRORS_FILE:=${TEKHTON_DIR}/UI_TEST_ERRORS.md}"
: "${PREFLIGHT_ERRORS_FILE:=${TEKHTON_DIR}/PREFLIGHT_ERRORS.md}"
: "${DIAGNOSIS_FILE:=${TEKHTON_DIR}/DIAGNOSIS.md}"
: "${CLARIFICATIONS_FILE:=${TEKHTON_DIR}/CLARIFICATIONS.md}"
: "${HUMAN_NOTES_FILE:=${TEKHTON_DIR}/HUMAN_NOTES.md}"
: "${SPECIALIST_REPORT_FILE:=${TEKHTON_DIR}/SPECIALIST_REPORT.md}"
: "${UI_VALIDATION_REPORT_FILE:=${TEKHTON_DIR}/UI_VALIDATION_REPORT.md}"
: "${PREFLIGHT_REPORT_FILE:=${TEKHTON_DIR}/PREFLIGHT_REPORT.md}"
: "${SCOUT_REPORT_FILE:=${TEKHTON_DIR}/SCOUT_REPORT.md}"
: "${ARCHITECT_PLAN_FILE:=${TEKHTON_DIR}/ARCHITECT_PLAN.md}"
: "${CLEANUP_REPORT_FILE:=${TEKHTON_DIR}/CLEANUP_REPORT.md}"
: "${DRIFT_ARCHIVE_FILE:=${TEKHTON_DIR}/DRIFT_ARCHIVE.md}"
: "${PROJECT_INDEX_FILE:=${TEKHTON_DIR}/PROJECT_INDEX.md}"
: "${REPLAN_DELTA_FILE:=${TEKHTON_DIR}/REPLAN_DELTA.md}"
: "${MERGE_CONTEXT_FILE:=${TEKHTON_DIR}/MERGE_CONTEXT.md}"
: "${ARCHITECTURE_LOG_FILE:=${TEKHTON_DIR}/ARCHITECTURE_LOG.md}"
: "${DRIFT_LOG_FILE:=${TEKHTON_DIR}/DRIFT_LOG.md}"
: "${HUMAN_ACTION_FILE:=${TEKHTON_DIR}/HUMAN_ACTION_REQUIRED.md}"
: "${NON_BLOCKING_LOG_FILE:=${TEKHTON_DIR}/NON_BLOCKING_LOG.md}"
: "${MILESTONE_ARCHIVE_FILE:=${TEKHTON_DIR}/MILESTONE_ARCHIVE.md}"
: "${SECURITY_NOTES_FILE:=${TEKHTON_DIR}/SECURITY_NOTES.md}"
: "${SECURITY_REPORT_FILE:=${TEKHTON_DIR}/SECURITY_REPORT.md}"
: "${INTAKE_REPORT_FILE:=${TEKHTON_DIR}/INTAKE_REPORT.md}"
: "${TDD_PREFLIGHT_FILE:=${TEKHTON_DIR}/TESTER_PREFLIGHT.md}"
: "${TEST_AUDIT_REPORT_FILE:=${TEKHTON_DIR}/TEST_AUDIT_REPORT.md}"
: "${HEALTH_REPORT_FILE:=${TEKHTON_DIR}/HEALTH_REPORT.md}"
: "${DOCS_AGENT_REPORT_FILE:=${TEKHTON_DIR}/DOCS_AGENT_REPORT.md}"

# --- Terminal colors ---------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# NO_COLOR support (https://no-color.org/)
# RED/GREEN/YELLOW look locally unused after M99 moved log/warn/error into
# output.sh; shellcheck can't see across the source boundary.
if [[ "${NO_COLOR:-}" == "1" ]]; then
    # shellcheck disable=SC2034
    RED="" GREEN="" YELLOW="" CYAN="" BOLD="" NC=""
fi

# --- Logging -----------------------------------------------------------------

# M97: strip ANSI SGR sequences before forwarding to TUI event feed.
# Handles both actual ESC bytes (0x1b) and the literal \033 octal notation
# that bash produces when BOLD/NC variables use single-quoted '\033[...'.
_tui_strip_ansi() {
    local s="$*"
    # shellcheck disable=SC2001
    printf '%s' "$s" \
        | sed $'s/\x1b\\[[0-9;]*[a-zA-Z]//g' \
        | sed 's/\\033\[[0-9;]*[a-zA-Z]//g'
}
# M117: compute a TUI-only source attribution for Recent Events. Consults the
# M113 substage label and the current pipeline stage label; returns the
# breadcrumb form "stage » substage" when both are set, the stage label alone
# when no substage is active, or an empty string before any stage is open.
# Skipped when TUI_LIFECYCLE_V2=false so the opt-out flag suppresses the
# whole attribution surface (matches M113's no-op substage behavior).
_tui_compute_source() {
    if [[ "${TUI_LIFECYCLE_V2:-true}" == "false" ]]; then
        printf ''
        return 0
    fi
    local stage="${_TUI_CURRENT_STAGE_LABEL:-}"
    local sub="${_TUI_CURRENT_SUBSTAGE_LABEL:-}"
    if [[ -n "$stage" && -n "$sub" ]]; then
        printf '%s » %s' "$stage" "$sub"
    elif [[ -n "$sub" ]]; then
        printf '%s' "$sub"
    elif [[ -n "$stage" ]]; then
        printf '%s' "$stage"
    fi
}

_tui_notify() {
    local level="$1"; shift
    if declare -f tui_append_event &>/dev/null; then
        local _src
        _src=$(_tui_compute_source)
        tui_append_event "$level" "$(_tui_strip_ansi "$*")" "runtime" "$_src" 2>/dev/null || true
    fi
}

# M99: Output Bus — context store (_OUT_CTX) + unified routing (_out_emit).
# Must be sourced AFTER _tui_strip_ansi and _tui_notify are defined above.
# shellcheck source=output.sh disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/output.sh"

# M101: Structured display formatters built on top of output.sh.
# shellcheck source=output_format.sh disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/output_format.sh"

log()       { _out_emit info    "$*"; }
success()   { _out_emit success "$*"; }
warn()      { _out_emit warn    "$*"; }
error()     { _out_emit error   "$*"; }
mode_info() { _out_emit mode    "$*"; }
header()    { _out_emit header  "$*"; }

# run_op — passthrough stub. lib/tui_ops.sh redefines with the full TUI-aware
# implementation when the sidecar is active. Keeps scripts that source only
# common.sh (e.g. test harnesses) able to call run_op without guards.
run_op() { local _l="$1"; shift; "$@"; }

# log_verbose — write an informational diagnostic line that stays off stdout
# unless VERBOSE_OUTPUT=true. The message is always appended to ${LOG_FILE}
# when set, preserving post-mortem visibility. Use for internal diagnostics
# (cache hits, keyword extraction, breakdown tables) that the human doesn't
# need to see scrolling past in real time.
log_verbose() {
    if [[ "${VERBOSE_OUTPUT:-false}" == "true" ]]; then
        echo -e "${CYAN}[tekhton]${NC} $*"
    elif [[ -n "${LOG_FILE:-}" ]]; then
        printf '[tekhton] %s\n' "$*" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

# --- Line counting (portable) ------------------------------------------------

# count_lines — Reads stdin and prints the line count with no leading whitespace.
# Usage: echo "$var" | count_lines
#        count_lines < "$file"
count_lines() {
    wc -l | tr -d '[:space:]'
}

# --- UTF-8 terminal detection (shared by report_error + agent summary) --------

# _is_utf8_terminal — returns 0 if LANG or LC_ALL indicates UTF-8 support.
_is_utf8_terminal() {
    echo "${LANG:-}${LC_ALL:-}" | grep -qi 'utf-\?8' 2>/dev/null
}

# --- Box-drawing helpers (shared by report_error + report_retry) ---------------

# _build_box_hline — builds a horizontal line of the given width using the given char.
# Usage: _build_box_hline WIDTH CHAR
# Prints the result to stdout.
_build_box_hline() {
    local _w="$1" _ch="$2" _line="" _i=0
    while [[ "$_i" -lt "$_w" ]]; do
        _line="${_line}${_ch}"
        _i=$(( _i + 1 ))
    done
    echo "$_line"
}

# _print_box_line — prints a content line with left/right borders and padded interior.
# Usage: _print_box_line BOX_V BOX_W CONTENT
# CONTENT="" prints an empty separator line.
_print_box_line() {
    local _bv="$1" _bw="$2" _content="$3"
    if [[ -n "$_content" ]]; then
        printf '%s  %-*s%s\n' "$_bv" "$((_bw - 2))" "$_content" "$_bv" 2>/dev/null || \
            echo "${_bv}  ${_content}  ${_bv}"
    else
        printf '%s%-*s%s\n' "$_bv" "$_bw" "" "$_bv" 2>/dev/null || \
            echo "${_bv}$(_build_box_hline "$_bw" " ")${_bv}"
    fi
}

# --- Box-drawing setup (shared by report_error + report_retry) ---------------
# Sets script-level _BOX_* variables. Called at the top of each reporting function.
# Usage: _setup_box_chars WIDTH
_setup_box_chars() {
    _BOX_W="${1:-60}"
    _BOX_TL="+" _BOX_TR="+" _BOX_BL="+" _BOX_BR="+"
    _BOX_H="-" _BOX_V="|"
    if _is_utf8_terminal; then
        _BOX_TL="╔" _BOX_TR="╗" _BOX_BL="╚" _BOX_BR="╝"
        _BOX_H="═" _BOX_V="║"
    fi
    _HLINE=$(_build_box_hline "$_BOX_W" "$_BOX_H")
}

# --- Box frame renderer (shared by report_error + report_retry) ---------------
# _print_box_frame — renders a boxed message block to stderr.
# Pass content lines as positional arguments. Empty string "" inserts a blank separator.
# Usage: _print_box_frame "line1" "" "line2" ...
#        _print_box_frame --width 80 "line1" "" "line2" ...
_print_box_frame() {
    local _width=60
    if [[ "${1:-}" = "--width" ]]; then
        _width="${2:-60}"
        shift 2
    fi
    _setup_box_chars "$_width"
    {
        echo
        echo "${_BOX_TL}${_HLINE}${_BOX_TR}"
        local _line
        for _line in "$@"; do
            _print_box_line "$_BOX_V" "$_BOX_W" "$_line"
        done
        echo "${_BOX_BL}${_HLINE}${_BOX_BR}"
        echo
    } >&2
}

# --- Structured error reporting (12.2) ----------------------------------------
# Prints a boxed error block to stderr with category, message, and recovery.
# Falls back to ASCII when terminal lacks UTF-8 support.
#
# Usage: report_error CATEGORY SUBCATEGORY TRANSIENT MESSAGE RECOVERY

report_error() {
    local category="$1"
    local subcategory="$2"
    local transient="$3"
    local message="$4"
    local recovery="${5:-}"

    local _transient_label="PERMANENT"
    if [[ "$transient" = "true" ]]; then
        _transient_label="TRANSIENT (safe to retry)"
    fi

    local _lines=("ERROR: ${category}/${subcategory}" "$_transient_label" "" "${message}")
    if [[ -n "$recovery" ]]; then
        _lines+=("" "Recovery: ${recovery}")
    fi
    _print_box_frame "${_lines[@]}"
}

# --- Structured retry reporting (13.1) ----------------------------------------
# Prints a formatted retry notice to stderr with attempt number, category, and delay.
# Uses the same box-drawing helpers as report_error() for consistent rendering.
#
# Usage: report_retry ATTEMPT MAX_ATTEMPTS CATEGORY DELAY

report_retry() {
    local attempt="$1"
    local max="$2"
    local category="$3"
    local delay="$4"

    local _dash="--"
    if _is_utf8_terminal; then _dash="—"; fi

    _print_box_frame \
        "RETRY: Transient error (${category})" \
        "Attempt ${attempt}/${max} ${_dash} retrying in ${delay}s..."
}

# --- Phase timing helpers (M46) ----------------------------------------------
# Per-phase wall-clock instrumentation. Uses associative arrays for storage.
# All functions are safe to call at top-level scope (no subshell issues).
#
# Usage:
#   _phase_start "build_gate_analyze"
#   ... do work ...
#   _phase_end "build_gate_analyze"
#   dur=$(_get_phase_duration "build_gate_analyze")

declare -gA _PHASE_STARTS=()    # epoch seconds (start timestamp per phase)
declare -gA _PHASE_TIMINGS=()   # elapsed seconds per completed phase

# _get_epoch_secs — returns current epoch seconds.
# Uses date +%s (universally available). Nanosecond precision is not needed
# for phase-level instrumentation where phases are >= 1 second.
_get_epoch_secs() {
    date +%s
}

# _phase_start NAME — records the start time for a named phase.
# Overwrites any previous start for the same name (allows re-use).
_phase_start() {
    local name="$1"
    _PHASE_STARTS[$name]=$(_get_epoch_secs)
}

# _phase_end NAME — records the end time and computes duration.
# If _phase_start was never called for NAME, logs a warning and returns.
# Accumulates into _PHASE_TIMINGS (does NOT overwrite — adds to existing).
_phase_end() {
    local name="$1"
    local start="${_PHASE_STARTS[$name]:-}"
    if [[ -z "$start" ]]; then
        # Graceful handling: missing _phase_start is not fatal
        return 0
    fi
    local end
    end=$(_get_epoch_secs)
    local elapsed=$(( end - start ))
    # Accumulate (supports nested/repeated phases like multiple build gates)
    local prev="${_PHASE_TIMINGS[$name]:-0}"
    _PHASE_TIMINGS[$name]=$(( prev + elapsed ))
    unset '_PHASE_STARTS[$name]'
}

# _get_phase_duration NAME — prints the recorded duration in seconds.
# Returns 0 if phase was never recorded.
_get_phase_duration() {
    echo "${_PHASE_TIMINGS[${1}]:-0}"
}

# _format_duration_human SECONDS — prints human-readable duration (e.g. "4m 22s").
_format_duration_human() {
    local secs="$1"
    if [[ "$secs" -ge 60 ]]; then
        echo "$(( secs / 60 ))m $(( secs % 60 ))s"
    else
        echo "${secs}s"
    fi
}

# --- Prerequisite check ------------------------------------------------------

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || { error "Required command not found: $1"; exit 1; }
}

# --- Usage threshold check ---------------------------------------------------
# Checks if Claude CLI session usage exceeds the configured threshold.
# Returns 0 if under threshold (safe to continue), 1 if over (should pause).
# When USAGE_THRESHOLD_PCT=0, always returns 0 (disabled).
#
# Usage: check_usage_threshold || { log "Usage threshold reached"; exit 0; }

check_usage_threshold() {
    local threshold="${USAGE_THRESHOLD_PCT:-0}"

    # Disabled when threshold is 0 or non-numeric
    if ! [[ "$threshold" =~ ^[0-9]+$ ]] || [ "$threshold" -eq 0 ]; then
        return 0
    fi

    # Parse claude /usage output for the current cost percentage
    local usage_output
    usage_output=$(claude usage 2>/dev/null || true)

    if [ -z "$usage_output" ]; then
        warn "[usage] Could not read claude usage — skipping threshold check."
        return 0
    fi

    # Extract percentage from usage output (look for a line with N% or N.N%).
    # Expected format from `claude usage`: one or more lines containing "N%" or "N.N%"
    # (e.g., "Session usage: 45.2%"). If the format changes and no percentage is found,
    # the function warns and returns 0 (allow) to avoid blocking the pipeline silently.
    local pct
    pct=$(echo "$usage_output" | grep -oE '[0-9]+(\.[0-9]+)?%' | head -1 | tr -d '%' || true)

    if [ -z "$pct" ]; then
        warn "[usage] Could not parse usage percentage — skipping threshold check."
        return 0
    fi

    # Compare integer parts (bash can't do float comparison)
    local pct_int
    pct_int=$(echo "$pct" | cut -d. -f1)

    if [ "$pct_int" -ge "$threshold" ]; then
        warn "[usage] Session usage is ${pct}% — exceeds threshold of ${threshold}%."
        warn "[usage] Pausing to avoid exceeding rate limits."
        return 1
    fi

    log "[usage] Session usage: ${pct}% (threshold: ${threshold}%)"
    return 0
}

# --- Orchestration status banner (M16) ------------------------------------------
#
# report_orchestration_status ATTEMPT MAX ELAPSED AGENT_CALLS
# Prints a banner at the start of each outer loop iteration.
report_orchestration_status() {
    local attempt="$1"
    local max="$2"
    local elapsed="$3"
    # shellcheck disable=SC2034  # agent_calls kept in signature for orchestrate.sh caller
    local agent_calls="$4"

    local elapsed_min=$(( elapsed / 60 ))
    local elapsed_sec=$(( elapsed % 60 ))

    echo
    echo -e "${BOLD}${CYAN}── Orchestration Loop ──────────────────${NC}"
    echo -e "  Attempt:     ${BOLD}${attempt}${NC} / ${max}"
    echo -e "  Elapsed:     ${elapsed_min}m ${elapsed_sec}s"
    echo -e "${BOLD}${CYAN}────────────────────────────────────────${NC}"
    echo
}

# --- Gitignore management -----------------------------------------------------

# _ensure_gitignore_entries — Appends Tekhton runtime artifact patterns to
# .gitignore. Creates the file if absent. Idempotent: skips present entries.
# Args: $1 = project_dir (defaults to PROJECT_DIR or .)
# Called from --plan (tekhton.sh) and from _ensure_init_gitignore (init_helpers.sh).
_ensure_gitignore_entries() {
    local _gi_dir="${1:-${PROJECT_DIR:-.}}"
    local _gi_file="${_gi_dir}/.gitignore"
    local -a _gi_entries=(
        ".claude/PIPELINE.lock" ".claude/PIPELINE_STATE.md"
        ".claude/MILESTONE_STATE.md" ".claude/CHECKPOINT_META.json"
        ".claude/LAST_FAILURE_CONTEXT.json" ".claude/TEST_BASELINE.json"
        ".claude/TEST_BASELINE_OUTPUT.txt" ".claude/test_acceptance_output.tmp"
        ".claude/dashboard/data/" ".claude/logs/" ".claude/indexer-venv/"
        ".claude/index/" ".claude/serena/" ".claude/dry_run_cache/"
        ".claude/migration-backups/" ".claude/watchtower_inbox/"
        ".claude/tui_sidecar.pid"
    )
    [[ ! -f "$_gi_file" ]] && touch "$_gi_file"
    local _gi_added=0
    local _gi_entry
    for _gi_entry in "${_gi_entries[@]}"; do
        grep -qF "$_gi_entry" "$_gi_file" 2>/dev/null && continue
        if (( _gi_added == 0 )) && ! grep -qF "# Tekhton runtime artifacts" "$_gi_file" 2>/dev/null; then
            if [[ -s "$_gi_file" ]] && [[ "$(tail -c1 "$_gi_file" | wc -l)" -eq 0 ]]; then
                printf '\n' >> "$_gi_file"
            fi
            printf '\n# Tekhton runtime artifacts\n' >> "$_gi_file"
        fi
        printf '%s\n' "$_gi_entry" >> "$_gi_file"
        _gi_added=$(( _gi_added + 1 ))
    done
    (( _gi_added > 0 )) && success "Added ${_gi_added} Tekhton runtime artifact pattern(s) to .gitignore"
    return 0
}

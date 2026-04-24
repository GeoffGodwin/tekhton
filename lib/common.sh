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
# M120: Extracted to artifact_defaults.sh so planning mode can re-source the
# same := block after load_plan_config to self-heal empty values written by
# older pipeline.conf files (issue #179).
# shellcheck source=artifact_defaults.sh disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/artifact_defaults.sh"

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

# --- Box-drawing + structured error/retry reporting --------------------------
# Extracted to common_box.sh to keep this file under the 300-line ceiling.
# Provides: _is_utf8_terminal, _build_box_hline, _print_box_line,
#           _setup_box_chars, _print_box_frame, report_error, report_retry
# shellcheck source=common_box.sh disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/common_box.sh"

# --- Phase timing helpers (M46) ----------------------------------------------
# Extracted to common_timing.sh to keep this file under the 300-line ceiling.
# Provides: _get_epoch_secs, _phase_start, _phase_end, _get_phase_duration,
#           _format_duration_human, _PHASE_STARTS, _PHASE_TIMINGS
# shellcheck source=common_timing.sh disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/common_timing.sh"

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
        ".claude/tui_sidecar.pid" ".claude/worktrees/"
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

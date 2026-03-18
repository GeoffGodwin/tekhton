#!/usr/bin/env bash
# =============================================================================
# common.sh — Shared color codes, logging utilities, and prerequisite checks
#
# Sourced by tekhton.sh — do not run directly.
# =============================================================================

# --- Terminal colors ---------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# --- Logging -----------------------------------------------------------------

log()    { echo -e "${CYAN}[tekhton]${NC} $*"; }
success(){ echo -e "${GREEN}[✓]${NC} $*"; }
warn()   { echo -e "${YELLOW}[!]${NC} $*"; }
error()  { echo -e "${RED}[✗]${NC} $*"; }
header() { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════${NC}"; echo -e "${BOLD}${CYAN}  $*${NC}"; echo -e "${BOLD}${CYAN}══════════════════════════════════════${NC}\n"; }

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

    # Detect Unicode support for box-drawing characters
    local _box_tl="+" _box_tr="+" _box_bl="+" _box_br="+"
    local _box_h="-" _box_v="|" _box_w=60
    if _is_utf8_terminal; then
        _box_tl="╔" _box_tr="╗" _box_bl="╚" _box_br="╝"
        _box_h="═" _box_v="║"
    fi

    local _hline=""
    local _i=0
    while [[ "$_i" -lt "$_box_w" ]]; do
        _hline="${_hline}${_box_h}"
        _i=$(( _i + 1 ))
    done

    local _transient_label="PERMANENT"
    if [[ "$transient" = "true" ]]; then
        _transient_label="TRANSIENT (safe to retry)"
    fi

    {
        echo
        echo "${_box_tl}${_hline}${_box_tr}"
        echo "${_box_v}  ERROR: ${category}/${subcategory}"
        printf '%s  %-*s%s\n' "$_box_v" "$_box_w" "$_transient_label" "$_box_v" 2>/dev/null || \
            echo "${_box_v}  ${_transient_label}"
        echo "${_box_v}"
        echo "${_box_v}  ${message}"
        if [[ -n "$recovery" ]]; then
            echo "${_box_v}"
            echo "${_box_v}  Recovery: ${recovery}"
        fi
        echo "${_box_bl}${_hline}${_box_br}"
        echo
    } >&2
}

# --- Prerequisite check ------------------------------------------------------

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || { error "Required command not found: $1"; exit 1; }
}

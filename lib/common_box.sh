#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# common_box.sh — Box-drawing helpers + structured error/retry reporting
#
# Extracted from common.sh to keep that file under the 300-line ceiling.
# Sourced by common.sh — do not run directly.
# Provides: _is_utf8_terminal, _build_box_hline, _print_box_line,
#           _setup_box_chars, _print_box_frame, report_error, report_retry
# =============================================================================

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

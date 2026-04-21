#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# output_format.sh — Structured display formatters built on top of output.sh.
#
# Sourced by lib/common.sh after lib/output.sh. Do not run directly.
#
# Provides:
#   _out_color CODE          — CODE or empty when NO_COLOR is set at call time
#   out_msg MSG              — plain body line (no prefix), routed via bus
#   out_banner T [K V ...]   — boxed header with optional key/value rows
#   out_section T            — separator line with inline title
#   out_kv L V [SEV]         — single key/value line (normal|warn|error)
#   out_hr [L]               — horizontal rule (optionally labelled)
#   out_progress L CUR MAX   — labelled progress bar with counts
#   out_action_item MSG SEV  — action item line (normal|warning|critical)
#                              TUI mode: appends to _OUT_CTX[action_items] JSON
# =============================================================================

# _out_color CODE — return the given ANSI code, or empty when NO_COLOR is set.
# Evaluated at call time so callers can export NO_COLOR after common.sh sources.
_out_color() {
    [[ -n "${NO_COLOR:-}" ]] && return 0
    printf '%s' "${1:-}"
}

# _out_term_width — usable terminal width with a conservative default.
# Clamps to 20..80 so layouts stay readable in narrow shells and don't blow
# out wide ones with oversized rules.
_out_term_width() {
    local w="${COLUMNS:-}"
    if [[ -z "$w" ]] && command -v tput >/dev/null 2>&1; then
        w=$(tput cols 2>/dev/null || echo 60)
    fi
    [[ -z "$w" || "$w" -lt 20 ]] && w=60
    [[ "$w" -gt 80 ]] && w=80
    printf '%s' "$w"
}

# _out_repeat CHAR N — print CHAR N times; N<=0 prints nothing.
_out_repeat() {
    local ch="$1" n="${2:-0}" i=0 out=""
    while (( i < n )); do
        out="${out}${ch}"
        i=$(( i + 1 ))
    done
    printf '%s' "$out"
}

# --- out_msg -------------------------------------------------------------------
# out_msg MSG
# Plain message line — no prefix, no leading style. Routes through the bus so
# TUI mode captures to the log file and event feed. Use for body content inside
# reports/banners where the `[tekhton]` prefix of out_log would be noise.
out_msg() {
    local msg="$*"
    if [[ "${_TUI_ACTIVE:-false}" == "true" ]]; then
        if [[ -n "${LOG_FILE:-}" ]]; then
            printf '%s\n' "$(_tui_strip_ansi "$msg")" >> "$LOG_FILE" 2>/dev/null || true
        fi
        _tui_notify "info" "$msg"
    else
        printf '%s\n' "$msg"
    fi
}

# --- out_banner ----------------------------------------------------------------
# out_banner TITLE [KEY VALUE ...]
# CLI: boxed header with optional key/value body rows.
# TUI: TITLE emitted as a 'header' event; each KEY/VALUE pair as an 'info' event.
out_banner() {
    local title="${1:-}"
    shift || true
    if [[ "${_TUI_ACTIVE:-false}" == "true" ]]; then
        out_header "$title"
        while [[ $# -ge 2 ]]; do
            out_log "${1}: ${2}"
            shift 2
        done
        return 0
    fi
    local bold nc w hline
    bold=$(_out_color "${BOLD:-}")
    nc=$(_out_color "${NC:-}")
    w=$(_out_term_width)
    hline=$(_out_repeat "═" "$w")
    echo
    echo -e "${bold}${hline}${nc}"
    echo -e "${bold}  ${title}${nc}"
    while [[ $# -ge 2 ]]; do
        printf '%b  %-10s %s%b\n' "$bold" "${1}:" "$2" "$nc"
        shift 2
    done
    echo -e "${bold}${hline}${nc}"
    echo
}

# --- out_section ---------------------------------------------------------------
# out_section TITLE
# CLI: separator line with inline title (── TITLE ──────).
# TUI: 'info' event with the same text.
out_section() {
    local title="${1:-}"
    if [[ "${_TUI_ACTIVE:-false}" == "true" ]]; then
        out_log "── ${title} ──"
        return 0
    fi
    local bold nc w pad right
    bold=$(_out_color "${BOLD:-}")
    nc=$(_out_color "${NC:-}")
    w=$(_out_term_width)
    pad=$(( w - ${#title} - 8 ))
    (( pad < 0 )) && pad=0
    right=$(_out_repeat "─" "$pad")
    echo -e "${bold}──── ${title} ${right}${nc}"
}

# --- out_kv --------------------------------------------------------------------
# out_kv LABEL VALUE [SEVERITY]
# SEVERITY: normal (default) | warn | error. 'error' appends ' [CRITICAL]'.
out_kv() {
    local label="${1:-}" value="${2:-}" sev="${3:-normal}"
    if [[ "${_TUI_ACTIVE:-false}" == "true" ]]; then
        case "$sev" in
            warn)  out_warn  "${label}: ${value}" ;;
            error) out_error "${label}: ${value}" ;;
            *)     out_log   "${label}: ${value}" ;;
        esac
        return 0
    fi
    _out_kv_print "$label" "$value" "$sev"
}

# --- out_summary_kv ------------------------------------------------------------
# out_summary_kv LABEL VALUE
# Like out_kv, but TUI mode routes the event as type="summary" so the hold view
# renders the line in a dedicated recap block rather than as a late runtime
# chronology event (M110). CLI mode is identical to out_kv.
out_summary_kv() {
    local label="${1:-}" value="${2:-}"
    if [[ "${_TUI_ACTIVE:-false}" == "true" ]]; then
        if declare -f tui_append_summary_event &>/dev/null; then
            tui_append_summary_event "info" "${label}: ${value}"
        else
            out_log "${label}: ${value}"
        fi
        return 0
    fi
    _out_kv_print "$label" "$value" "normal"
}

# _out_kv_print LABEL VALUE SEV — shared CLI renderer for out_kv/out_summary_kv.
_out_kv_print() {
    local label="$1" value="$2" sev="$3"
    local bold nc color suffix=""
    bold=$(_out_color "${BOLD:-}")
    nc=$(_out_color "${NC:-}")
    case "$sev" in
        warn)  color=$(_out_color "${YELLOW:-}") ;;
        error) color=$(_out_color "${RED:-}"); suffix=" [CRITICAL]" ;;
        *)     color="" ;;
    esac
    printf '  %b%s:%b %b%s%b%s\n' \
        "$bold" "$label" "$nc" "$color" "$value" "$nc" "$suffix"
}

# --- out_hr --------------------------------------------------------------------
# out_hr [LABEL]  — horizontal rule, optionally with an inline label prefix.
out_hr() {
    local label="${1:-}"
    if [[ "${_TUI_ACTIVE:-false}" == "true" ]]; then
        if [[ -n "$label" ]]; then
            out_log "── ${label} ──"
        else
            out_log "────"
        fi
        return 0
    fi
    local bold nc w line pad
    bold=$(_out_color "${BOLD:-}")
    nc=$(_out_color "${NC:-}")
    w=$(_out_term_width)
    if [[ -z "$label" ]]; then
        line=$(_out_repeat "─" "$w")
        echo -e "${bold}${line}${nc}"
    else
        pad=$(( w - ${#label} - 1 ))
        (( pad < 0 )) && pad=0
        line=$(_out_repeat "─" "$pad")
        echo -e "${bold}${label} ${line}${nc}"
    fi
}

# --- out_progress --------------------------------------------------------------
# out_progress LABEL CURRENT MAX [BAR_WIDTH]
# Renders: "LABEL  [████░░░]  CURRENT/MAX".
out_progress() {
    local label="${1:-}" cur="${2:-0}" max="${3:-0}" bar_w="${4:-20}"
    local pct=0 filled=0 empty
    if (( max > 0 )); then
        pct=$(( cur * 100 / max ))
        filled=$(( cur * bar_w / max ))
    fi
    (( filled > bar_w )) && filled=$bar_w
    (( filled < 0 )) && filled=0
    empty=$(( bar_w - filled ))
    if [[ "${_TUI_ACTIVE:-false}" == "true" ]]; then
        out_log "${label} ${cur}/${max} (${pct}%)"
        return 0
    fi
    local green nc fill_chars empty_chars
    green=$(_out_color "${GREEN:-}")
    nc=$(_out_color "${NC:-}")
    fill_chars=$(_out_repeat "█" "$filled")
    empty_chars=$(_out_repeat "░" "$empty")
    printf '%s [%b%s%s%b] %d/%d\n' \
        "$label" "$green" "$fill_chars" "$empty_chars" "$nc" "$cur" "$max"
}

# --- out_action_item -----------------------------------------------------------
# out_action_item MSG SEVERITY
# SEVERITY: normal (ℹ cyan) | warning (⚠ yellow) | critical (✗ red, suffix).
# CLI: prints a single colored line. TUI: no stdout — the item is appended to
# _OUT_CTX[action_items] as a JSON object for M102's hold screen to consume.
out_action_item() {
    local msg="${1:-}" sev="${2:-normal}"
    local prefix color suffix=""
    case "$sev" in
        critical) prefix="✗"; color=$(_out_color "${RED:-}");    suffix=" [CRITICAL]" ;;
        warning)  prefix="⚠"; color=$(_out_color "${YELLOW:-}") ;;
        *)        prefix="ℹ"; color=$(_out_color "${CYAN:-}") ;;
    esac
    if [[ "${_TUI_ACTIVE:-false}" == "true" ]]; then
        _out_append_action_item "$msg" "$sev"
        return 0
    fi
    local nc
    nc=$(_out_color "${NC:-}")
    printf '  %b%s %s%s%b\n' "$color" "$prefix" "$msg" "$suffix" "$nc"
}

# _out_append_action_item MSG SEV — append a JSON object to the action_items
# array stored in _OUT_CTX. Maintains a valid JSON array in-place.
# SEV is escaped alongside MSG so any future computed-severity caller can't
# break the JSON envelope.
_out_append_action_item() {
    local msg="$1" sev="$2"
    local esc_msg esc_sev frag cur
    esc_msg=$(_out_json_escape "$msg")
    esc_sev=$(_out_json_escape "$sev")
    frag="{\"msg\":\"${esc_msg}\",\"severity\":\"${esc_sev}\"}"
    cur="${_OUT_CTX[action_items]:-}"
    if [[ -z "$cur" || "$cur" == "[]" ]]; then
        _OUT_CTX[action_items]="[${frag}]"
    else
        _OUT_CTX[action_items]="${cur%]},${frag}]"
    fi
}

# _out_json_escape STR — minimal JSON string escape (backslash, quote, controls).
# Handles \n/\r/\t explicitly; strips remaining control chars U+0000..U+001F
# (backspace, formfeed, NUL, etc.) because bare control bytes are invalid
# inside a JSON string literal per RFC 8259 §7.
_out_json_escape() {
    local s="$*"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    # Strip any remaining U+0000..U+001F bytes (tr handles NUL cleanly via -d).
    s=$(printf '%s' "$s" | LC_ALL=C tr -d '\000-\010\013\014\016-\037')
    printf '%s' "$s"
}

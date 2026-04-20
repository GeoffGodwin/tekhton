#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# init_report_banner_next.sh — "What's next" + auto-prompt helpers extracted
# from init_report_banner.sh to keep that file under the 300-line ceiling.
# Sourced by init_report_banner.sh — do not run directly.
# Provides: _emit_next_section, _emit_auto_prompt
# =============================================================================

# _banner_detect_milestone_state — Sets out_manifest/out_pending vars by name
# reference based on milestone manifest / inline CLAUDE.md state.
# Args: $1 = project_dir, $2 = name of has_manifest var, $3 = name of has_pending var
_banner_detect_milestone_state() {
    local project_dir="$1"
    local -n _out_manifest="$2"
    local -n _out_pending="$3"
    _out_manifest=false
    _out_pending=false

    local _milestone_dir="${project_dir}/.claude/milestones"
    local _claude_md="${project_dir}/CLAUDE.md"
    if [[ -f "${_milestone_dir}/MANIFEST.cfg" ]] \
        && grep -q '|' "${_milestone_dir}/MANIFEST.cfg" 2>/dev/null; then
        _out_manifest=true
        if grep -qE '\|pending\||\|in_progress\|' "${_milestone_dir}/MANIFEST.cfg" 2>/dev/null; then
            _out_pending=true
        fi
    elif [[ -f "$_claude_md" ]] \
        && ! grep -q '<!-- TODO:.*--plan' "$_claude_md" 2>/dev/null \
        && grep -q '^#### Milestone' "$_claude_md" 2>/dev/null; then
        _out_manifest=true
        _out_pending=true
    fi
}

# _emit_next_section — Renders the "What's next" block with recommendation.
# Args: $1=project_dir, $2=file_count, $3=commands (reserved),
#       $4=bullet (reserved, currently unused), $5=arrow
_emit_next_section() {
    local project_dir="$1"
    local file_count="$2"
    # $3 (commands) reserved for future "rerun X" hints
    # $4 (bullet) reserved — not currently rendered
    local arrow="$5"

    local has_manifest has_pending
    _banner_detect_milestone_state "$project_dir" has_manifest has_pending

    local rec_line
    rec_line=$(_init_pick_recommendation "$file_count" "$has_manifest" "$has_pending")
    local rec_cmd rec_desc alt1 alt2
    rec_cmd=$(echo "$rec_line" | cut -d'|' -f1)
    rec_desc=$(echo "$rec_line" | cut -d'|' -f2)
    alt1=$(echo "$rec_line" | cut -d'|' -f3)
    alt2=$(echo "$rec_line" | cut -d'|' -f4)

    out_section "What's next"
    local bold nc green cyan
    bold=$(_out_color "${BOLD:-}")
    nc=$(_out_color "${NC:-}")
    green=$(_out_color "${GREEN:-}")
    cyan=$(_out_color "${CYAN:-}")
    out_msg "    ${green}${arrow}${nc}  ${bold}${rec_cmd}${nc}   (${rec_desc})"
    [[ -n "$alt1" ]] && out_msg "       or ${alt1}"
    [[ -n "$alt2" ]] && out_msg "       or ${alt2}"
    out_msg ""

    if _is_watchtower_enabled; then
        out_msg "  Full report: ${cyan}.claude/dashboard/index.html${nc}"
    else
        out_msg "  Full report: ${cyan}INIT_REPORT.md${nc}"
    fi
    out_msg "  Run ${cyan}tekhton --help${nc} for all commands."
    out_msg ""
}

# _emit_auto_prompt — Optional auto-prompt to run recommended command.
_emit_auto_prompt() {
    local project_dir="$1"
    local file_count="$2"

    [[ "${INIT_AUTO_PROMPT:-false}" != "true" ]] && return 0
    [[ ! -t 0 ]] && return 0
    [[ ! -t 1 ]] && return 0

    local has_manifest has_pending
    _banner_detect_milestone_state "$project_dir" has_manifest has_pending

    local rec_line
    rec_line=$(_init_pick_recommendation "$file_count" "$has_manifest" "$has_pending")
    local rec_cmd
    rec_cmd=$(echo "$rec_line" | cut -d'|' -f1)

    local _reply
    read -r -p "  Run ${rec_cmd} now? [Y/n] " _reply </dev/tty || return 0
    case "${_reply:-Y}" in
        y|Y|yes|Yes|YES|"")
            local _cmd_array
            read -ra _cmd_array <<< "$rec_cmd"
            exec "${_cmd_array[@]}"
            ;;
        *) : ;;
    esac
}

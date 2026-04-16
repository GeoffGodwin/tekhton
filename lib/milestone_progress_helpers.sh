#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# milestone_progress_helpers.sh — Rendering helpers for milestone progress
#
# Sourced by milestone_progress.sh — do not run directly.
# Expects: common.sh, milestone_dag.sh sourced first (provides _is_utf8_terminal,
#          dag_id_to_number, dag_get_title, dag_get_frontier, dag_find_next,
#          GREEN, NC color codes).
# Expects: _DAG_IDS, _DAG_TITLES, _DAG_STATUSES, _DAG_DEPS, _DAG_LOADED,
#          load_manifest from milestone_dag.sh / milestone_dag_io.sh.
#
# Provides:
#   _render_progress_dag     — DAG-based progress rendering
#   _render_progress_inline  — inline milestone fallback rendering
#   _render_progress_bar     — 40-char progress bar
#   _render_milestone_line   — single milestone line with optional deps
# =============================================================================

# _render_progress_dag SHOW_ALL SHOW_DEPS SYM_DONE SYM_READY SYM_PENDING
# DAG-based progress rendering (uses loaded manifest).
_render_progress_dag() {
    local show_all="$1" show_deps="$2"
    local sym_done="$3" sym_ready="$4" sym_pending="$5"

    if [[ "${_DAG_LOADED:-false}" != "true" ]]; then
        load_manifest || { echo "Failed to load milestone manifest."; return 1; }
    fi

    local total="${#_DAG_IDS[@]}"
    if [[ "$total" -eq 0 ]]; then
        echo "No milestones found. Run tekhton --draft-milestones to create some."
        return 0
    fi

    # Count done
    local done_count=0 i
    for (( i = 0; i < total; i++ )); do
        [[ "${_DAG_STATUSES[$i]}" == "done" ]] && done_count=$(( done_count + 1 ))
    done

    # Frontier IDs (for ready marker)
    local frontier
    frontier=$(dag_get_frontier) || frontier=""

    # Progress header + bar
    local pct=0
    [[ "$total" -gt 0 ]] && pct=$(( done_count * 100 / total ))
    echo "Milestones: ${done_count} done / ${total} total (${pct}%)"
    _render_progress_bar "$done_count" "$total"
    echo

    # Done section (recent — last 3, or all if --all)
    local done_ids=()
    for (( i = 0; i < total; i++ )); do
        [[ "${_DAG_STATUSES[$i]}" == "done" ]] && done_ids+=("$i")
    done

    if [[ ${#done_ids[@]} -gt 0 ]]; then
        if [[ "$show_all" == "true" ]]; then
            echo "Done:"
            for idx in "${done_ids[@]}"; do
                _render_milestone_line "$idx" "$sym_done" "$show_deps" "done"
            done
        elif [[ ${#done_ids[@]} -gt 3 ]]; then
            echo "Done (recent):"
            local start=$(( ${#done_ids[@]} - 3 ))
            for (( j = start; j < ${#done_ids[@]}; j++ )); do
                _render_milestone_line "${done_ids[$j]}" "$sym_done" "$show_deps" "done"
            done
        else
            echo "Done:"
            for idx in "${done_ids[@]}"; do
                _render_milestone_line "$idx" "$sym_done" "$show_deps" "done"
            done
        fi
        echo
    fi

    # Next section (pending milestones)
    local pending_printed=false
    for (( i = 0; i < total; i++ )); do
        [[ "${_DAG_STATUSES[$i]}" == "done" ]] && continue
        if [[ "$pending_printed" == "false" ]]; then
            echo "Next:"
            pending_printed=true
        fi
        local id="${_DAG_IDS[$i]}"
        if echo "$frontier" | grep -qx "$id" 2>/dev/null; then
            _render_milestone_line "$i" "$sym_ready" "$show_deps" "ready"
        else
            _render_milestone_line "$i" "$sym_pending" "$show_deps" "blocked"
        fi
    done

    # Run command for next milestone
    local next_id
    next_id=$(dag_find_next 2>/dev/null) || next_id=""
    if [[ -n "$next_id" ]]; then
        local next_num
        next_num=$(dag_id_to_number "$next_id")
        local next_title
        next_title=$(dag_get_title "$next_id" 2>/dev/null || echo "")
        echo
        echo "Run: tekhton --milestone \"M${next_num}: ${next_title}\""
    elif [[ "$done_count" -eq "$total" ]]; then
        echo
        echo "All milestones complete. Run tekhton --draft-milestones for next steps."
    fi
}

# _render_progress_inline SHOW_ALL SYM_DONE SYM_READY SYM_PENDING
# Inline-milestone fallback (no dependency info).
_render_progress_inline() {
    local show_all="$1"
    local sym_done="$2" sym_ready="$3" sym_pending="$4"

    local ms_data
    ms_data=$(parse_milestones_auto 2>/dev/null) || ms_data=""

    if [[ -z "$ms_data" ]]; then
        echo "No milestones found. Run tekhton --draft-milestones to create some."
        return 0
    fi

    local total=0 done_count=0
    while IFS='|' read -r num title _; do
        [[ -z "$num" ]] && continue
        total=$(( total + 1 ))
        if is_milestone_done "$num" 2>/dev/null; then
            done_count=$(( done_count + 1 ))
        fi
    done <<< "$ms_data"

    local pct=0
    [[ "$total" -gt 0 ]] && pct=$(( done_count * 100 / total ))
    echo "Milestones: ${done_count} done / ${total} total (${pct}%)"
    _render_progress_bar "$done_count" "$total"
    echo

    local first_pending=true
    while IFS='|' read -r num title _; do
        [[ -z "$num" ]] && continue
        if is_milestone_done "$num" 2>/dev/null; then
            [[ "$show_all" == "true" ]] && printf "  %b %-5s %s\n" "$sym_done" "m${num}" "$title"
        else
            if [[ "$first_pending" == "true" ]]; then
                printf "  %b %-5s %s  (ready)\n" "$sym_ready" "m${num}" "$title"
                first_pending=false
            else
                printf "  %b %-5s %s\n" "$sym_pending" "m${num}" "$title"
            fi
        fi
    done <<< "$ms_data"

    echo
    echo "(dependency tracking requires MILESTONE_DAG_ENABLED=true)"
}

# _render_progress_bar DONE TOTAL
# Prints a 40-char progress bar.
_render_progress_bar() {
    local done_count="$1" total="$2"
    local bar_width=40
    local filled=0
    [[ "$total" -gt 0 ]] && filled=$(( done_count * bar_width / total ))
    local empty=$(( bar_width - filled ))

    local bar_ch="=" bar_empty=" "
    if _is_utf8_terminal; then
        bar_ch="\xe2\x94\x81"  # ━
    fi

    local decoded_ch decoded_empty
    printf -v decoded_ch '%b' "$bar_ch"
    printf -v decoded_empty '%b' "$bar_empty"
    local bar=""
    local k
    for (( k = 0; k < filled; k++ )); do
        bar="${bar}${decoded_ch}"
    done
    for (( k = 0; k < empty; k++ )); do
        bar="${bar}${decoded_empty}"
    done
    echo -e "${GREEN}${bar}${NC}"
}

# _render_milestone_line INDEX SYMBOL SHOW_DEPS STATUS
# Prints a single milestone line with optional dependency info.
_render_milestone_line() {
    local idx="$1" sym="$2" show_deps="$3" status="$4"
    local id="${_DAG_IDS[$idx]}"
    local num
    num=$(dag_id_to_number "$id")
    local title="${_DAG_TITLES[$idx]}"
    local deps="${_DAG_DEPS[$idx]}"

    local suffix=""
    case "$status" in
        ready)   suffix="  (ready)" ;;
        blocked)
            if [[ -n "$deps" ]]; then
                suffix="  (blocked by ${deps})"
            else
                suffix="  (pending)"
            fi
            ;;
    esac

    printf "  %b %-5s %s%s\n" "$sym" "$id" "$title" "$suffix"

    if [[ "$show_deps" == "true" ]] && [[ -n "$deps" ]]; then
        printf "         depends: %s\n" "$deps"
    fi
}

#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# timing.sh — TIMING_REPORT.md emission and top-phase extraction (M46)
#
# Sourced by finalize.sh — do not run directly.
# Expects: _PHASE_TIMINGS associative array from common.sh
# Expects: _STAGE_DURATION associative array from tekhton.sh
# Expects: LOG_DIR, TIMESTAMP, TOTAL_TIME from caller
#
# Provides:
#   _hook_emit_timing_report — writes TIMING_REPORT.md at run end
#   _get_top_phases N         — prints top N phases by duration
#   _format_timing_banner     — prints top-3 for completion banner
# =============================================================================

# _compute_total_phase_time — sums all recorded phase durations.
# Prints the total in seconds.
_compute_total_phase_time() {
    local total=0
    local key
    for key in "${!_PHASE_TIMINGS[@]}"; do
        total=$(( total + ${_PHASE_TIMINGS[$key]:-0} ))
    done
    echo "$total"
}

# _get_top_phases N — prints the top N phases sorted by duration (descending).
# Output format: "duration|name" per line (for easy parsing).
_get_top_phases() {
    local n="${1:-3}"
    local key
    # Collect all phases into sortable format
    {
        for key in "${!_PHASE_TIMINGS[@]}"; do
            local dur="${_PHASE_TIMINGS[$key]:-0}"
            [[ "$dur" -gt 0 ]] && echo "${dur}|${key}"
        done
    } | sort -t'|' -k1 -rn | head -n "$n"
}

# _phase_display_name KEY — converts internal phase keys to human-friendly names.
# E.g. "coder_agent" → "Coder (agent)", "build_gate_analyze" → "Build gate (analyze)"
_phase_display_name() {
    local key="$1"
    case "$key" in
        startup)                echo "Startup" ;;
        config_load)            echo "Config load + detection" ;;
        indexer)                echo "Indexer (repo map)" ;;
        scout_prompt)           echo "Scout (prompt assembly)" ;;
        scout_agent)            echo "Scout (agent)" ;;
        coder_prompt)           echo "Coder (prompt assembly)" ;;
        coder_agent)            echo "Coder (agent)" ;;
        coder_continuation)     echo "Coder (continuation)" ;;
        reviewer_prompt)        echo "Reviewer (prompt assembly)" ;;
        reviewer_agent)         echo "Reviewer (agent)" ;;
        rework_agent)           echo "Rework (agent)" ;;
        tester_prompt)          echo "Tester (prompt assembly)" ;;
        tester_agent)           echo "Tester (agent)" ;;
        tester_continuation)    echo "Tester (continuation)" ;;
        build_gate)             echo "Build gate" ;;
        build_gate_analyze)     echo "Build gate (analyze)" ;;
        build_gate_compile)     echo "Build gate (compile)" ;;
        build_gate_constraints) echo "Build gate (constraints)" ;;
        build_gate_ui_test)     echo "Build gate (UI test)" ;;
        build_gate_ui_validate) echo "Build gate (UI validate)" ;;
        intake_agent)           echo "Intake (agent)" ;;
        security_agent)         echo "Security (agent)" ;;
        architect_agent)        echo "Architect (agent)" ;;
        context_assembly)       echo "Context assembly" ;;
        finalization)           echo "Finalization" ;;
        preflight_fix)          echo "Preflight fix" ;;
        *)                      echo "$key" ;;
    esac
}

# _format_timing_banner — prints a concise top-3 summary for the completion banner.
# Output: one line per top phase, e.g. "  Coder (agent): 4m 22s (68%)"
_format_timing_banner() {
    local total_time="${TOTAL_TIME:-0}"
    if [[ "$total_time" -eq 0 ]]; then
        total_time=$(_compute_total_phase_time)
    fi
    [[ "$total_time" -eq 0 ]] && return 0

    while IFS='|' read -r dur name; do
        [[ -z "$dur" ]] && continue
        local display_name
        display_name=$(_phase_display_name "$name")
        local human_dur
        human_dur=$(_format_duration_human "$dur")
        local pct=0
        if [[ "$total_time" -gt 0 ]]; then
            pct=$(( (dur * 100) / total_time ))
        fi
        echo "  ${display_name}: ${human_dur} (${pct}%)"
    done < <(_get_top_phases 3)
}

# _hook_emit_timing_report EXIT_CODE — writes TIMING_REPORT.md to LOG_DIR.
# Registered as a finalize hook; runs on both success and failure.
_hook_emit_timing_report() {
    # shellcheck disable=SC2034  # exit_code used for hook interface
    local exit_code="$1"

    # Close any unclosed phases (graceful handling for phases left open on crash)
    local key
    for key in "${!_PHASE_STARTS[@]}"; do
        _phase_end "$key" 2>/dev/null || true
    done

    # Skip if no phases were recorded
    if [[ ${#_PHASE_TIMINGS[@]} -eq 0 ]]; then
        return 0
    fi

    local report_dir="${LOG_DIR:-${PROJECT_DIR:-.}/.claude/logs}"
    mkdir -p "$report_dir" 2>/dev/null || true
    local report_file="${report_dir}/TIMING_REPORT.md"

    local total_time="${TOTAL_TIME:-0}"
    if [[ "$total_time" -eq 0 ]]; then
        total_time=$(_compute_total_phase_time)
    fi

    local total_human
    total_human=$(_format_duration_human "$total_time")

    # Build the table rows sorted by duration descending
    local table_rows=""
    while IFS='|' read -r dur name; do
        [[ -z "$dur" ]] && continue
        local display_name
        display_name=$(_phase_display_name "$name")
        local human_dur
        human_dur=$(_format_duration_human "$dur")
        local pct="<1"
        if [[ "$total_time" -gt 0 ]] && [[ "$dur" -gt 0 ]]; then
            pct=$(( (dur * 100) / total_time ))
            [[ "$pct" -eq 0 ]] && pct="<1"
        fi
        table_rows="${table_rows}| ${display_name} | ${human_dur} | ${pct}% |
"
    done < <(
        for key in "${!_PHASE_TIMINGS[@]}"; do
            local d="${_PHASE_TIMINGS[$key]:-0}"
            [[ "$d" -gt 0 ]] && echo "${d}|${key}"
        done | sort -t'|' -k1 -rn
    )

    # Agent call count
    local agent_calls="${TOTAL_AGENT_INVOCATIONS:-0}"
    local max_calls="${MAX_AUTONOMOUS_AGENT_CALLS:-20}"

    local ts="${TIMESTAMP:-$(date +%Y%m%d_%H%M%S)}"

    cat > "$report_file" <<EOF
## Timing Report — run_${ts}

> **Note:** Some phases are nested (e.g., \`coder_prompt\` runs inside
> \`context_assembly\`). Percentage totals may slightly exceed the expected
> sum due to this overlap. Individual phase durations are accurate.

| Phase | Duration | % of Total |
|-------|----------|-----------|
${table_rows}
Total wall time: ${total_human}
Agent calls: ${agent_calls} (of ${max_calls} max)
EOF

    log "Timing report written to ${report_file}"
}

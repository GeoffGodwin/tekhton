#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# dashboard_parsers_runs_files.sh — Legacy RUN_SUMMARY_*.json file parser.
# Fallback path when metrics.jsonl doesn't exist.
#
# Sourced by dashboard_parsers_runs.sh — do not run directly.
# Expects: _json_escape() from causality.sh
# =============================================================================

# _parse_run_summaries_from_files DIR DEPTH
# Legacy path: read individual RUN_SUMMARY_*.json files (fallback when
# metrics.jsonl doesn't exist).
_parse_run_summaries_from_files() {
    local dir="$1"
    local depth="${2:-50}"

    local result="["
    local first=true
    local count=0

    # Note: No zero-turn filter is required here. RUN_SUMMARY_*.json files are written
    # only on successful pipeline completion by _hook_finalize. Unlike metrics.jsonl,
    # which accumulates noise records from error traps and crash paths, these JSON files
    # are never produced by failure modes — every record represents a completed run.
    while IFS= read -r summary_file; do
        [[ "$count" -ge "$depth" ]] && break
        [[ ! -f "$summary_file" ]] && continue

        local json_content=""
        # Prefer python3 for JSON parsing if available
        if command -v python3 &>/dev/null; then
            json_content=$(python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    print(json.dumps({
        'outcome': d.get('outcome', 'unknown'),
        'total_turns': d.get('total_turns', d.get('total_agent_calls', 0)),
        'total_time_s': d.get('total_time_s', d.get('wall_clock_seconds', 0)),
        'milestone': d.get('milestone', ''),
        'run_type': d.get('run_type', 'adhoc'),
        'task_label': d.get('task_label', ''),
        'timestamp': d.get('timestamp', ''),
        'team': d.get('team', ''),
        'stages': d.get('stages', {}),
        'causal_primary_category': d.get('causal_context', {}).get('primary_category', ''),
        'causal_primary_subcategory': d.get('causal_context', {}).get('primary_subcategory', ''),
        'build_fix_outcome': d.get('build_fix_stats', {}).get('outcome', 'not_run'),
        'build_fix_attempts': d.get('build_fix_stats', {}).get('attempts', 0),
        'recovery_route': d.get('recovery_routing', {}).get('route_taken', 'save_exit'),
        'preflight_ui_detected': d.get('preflight_ui', {}).get('interactive_config_detected', False),
        'preflight_ui_patched': d.get('preflight_ui', {}).get('reporter_auto_patched', False)
    }))
except: pass
" "$summary_file" 2>/dev/null || true)
        fi

        # Fallback: portable sed extraction (no grep -P)
        if [[ -z "$json_content" ]]; then
            local outcome
            outcome=$(sed -n 's/.*"outcome"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$summary_file" 2>/dev/null | head -1)
            : "${outcome:=unknown}"
            local turns
            turns=$(sed -n 's/.*"total_turns"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$summary_file" 2>/dev/null | head -1)
            [[ -z "$turns" ]] && turns=$(sed -n 's/.*"total_agent_calls"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$summary_file" 2>/dev/null | head -1)
            : "${turns:=0}"
            local time_s
            time_s=$(sed -n 's/.*"total_time_s"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$summary_file" 2>/dev/null | head -1)
            [[ -z "$time_s" ]] && time_s=$(sed -n 's/.*"wall_clock_seconds"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$summary_file" 2>/dev/null | head -1)
            : "${time_s:=0}"
            local milestone
            milestone=$(sed -n 's/.*"milestone"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$summary_file" 2>/dev/null | head -1)
            : "${milestone:=}"
            local run_type
            run_type=$(sed -n 's/.*"run_type"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$summary_file" 2>/dev/null | head -1)
            : "${run_type:=adhoc}"
            local task_label
            task_label=$(sed -n 's/.*"task_label"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$summary_file" 2>/dev/null | head -1)
            : "${task_label:=}"
            # M132: extract enrichment fields via portable sed (no grep -oP)
            local recovery_route
            recovery_route=$(sed -n 's/.*"route_taken"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$summary_file" 2>/dev/null | head -1)
            : "${recovery_route:=save_exit}"
            local build_fix_outcome
            build_fix_outcome=$(sed -n 's/.*"outcome"[[:space:]]*:[[:space:]]*"\(passed\|exhausted\|no_progress\|not_run\)".*/\1/p' "$summary_file" 2>/dev/null | head -1)
            : "${build_fix_outcome:=not_run}"
            json_content="{\"outcome\":\"$(_json_escape "${outcome}")\",\"total_turns\":${turns},\"total_time_s\":${time_s},\"milestone\":\"$(_json_escape "${milestone}")\",\"run_type\":\"$(_json_escape "${run_type}")\",\"task_label\":\"$(_json_escape "${task_label}")\",\"stages\":{},\"recovery_route\":\"$(_json_escape "${recovery_route}")\",\"build_fix_outcome\":\"$(_json_escape "${build_fix_outcome}")\"}"
        fi

        if [[ -n "$json_content" ]]; then
            if [[ "$first" = true ]]; then
                first=false
            else
                result="${result},"
            fi
            result="${result}${json_content}"
        fi
        count=$(( count + 1 ))
    done < <(ls -t "$dir"/RUN_SUMMARY_*.json 2>/dev/null || true)

    result="${result}]"
    echo "$result"
}

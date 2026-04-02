#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# dashboard_parsers_runs.sh — Run summary parsing from metrics.jsonl (primary).
# Python and bash/sed paths. Legacy RUN_SUMMARY_*.json fallback is in
# dashboard_parsers_runs_files.sh (sourced at end of this file).
#
# Sourced by dashboard_parsers.sh — do not run directly.
# Expects: _json_escape() from causality.sh
# =============================================================================

# _parse_run_summaries DIR DEPTH
# Read last N run records from metrics.jsonl (primary) or RUN_SUMMARY_*.json
# files (fallback). metrics.jsonl is authoritative because it accumulates
# across all runs and is written by _hook_record_metrics before dashboard
# emission. Individual RUN_SUMMARY_*.json files are only a fallback for
# projects that have them but lack a metrics.jsonl.
_parse_run_summaries() {
    local dir="$1"
    local depth="${2:-50}"

    local metrics_file="${dir}/metrics.jsonl"

    # Primary path: read from metrics.jsonl (has all historical data)
    if [[ -f "$metrics_file" ]] && [[ -s "$metrics_file" ]]; then
        _parse_run_summaries_from_jsonl "$metrics_file" "$depth"
        return
    fi

    # Fallback: read individual RUN_SUMMARY_*.json files
    _parse_run_summaries_from_files "$dir" "$depth"
}

# _parse_run_summaries_from_jsonl METRICS_FILE DEPTH
# Parse metrics.jsonl (one JSON object per line) and convert to the runs
# array format expected by the frontend. Reads the last DEPTH lines.
_parse_run_summaries_from_jsonl() {
    local metrics_file="$1"
    local depth="$2"

    # Prefer python3 for reliable JSON parsing
    if command -v python3 &>/dev/null; then
        local py_result
        py_result=$(python3 -c "
import json, sys
results = []
lines = []
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if line:
            lines.append(line)
# Take last N lines (most recent runs)
for line in lines[-int(sys.argv[2]):]:
    try:
        d = json.loads(line)
        # Skip crash/noise records with no agent invocations
        if int(d.get('total_turns', 0)) == 0:
            continue
        # Derive run_type from task_type + milestone_mode
        run_type = 'adhoc'
        if d.get('milestone_mode') is True or d.get('milestone_mode') == 'true':
            run_type = 'milestone'
        else:
            tt = d.get('task_type', '')
            if tt == 'bug':
                run_type = 'human_bug'
            elif tt == 'feature':
                run_type = 'human_feat'
            elif tt == 'polish':
                run_type = 'human_polish'
            elif tt == 'drift':
                run_type = 'drift'
        # Build per-stage data from individual turn counts
        # Use adjusted_* as per-stage budget (turn limit from scout calibration)
        stages = {}
        budget_map = {'coder': 'adjusted_coder', 'reviewer': 'adjusted_reviewer', 'tester': 'adjusted_tester'}
        for sname, skey in [('coder','coder_turns'),('reviewer','reviewer_turns'),('tester','tester_turns'),('scout','scout_turns')]:
            t = d.get(skey, 0)
            bkey = budget_map.get(sname)
            b = int(d.get(bkey, 0)) if bkey else 0
            dur = int(d.get(sname + '_duration_s', 0))
            if t and int(t) > 0:
                stages[sname] = {'turns': int(t), 'duration_s': dur, 'budget': b}
        # Estimate per-stage durations proportionally from total_time_s when
        # individual duration_s fields are missing (legacy metrics records).
        total_ts = int(d.get('total_time_s', 0))
        has_any_dur = any(s.get('duration_s', 0) > 0 for s in stages.values())
        if total_ts > 0 and not has_any_dur and stages:
            total_turns = sum(s['turns'] for s in stages.values())
            if total_turns > 0:
                for s in stages.values():
                    s['duration_s'] = round(total_ts * s['turns'] / total_turns)
        # Task label: first 80 chars of task
        task = d.get('task', '')
        task_label = task[:80] if task else ''
        results.append({
            'outcome': d.get('outcome', 'unknown'),
            'total_turns': d.get('total_turns', 0),
            'total_time_s': d.get('total_time_s', 0),
            'milestone': '',
            'run_type': run_type,
            'task_label': task_label,
            'timestamp': d.get('timestamp', ''),
            'team': '',
            'stages': stages
        })
    except:
        pass
# Reverse so newest is first
results.reverse()
print(json.dumps(results))
" "$metrics_file" "$depth" 2>/dev/null || true)

        if [[ -n "$py_result" ]] && [[ "$py_result" != "[]" ]]; then
            echo "$py_result"
            return
        fi
    fi

    # Fallback: portable sed/awk extraction from JSONL
    local result="["
    local first=true
    local count=0

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        [[ "$count" -ge "$depth" ]] && break

        local turns
        turns=$(printf '%s' "$line" | sed -n 's/.*"total_turns"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' | head -1)
        : "${turns:=0}"
        # Skip crash/noise records with no agent invocations
        [[ "$turns" -eq 0 ]] && continue

        local outcome
        outcome=$(printf '%s' "$line" | sed -n 's/.*"outcome"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
        : "${outcome:=unknown}"
        local time_s
        time_s=$(printf '%s' "$line" | sed -n 's/.*"total_time_s"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' | head -1)
        : "${time_s:=0}"
        local task_type
        task_type=$(printf '%s' "$line" | sed -n 's/.*"task_type"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
        : "${task_type:=adhoc}"
        local ms_mode
        ms_mode=$(printf '%s' "$line" | sed -n 's/.*"milestone_mode"[[:space:]]*:[[:space:]]*\([a-z]*\).*/\1/p' | head -1)
        local run_type="adhoc"
        if [[ "$ms_mode" = "true" ]]; then
            run_type="milestone"
        else
            case "$task_type" in
                bug) run_type="human_bug" ;;
                feature) run_type="human_feat" ;;
                polish) run_type="human_polish" ;;
                drift) run_type="drift" ;;
            esac
        fi
        local task_label
        task_label=$(printf '%s' "$line" | sed -n 's/.*"task"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
        task_label="${task_label:0:80}"
        local timestamp
        timestamp=$(printf '%s' "$line" | sed -n 's/.*"timestamp"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)

        # Extract per-stage turn counts and budgets (mirrors Python parser)
        local coder_t reviewer_t tester_t scout_t
        coder_t=$(printf '%s' "$line" | sed -n 's/.*"coder_turns"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' | head -1)
        reviewer_t=$(printf '%s' "$line" | sed -n 's/.*"reviewer_turns"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' | head -1)
        tester_t=$(printf '%s' "$line" | sed -n 's/.*"tester_turns"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' | head -1)
        scout_t=$(printf '%s' "$line" | sed -n 's/.*"scout_turns"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' | head -1)
        local adj_coder adj_reviewer adj_tester
        adj_coder=$(printf '%s' "$line" | sed -n 's/.*"adjusted_coder"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' | head -1)
        adj_reviewer=$(printf '%s' "$line" | sed -n 's/.*"adjusted_reviewer"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' | head -1)
        adj_tester=$(printf '%s' "$line" | sed -n 's/.*"adjusted_tester"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' | head -1)
        # Extract per-stage durations when available (added by metrics.sh)
        local coder_dur reviewer_dur tester_dur scout_dur
        coder_dur=$(printf '%s' "$line" | sed -n 's/.*"coder_duration_s"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' | head -1)
        reviewer_dur=$(printf '%s' "$line" | sed -n 's/.*"reviewer_duration_s"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' | head -1)
        tester_dur=$(printf '%s' "$line" | sed -n 's/.*"tester_duration_s"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' | head -1)
        scout_dur=$(printf '%s' "$line" | sed -n 's/.*"scout_duration_s"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' | head -1)
        : "${coder_t:=0}" "${reviewer_t:=0}" "${tester_t:=0}" "${scout_t:=0}"
        : "${adj_coder:=0}" "${adj_reviewer:=0}" "${adj_tester:=0}"
        : "${coder_dur:=0}" "${reviewer_dur:=0}" "${tester_dur:=0}" "${scout_dur:=0}"
        # Estimate per-stage durations proportionally when missing (legacy records)
        if [[ "$time_s" -gt 0 ]] && \
           [[ "$coder_dur" -eq 0 ]] && [[ "$reviewer_dur" -eq 0 ]] && \
           [[ "$tester_dur" -eq 0 ]] && [[ "$scout_dur" -eq 0 ]]; then
            local _total_st=$(( coder_t + reviewer_t + tester_t + scout_t ))
            if [[ "$_total_st" -gt 0 ]]; then
                coder_dur=$(( time_s * coder_t / _total_st ))
                reviewer_dur=$(( time_s * reviewer_t / _total_st ))
                tester_dur=$(( time_s * tester_t / _total_st ))
                scout_dur=$(( time_s * scout_t / _total_st ))
            fi
        fi
        local stages_json="{"
        local sfirst=true
        local _sn _st _sb _sd
        for _sn in coder reviewer tester scout; do
            case "$_sn" in
                coder)    _st="$coder_t"; _sb="$adj_coder"; _sd="$coder_dur" ;;
                reviewer) _st="$reviewer_t"; _sb="$adj_reviewer"; _sd="$reviewer_dur" ;;
                tester)   _st="$tester_t"; _sb="$adj_tester"; _sd="$tester_dur" ;;
                scout)    _st="$scout_t"; _sb=0; _sd="$scout_dur" ;;
            esac
            if [[ "$_st" -gt 0 ]]; then
                if [[ "$sfirst" = true ]]; then sfirst=false; else stages_json="${stages_json},"; fi
                stages_json="${stages_json}\"${_sn}\":{\"turns\":${_st},\"duration_s\":${_sd},\"budget\":${_sb}}"
            fi
        done
        stages_json="${stages_json}}"

        local json_content
        json_content="{\"outcome\":\"$(_json_escape "${outcome}")\",\"total_turns\":${turns},\"total_time_s\":${time_s},\"milestone\":\"\",\"run_type\":\"$(_json_escape "${run_type}")\",\"task_label\":\"$(_json_escape "${task_label}")\",\"timestamp\":\"$(_json_escape "${timestamp}")\",\"stages\":${stages_json}}"

        if [[ "$first" = true ]]; then
            first=false
        else
            result="${result},"
        fi
        result="${result}${json_content}"
        count=$(( count + 1 ))
    # Note: Divergent depth-counting semantics from Python path. The Python branch above
    # uses lines[-depth:] to select the last depth JSONL lines, then filters zero-turn
    # records — so zero-turn records consume the depth budget. This bash fallback reads
    # tail -n "$depth" lines but increments count only for non-zero-turn records (the
    # continue guard skips them). Result: the bash path can return fewer records than
    # the Python path when many consecutive crash/noise records are present and depth
    # is the binding constraint. This divergence is benign for normal usage patterns.
    done < <(tail -n "$depth" "$metrics_file" 2>/dev/null | tac 2>/dev/null || tail -n "$depth" "$metrics_file")

    result="${result}]"
    echo "$result"
}

# --- Legacy RUN_SUMMARY_*.json parser (sourced from dashboard_parsers_runs_files.sh) ---
# shellcheck source=lib/dashboard_parsers_runs_files.sh
source "${BASH_SOURCE[0]%/*}/dashboard_parsers_runs_files.sh"

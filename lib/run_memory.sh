#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# run_memory.sh — Structured run-end memory (Milestone 49)
#
# Sourced by finalize.sh — do not run directly.
# Expects: _json_escape() from causality.sh, LOG_DIR, PROJECT_DIR,
#          _CURRENT_MILESTONE, TASK, _ORCH_AGENT_CALLS, _ORCH_ELAPSED
#
# Provides:
#   _hook_emit_run_memory         — finalize hook: append JSONL record
#   build_intake_history_from_memory — query filtered memory for intake prompt
# =============================================================================

# --- Stop words for keyword matching ------------------------------------------
# Used by both emission (task normalization) and query (filter).
_RUN_MEMORY_STOP_WORDS=" the a an is in of to and or for with on at by from that this it be as "

# --- Helpers ------------------------------------------------------------------

# _rm_is_stop_word WORD
# Returns 0 if word is a stop word.
_rm_is_stop_word() {
    local w=" ${1} "
    [[ "$_RUN_MEMORY_STOP_WORDS" == *"$w"* ]]
}

# _rm_extract_keywords TEXT
# Extracts lowercase words (3+ chars), excluding stop words, one per line.
_rm_extract_keywords() {
    local text="$1"
    local lower
    lower=$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')
    local words
    words=$(printf '%s' "$lower" | grep -oE '[a-z0-9_.-]{3,}' || true)
    local word
    while IFS= read -r word; do
        [[ -z "$word" ]] && continue
        _rm_is_stop_word "$word" && continue
        printf '%s\n' "$word"
    done <<< "$words" | sort -u
}

# _rm_extract_decisions
# Best-effort extraction of decisions from ${CODER_SUMMARY_FILE}.
# Returns JSON array string.
_rm_extract_decisions() {
    local summary_file="${PROJECT_DIR:-.}/${CODER_SUMMARY_FILE}"
    local arr="[]"
    [[ ! -f "$summary_file" ]] && printf '%s' "$arr" && return

    # Look for "## What Was Implemented" or "## Architecture Change Proposals"
    # and collect bullet points
    local items=""
    local in_section=false
    while IFS= read -r line; do
        if [[ "$line" =~ ^##\  ]]; then
            if [[ "$line" == *"What Was Implemented"* ]] || \
               [[ "$line" == *"Architecture Change Proposals"* ]] || \
               [[ "$line" == *"Architecture Decisions"* ]]; then
                in_section=true
                continue
            else
                in_section=false
            fi
        fi
        if [[ "$in_section" == true ]] && [[ "$line" =~ ^-\  ]]; then
            local item="${line#- }"
            item="${item#\*\* }"
            # Truncate to 120 chars
            item="${item:0:120}"
            items="${items:+${items},}\"$(_json_escape "$item")\""
        fi
    done < "$summary_file"

    if [[ -n "$items" ]]; then
        printf '[%s]' "$items"
    else
        printf '[]'
    fi
}

# _rm_extract_rework_reasons
# Best-effort extraction from ${REVIEWER_REPORT_FILE}.
# Returns JSON array string.
_rm_extract_rework_reasons() {
    local report_file="${PROJECT_DIR:-.}/${REVIEWER_REPORT_FILE}"
    local arr="[]"
    [[ ! -f "$report_file" ]] && printf '%s' "$arr" && return

    local items=""
    local in_section=false
    while IFS= read -r line; do
        if [[ "$line" =~ ^##\  ]]; then
            if [[ "$line" == *"Blocker"* ]] || [[ "$line" == *"Changes Required"* ]]; then
                in_section=true
                continue
            else
                in_section=false
            fi
        fi
        if [[ "$in_section" == true ]] && [[ "$line" =~ ^-\  ]]; then
            local item="${line#- }"
            item="${item:0:120}"
            items="${items:+${items},}\"$(_json_escape "$item")\""
        fi
    done < "$report_file"

    if [[ -n "$items" ]]; then
        printf '[%s]' "$items"
    else
        printf '[]'
    fi
}

# _rm_extract_test_outcomes
# Returns JSON object with passed/failed/skipped counts.
_rm_extract_test_outcomes() {
    local tester_file="${PROJECT_DIR:-.}/${TESTER_REPORT_FILE}"
    local p=0 f=0 s=0

    if [[ -f "$tester_file" ]]; then
        p=$(grep -ciE '^\s*-\s*\[x\]' "$tester_file" 2>/dev/null || true)
        f=$(grep -ciE '^\s*-\s*\[ \]' "$tester_file" 2>/dev/null || true)
        s=$(grep -ciE 'skip' "$tester_file" 2>/dev/null || true)
        p="${p:-0}"; f="${f:-0}"; s="${s:-0}"
    fi
    printf '{"passed":%d,"failed":%d,"skipped":%d}' "$p" "$f" "$s"
}

# --- Emission -----------------------------------------------------------------

# _hook_emit_run_memory EXIT_CODE
# Appends a structured JSONL record to RUN_MEMORY.jsonl, then prunes.
_hook_emit_run_memory() {
    local exit_code="$1"

    local memory_dir="${LOG_DIR:-${PROJECT_DIR:-.}/.claude/logs}"
    mkdir -p "$memory_dir" 2>/dev/null || true
    local memory_file="${memory_dir}/RUN_MEMORY.jsonl"

    # Run ID
    local run_id="run_${TIMESTAMP:-$(date +%Y%m%d_%H%M%S)}"

    # Milestone
    local milestone
    milestone=$(_json_escape "${_CURRENT_MILESTONE:-none}")

    # Task
    local task_text
    task_text=$(_json_escape "$(printf '%s' "${TASK:-}" | head -c 200)")

    # Files touched
    local files_json="[]"
    local changed_files
    changed_files=$(git diff --name-only HEAD 2>/dev/null || true)
    if [[ -n "$changed_files" ]]; then
        files_json="["
        local first=true
        while IFS= read -r fpath; do
            [[ -z "$fpath" ]] && continue
            local safe
            safe=$(_json_escape "$fpath")
            if [[ "$first" = true ]]; then
                files_json="${files_json}\"${safe}\""
                first=false
            else
                files_json="${files_json},\"${safe}\""
            fi
        done <<< "$changed_files"
        files_json="${files_json}]"
    fi

    # Decisions and rework reasons (best-effort)
    local decisions
    decisions=$(_rm_extract_decisions)
    local rework_reasons
    rework_reasons=$(_rm_extract_rework_reasons)

    # Test outcomes
    local test_outcomes
    test_outcomes=$(_rm_extract_test_outcomes)

    # Duration and agent calls
    local duration="${_ORCH_ELAPSED:-0}"
    local agent_calls="${_ORCH_AGENT_CALLS:-0}"

    # Verdict
    local verdict="FAIL"
    [[ "$exit_code" -eq 0 ]] && verdict="PASS"

    # Emit single-line JSON (JSONL format)
    printf '{"run_id":"%s","milestone":"%s","task":"%s","files_touched":%s,"decisions":%s,"rework_reasons":%s,"test_outcomes":%s,"duration_seconds":%d,"agent_calls":%d,"verdict":"%s"}\n' \
        "$(_json_escape "$run_id")" \
        "$milestone" \
        "$task_text" \
        "$files_json" \
        "$decisions" \
        "$rework_reasons" \
        "$test_outcomes" \
        "$duration" \
        "$agent_calls" \
        "$verdict" \
        >> "$memory_file"

    # Prune if over limit
    _prune_run_memory "$memory_file"

    log_verbose "Run memory appended to ${memory_file}"
}

# --- Pruning ------------------------------------------------------------------

# _prune_run_memory FILE
# FIFO prune: keep only the last RUN_MEMORY_MAX_ENTRIES lines.
_prune_run_memory() {
    local file="$1"
    local max="${RUN_MEMORY_MAX_ENTRIES:-50}"

    [[ ! -f "$file" ]] && return 0

    local count
    count=$(wc -l < "$file" 2>/dev/null || echo "0")
    count=$(echo "$count" | tr -d '[:space:]')

    if [[ "$count" -gt "$max" ]]; then
        local keep_from=$(( count - max + 1 ))
        local tmp="${file}.tmp.$$"
        tail -n +"$keep_from" "$file" > "$tmp"
        mv "$tmp" "$file"
    fi
}

# --- Query (for intake) ------------------------------------------------------

# build_intake_history_from_memory [TASK_TEXT]
# Reads RUN_MEMORY.jsonl, filters by keyword relevance to the given task,
# and outputs a human-readable summary for INTAKE_HISTORY_BLOCK.
# Requires >=1 keyword overlap (case-insensitive, stop words excluded).
build_intake_history_from_memory() {
    local task_text="${1:-${TASK:-}}"
    local memory_dir="${LOG_DIR:-${PROJECT_DIR:-.}/.claude/logs}"
    local memory_file="${memory_dir}/RUN_MEMORY.jsonl"

    [[ ! -f "$memory_file" ]] && return 0

    # Extract keywords from current task
    local task_keywords
    task_keywords=$(_rm_extract_keywords "$task_text")
    [[ -z "$task_keywords" ]] && return 0

    # Read last N entries (newest last in file, but we want recent ones)
    local max_scan=50
    local entries
    entries=$(tail -n "$max_scan" "$memory_file" 2>/dev/null || true)
    [[ -z "$entries" ]] && return 0

    local output=""
    local match_count=0

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        # Extract task and files from the JSONL line using bash string ops
        # Quick keyword check: does any task keyword appear in the line?
        local line_lower
        line_lower=$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]')

        local matched=false
        while IFS= read -r kw; do
            [[ -z "$kw" ]] && continue
            if [[ "$line_lower" == *"$kw"* ]]; then
                matched=true
                break
            fi
        done <<< "$task_keywords"

        [[ "$matched" == false ]] && continue

        # Extract fields with portable sed (no grep -oP which requires GNU grep)
        local run_id milestone task verdict duration
        run_id=$(printf '%s' "$line" | sed -n 's/.*"run_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' 2>/dev/null)
        run_id="${run_id:-unknown}"
        milestone=$(printf '%s' "$line" | sed -n 's/.*"milestone"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' 2>/dev/null)
        milestone="${milestone:-none}"
        task=$(printf '%s' "$line" | sed -n 's/.*"task"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' 2>/dev/null)
        task="${task:-}"
        verdict=$(printf '%s' "$line" | sed -n 's/.*"verdict"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' 2>/dev/null)
        verdict="${verdict:-unknown}"
        duration=$(printf '%s' "$line" | sed -n 's/.*"duration_seconds"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' 2>/dev/null)
        duration="${duration:-0}"

        output="${output}- [${verdict}] ${task} (milestone: ${milestone}, ${duration}s)
"
        match_count=$((match_count + 1))

        # Cap at 10 matches
        [[ "$match_count" -ge 10 ]] && break
    done <<< "$entries"

    if [[ -n "$output" ]]; then
        printf 'Related prior runs (%d matches):\n%s' "$match_count" "$output"
    fi
}

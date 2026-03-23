#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# milestone_split.sh — Pre-flight milestone sizing and null-run auto-split
#
# Sourced by tekhton.sh — do not run directly.
# Expects: milestones.sh, milestone_archival.sh sourced first
#   (uses _extract_milestone_block() and _replace_milestone_block() from archival)
# Expects: config.sh defaults: MILESTONE_SPLIT_*, MILESTONE_AUTO_RETRY,
#          MILESTONE_MAX_SPLIT_DEPTH, CODER_MAX_TURNS_CAP, ADJUSTED_CODER_TURNS
# Expects: _call_planning_batch() from plan.sh (lazy-sourced if needed)
# Expects: render_prompt() from prompts.sh
# Expects: log(), warn(), error(), success() from common.sh
#
# Provides:
#   check_milestone_size      — pre-flight sizing gate
#   split_milestone           — invoke splitting agent and update CLAUDE.md
#   record_milestone_attempt  — log an attempt for the splitter to reference
#   get_milestone_attempts    — read prior attempts for a milestone
#   get_split_depth           — determine recursive split depth from milestone number
#   handle_null_run_split     — auto-split after null-run detection
# =============================================================================

# --- Pre-flight sizing gate ---------------------------------------------------

# check_milestone_size MILESTONE_NUM SCOUT_ESTIMATE
# Compares the scout's coder turn estimate against the configured cap.
# Returns 0 if the milestone fits within limits, 1 if oversized.
check_milestone_size() {
    local milestone_num="$1"
    local scout_estimate="$2"

    if [[ "${MILESTONE_SPLIT_ENABLED:-true}" != "true" ]]; then
        return 0
    fi

    # Use ADJUSTED_CODER_TURNS (post-milestone-override) as the cap reference
    local turn_cap="${ADJUSTED_CODER_TURNS:-${CODER_MAX_TURNS_CAP:-200}}"
    local threshold_pct="${MILESTONE_SPLIT_THRESHOLD_PCT:-120}"

    # Calculate threshold: cap * threshold_pct / 100
    local threshold
    threshold=$(( turn_cap * threshold_pct / 100 ))

    if [[ "${scout_estimate:-0}" -gt "$threshold" ]] 2>/dev/null; then
        warn "Milestone ${milestone_num} estimated at ${scout_estimate} turns (cap: ${turn_cap}, threshold: ${threshold})"
        return 1
    fi

    return 0
}

# --- Split depth tracking -----------------------------------------------------

# get_split_depth MILESTONE_NUM
# Returns the split depth based on the milestone number format.
# "5" → 0, "5.1" → 1, "5.1.1" → 2, "5.1.1.1" → 3
get_split_depth() {
    local num="$1"
    local dots="${num//[^.]/}"
    echo "${#dots}"
}

# --- Milestone attempt tracking -----------------------------------------------

# record_milestone_attempt MILESTONE_NUM OUTCOME TURNS_USED
# Appends a record to .claude/milestone_attempts.log for the splitter to reference.
record_milestone_attempt() {
    local milestone_num="$1"
    local outcome="$2"
    local turns_used="${3:-0}"

    local attempts_file="${PROJECT_DIR}/.claude/milestone_attempts.log"
    mkdir -p "$(dirname "$attempts_file")"

    echo "$(date '+%Y-%m-%d %H:%M:%S')|${milestone_num}|${outcome}|${turns_used}" >> "$attempts_file"
}

# get_milestone_attempts MILESTONE_NUM
# Returns prior attempt records for a milestone (one per line).
get_milestone_attempts() {
    local milestone_num="$1"
    local attempts_file="${PROJECT_DIR}/.claude/milestone_attempts.log"

    if [[ ! -f "$attempts_file" ]]; then
        return
    fi

    # Escape dots for grep
    local num_pattern="${milestone_num//./\\.}"
    grep "|${num_pattern}|" "$attempts_file" 2>/dev/null || true
}

# --- Milestone splitting ------------------------------------------------------

# split_milestone MILESTONE_NUM CLAUDE_MD_PATH
# Invokes an opus-class model to decompose the milestone into 2-4 sub-milestones.
# Updates CLAUDE.md in-place with sub-milestones replacing the original.
# Returns 0 on success, 1 on failure or CANNOT_SPLIT.
split_milestone() {
    local milestone_num="$1"
    local claude_md="${2:-CLAUDE.md}"

    # Check split depth
    local depth
    depth=$(get_split_depth "$milestone_num")
    local max_depth="${MILESTONE_MAX_SPLIT_DEPTH:-3}"

    if [[ "$depth" -ge "$max_depth" ]]; then
        error "Milestone ${milestone_num} is at split depth ${depth} (max: ${max_depth})."
        error "Cannot split further — this milestone is irreducible at this granularity."
        error "Consider architectural rethinking or manual decomposition."
        return 1
    fi

    # Extract the full milestone definition
    local milestone_def
    milestone_def=$(_extract_milestone_block "$milestone_num" "$claude_md") || {
        error "Could not extract milestone ${milestone_num} from ${claude_md}"
        return 1
    }

    # Get prior attempts for context
    local prior_history
    prior_history=$(get_milestone_attempts "$milestone_num")

    # Get the turn cap for the prompt
    local turn_cap="${ADJUSTED_CODER_TURNS:-${CODER_MAX_TURNS_CAP:-200}}"
    local scout_est="${SCOUT_REC_CODER_TURNS:-0}"

    # Lazy-source plan.sh for _call_planning_batch. In the normal execution pipeline,
    # plan.sh is NOT sourced (it's only loaded for --plan/--replan early-exit paths).
    # We source it here on demand rather than eagerly in tekhton.sh to avoid loading
    # planning functions into every pipeline run.
    if ! declare -f _call_planning_batch &>/dev/null; then
        if [[ -f "${TEKHTON_HOME}/lib/plan.sh" ]]; then
            # shellcheck source=lib/plan.sh
            source "${TEKHTON_HOME}/lib/plan.sh"
        else
            error "Cannot split milestone: lib/plan.sh not found."
            return 1
        fi
    fi

    # Set template variables for the prompt (shell scope — render_prompt reads
    # via indirect expansion, no need to export to process environment)
    # shellcheck disable=SC2034  # used by render_prompt() via ${!var_name} indirect expansion
    MILESTONE_DEFINITION="$milestone_def"
    # shellcheck disable=SC2034
    SCOUT_ESTIMATE="$scout_est"
    # shellcheck disable=SC2034
    TURN_CAP="$turn_cap"
    # shellcheck disable=SC2034
    PRIOR_RUN_HISTORY="${prior_history:-No prior attempts.}"

    local split_prompt
    split_prompt=$(render_prompt "milestone_split")

    local split_model="${MILESTONE_SPLIT_MODEL:-${CLAUDE_CODER_MODEL:-claude-sonnet-4-20250514}}"
    local split_turns="${MILESTONE_SPLIT_MAX_TURNS:-15}"

    local log_dir="${LOG_DIR:-.claude/logs}"
    mkdir -p "$log_dir"
    local split_log
    split_log="${log_dir}/$(date +%Y%m%d_%H%M%S)_milestone_split.log"

    log "Splitting milestone ${milestone_num} (model: ${split_model}, max turns: ${split_turns})..."

    local split_output=""
    local split_exit=0
    split_output=$(_call_planning_batch "$split_model" "$split_turns" "$split_prompt" "$split_log") || split_exit=$?

    if [[ "$split_exit" -ne 0 ]] || [[ -z "$split_output" ]]; then
        error "Milestone split agent produced no output."
        return 1
    fi

    # Check for CANNOT_SPLIT signal
    if echo "$split_output" | grep -q '\[CANNOT_SPLIT\]'; then
        warn "Split agent reports milestone ${milestone_num} cannot be decomposed further."
        return 1
    fi

    # Validate the output contains at least 2 sub-milestones
    local sub_count
    sub_count=$(echo "$split_output" | grep -cE "^#{1,5}[[:space:]]*[Mm]ilestone[[:space:]]+${milestone_num//./\\.}\.[0-9]" || echo "0")

    if [[ "$sub_count" -lt 2 ]]; then
        error "Split agent produced ${sub_count} sub-milestone(s) — expected at least 2."
        error "Split output may be malformed. Check log: ${split_log}"
        return 1
    fi

    log "Split produced ${sub_count} sub-milestones for milestone ${milestone_num}"

    # DAG path: write sub-milestone files + update manifest
    if [[ "${MILESTONE_DAG_ENABLED:-true}" == "true" ]] \
       && declare -f has_milestone_manifest &>/dev/null \
       && has_milestone_manifest; then
        if [[ "${_DAG_LOADED:-false}" != "true" ]]; then
            load_manifest 2>/dev/null || true
        fi

        local milestone_dir
        milestone_dir=$(_dag_milestone_dir)

        # Parse sub-milestones from split output and create files + manifest rows
        local sub_num=""
        local sub_title=""
        local sub_block=""
        local sub_nums=()

        while IFS= read -r line; do
            if [[ "$line" =~ ^#{1,5}[[:space:]]*[Mm]ilestone[[:space:]]+([0-9]+([.][0-9]+)*)[[:space:]]*[:.\—\-][[:space:]]*(.*) ]]; then
                # Flush previous sub-milestone
                if [[ -n "$sub_num" ]]; then
                    local sub_main="${sub_num%%.*}"
                    local sub_suffix="${sub_num#"$sub_main"}"
                    local sub_id
                    sub_id=$(printf "m%02d%s" "$sub_main" "$sub_suffix")
                    local sub_slug
                    sub_slug=$(_slugify "$sub_title")
                    local sub_file="${sub_id}-${sub_slug}.md"
                    echo "$sub_block" > "${milestone_dir}/${sub_file}"

                    # Determine deps: first sub depends on parent's deps, rest depend on previous sub
                    local sub_deps=""
                    if [[ ${#sub_nums[@]} -eq 0 ]]; then
                        local parent_id
                        parent_id=$(dag_number_to_id "$milestone_num")
                        sub_deps="${_DAG_DEPS[${_DAG_IDX[$parent_id]}]:-}"
                    else
                        local prev_num="${sub_nums[-1]}"
                        local prev_main="${prev_num%%.*}"
                        local prev_suf="${prev_num#"$prev_main"}"
                        sub_deps=$(printf "m%02d%s" "$prev_main" "$prev_suf")
                    fi

                    # Insert into manifest arrays
                    _DAG_IDS+=("$sub_id")
                    _DAG_TITLES+=("$sub_title")
                    _DAG_STATUSES+=("pending")
                    _DAG_DEPS+=("$sub_deps")
                    _DAG_FILES+=("$sub_file")
                    _DAG_GROUPS+=("")
                    _DAG_IDX["$sub_id"]=$(( ${#_DAG_IDS[@]} - 1 ))

                    sub_nums+=("$sub_num")
                fi
                sub_num="${BASH_REMATCH[1]}"
                sub_title="${BASH_REMATCH[3]}"
                sub_title="${sub_title%"${sub_title##*[![:space:]]}"}"
                sub_block="$line"
                continue
            fi
            if [[ -n "$sub_num" ]]; then
                sub_block="${sub_block}"$'\n'"${line}"
            fi
        done <<< "$split_output"

        # Flush last sub-milestone
        if [[ -n "$sub_num" ]]; then
            local sub_main="${sub_num%%.*}"
            local sub_suffix="${sub_num#"$sub_main"}"
            local sub_id
            sub_id=$(printf "m%02d%s" "$sub_main" "$sub_suffix")
            local sub_slug
            sub_slug=$(_slugify "$sub_title")
            local sub_file="${sub_id}-${sub_slug}.md"
            echo "$sub_block" > "${milestone_dir}/${sub_file}"

            local sub_deps=""
            if [[ ${#sub_nums[@]} -eq 0 ]]; then
                local parent_id
                parent_id=$(dag_number_to_id "$milestone_num")
                sub_deps="${_DAG_DEPS[${_DAG_IDX[$parent_id]}]:-}"
            else
                local prev_num="${sub_nums[-1]}"
                local prev_main="${prev_num%%.*}"
                local prev_suf="${prev_num#"$prev_main"}"
                sub_deps=$(printf "m%02d%s" "$prev_main" "$prev_suf")
            fi

            _DAG_IDS+=("$sub_id")
            _DAG_TITLES+=("$sub_title")
            _DAG_STATUSES+=("pending")
            _DAG_DEPS+=("$sub_deps")
            _DAG_FILES+=("$sub_file")
            _DAG_GROUPS+=("")
            _DAG_IDX["$sub_id"]=$(( ${#_DAG_IDS[@]} - 1 ))

            sub_nums+=("$sub_num")
        fi

        # Mark original milestone as "split" in manifest
        local parent_id
        parent_id=$(dag_number_to_id "$milestone_num")
        dag_set_status "$parent_id" "split"
        save_manifest

        success "Milestone ${milestone_num} split into ${sub_count} sub-milestones (DAG mode)"
        return 0
    fi

    # Inline path: replace the original milestone block in CLAUDE.md
    _replace_milestone_block "$milestone_num" "$claude_md" "$split_output"
    local replace_exit=$?

    if [[ "$replace_exit" -ne 0 ]]; then
        error "Failed to update ${claude_md} with sub-milestones."
        return 1
    fi

    success "Milestone ${milestone_num} split into ${sub_count} sub-milestones in ${claude_md}"
    return 0
}

# --- Null-run auto-split handler ----------------------------------------------

# handle_null_run_split MILESTONE_NUM CLAUDE_MD_PATH
# Called when the coder produces a null-run or minimal output on a milestone.
# Checks for substantive partial work before splitting.
# Returns 0 if split succeeded and pipeline should retry, 1 otherwise.
handle_null_run_split() {
    local milestone_num="$1"
    local claude_md="${2:-CLAUDE.md}"

    if [[ "${MILESTONE_AUTO_RETRY:-true}" != "true" ]]; then
        log "MILESTONE_AUTO_RETRY is disabled — skipping auto-split."
        return 1
    fi

    if [[ "${MILESTONE_SPLIT_ENABLED:-true}" != "true" ]]; then
        log "MILESTONE_SPLIT_ENABLED is disabled — skipping auto-split."
        return 1
    fi

    # Check split depth
    local depth
    depth=$(get_split_depth "$milestone_num")
    local max_depth="${MILESTONE_MAX_SPLIT_DEPTH:-3}"

    if [[ "$depth" -ge "$max_depth" ]]; then
        error "Milestone ${milestone_num} at max split depth (${depth}/${max_depth}) — cannot split further."
        return 1
    fi

    # Check for substantive partial work.
    # We use `git diff --quiet` (unstaged) and `git diff --cached --quiet` (staged)
    # as the activation condition. Then `git diff --stat HEAD` measures scope —
    # `git diff HEAD` (not bare `git diff`) is intentional because it captures
    # both staged and unstaged changes in a single pass.
    local has_substantive_work=false
    local diff_stat=""
    local summary_lines=0

    if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
        diff_stat=$(git diff --stat HEAD 2>/dev/null | tail -1 || true)
    fi

    if [[ -f "CODER_SUMMARY.md" ]]; then
        summary_lines=$(wc -l < "CODER_SUMMARY.md" 2>/dev/null || echo "0")
        summary_lines=$(echo "$summary_lines" | tr -d '[:space:]')
    fi

    # If there's substantial work (files changed AND summary > 20 lines),
    # this is partial progress — don't split, let it resume
    if [[ -n "$diff_stat" ]] && [[ "$summary_lines" -gt 20 ]]; then
        has_substantive_work=true
    fi

    if [[ "$has_substantive_work" = true ]]; then
        log "Coder produced substantive partial work — preserving for resume (not splitting)."
        return 1
    fi

    # Record the failed attempt
    record_milestone_attempt "$milestone_num" "null_run" "${LAST_AGENT_TURNS:-0}"

    # Perform the split
    warn "Null-run detected on milestone ${milestone_num} — attempting auto-split..."

    if ! split_milestone "$milestone_num" "$claude_md"; then
        error "Auto-split failed for milestone ${milestone_num}."
        return 1
    fi

    return 0
}

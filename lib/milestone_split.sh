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
# Expects: _split_read_dag_milestone(), _split_apply_dag() from
#          milestone_split_dag.sh (sourced below)
#
# Provides:
#   check_milestone_size      — pre-flight sizing gate
#   split_milestone           — invoke splitting agent and update manifest/CLAUDE.md
#   record_milestone_attempt  — log an attempt for the splitter to reference
#   get_milestone_attempts    — read prior attempts for a milestone
#   get_split_depth           — determine recursive split depth from milestone number
#   handle_null_run_split     — auto-split after null-run detection (from
#                              milestone_split_nullrun.sh)
# =============================================================================

# shellcheck source=milestone_split_dag.sh disable=SC1091
source "${TEKHTON_HOME}/lib/milestone_split_dag.sh"

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

    # Detect DAG mode once — controls both extraction source and apply path.
    local in_dag=false
    if [[ "${MILESTONE_DAG_ENABLED:-true}" == "true" ]] \
       && declare -f has_milestone_manifest &>/dev/null \
       && has_milestone_manifest; then
        in_dag=true
        if [[ "${_DAG_LOADED:-false}" != "true" ]]; then
            load_manifest 2>/dev/null || true
        fi
    fi

    # Extract the full milestone definition (DAG file or CLAUDE.md).
    local milestone_def
    if [[ "$in_dag" == "true" ]]; then
        milestone_def=$(_split_read_dag_milestone "$milestone_num") || return 1
    else
        milestone_def=$(_extract_milestone_block "$milestone_num" "$claude_md") || {
            error "Could not extract milestone ${milestone_num} from ${claude_md}"
            return 1
        }
    fi

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

    # Apply split — DAG path writes sub-files + splices manifest; inline path
    # replaces the milestone block in CLAUDE.md.
    if [[ "$in_dag" == "true" ]]; then
        if ! _split_apply_dag "$milestone_num" "$split_output"; then
            error "Failed to apply DAG split for milestone ${milestone_num}."
            return 1
        fi
        success "Milestone ${milestone_num} split into ${sub_count} sub-milestones (DAG mode)"
    else
        if ! _replace_milestone_block "$milestone_num" "$claude_md" "$split_output"; then
            error "Failed to update ${claude_md} with sub-milestones."
            return 1
        fi
        success "Milestone ${milestone_num} split into ${sub_count} sub-milestones in ${claude_md}"
    fi

    # Emit milestone_split event (Milestone 13)
    if command -v emit_event &>/dev/null; then
        emit_event "milestone_split" "pipeline" "Split milestone ${milestone_num} into ${sub_count} subs" \
            "${_LAST_STAGE_EVT:-}" "" \
            "{\"milestone\":\"$(_json_escape "$milestone_num")\",\"sub_count\":${sub_count}}" >/dev/null 2>&1 || true
    fi
    if [[ "$in_dag" == "true" ]] && command -v emit_dashboard_milestones &>/dev/null; then
        emit_dashboard_milestones 2>/dev/null || true
    fi
    return 0
}

# --- Null-run auto-split handler (handle_null_run_split) ---------------------
# shellcheck source=milestone_split_nullrun.sh disable=SC1091
source "${TEKHTON_HOME}/lib/milestone_split_nullrun.sh"

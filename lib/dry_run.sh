#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# dry_run.sh — Dry-run orchestration and caching (Milestone 23)
#
# Runs scout + intake agents in preview mode, caches results, and offers to
# continue with a full pipeline run. Cached results can be consumed by the
# next actual run to skip re-running scout and intake.
#
# Sourced by tekhton.sh — do not run directly.
# Expects: TASK, LOG_FILE, TEKHTON_SESSION_DIR, PROJECT_DIR, MILESTONE_MODE
# Expects: log(), warn(), success(), header(), error() from common.sh
# Expects: run_agent() from agent.sh
# Expects: render_prompt() from prompts.sh
# Expects: run_stage_intake() from stages/intake.sh
# =============================================================================

# --- Cache directory and metadata -------------------------------------------

# _dry_run_cache_dir — Returns the path to the dry-run cache directory.
_dry_run_cache_dir() {
    echo "${DRY_RUN_CACHE_DIR:-${PROJECT_DIR:-.}/.claude/dry_run_cache}"
}

# _dry_run_task_hash — Compute a stable hash of the task string.
# Uses md5sum (or md5 on macOS) for a short, deterministic fingerprint.
_dry_run_task_hash() {
    local task="$1"
    if command -v md5sum &>/dev/null; then
        echo -n "$task" | md5sum | awk '{print $1}'
    elif command -v md5 &>/dev/null; then
        echo -n "$task" | md5
    else
        # Fallback: use cksum (always available)
        echo -n "$task" | cksum | awk '{print $1}'
    fi
}

# _dry_run_git_head — Returns current git HEAD sha (short form).
_dry_run_git_head() {
    git rev-parse HEAD 2>/dev/null || echo "no-git"
}

# --- Cache validation -------------------------------------------------------

# validate_dry_run_cache — Returns 0 (valid) when ALL conditions met:
#   - Cache exists and is non-empty
#   - Task hash matches (same task string)
#   - Git HEAD sha matches (no code changes since dry-run)
#   - Cache age < DRY_RUN_CACHE_TTL
# Returns 1 (invalid) and logs reason when any condition fails.
validate_dry_run_cache() {
    local task="$1"
    local cache_dir
    cache_dir=$(_dry_run_cache_dir)
    local meta_file="${cache_dir}/DRY_RUN_META.json"

    if [[ ! -d "$cache_dir" ]] || [[ ! -f "$meta_file" ]]; then
        log "Dry-run cache: no cache found."
        return 1
    fi

    # Parse metadata (simple grep-based — no jq dependency)
    local cached_task_hash cached_git_head cached_timestamp cached_ttl
    cached_task_hash=$(grep -o '"task_hash":"[^"]*"' "$meta_file" | head -1 | cut -d'"' -f4)
    cached_git_head=$(grep -o '"git_head":"[^"]*"' "$meta_file" | head -1 | cut -d'"' -f4)
    cached_timestamp=$(grep -o '"timestamp":[0-9]*' "$meta_file" | head -1 | cut -d: -f2)
    cached_ttl=$(grep -o '"cache_ttl":[0-9]*' "$meta_file" | head -1 | cut -d: -f2)

    if [[ -z "$cached_task_hash" ]] || [[ -z "$cached_git_head" ]] || [[ -z "$cached_timestamp" ]]; then
        log "Dry-run cache: metadata is incomplete or corrupted."
        return 1
    fi

    # Task hash check
    local current_hash
    current_hash=$(_dry_run_task_hash "$task")
    if [[ "$current_hash" != "$cached_task_hash" ]]; then
        log "Dry-run cache: task changed since dry-run (hash mismatch)."
        return 1
    fi

    # Git HEAD check — ANY code change invalidates
    local current_head
    current_head=$(_dry_run_git_head)
    if [[ "$current_head" != "$cached_git_head" ]]; then
        log "Dry-run cache: code changed since dry-run (HEAD mismatch)."
        return 1
    fi

    # TTL check
    local now age ttl
    now=$(date +%s)
    age=$(( now - cached_timestamp ))
    ttl="${cached_ttl:-${DRY_RUN_CACHE_TTL:-3600}}"
    if [[ "$age" -ge "$ttl" ]]; then
        log "Dry-run cache: expired (age ${age}s > TTL ${ttl}s)."
        return 1
    fi

    log "Dry-run cache: valid (age ${age}s, TTL ${ttl}s)."
    return 0
}

# --- Cache consumption ------------------------------------------------------

# consume_dry_run_cache — Called at start of a real run when valid cache exists.
# Copies cached reports to active session, sets skip flags, deletes cache.
consume_dry_run_cache() {
    local cache_dir
    cache_dir=$(_dry_run_cache_dir)
    local cached_timestamp
    cached_timestamp=$(grep -o '"timestamp":[0-9]*' "${cache_dir}/DRY_RUN_META.json" | head -1 | cut -d: -f2)

    local now age_minutes
    now=$(date +%s)
    age_minutes=$(( (now - cached_timestamp) / 60 ))

    # Copy cached scout report
    if [[ -f "${cache_dir}/SCOUT_REPORT.md" ]]; then
        cp "${cache_dir}/SCOUT_REPORT.md" "SCOUT_REPORT.md"
        SCOUT_CACHED=true
        export SCOUT_CACHED
    fi

    # Copy cached intake report
    if [[ -f "${cache_dir}/INTAKE_REPORT.md" ]]; then
        cp "${cache_dir}/INTAKE_REPORT.md" "${INTAKE_REPORT_FILE:-INTAKE_REPORT.md}"
        INTAKE_CACHED=true
        export INTAKE_CACHED
    fi

    log "Using cached dry-run results (scout + intake from ${age_minutes}m ago)."

    # Delete cache after consumption (one-use)
    rm -rf "$cache_dir"
}

# discard_dry_run_cache — Remove stale or unwanted cache.
discard_dry_run_cache() {
    local cache_dir
    cache_dir=$(_dry_run_cache_dir)
    if [[ -d "$cache_dir" ]]; then
        rm -rf "$cache_dir"
        log "Dry-run cache discarded."
    fi
}

# --- Cache writing ----------------------------------------------------------

# _write_dry_run_cache — Save scout and intake results to cache directory.
_write_dry_run_cache() {
    local task="$1"
    local cache_dir
    cache_dir=$(_dry_run_cache_dir)

    mkdir -p "$cache_dir"

    # Copy reports if they exist
    if [[ -f "SCOUT_REPORT.md" ]]; then
        cp "SCOUT_REPORT.md" "${cache_dir}/SCOUT_REPORT.md"
    fi
    if [[ -f "${INTAKE_REPORT_FILE:-INTAKE_REPORT.md}" ]]; then
        cp "${INTAKE_REPORT_FILE:-INTAKE_REPORT.md}" "${cache_dir}/INTAKE_REPORT.md"
    fi

    # Write metadata
    local task_hash git_head now ttl
    task_hash=$(_dry_run_task_hash "$task")
    git_head=$(_dry_run_git_head)
    now=$(date +%s)
    ttl="${DRY_RUN_CACHE_TTL:-3600}"

    cat > "${cache_dir}/DRY_RUN_META.json" <<METAEOF
{"task_hash":"${task_hash}","git_head":"${git_head}","timestamp":${now},"cache_ttl":${ttl},"task":"$(_json_escape_simple "$task")"}
METAEOF
}

# _json_escape_simple — Minimal JSON string escaping for task text.
# Escapes backslashes, double quotes, and newlines.
_json_escape_simple() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    echo -n "$s"
}

# --- Preview formatting -----------------------------------------------------

# _format_dry_run_preview — Print formatted preview to terminal.
_format_dry_run_preview() {
    local task="$1"
    local intake_verdict="${2:-N/A}"
    local intake_confidence="${3:-0}"
    local scout_file_count="${4:-0}"
    local scout_summary="${5:-}"
    local estimated_turns="${6:-unknown}"
    local security_flag="${7:-NO}"

    echo
    echo -e "${BOLD:-}══════════════════════════════════════${NC:-}"
    echo -e "${BOLD:-}  Tekhton — Dry Run Preview${NC:-}"
    echo -e "${BOLD:-}══════════════════════════════════════${NC:-}"
    echo -e "  Task:       ${task}"

    if [[ "$intake_verdict" != "N/A" ]]; then
        local _color="${GREEN:-}"
        if [[ "$intake_verdict" == "NEEDS_CLARITY" ]]; then
            _color="${YELLOW:-}"
        elif [[ "$intake_verdict" == "REJECT" ]]; then
            _color="${RED:-}"
        fi
        echo -e "  Intake:     ${_color}${intake_verdict}${NC:-} (confidence ${intake_confidence})"
    fi

    if [[ "$scout_file_count" -gt 0 ]]; then
        echo
        echo -e "  Scout identified ${BOLD:-}${scout_file_count}${NC:-} files:"
        if [[ -n "$scout_summary" ]]; then
            echo "$scout_summary" | while IFS= read -r line; do
                echo "    $line"
            done
        fi
        echo -e "  Estimated:  ~${estimated_turns} turns (coder)"
    fi

    if [[ "$security_flag" == "YES" ]]; then
        echo
        echo -e "  ${YELLOW:-}Security-relevant: YES${NC:-} (auth, config, or sensitive file changes)"
    fi

    echo -e "${BOLD:-}══════════════════════════════════════${NC:-}"
    echo
}

# _parse_scout_preview — Extract preview data from SCOUT_REPORT.md.
# Sets caller-scoped variables: _scout_file_count, _scout_summary,
# _estimated_turns, _security_flag.
_parse_scout_preview() {
    local report_file="$1"
    _scout_file_count=0
    _scout_summary=""
    _estimated_turns="unknown"
    _security_flag="NO"

    if [[ ! -f "$report_file" ]]; then
        return 0
    fi

    # Count files listed in the scout report (lines starting with - or *)
    _scout_file_count=$(grep -cE '^\s*[-*]\s+' "$report_file" 2>/dev/null || echo "0")

    # Extract file listing (first 10 lines of file references)
    _scout_summary=$(grep -E '^\s*[-*]\s+' "$report_file" 2>/dev/null | head -10 || true)
    if [[ "$_scout_file_count" -gt 10 ]]; then
        _scout_summary="${_scout_summary}
    ... and $((_scout_file_count - 10)) more"
    fi

    # Extract estimated turns from scout report
    local _turns_line
    _turns_line=$(grep -iE '(recommend|estimat|suggest).*turn' "$report_file" 2>/dev/null | head -1 || true)
    if [[ -n "$_turns_line" ]]; then
        _estimated_turns=$(echo "$_turns_line" | grep -oE '[0-9]+' | head -1 || echo "unknown")
    fi

    # Security flag: check for auth, security, credential, config, middleware mentions
    if grep -qiE '(auth|security|credential|secret|token|middleware|permission|encrypt|password)' "$report_file" 2>/dev/null; then
        _security_flag="YES"
    fi
}

# _parse_intake_preview — Extract verdict and confidence from INTAKE_REPORT.md.
# Sets caller-scoped variables: _intake_verdict, _intake_confidence.
_parse_intake_preview() {
    local report_file="$1"
    _intake_verdict="N/A"
    _intake_confidence=0

    if [[ ! -f "$report_file" ]]; then
        return 0
    fi

    # Extract verdict (PASS, TWEAKED, NEEDS_CLARITY, REJECT)
    local _verdict_line
    _verdict_line=$(grep -iE '^\s*##?\s*Verdict' -A2 "$report_file" 2>/dev/null | tail -1 || true)
    if [[ -n "$_verdict_line" ]]; then
        _intake_verdict=$(echo "$_verdict_line" | grep -oE '(PASS|TWEAKED|NEEDS_CLARITY|REJECT)' | head -1 || echo "N/A")
    fi

    # Extract confidence score
    local _conf_line
    _conf_line=$(grep -iE '(confidence|score)' "$report_file" 2>/dev/null | head -1 || true)
    if [[ -n "$_conf_line" ]]; then
        _intake_confidence=$(echo "$_conf_line" | grep -oE '[0-9]+' | head -1 || echo "0")
    fi
}

# --- Main dry-run orchestration ---------------------------------------------

# run_dry_run — Execute dry-run mode: run intake + scout, display preview,
# cache results, and optionally continue to full pipeline.
# Returns: sets DRY_RUN_CONTINUE=true if user wants to continue.
run_dry_run() {
    local task="$1"
    local has_intake=false
    local has_scout=false

    header "Tekhton — Dry Run"
    log "Task: ${task}"

    # --- Run intake gate (if enabled) -----------------------------------------
    if [[ "${INTAKE_AGENT_ENABLED:-true}" == "true" ]]; then
        log "Running intake evaluation..."
        run_stage_intake || true
        if [[ -f "${INTAKE_REPORT_FILE:-INTAKE_REPORT.md}" ]]; then
            has_intake=true
        fi
    else
        log "Intake agent disabled. Skipping."
    fi

    # --- Run scout agent ------------------------------------------------------
    log "Running scout agent for file discovery and complexity estimation..."

    export HUMAN_NOTES_CONTENT=""
    if command -v extract_human_notes &>/dev/null && should_claim_notes; then
        HUMAN_NOTES_CONTENT=$(extract_human_notes 2>/dev/null || true)
    fi

    # Build architecture block for scout if available
    # shellcheck disable=SC2034  # ARCHITECTURE_BLOCK used by render_prompt("scout")
    ARCHITECTURE_BLOCK=""
    if [[ -n "${ARCHITECTURE_FILE:-}" ]] && [[ -f "${ARCHITECTURE_FILE}" ]]; then
        local _arch_content
        _arch_content=$(_safe_read_file "${ARCHITECTURE_FILE}" "ARCHITECTURE_FILE")
        # shellcheck disable=SC2034  # ARCHITECTURE_BLOCK used by render_prompt("scout")
        ARCHITECTURE_BLOCK="
## Architecture Map (use this to find files — do NOT explore blindly)
$(_wrap_file_content "ARCHITECTURE" "$_arch_content")"
    fi

    # Generate repo map for scout if available
    REPO_MAP_CONTENT=""
    if [[ "${INDEXER_AVAILABLE:-false}" == "true" ]]; then
        if run_repo_map "$task" 2>/dev/null; then
            log "[indexer] Repo map generated (${#REPO_MAP_CONTENT} chars)."
        fi
    fi

    # M45: Set fallback flag and reduce tools when repo map available
    export SCOUT_NO_REPO_MAP=""
    if [[ -z "${REPO_MAP_CONTENT}" ]]; then
        SCOUT_NO_REPO_MAP="true"
    fi
    local _scout_tools="${AGENT_TOOLS_SCOUT:-}"
    if [[ -n "${REPO_MAP_CONTENT}" ]] && [[ "${SCOUT_REPO_MAP_TOOLS_ONLY:-true}" = "true" ]]; then
        _scout_tools="Read Glob Grep Write"
    fi

    SCOUT_PROMPT=$(render_prompt "scout")

    run_agent \
        "Scout" \
        "${CLAUDE_SCOUT_MODEL:-${CLAUDE_JR_CODER_MODEL:-sonnet}}" \
        "${SCOUT_MAX_TURNS:-20}" \
        "$SCOUT_PROMPT" \
        "$LOG_FILE" \
        "$_scout_tools"

    if [[ -f "SCOUT_REPORT.md" ]]; then
        has_scout=true
        success "Scout completed."
    else
        warn "Scout did not produce SCOUT_REPORT.md."
    fi

    # --- Validate results --------------------------------------------------
    if [[ "$has_intake" == false ]] && [[ "$has_scout" == false ]]; then
        warn "No stages produced meaningful preview data."
        warn "Consider running the full pipeline instead: tekhton \"${task}\""
        _TEKHTON_CLEAN_EXIT=true
        return 0
    fi

    # --- Parse and display preview ------------------------------------------
    local _intake_verdict="N/A" _intake_confidence=0
    if [[ "$has_intake" == true ]]; then
        _parse_intake_preview "${INTAKE_REPORT_FILE:-INTAKE_REPORT.md}"
    fi

    local _scout_file_count=0 _scout_summary="" _estimated_turns="unknown" _security_flag="NO"
    if [[ "$has_scout" == true ]]; then
        _parse_scout_preview "SCOUT_REPORT.md"
    fi

    _format_dry_run_preview \
        "$task" \
        "$_intake_verdict" \
        "$_intake_confidence" \
        "$_scout_file_count" \
        "$_scout_summary" \
        "$_estimated_turns" \
        "$_security_flag"

    # --- Cache results ------------------------------------------------------
    _write_dry_run_cache "$task"
    log "Results cached to $(_dry_run_cache_dir)."

    # --- Emit to dashboard if available -------------------------------------
    if command -v emit_dashboard_run_state &>/dev/null; then
        # shellcheck disable=SC2034  # PIPELINE_STATUS used by emit_dashboard_run_state
        PIPELINE_STATUS="dry_run_complete"
        emit_dashboard_run_state 2>/dev/null || true
    fi

    # --- Interactive continue prompt ----------------------------------------
    echo -e "  Continue with full run? [${BOLD:-}y${NC:-}/n]"
    local _choice
    read -r _choice
    case "$_choice" in
        [Yy]|"")
            DRY_RUN_CONTINUE=true
            export DRY_RUN_CONTINUE
            log "Continuing to full pipeline run..."
            # Consume the cache we just wrote (sets SCOUT_CACHED, INTAKE_CACHED)
            consume_dry_run_cache
            ;;
        *)
            DRY_RUN_CONTINUE=false
            export DRY_RUN_CONTINUE
            log "Dry-run results saved. Resume later with: tekhton --continue-preview \"${task}\""
            # Save state for --continue-preview
            _save_dry_run_state "$task"
            ;;
    esac
}

# _save_dry_run_state — Persist dry-run state for --continue-preview resume.
_save_dry_run_state() {
    local task="$1"
    if command -v write_pipeline_state &>/dev/null; then
        write_pipeline_state \
            "dry_run" \
            "dry_run_complete" \
            "--continue-preview" \
            "$task" \
            "Dry-run completed. Use --continue-preview to resume." \
            "${_CURRENT_MILESTONE:-}"
    fi
}

# load_dry_run_for_continue — Load cached dry-run for --continue-preview.
# Returns 0 if cache is valid and consumed, 1 otherwise.
load_dry_run_for_continue() {
    local task="$1"

    if ! validate_dry_run_cache "$task"; then
        warn "Dry-run cache is invalid or expired. Running fresh pipeline."
        discard_dry_run_cache
        return 1
    fi

    consume_dry_run_cache
    # Clear the pipeline state since we're resuming
    if command -v clear_pipeline_state &>/dev/null; then
        clear_pipeline_state
    fi
    return 0
}

# offer_cached_dry_run — At pipeline startup, check for valid cache and offer
# to use it. Called before stage execution in tekhton.sh.
# Returns 0 if cache was consumed, 1 if not (run normally).
offer_cached_dry_run() {
    local task="$1"

    if ! validate_dry_run_cache "$task"; then
        return 1
    fi

    local cache_dir
    cache_dir=$(_dry_run_cache_dir)
    local cached_timestamp
    cached_timestamp=$(grep -o '"timestamp":[0-9]*' "${cache_dir}/DRY_RUN_META.json" | head -1 | cut -d: -f2)
    local now age_minutes
    now=$(date +%s)
    age_minutes=$(( (now - cached_timestamp) / 60 ))

    echo
    log "Found cached dry-run from ${age_minutes}m ago."
    echo -e "  Use cached scout results? [${BOLD:-}y${NC:-}/n/fresh]"
    local _choice
    read -r _choice
    case "$_choice" in
        [Yy]|"")
            consume_dry_run_cache
            return 0
            ;;
        fresh)
            discard_dry_run_cache
            log "Cache discarded. Running fresh."
            return 1
            ;;
        *)
            log "Cache preserved. Running without cached results."
            return 1
            ;;
    esac
}

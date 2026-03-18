#!/usr/bin/env bash
# =============================================================================
# agent.sh — Agent invocation wrapper with metrics tracking + exit detection
#
# Sourced by tekhton.sh — do not run directly.
# Expects: TOTAL_TURNS, TOTAL_TIME, STAGE_SUMMARY (set by caller)
# Expects: log(), success(), warn(), error() from common.sh
# =============================================================================

# Source monitoring infrastructure (FIFO loop, activity detection, process mgmt)
# shellcheck source=lib/agent_monitor.sh
source "${TEKHTON_HOME}/lib/agent_monitor.sh"

# --- Metrics accumulators (initialize if not already set) --------------------

: "${TOTAL_TURNS:=0}"
: "${TOTAL_TIME:=0}"
: "${STAGE_SUMMARY:=}"

# --- Tool Profiles (--allowedTools per role, override with AGENT_SKIP_PERMISSIONS) ---
# SCOUT: read-only + Write for SCOUT_REPORT.md (no path-scoped write restriction in CLI)
export AGENT_TOOLS_SCOUT="Read Glob Grep Bash(find:*) Bash(head:*) Bash(wc:*) Bash(cat:*) Bash(ls:*) Bash(tail:*) Bash(file:*) Write"
export AGENT_TOOLS_CODER="Read Write Edit Glob Grep Bash"       # Full implementation
export AGENT_TOOLS_JR_CODER="Read Write Edit Glob Grep Bash"    # Simpler tasks
export AGENT_TOOLS_REVIEWER="Read Glob Grep Write"              # Read + report only
export AGENT_TOOLS_TESTER="Read Write Edit Glob Grep Bash"      # Tests + bash for $TEST_CMD
export AGENT_TOOLS_ARCHITECT="Read Glob Grep Write"             # Read + plan only
export AGENT_TOOLS_BUILD_FIX="Read Write Edit Glob Grep Bash"   # Targeted fixes + build
export AGENT_TOOLS_SEED="Read Write Edit Glob Grep Bash"        # Doc comments + analyze
export AGENT_TOOLS_CLEANUP="Read Write Edit Glob Grep Bash"     # Lint fixes + analyze
# Disallowed tools — best-effort denylist; --allowedTools is the primary boundary.
AGENT_DISALLOWED_TOOLS="WebFetch WebSearch Bash(git push:*) Bash(git remote:*) Bash(rm -rf /:*) Bash(rm -rf ~:*) Bash(rm -rf .:*) Bash(rm -rf ..:*) Bash(curl:*) Bash(wget:*) Bash(ssh:*) Bash(scp:*) Bash(nc:*) Bash(ncat:*)"

# --- Agent exit detection globals (set after each run_agent() call) -----------
LAST_AGENT_TURNS=0         # Turns the agent actually used
LAST_AGENT_EXIT_CODE=0     # claude CLI exit code
LAST_AGENT_ELAPSED=0       # Wall-clock seconds
LAST_AGENT_NULL_RUN=false  # true if agent likely died without doing work

# --- Error classification globals (12.2 — set after classify_error()) --------
AGENT_ERROR_CATEGORY=""
AGENT_ERROR_SUBCATEGORY=""
AGENT_ERROR_TRANSIENT=""
AGENT_ERROR_MESSAGE=""

# --- Run summary -------------------------------------------------------------

print_run_summary() {
    local total_mins=$(( TOTAL_TIME / 60 ))
    local total_secs=$(( TOTAL_TIME % 60 ))
    echo
    echo "══════════════════════════════════════"
    echo "  Run Summary"
    echo "══════════════════════════════════════"
    echo -e "$STAGE_SUMMARY"
    echo "  ──────────────────────────────────"
    echo "  Total turns: ${TOTAL_TURNS}"
    echo "  Total time:  ${total_mins}m${total_secs}s"
    # LAST_CONTEXT_TOKENS reflects the most recently completed stage only (by design).
    # Each stage calls log_context_report() which resets and re-exports LAST_CONTEXT_TOKENS.
    # The final summary therefore shows the tester's context, not the coder's (typically
    # largest). Per-stage context breakdowns are logged individually during each stage.
    # This is intentional: the run summary is a snapshot, not an aggregate. Detailed
    # per-stage context data is available in the run log output.
    if [[ -n "${LAST_CONTEXT_TOKENS:-}" ]] && [[ "${LAST_CONTEXT_TOKENS:-0}" -gt 0 ]]; then
        local ctx_k=$(( LAST_CONTEXT_TOKENS / 1000 ))
        echo "  Context:     ~${ctx_k}k tokens (${LAST_CONTEXT_PCT:-0}% of window)"
    fi
    echo "══════════════════════════════════════"
    echo
}

# --- Agent invocation wrapper — tracks turns and wall-clock time per stage ----
run_agent() {
    local label="$1"        # e.g. "Coder", "Reviewer", "Tester"
    local model="$2"
    local max_turns="$3"
    local prompt="$4"
    local log_file="$5"
    local allowed_tools="${6:-$AGENT_TOOLS_CODER}"  # default: coder-level access

    # Sanitize max_turns — must be a bare integer. Adaptive calibration log
    # messages can leak into ADJUSTED_*_TURNS via $() capture of functions
    # that call log() (which writes to stdout).
    if ! [[ "$max_turns" =~ ^[0-9]+$ ]]; then
        local _clean_turns
        _clean_turns=$(echo "$max_turns" | grep -oE '[0-9]+' | tail -1)
        if [[ -n "$_clean_turns" ]]; then
            warn "[$label] max_turns contained non-numeric content, extracted: ${_clean_turns}"
            max_turns="$_clean_turns"
        else
            warn "[$label] max_turns was not numeric ('${max_turns:0:40}...'), using CODER_MAX_TURNS=${CODER_MAX_TURNS:-100}"
            max_turns="${CODER_MAX_TURNS:-100}"
        fi
    fi

    local start_time
    start_time=$(date +%s)

    set +o pipefail  # claude can exit non-zero on turn limits
    local _timeout="${AGENT_TIMEOUT:-7200}"  # 0 to disable
    local _invoke
    if [ "$_timeout" -gt 0 ] 2>/dev/null && command -v timeout &>/dev/null; then
        _invoke="timeout ${_TIMEOUT_KILL_AFTER_FLAG} $_timeout"
    else
        _invoke=""
    fi

    local _activity_timeout="${AGENT_ACTIVITY_TIMEOUT:-600}"  # 0 to disable

    local _session_dir="${TEKHTON_SESSION_DIR:-/tmp}"
    local _turns_file="${_session_dir}/agent_last_turns"
    local _exit_file="${_session_dir}/agent_exit"
    rm -f "$_exit_file" "$_turns_file"

    local _prerun_marker="${_session_dir}/prerun_marker"  # file-change detection
    touch "$_prerun_marker"

    # --- Build permission flags (--allowedTools default, override with AGENT_SKIP_PERMISSIONS) ---
    local -a _perm_flags=()
    if [ "${AGENT_SKIP_PERMISSIONS:-false}" = true ]; then
        _perm_flags=(--dangerously-skip-permissions)
        if [ "${_AGENT_PERM_WARNED:-}" != true ]; then
            warn "[agent] AGENT_SKIP_PERMISSIONS=true — agents have unrestricted access."
            warn "[agent] This is NOT recommended. Set to false in pipeline.conf."
            _AGENT_PERM_WARNED=true
        fi
    else
        _perm_flags=(--allowedTools "$allowed_tools")
        # Apply disallowed tools for agents with Bash access
        if echo "$allowed_tools" | grep -q 'Bash'; then
            _perm_flags+=(--disallowedTools "$AGENT_DISALLOWED_TOOLS")
        fi
    fi

    _IM_PERM_FLAGS=("${_perm_flags[@]}")  # Pass to monitor
    _invoke_and_monitor "$_invoke" "$model" "$max_turns" "$prompt" \
        "$log_file" "$_activity_timeout" "$_session_dir" "$_exit_file" "$_turns_file"

    local agent_exit="$_MONITOR_EXIT_CODE"
    local _was_activity_timeout="$_MONITOR_WAS_ACTIVITY_TIMEOUT"

    trap - INT TERM
    set -o pipefail

    if [ "$agent_exit" -ne 0 ]; then
        if [ "$agent_exit" -eq 124 ]; then
            if [ "$_was_activity_timeout" = true ]; then
                warn "[$label] ACTIVITY TIMEOUT — agent produced no output for ${_activity_timeout}s."
                warn "[$label] This usually means claude hung on an API call or entered a retry loop."
                warn "[$label] Set AGENT_ACTIVITY_TIMEOUT in pipeline.conf to change (0 = disable)."
            else
                warn "[$label] TIMEOUT — agent did not complete within ${_timeout}s. Set AGENT_TIMEOUT in pipeline.conf to change."
            fi
        else
            warn "[$label] claude exited with code ${agent_exit} (may indicate turn limit or error)"
        fi
    fi

    local end_time
    end_time=$(date +%s)
    local elapsed=$(( end_time - start_time ))
    local mins=$(( elapsed / 60 ))
    local secs=$(( elapsed % 60 ))
    local turns_used
    turns_used=$(cat "$_turns_file" 2>/dev/null || echo "0")
    [[ "$turns_used" =~ ^[0-9]+$ ]] || turns_used=0

    local turns_display="${turns_used}/${max_turns}"  # --max-turns is a soft cap
    if [ "$turns_used" -gt "$max_turns" ] 2>/dev/null; then
        turns_display="${turns_used}/${max_turns} (overshot by $(( turns_used - max_turns )))"
    fi

    log "[$label] Turns: ${turns_display} | Time: ${mins}m${secs}s"

    TOTAL_TURNS=$(( TOTAL_TURNS + turns_used ))
    TOTAL_TIME=$(( TOTAL_TIME + elapsed ))
    STAGE_SUMMARY="${STAGE_SUMMARY}\n  ${label}: ${turns_display} turns, ${mins}m${secs}s"

    # --- Error classification (12.2) ------------------------------------------
    # Classify the agent exit using the error taxonomy. UPSTREAM errors bypass
    # null-run classification entirely — an API 500 is never a "null run".
    AGENT_ERROR_CATEGORY=""
    AGENT_ERROR_SUBCATEGORY=""
    AGENT_ERROR_TRANSIENT=""
    AGENT_ERROR_MESSAGE=""

    if [[ "$agent_exit" -ne 0 ]] || [[ "$_API_ERROR_DETECTED" = true ]]; then
        # classify_error is from lib/errors.sh — guard for tests that source agent.sh directly
        if command -v classify_error &>/dev/null; then
            local _stderr_file="${_session_dir}/agent_stderr.txt"
            local _last_output_file="${_session_dir}/agent_last_output.txt"
            local _fc=0
            if [[ -f "$_prerun_marker" ]] && _detect_file_changes "$_prerun_marker"; then
                _fc=$(_count_changed_files_since "$_prerun_marker")
            fi

            # If API error was detected in stream, create a synthetic stderr hint
            if [[ "$_API_ERROR_DETECTED" = true ]] && [[ ! -s "$_stderr_file" ]]; then
                echo "API error detected in stream: ${_API_ERROR_TYPE}" > "$_stderr_file"
            fi

            local _error_record
            _error_record=$(classify_error "$agent_exit" "$_stderr_file" "$_last_output_file" "$_fc" "$turns_used")

            AGENT_ERROR_CATEGORY=$(echo "$_error_record" | cut -d'|' -f1)
            AGENT_ERROR_SUBCATEGORY=$(echo "$_error_record" | cut -d'|' -f2)
            AGENT_ERROR_TRANSIENT=$(echo "$_error_record" | cut -d'|' -f3)
            AGENT_ERROR_MESSAGE=$(echo "$_error_record" | cut -d'|' -f4-)
        fi
    fi

    # --- Null run detection (file changes override FIFO-based heuristic) ------
    export LAST_AGENT_TURNS="$turns_used"
    export LAST_AGENT_EXIT_CODE="$agent_exit"
    export LAST_AGENT_ELAPSED="$elapsed"
    LAST_AGENT_NULL_RUN=false

    # UPSTREAM errors bypass null-run classification — API failures are not scope issues
    if [[ "$AGENT_ERROR_CATEGORY" = "UPSTREAM" ]]; then
        warn "[$label] API error detected (${AGENT_ERROR_SUBCATEGORY}): ${AGENT_ERROR_MESSAGE}"
        if command -v suggest_recovery &>/dev/null; then
            local _recovery
            _recovery=$(suggest_recovery "$AGENT_ERROR_CATEGORY" "$AGENT_ERROR_SUBCATEGORY")
            warn "[$label] Recovery: ${_recovery}"
            if command -v report_error &>/dev/null; then
                report_error "$AGENT_ERROR_CATEGORY" "$AGENT_ERROR_SUBCATEGORY" \
                    "$AGENT_ERROR_TRANSIENT" "$AGENT_ERROR_MESSAGE" "$_recovery"
            fi
        fi
        # Do NOT classify as null run — this was an API failure, not a scope issue
        return
    fi

    # Check for file changes since agent start (secondary productivity signal)
    local _has_file_changes=false
    if [ -f "$_prerun_marker" ] && _detect_file_changes "$_prerun_marker"; then
        _has_file_changes=true
    fi

    # CODER_SUMMARY.md newer than pre-run marker = completion signal
    local _has_summary=false
    local _summary_path="${PROJECT_DIR:-.}/CODER_SUMMARY.md"
    if [ -f "$_summary_path" ] && [ -f "$_prerun_marker" ]; then
        if [ "$_summary_path" -nt "$_prerun_marker" ]; then
            local _summary_lines
            _summary_lines=$(count_lines < "$_summary_path" 2>/dev/null)
            if [ "${_summary_lines:-0}" -ge 3 ]; then
                _has_summary=true
            fi
        fi
    fi

    # Null run: ≤2 turns + non-zero exit, or timeout with no file changes
    local null_threshold="${AGENT_NULL_RUN_THRESHOLD:-2}"
    local _changed_count="0"
    if [ "$_has_file_changes" = true ]; then
        _changed_count=$(_count_changed_files_since "$_prerun_marker")
    fi
    if [ "$agent_exit" -eq 124 ]; then
        if [ "$_has_file_changes" = true ] || [ "$_has_summary" = true ]; then
            # Agent timed out but produced file changes — NOT a null run.
            if [ "$_was_activity_timeout" = true ]; then
                warn "[$label] Activity timeout fired but agent modified ${_changed_count} file(s) — classifying as productive run."
            else
                warn "[$label] Timeout fired but agent modified ${_changed_count} file(s) — classifying as productive run."
            fi
        else
            LAST_AGENT_NULL_RUN=true
            if [ "$_was_activity_timeout" = true ]; then
                warn "[$label] NULL RUN DETECTED — agent activity-timed out after ${_activity_timeout}s of silence."
            else
                if [ "$_timeout" -gt 0 ] 2>/dev/null; then
                    warn "[$label] NULL RUN DETECTED — agent timed out after ${_timeout}s."
                else
                    warn "[$label] NULL RUN DETECTED — agent timed out (outer timeout disabled)."
                fi
            fi
        fi
    elif [ "$turns_used" -le "$null_threshold" ] && [ "$agent_exit" -ne 0 ]; then
        if [ "$_has_file_changes" = true ] || [ "$_has_summary" = true ]; then
            warn "[$label] Low turn count (${turns_used}) with exit ${agent_exit}, but agent modified ${_changed_count} file(s) — NOT a null run."
        else
            LAST_AGENT_NULL_RUN=true
            warn "[$label] NULL RUN DETECTED — agent used ${turns_used} turn(s) and exited ${agent_exit}."
            # Provide specific guidance based on exit code
            if [ "$agent_exit" -eq 137 ]; then
                warn "[$label] Exit 137 = SIGKILL (signal 9). The process was killed externally."
                warn "[$label] Common cause: OOM killer in WSL2, or the prompt was too large for available memory."
            elif [ "$agent_exit" -eq 139 ]; then
                warn "[$label] Exit 139 = SIGSEGV. The process crashed."
            else
                warn "[$label] The agent likely died during initial discovery/file search."
            fi
        fi
    elif [ "$turns_used" -eq 0 ]; then
        if [ "$_has_file_changes" = true ] || [ "$_has_summary" = true ]; then
            warn "[$label] 0 turns reported but agent modified ${_changed_count} file(s) — NOT a null run."
        else
            LAST_AGENT_NULL_RUN=true
            warn "[$label] NULL RUN DETECTED — agent used 0 turns."
        fi
    fi

    # --- Structured agent run summary block (12.3) ----------------------------
    # Appended to the end of the log file so `tail -20 <logfile>` diagnoses failures.
    _append_agent_summary "$label" "$model" "$turns_used" "$max_turns" \
        "$mins" "$secs" "$agent_exit" "$_changed_count" "$log_file"
}

# --- Structured agent run summary (12.3) — appended to log file end ----------
_append_agent_summary() {
    local label="$1" model="$2" turns_used="$3" max_turns="$4"
    local mins="$5" secs="$6" exit_code="$7" files_changed="$8"
    local log_file="$9"

    # Detect Unicode for consistent rendering with report_error
    local _sep="═══"
    if ! _is_utf8_terminal; then
        _sep="==="
    fi

    local _class="SUCCESS"
    if [[ "$exit_code" -ne 0 ]]; then
        if [[ -n "$AGENT_ERROR_CATEGORY" ]]; then
            _class="${AGENT_ERROR_CATEGORY}/${AGENT_ERROR_SUBCATEGORY}"
        elif [[ "$LAST_AGENT_NULL_RUN" = true ]]; then
            _class="NULL_RUN"
        else
            _class="FAILED (exit ${exit_code})"
        fi
    fi

    # Count created files (heuristic: new untracked files since prerun marker)
    local _created=0
    local _modified="${files_changed}"
    if command -v git &>/dev/null; then
        _created=$(git ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d '[:space:]')
        _created="${_created:-0}"
    fi

    local _summary_block
    _summary_block=$(cat <<AGENTSUMMARY

${_sep} Agent Run Summary ${_sep}
Agent:     ${label} (${model})
Turns:     ${turns_used} / ${max_turns}
Duration:  ${mins}m ${secs}s
Exit Code: ${exit_code}
Class:     ${_class}
Files:     ${_modified} modified, ${_created} created
AGENTSUMMARY
)

    # Add error details on failure
    if [[ "$_class" != "SUCCESS" ]] && [[ -n "$AGENT_ERROR_CATEGORY" ]]; then
        local _recovery
        _recovery=$(suggest_recovery "$AGENT_ERROR_CATEGORY" "$AGENT_ERROR_SUBCATEGORY")
        _summary_block="${_summary_block}
Error:     ${AGENT_ERROR_MESSAGE}
Recovery:  ${_recovery}"
    fi

    _summary_block="${_summary_block}
${_sep}${_sep}${_sep}${_sep}${_sep}${_sep}"

    # Redact sensitive data before writing to log
    if command -v redact_sensitive &>/dev/null; then
        _summary_block=$(redact_sensitive "$_summary_block")
    fi

    echo "$_summary_block" >> "$log_file"
}

# --- Null run detection helpers (call after run_agent()) --------------------

# was_null_run — true if last agent died before accomplishing meaningful work.
was_null_run() {
    [ "$LAST_AGENT_NULL_RUN" = true ]
}

# check_agent_output FILE LABEL — returns 0 if agent produced meaningful work.
check_agent_output() {
    local expected_file="$1"
    local label="$2"

    if was_null_run; then
        warn "[$label] Agent was a null run — no output expected."
        return 1
    fi

    if [ ! -f "$expected_file" ]; then
        warn "[$label] Expected output file '${expected_file}' not found."
        return 1
    fi

    local line_count
    line_count=$(count_lines < "$expected_file")
    if [ "$line_count" -lt 3 ]; then
        warn "[$label] Output file '${expected_file}' has only ${line_count} line(s) — likely a stub."
        return 1
    fi

    local has_changes=false
    if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
        has_changes=true
    fi

    if [ "$has_changes" = false ] && [ "$line_count" -lt 5 ]; then
        warn "[$label] No git changes and minimal output — agent may not have accomplished anything."
        return 1
    fi

    return 0
}

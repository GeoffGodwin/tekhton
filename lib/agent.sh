#!/usr/bin/env bash
# =============================================================================
# agent.sh — Agent invocation wrapper with metrics tracking + exit detection
#
# Sourced by tekhton.sh — do not run directly.
# Expects: TOTAL_TURNS, TOTAL_TIME, STAGE_SUMMARY (set by caller)
# Expects: log(), success(), warn(), error() from common.sh
# =============================================================================
set -euo pipefail

# Source platform detection (Windows/WSL interop, timeout flags, _kill_agent_windows)
# shellcheck source=lib/agent_monitor_platform.sh
source "${TEKHTON_HOME}/lib/agent_monitor_platform.sh"

# Source monitoring infrastructure (FIFO loop, activity detection, process mgmt)
# shellcheck source=lib/agent_monitor.sh
source "${TEKHTON_HOME}/lib/agent_monitor.sh"

# Source post-invocation monitoring helpers (file-change detection, state reset)
# shellcheck source=lib/agent_monitor_helpers.sh
source "${TEKHTON_HOME}/lib/agent_monitor_helpers.sh"

# Source transient error retry envelope (13.2.1)
# shellcheck source=lib/agent_retry.sh
source "${TEKHTON_HOME}/lib/agent_retry.sh"

# Source helper functions (run summary, output validation, null-run helpers)
# shellcheck source=lib/agent_helpers.sh
source "${TEKHTON_HOME}/lib/agent_helpers.sh"

# Source spinner subshell management (non-TUI + TUI paths separated)
# shellcheck source=lib/agent_spinner.sh
source "${TEKHTON_HOME}/lib/agent_spinner.sh"

# --- Metrics accumulators (initialize if not already set) --------------------

: "${TOTAL_TURNS:=0}"
: "${TOTAL_TIME:=0}"
: "${STAGE_SUMMARY:=}"

# --- Tool Profiles (--allowedTools per role, override with AGENT_SKIP_PERMISSIONS) ---
# SCOUT: read-only + Write for scout report (no path-scoped write restriction in CLI)
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
LAST_AGENT_RETRY_COUNT=0   # Transient error retries used in last run_agent() call
TOTAL_AGENT_INVOCATIONS=0  # Cumulative agent calls (M16 orchestration tracking)
# --- Error classification globals (12.2 — set after classify_error()) --------
AGENT_ERROR_CATEGORY=""
AGENT_ERROR_SUBCATEGORY=""
AGENT_ERROR_TRANSIENT=""
AGENT_ERROR_MESSAGE=""

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

    # Increment global invocation counter (M16 orchestration tracking)
    TOTAL_AGENT_INVOCATIONS=$(( TOTAL_AGENT_INVOCATIONS + 1 ))

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

    # Add MCP config flag when Serena is available.
    # Skip for read-only agents (Reviewer, Scout, Architect) — they can't use MCP
    # tools anyway (allowedTools restricts to Read/Glob/Grep/Write) and loading the
    # MCP tool schema into context is pure overhead.
    if [[ "${SERENA_MCP_AVAILABLE:-false}" == "true" ]] && command -v get_mcp_config_path &>/dev/null; then
        if [[ "$label" =~ ^(Coder|Tester|Jr.Coder|Build.Fix|Cleanup|Security.Rework) ]] \
           || echo "$allowed_tools" | grep -q 'Bash'; then
            local _mcp_config
            _mcp_config=$(get_mcp_config_path)
            if [[ -n "$_mcp_config" ]] && [ -f "$_mcp_config" ]; then
                _perm_flags+=(--mcp-config "$_mcp_config")
            fi
        fi
    fi

    _IM_PERM_FLAGS=("${_perm_flags[@]}")  # Pass to monitor
    local _spinner_pid="" _tui_updater_pid=""
    IFS=: read -r _spinner_pid _tui_updater_pid < <(_start_agent_spinner "$label" "$_turns_file" "$max_turns")

    # Delegates invocation + classification + retry to _run_with_retry() in
    # agent_retry.sh. Results come back via globals: AGENT_ERROR_*,
    # LAST_AGENT_RETRY_COUNT, _RWR_EXIT, _RWR_TURNS, _RWR_WAS_ACTIVITY_TIMEOUT.
    _run_with_retry "$label" "$_invoke" "$model" "$max_turns" "$prompt" \
        "$log_file" "$_activity_timeout" "$_session_dir" "$_exit_file" "$_turns_file" \
        "$_prerun_marker" "$_timeout"
    _stop_agent_spinner "$_spinner_pid" "$_tui_updater_pid"

    local agent_exit="$_RWR_EXIT"
    local _was_activity_timeout="$_RWR_WAS_ACTIVITY_TIMEOUT"
    local turns_used="$_RWR_TURNS"

    set -o pipefail

    # --- Timing and turn accounting (after retry loop) -------------------------
    local end_time
    end_time=$(date +%s)
    local elapsed=$(( end_time - start_time ))
    local mins=$(( elapsed / 60 ))
    local secs=$(( elapsed % 60 ))

    local turns_display="${turns_used}/${max_turns}"  # --max-turns is a soft cap
    if [ "$turns_used" -gt "$max_turns" ] 2>/dev/null; then
        turns_display="${turns_used}/${max_turns} (overshot by $(( turns_used - max_turns )))"
    fi

    local _retry_suffix=""
    if [[ "$LAST_AGENT_RETRY_COUNT" -gt 0 ]]; then
        local _retry_word="retry"
        if [[ "$LAST_AGENT_RETRY_COUNT" -ne 1 ]]; then
            _retry_word="retries"
        fi
        _retry_suffix=" (after ${LAST_AGENT_RETRY_COUNT} ${_retry_word})"
    fi
    # M96 (NR3): fold context total into completion line when available.
    local _ctx_suffix=""
    if [[ -n "${LAST_CONTEXT_TOKENS:-}" ]] && [[ "${LAST_CONTEXT_TOKENS}" -gt 0 ]] 2>/dev/null; then
        local _ctx_k=$(( LAST_CONTEXT_TOKENS / 1000 ))
        local _ctx_frac=$(( (LAST_CONTEXT_TOKENS % 1000) / 100 ))
        _ctx_suffix=" | Context: ~${_ctx_k}.${_ctx_frac}k tokens (${LAST_CONTEXT_PCT:-0}%)"
    fi
    log "[$label] Turns: ${turns_display} | Time: ${mins}m${secs}s${_ctx_suffix}${_retry_suffix}"

    TOTAL_TURNS=$(( TOTAL_TURNS + turns_used ))
    TOTAL_TIME=$(( TOTAL_TIME + elapsed ))
    STAGE_SUMMARY="${STAGE_SUMMARY}\n  ${label} (${model}): ${turns_display} turns, ${mins}m${secs}s${_retry_suffix}"

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
        # Still emit structured summary so `tail -20 <logfile>` diagnoses failures
        _append_agent_summary "$label" "$model" "$turns_used" "$max_turns" \
            "$mins" "$secs" "$agent_exit" "0" "$log_file"
        return
    fi

    # Check for file changes since agent start (secondary productivity signal)
    local _has_file_changes=false
    if [ -f "$_prerun_marker" ] && _detect_file_changes "$_prerun_marker"; then
        _has_file_changes=true
    fi

    # ${CODER_SUMMARY_FILE} newer than pre-run marker = completion signal
    local _has_summary=false
    local _summary_path="${PROJECT_DIR:-.}/${CODER_SUMMARY_FILE}"
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

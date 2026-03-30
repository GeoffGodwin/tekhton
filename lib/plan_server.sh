#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# plan_server.sh — Local HTTP server for browser-based planning form
#
# Provides start/stop/wait functions for a Python HTTP server that serves the
# planning form and handles POST endpoints for saving answers.
#
# Sourced by tekhton.sh when --plan is passed. Do not run directly.
# Expects: PROJECT_DIR, TEKHTON_HOME, TEKHTON_SESSION_DIR from tekhton.sh
# Expects: PLAN_ANSWER_FILE from lib/plan_answers.sh
# Expects: log(), warn(), error(), success() from common.sh
# =============================================================================

# --- Module state -----------------------------------------------------------
_PLAN_SERVER_PID=0
_PLAN_SERVER_PORT=0
_PLAN_COMPLETION_FILE=""

# --- Port detection ---------------------------------------------------------

# _plan_find_available_port BASE_PORT
# Returns the first available port starting from BASE_PORT.
_plan_find_available_port() {
    local base_port="$1"
    local port
    for port in $(seq "$base_port" "$((base_port + 50))"); do
        if ! _plan_is_port_in_use "$port"; then
            echo "$port"
            return 0
        fi
    done
    return 1
}

# _plan_is_port_in_use PORT
# Returns 0 if port is in use, 1 if free.
_plan_is_port_in_use() {
    local port="$1"
    if command -v ss &>/dev/null; then
        ss -tlnp 2>/dev/null | grep -qE ":${port}([^0-9]|$)" && return 0
    elif command -v netstat &>/dev/null; then
        netstat -tlnp 2>/dev/null | grep -qE ":${port}([^0-9]|$)" && return 0
    else
        (echo >/dev/tcp/localhost/"$port") 2>/dev/null && return 0
    fi
    return 1
}

# --- Python server (extracted to plan_server_script.sh) ---------------------

# shellcheck source=lib/plan_server_script.sh
source "${TEKHTON_HOME}/lib/plan_server_script.sh"

# _start_plan_server FORM_DIR
# Starts the Python HTTP server serving files from FORM_DIR.
# Sets _PLAN_SERVER_PID and _PLAN_SERVER_PORT.
# Returns 0 on success, 1 on failure.
_start_plan_server() {
    local form_dir="$1"

    if ! command -v python3 &>/dev/null; then
        error "Browser mode requires Python 3. Install python3 and try again."
        return 1
    fi

    local port
    port=$(_plan_find_available_port 8787) || {
        error "No available port in range 8787-8797."
        return 1
    }
    _PLAN_SERVER_PORT="$port"

    local session_dir="${TEKHTON_SESSION_DIR:-${PROJECT_DIR}/.claude/logs}"
    mkdir -p "$session_dir"

    _PLAN_COMPLETION_FILE="${session_dir}/plan_submit_complete"
    rm -f "$_PLAN_COMPLETION_FILE"

    local server_script="${session_dir}/plan_server.py"
    _write_plan_server_script "$server_script"

    local server_log="${session_dir}/plan_server.log"

    # shellcheck disable=SC2153  # PLAN_ANSWER_FILE defined in plan_answers.sh
    export PLAN_ANSWERS_FILE="$PLAN_ANSWER_FILE"
    export PLAN_COMPLETION_FILE="$_PLAN_COMPLETION_FILE"
    export PLAN_SERVER_PORT="$port"
    export PLAN_SERVER_LOG="$server_log"

    (cd "$form_dir" && python3 "$server_script" 2>>"$server_log") &
    _PLAN_SERVER_PID=$!

    # Wait for server readiness (up to 15 seconds, checking frequently at first)
    local retries=0
    local max_retries=30  # 30 * 0.5s = 15s
    while [[ "$retries" -lt "$max_retries" ]]; do
        # Verify process is still alive
        if ! kill -0 "$_PLAN_SERVER_PID" 2>/dev/null; then
            local error_msg
            error_msg=$(tail -5 "$server_log" 2>/dev/null | tr '\n' ' ' || echo "Unknown error")
            warn "Planning server process exited before becoming ready. Last stderr: $error_msg"
            _PLAN_SERVER_PID=0
            return 1
        fi

        # Try health check with connection timeout
        if curl -s --connect-timeout 1 --max-time 2 -o /dev/null "http://127.0.0.1:${port}" 2>/dev/null; then
            log "Planning form server ready on port ${port}."
            return 0
        fi

        sleep 0.5
        retries=$((retries + 1))
    done

    # Collect diagnostics before giving up
    local diag=""
    if [[ -f "$server_log" ]]; then
        diag=$(tail -10 "$server_log" 2>/dev/null | sed 's/^/  [server] /')
    fi
    warn "Planning server did not become ready within 15 seconds."
    [[ -n "$diag" ]] && warn "Server log:\n${diag}"
    _stop_plan_server
    return 1
}

# _stop_plan_server
# Stops the background server if running.
_stop_plan_server() {
    if [[ "$_PLAN_SERVER_PID" -gt 0 ]]; then
        # Kill the process and any children (the subshell may have spawned python3)
        kill "$_PLAN_SERVER_PID" 2>/dev/null || true
        # Also kill children — the subshell's child python3 process
        pkill -P "$_PLAN_SERVER_PID" 2>/dev/null || true
        wait "$_PLAN_SERVER_PID" 2>/dev/null || true
        _PLAN_SERVER_PID=0
    fi
}

# _open_plan_browser PORT
# Opens the form URL in the default browser.
_open_plan_browser() {
    local port="$1"
    local url="http://127.0.0.1:${port}"

    log "Planning form URL: ${url}"

    if [[ -n "${WSL_DISTRO_NAME:-}" ]] || grep -qi microsoft /proc/version 2>/dev/null; then
        cmd.exe /c start "$url" 2>/dev/null && return 0
    elif command -v xdg-open &>/dev/null; then
        xdg-open "$url" 2>/dev/null &
        return 0
    elif command -v open &>/dev/null; then
        open "$url" 2>/dev/null && return 0
    fi

    warn "Could not detect browser. Open this URL manually:"
    log "  ${url}"
}

# _wait_for_plan_submit
# Polls for the completion sentinel file. Shows a spinner.
# On Ctrl-C, exits cleanly (server cleanup handled by caller's trap).
# Returns 0 on submission detected, 1 on interrupt.
_wait_for_plan_submit() {
    local chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0

    log "Waiting for browser submission... (Ctrl-C to cancel)"

    trap '_plan_handle_interrupt; return 1' INT

    while true; do
        if [[ -f "$_PLAN_COMPLETION_FILE" ]]; then
            printf '\r\033[K'
            success "Form submitted!"
            trap - INT
            return 0
        fi

        if [[ "$_PLAN_SERVER_PID" -gt 0 ]] && ! kill -0 "$_PLAN_SERVER_PID" 2>/dev/null; then
            printf '\r\033[K'
            warn "Server process died unexpectedly."
            trap - INT
            return 1
        fi

        printf '\r  %s Waiting for browser submission... (Ctrl-C to cancel) ' \
            "${chars:i%${#chars}:1}"
        i=$((i + 1))
        sleep 1
    done
}

# _plan_handle_interrupt
# Called on Ctrl-C during wait. Logs draft save status.
_plan_handle_interrupt() {
    printf '\r\033[K'
    log "Interrupted. Any auto-saved drafts are preserved in the answer file."
    trap - INT
}

# _plan_server_port — Accessor for the current server port.
_plan_server_port() {
    echo "$_PLAN_SERVER_PORT"
}

#!/usr/bin/env bash
# agent_monitor.sh — Agent monitoring, activity detection, process management
# Sourced by agent.sh. Provides: _invoke_and_monitor(), _detect_file_changes(),
# _count_changed_files_since(), _kill_agent_windows()

# File scan depth for change detection (configurable via pipeline.conf)
: "${AGENT_FILE_SCAN_DEPTH:=8}"

# GNU coreutils timeout supports --kill-after; macOS/BSD does not. Detect once.
_TIMEOUT_KILL_AFTER_FLAG=""
if command -v timeout &>/dev/null && timeout --help 2>&1 | grep -q 'kill-after'; then
    _TIMEOUT_KILL_AFTER_FLAG="--kill-after=60"
fi

# Windows-native claude.exe doesn't receive POSIX signals from MSYS2/WSL interop.
# When detected, the abort handler uses taskkill.exe to terminate the process.
_AGENT_WINDOWS_CLAUDE=false
_claude_path="$(command -v claude 2>/dev/null || true)"

if grep -qiE 'microsoft|WSL' /proc/version 2>/dev/null; then
    if echo "${_claude_path:-}" | grep -qiE '(/mnt/c/|\.exe$|AppData|Program)'; then
        _AGENT_WINDOWS_CLAUDE=true
        warn "[agent] WARNING: claude appears to be a Windows binary running via WSL interop."
        warn "[agent] To fix: install claude natively in WSL (npm install -g @anthropic-ai/claude-code)."
    fi
elif uname -s 2>/dev/null | grep -qiE 'MINGW|MSYS'; then
    if [ -n "${_claude_path:-}" ]; then
        _AGENT_WINDOWS_CLAUDE=true
    fi
fi

# taskkill.exe reliably terminates Windows-native processes ignoring POSIX signals.
_kill_agent_windows() {
    if [ "$_AGENT_WINDOWS_CLAUDE" != true ]; then
        return
    fi
    local _tk=""
    if command -v taskkill.exe &>/dev/null; then
        _tk="taskkill.exe"
    elif command -v taskkill &>/dev/null; then
        _tk="taskkill"
    else
        return
    fi

    # Try PID-based kill first (more precise, avoids killing unrelated claude instances)
    if [ -n "${_TEKHTON_AGENT_PID:-}" ]; then
        $_tk //F //PID "$_TEKHTON_AGENT_PID" //T 2>/dev/null || true
    fi
    # Fall back to image-name kill to catch child processes the PID kill might miss
    # //F = force, //T = kill process tree, //IM = by image name.
    $_tk //F //IM claude.exe //T 2>/dev/null || true
}

# --- Real-time API error detection flags (12.2) ------------------------------
# API error detection occurs inline in the FIFO reader subshell (lines 220–238).
# Variables are managed within the subshell and cannot be exported to the parent.
_API_ERROR_DETECTED=false
_API_ERROR_TYPE=""

# FIFO-monitored claude invocation. Sets _MONITOR_EXIT_CODE. Caller sets _IM_PERM_FLAGS.
_invoke_and_monitor() {
    local _invoke="$1"
    local model="$2"
    local max_turns="$3"
    local prompt="$4"
    local log_file="$5"
    local _activity_timeout="$6"
    local _session_dir="$7"
    local _exit_file="$8"
    local _turns_file="$9"

    _MONITOR_EXIT_CODE=1
    _MONITOR_WAS_ACTIVITY_TIMEOUT=false

    # Reset API error flags for this invocation
    _API_ERROR_DETECTED=false
    _API_ERROR_TYPE=""

    # FIFO: claude in bg subshell → pipe → foreground reader (ctrl+c, activity timeout)
    if command -v mkfifo &>/dev/null; then
        local _fifo="${_session_dir}/agent_fifo_$$"
        rm -f "$_fifo"
        mkfifo "$_fifo"

        # Background: run claude, write stdout to FIFO, tee stderr to
        # a dedicated file and the caller's stdout (not the FIFO).
        local _stderr_file="${_session_dir}/agent_stderr.txt"
        : > "$_stderr_file"
        (
            $_invoke claude \
                --model "$model" \
                "${_IM_PERM_FLAGS[@]}" \
                --max-turns "$max_turns" \
                --output-format json \
                -p "$prompt" \
                < /dev/null \
                > "$_fifo" 2> >(tee -a "$_stderr_file" >&1)
            echo "$?" > "$_exit_file"
        ) &
        _TEKHTON_AGENT_PID=$!

        # Trap: kill bg + Windows claude; reader gets EOF when fd closes
        _run_agent_abort() {
            trap - INT TERM
            _TEKHTON_CLEAN_EXIT=true
            if [ -n "${_TEKHTON_AGENT_PID:-}" ]; then
                kill "$_TEKHTON_AGENT_PID" 2>/dev/null || true
                kill -9 "$_TEKHTON_AGENT_PID" 2>/dev/null || true
            fi
            _kill_agent_windows
            rm -f "${_fifo:-}" 2>/dev/null || true
        }
        trap '_run_agent_abort' INT TERM

        # Foreground: read FIFO, log, parse JSON, detect silence + file changes
        (
            exec 3>>"$log_file"
            _last_activity=$(date +%s)
            _last_line=""
            _read_interval="${AGENT_ACTIVITY_POLL:-30}"
            [ "$_activity_timeout" -le 0 ] 2>/dev/null && _read_interval=0

            _activity_marker="${_session_dir}/activity_marker"
            touch "$_activity_marker"

            # Ring buffer for last 50 lines (12.2)
            declare -a _rb=()
            _rb_idx=0
            _rb_size=50
            # API error detection in the stream (12.2)
            _stream_api_error=false
            _stream_api_type=""

            # Shared per-line processing for both timed and blocking branches.
            # Modifies subshell globals directly (no `local`) — see comment at
            # the ring buffer dump block below for rationale.
            _process_fifo_line() {
                echo "$1" >&3
                _last_line="$1"
                # Ring buffer: store line
                _rb[$(( _rb_idx % _rb_size ))]="$1"
                _rb_idx=$(( _rb_idx + 1 ))
                # Real-time API error detection
                case "$1" in
                    *'"type":"error"'*|*'"status":'*429*|*'"status":'*500*|*'"status":'*502*|*'"status":'*503*|*'"status":'*529*|*server_error*|*rate_limit*|*overloaded*|*authentication_error*)
                        if echo "$1" | grep -qE '"type"[[:space:]]*:[[:space:]]*"error"' 2>/dev/null; then
                            _stream_api_error=true
                            if echo "$1" | grep -qi 'rate_limit' 2>/dev/null; then
                                _stream_api_type="api_rate_limit"
                            elif echo "$1" | grep -qi 'overloaded' 2>/dev/null; then
                                _stream_api_type="api_overloaded"
                            elif echo "$1" | grep -qi 'server_error' 2>/dev/null; then
                                _stream_api_type="api_500"
                            elif echo "$1" | grep -qi 'authentication_error' 2>/dev/null; then
                                _stream_api_type="api_auth"
                            fi
                        elif echo "$1" | grep -qE '"status"[[:space:]]*:[[:space:]]*(429|500|502|503|529)' 2>/dev/null; then
                            _stream_api_error=true
                            _stream_api_type="api_500"
                        fi
                        ;;
                esac
                if echo "$1" | grep -q '"type":"text"'; then
                    echo "$1" | python3 -c \
                        "import sys,json; d=json.load(sys.stdin); print(d.get('text',''))" \
                        2>/dev/null || true
                fi
            }

            while true; do
                if [ "$_read_interval" -gt 0 ]; then
                    if IFS= read -r -t "$_read_interval" line; then
                        _last_activity=$(date +%s)
                        _process_fifo_line "$line"
                    else
                        _rc=$?
                        if [ "$_rc" -le 128 ]; then
                            break  # EOF — claude exited
                        fi
                        # read timed out — check for silence
                        _now=$(date +%s)
                        _idle=$(( _now - _last_activity ))
                        if [ "$_idle" -ge "$_activity_timeout" ]; then
                            # Before killing: check if files changed since last marker.
                            # JSON output mode produces no FIFO output, but the agent
                            # may be actively writing files. If so, reset the timer.
                            _files_changed=false
                            if [ -f "$_activity_marker" ]; then
                                _changed_file=$(find "${PROJECT_DIR:-.}" -maxdepth "$AGENT_FILE_SCAN_DEPTH" \
                                    -newer "$_activity_marker" \
                                    -not -path '*/.git/*' \
                                    -not -path '*/.git' \
                                    -not -path "${_session_dir}/*" \
                                    -not -path "${LOG_DIR:-${PROJECT_DIR:-.}/.claude/logs}/*" \
                                    -type f 2>/dev/null | head -1)
                                if [ -n "$_changed_file" ]; then
                                    _files_changed=true
                                fi
                            fi

                            if [ "$_files_changed" = true ]; then
                                # Files changed — agent is actively working despite
                                # no FIFO output. Reset the activity timer.
                                echo "[tekhton] Activity timeout reached but files changed — resetting timer." >&3
                                _last_activity=$(date +%s)
                                touch "$_activity_marker"
                            else
                                echo "[tekhton] ACTIVITY TIMEOUT — no output or file changes for ${_idle}s. Killing agent." >&3
                                echo "ACTIVITY_TIMEOUT" > "$_exit_file"
                                # This subshell cannot reach the outer _run_agent_abort trap — kill directly.
                                kill "$_TEKHTON_AGENT_PID" 2>/dev/null || true
                                sleep 2
                                kill -9 "$_TEKHTON_AGENT_PID" 2>/dev/null || true
                                _kill_agent_windows
                                break
                            fi
                        fi
                    fi
                else
                    # Activity timeout disabled — blocking read
                    if IFS= read -r line; then
                        _process_fifo_line "$line"
                    else
                        break  # EOF
                    fi
                fi
            done

            # Extract turn count from final result object
            _turns=$(echo "$_last_line" | python3 -c \
                "import sys,json; d=json.load(sys.stdin); print(d.get('num_turns', 0))" \
                2>/dev/null || echo "0")
            echo "$_turns" > "$_turns_file"

            # Dump ring buffer to file for post-exit error classification (12.2).
            # Uses a compound group {…} instead of a function because this runs
            # inside a subshell where _rb[] and _rb_idx are local variables —
            # a function call would require passing the array, and bash doesn't
            # support passing arrays to functions by reference portably in bash 4.
            # Plain assignments (not `local`) because `local` is invalid outside
            # a function — and these are already subshell-scoped by the (...).
            {
                _rb_total=${#_rb[@]}
                if [[ "$_rb_total" -gt 0 ]]; then
                    _rb_start=0
                    if [[ "$_rb_idx" -ge "$_rb_size" ]]; then
                        _rb_start=$(( _rb_idx % _rb_size ))
                    fi
                    _j=0
                    while [[ "$_j" -lt "$_rb_total" ]]; do
                        echo "${_rb[$(( (_rb_start + _j) % _rb_size ))]}"
                        _j=$(( _j + 1 ))
                    done
                fi
            } > "${_session_dir}/agent_last_output.txt" 2>/dev/null || true

            # Write API error detection flags for parent process (12.2)
            if [[ "$_stream_api_error" = true ]]; then
                echo "$_stream_api_type" > "${_session_dir}/agent_api_error.txt"
            fi

            exec 3>&-
        ) < "$_fifo"

        # Wait for background subshell to fully exit
        wait "$_TEKHTON_AGENT_PID" 2>/dev/null || true
        rm -f "$_fifo"

        # Read API error detection from FIFO reader subshell (12.2)
        if [[ -f "${_session_dir}/agent_api_error.txt" ]]; then
            _API_ERROR_DETECTED=true
            _API_ERROR_TYPE=$(cat "${_session_dir}/agent_api_error.txt" 2>/dev/null || echo "api_unknown")
            rm -f "${_session_dir}/agent_api_error.txt"
        fi

        # Read exit code from background subshell
        if [ -f "$_exit_file" ]; then
            _MONITOR_EXIT_CODE=$(cat "$_exit_file")
            if [ "$_MONITOR_EXIT_CODE" = "ACTIVITY_TIMEOUT" ]; then
                _MONITOR_EXIT_CODE=124
                _MONITOR_WAS_ACTIVITY_TIMEOUT=true
            fi
            [[ "$_MONITOR_EXIT_CODE" =~ ^[0-9]+$ ]] || _MONITOR_EXIT_CODE=1
            rm -f "$_exit_file"
        else
            _MONITOR_EXIT_CODE=1
        fi
    else
        # =================================================================
        # FALLBACK: direct pipeline (mkfifo not available — extremely rare)
        # =================================================================
        # WARNING: Ctrl+C may not work if claude hangs, and there is no
        # activity timeout. This path exists only for exotic environments
        # without mkfifo (no known modern system lacks it).
        _run_agent_abort() {
            trap - INT TERM
            _TEKHTON_CLEAN_EXIT=true
            kill 0 2>/dev/null || true
        }
        trap '_run_agent_abort' INT TERM

        $_invoke claude \
            --model "$model" \
            "${_IM_PERM_FLAGS[@]}" \
            --max-turns "$max_turns" \
            --output-format json \
            -p "$prompt" \
            < /dev/null \
            2>&1 | tee -a "$log_file" | (
                turns=0
                last_line=""
                while IFS= read -r line; do
                    if echo "$line" | grep -q '"type":"text"'; then
                        echo "$line" | python3 -c \
                            "import sys,json; d=json.load(sys.stdin); print(d.get('text',''))" \
                            2>/dev/null || true
                    fi
                    last_line="$line"
                done
                turns=$(echo "$last_line" | python3 -c \
                    "import sys,json; d=json.load(sys.stdin); print(d.get('num_turns', 0))" \
                    2>/dev/null || echo "0")
                echo "$turns" > "$_turns_file"
            )
        _MONITOR_EXIT_CODE=${PIPESTATUS[0]}
    fi
}

# Post-invocation helpers (_reset_monitoring_state, _detect_file_changes,
# _count_changed_files_since) live in agent_monitor_helpers.sh — sourced
# separately by agent.sh after this file.

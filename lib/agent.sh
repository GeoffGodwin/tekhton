#!/usr/bin/env bash
# =============================================================================
# agent.sh — Agent invocation wrapper with metrics tracking + exit detection
#
# Sourced by tekhton.sh — do not run directly.
# Expects: TOTAL_TURNS, TOTAL_TIME, STAGE_SUMMARY (set by caller)
# Expects: log(), success(), warn(), error() from common.sh
# =============================================================================

# --- Metrics accumulators (initialize if not already set) --------------------

: "${TOTAL_TURNS:=0}"
: "${TOTAL_TIME:=0}"
: "${STAGE_SUMMARY:=}"

# --- Agent Tool Profiles (least-privilege allowlists) ------------------------
#
# Each profile grants only the Claude CLI tools the agent role actually needs.
# This replaces --dangerously-skip-permissions with --allowedTools to prevent
# agents from performing destructive operations (rm -rf, git push --force,
# arbitrary network access, etc.).
#
# Tool reference (Claude CLI):
#   Read    — read file contents          Edit    — string replace in files
#   Write   — create/overwrite files       Bash   — execute shell commands
#   Glob    — find files by pattern        Grep   — search file contents
#   Agent   — launch subagents             WebFetch/WebSearch — network access
#
# Bash sub-patterns: Bash(command:*) restricts to commands matching the glob.
# Example: "Bash(grep:*) Bash(find:*)" allows only grep and find.
#
# Override with AGENT_SKIP_PERMISSIONS=true in pipeline.conf to restore the
# old --dangerously-skip-permissions behavior (NOT recommended).
# -----------------------------------------------------------------------------

# SCOUT: read-only discovery. Finds relevant files, reads headers.
# NOTE: Write is included because the scout must create SCOUT_REPORT.md.
# The Claude CLI does not support path-scoped write restrictions, so the scout
# technically has write access to any file. This is a known least-privilege gap —
# the scout prompt restricts it to writing only SCOUT_REPORT.md.
export AGENT_TOOLS_SCOUT="Read Glob Grep Bash(find:*) Bash(head:*) Bash(wc:*) Bash(cat:*) Bash(ls:*) Bash(tail:*) Bash(file:*) Write"

# CODER: full implementation agent. Reads, writes, edits code, runs analyze/test.
# Bash access is broad but blocks destructive operations via disallowed tools.
export AGENT_TOOLS_CODER="Read Write Edit Glob Grep Bash"

# JR_CODER: same as coder but for simpler tasks. Same tool access.
export AGENT_TOOLS_JR_CODER="Read Write Edit Glob Grep Bash"

# REVIEWER: reads code and writes a report. No code edits, no bash.
export AGENT_TOOLS_REVIEWER="Read Glob Grep Write"

# TESTER: writes test files, runs test commands. Needs bash for $TEST_CMD.
export AGENT_TOOLS_TESTER="Read Write Edit Glob Grep Bash"

# ARCHITECT: reads drift logs and source, writes a plan. No code edits, no bash.
export AGENT_TOOLS_ARCHITECT="Read Glob Grep Write"

# BUILD_FIX: targeted code fixes + build verification. Needs bash for build check.
export AGENT_TOOLS_BUILD_FIX="Read Write Edit Glob Grep Bash"

# SEED_CONTRACTS: adds doc comments to source files, runs analyze.
export AGENT_TOOLS_SEED="Read Write Edit Glob Grep Bash"

# CLEANUP: analyze cleanup pass — fix lint warnings, runs analyze.
export AGENT_TOOLS_CLEANUP="Read Write Edit Glob Grep Bash"

# Disallowed tools for ALL agents — destructive operations that must never happen.
# Applied as --disallowedTools alongside --allowedTools for any agent with Bash.
#
# IMPORTANT: --disallowedTools is a BEST-EFFORT denylist. The Claude CLI matches
# tool invocations by prefix pattern, so agents can bypass these restrictions by
# using alternative command forms (e.g., /usr/bin/curl, python -c "import urllib",
# git config alias). The denylist is one layer in a defense-in-depth strategy —
# the --allowedTools whitelist is the primary security boundary.
AGENT_DISALLOWED_TOOLS="WebFetch WebSearch Bash(git push:*) Bash(git remote:*) Bash(rm -rf /:*) Bash(rm -rf ~:*) Bash(rm -rf .:*) Bash(rm -rf ..:*) Bash(curl:*) Bash(wget:*) Bash(ssh:*) Bash(scp:*) Bash(nc:*) Bash(ncat:*)"

# --- Timeout --kill-after support detection ----------------------------------
# GNU coreutils timeout supports --kill-after; macOS/BSD timeout does not.
# Detect once at source time so every run_agent() call can use it.
_TIMEOUT_KILL_AFTER_FLAG=""
if command -v timeout &>/dev/null && timeout --help 2>&1 | grep -q 'kill-after'; then
    _TIMEOUT_KILL_AFTER_FLAG="--kill-after=60"
fi

# --- Windows-native claude detection (for taskkill cleanup) ------------------
# A Windows-native claude.exe does NOT receive POSIX signals properly from
# MSYS2/MinGW (Git Bash) or WSL interop. When detected, the abort handler
# uses taskkill.exe to forcefully terminate the process.
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

# --- Windows process kill helper ---------------------------------------------
# taskkill.exe reliably terminates Windows-native processes that ignore POSIX
# signals. Used by the abort handler when _AGENT_WINDOWS_CLAUDE is true.
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

# --- Agent exit detection globals --------------------------------------------
# Set after every run_agent() call. Callers inspect these to decide next steps.

LAST_AGENT_TURNS=0         # Turns the agent actually used
LAST_AGENT_EXIT_CODE=0     # claude CLI exit code
LAST_AGENT_ELAPSED=0       # Wall-clock seconds
LAST_AGENT_NULL_RUN=false  # true if agent likely died without doing work

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
    if [ -n "${LAST_CONTEXT_TOKENS:-}" ] && [ "${LAST_CONTEXT_TOKENS:-0}" -gt 0 ]; then
        local ctx_k=$(( LAST_CONTEXT_TOKENS / 1000 ))
        echo "  Context:     ~${ctx_k}k tokens (${LAST_CONTEXT_PCT:-0}% of window)"
    fi
    echo "══════════════════════════════════════"
    echo
}

# =============================================================================
# AGENT INVOCATION WRAPPER
# Tracks turns used and wall-clock time for each stage
# =============================================================================

run_agent() {
    local label="$1"        # e.g. "Coder", "Reviewer", "Tester"
    local model="$2"
    local max_turns="$3"
    local prompt="$4"
    local log_file="$5"
    local allowed_tools="${6:-$AGENT_TOOLS_CODER}"  # default: coder-level access

    local start_time
    start_time=$(date +%s)

    # Temporarily disable pipefail — claude can exit non-zero on turn limits
    # and we don't want that to kill the entire tekhton pipeline
    set +o pipefail

    # AGENT_TIMEOUT (seconds) guards against a hung claude process. Defaults to
    # 7200 (2 hours). Set to 0 in pipeline.conf to disable.
    local _timeout="${AGENT_TIMEOUT:-7200}"
    local _invoke
    if [ "$_timeout" -gt 0 ] 2>/dev/null && command -v timeout &>/dev/null; then
        _invoke="timeout ${_TIMEOUT_KILL_AFTER_FLAG} $_timeout"
    else
        _invoke=""
    fi

    # AGENT_ACTIVITY_TIMEOUT (seconds) kills the agent if it produces no output
    # for this duration. Catches hung API connections, stuck retries, and silent
    # failures that the total AGENT_TIMEOUT would take hours to detect.
    # Default: 600 (10 minutes). Set to 0 in pipeline.conf to disable.
    local _activity_timeout="${AGENT_ACTIVITY_TIMEOUT:-600}"

    # Temp files for inter-process communication — created inside the per-session
    # directory (TEKHTON_SESSION_DIR) to avoid predictable /tmp paths (TOCTOU).
    local _session_dir="${TEKHTON_SESSION_DIR:-/tmp}"
    local _turns_file="${_session_dir}/agent_last_turns"
    local _exit_file="${_session_dir}/agent_exit"
    rm -f "$_exit_file" "$_turns_file"

    # Pre-run marker for file-change detection (Milestone 0.5).
    # Created before the agent starts so we can detect files modified DURING
    # the run (not pre-existing changes). Used by null-run detection and
    # the activity timeout file-change check.
    local _prerun_marker="${_session_dir}/prerun_marker"
    touch "$_prerun_marker"

    # --- Build permission flags -----------------------------------------------
    # Default: use --allowedTools + --disallowedTools for least-privilege.
    # Override: set AGENT_SKIP_PERMISSIONS=true in pipeline.conf for the old
    # --dangerously-skip-permissions behavior (NOT recommended).
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

    # =========================================================================
    # FIFO-ISOLATED INVOCATION
    # =========================================================================
    # Claude runs in a BACKGROUND subshell writing to a named pipe (FIFO).
    # The foreground reads from the FIFO. This architecture solves two problems:
    #
    # 1. CTRL+C WORKS RELIABLY — Bash defers trap handlers until foreground
    #    commands complete. In a direct pipeline (claude | tee | subshell),
    #    bash can't run the INT trap until claude exits. If claude is hung,
    #    Ctrl+C is permanently blocked. With the FIFO, the foreground is just
    #    a bash read loop — it exits immediately on signal, and the trap fires.
    #
    # 2. ACTIVITY TIMEOUT — The read loop uses `read -t` to detect silence.
    #    If claude produces no output for AGENT_ACTIVITY_TIMEOUT seconds, the
    #    reader kills the background process. This catches hung API connections,
    #    stuck retries, and other silent failures within minutes instead of
    #    waiting for the 2-hour AGENT_TIMEOUT.
    #
    # 3. WINDOWS COMPATIBILITY — On MSYS2/Git Bash, Windows claude.exe ignores
    #    POSIX signals entirely. The FIFO keeps it out of the foreground process
    #    group, and taskkill.exe cleans it up in the abort handler.
    # =========================================================================

    # Track whether the timeout was activity-based (for messaging)
    local _was_activity_timeout=false

    if command -v mkfifo &>/dev/null; then
        local _fifo="${_session_dir}/agent_fifo_$$"
        rm -f "$_fifo"
        mkfifo "$_fifo"

        # Background subshell: run claude, write output to FIFO.
        # stdin is /dev/null so piped input doesn't leak into claude.
        (
            $_invoke claude \
                --model "$model" \
                "${_perm_flags[@]}" \
                --max-turns "$max_turns" \
                --output-format json \
                -p "$prompt" \
                < /dev/null \
                > "$_fifo" 2>&1
            echo "$?" > "$_exit_file"
        ) &
        _TEKHTON_AGENT_PID=$!

        # Trap: kill background subshell + Windows claude if applicable.
        # The foreground read loop sees EOF when the FIFO write-end closes
        # (background subshell dies → fd closes → reader unblocks).
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

        # Foreground: read FIFO, log each line, parse JSON, detect silence.
        # No tee — logging is done here to avoid pipe buffering issues.
        # Uses fd 3 for efficient append-mode logging (one open, many writes).
        #
        # File-change activity detection (Milestone 0.5): When the FIFO read
        # times out (no streaming output), we check for file-system changes
        # before declaring an activity timeout. JSON output mode produces no
        # streaming output, so the agent may be actively modifying files while
        # the FIFO is silent. A timestamp marker file is used for fast
        # find-based change detection instead of slow `git status`.
        (
            exec 3>>"$log_file"
            _last_activity=$(date +%s)
            _last_line=""
            _read_interval="${AGENT_ACTIVITY_POLL:-30}"
            [ "$_activity_timeout" -le 0 ] 2>/dev/null && _read_interval=0

            # Create activity marker for file-change detection
            _activity_marker="${_session_dir}/activity_marker"
            touch "$_activity_marker"

            while true; do
                if [ "$_read_interval" -gt 0 ]; then
                    if IFS= read -r -t "$_read_interval" line; then
                        _last_activity=$(date +%s)
                        echo "$line" >&3
                        _last_line="$line"
                        if echo "$line" | grep -q '"type":"text"'; then
                            echo "$line" | python3 -c \
                                "import sys,json; d=json.load(sys.stdin); print(d.get('text',''))" \
                                2>/dev/null || true
                        fi
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
                                _changed_file=$(find "${PROJECT_DIR:-.}" -maxdepth 4 \
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
                        echo "$line" >&3
                        _last_line="$line"
                        if echo "$line" | grep -q '"type":"text"'; then
                            echo "$line" | python3 -c \
                                "import sys,json; d=json.load(sys.stdin); print(d.get('text',''))" \
                                2>/dev/null || true
                        fi
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
            exec 3>&-
        ) < "$_fifo"

        # Wait for background subshell to fully exit
        wait "$_TEKHTON_AGENT_PID" 2>/dev/null || true
        rm -f "$_fifo"

        # Read exit code from background subshell
        local agent_exit
        if [ -f "$_exit_file" ]; then
            agent_exit=$(cat "$_exit_file")
            if [ "$agent_exit" = "ACTIVITY_TIMEOUT" ]; then
                agent_exit=124
                _was_activity_timeout=true
            fi
            [[ "$agent_exit" =~ ^[0-9]+$ ]] || agent_exit=1
            rm -f "$_exit_file"
        else
            agent_exit=1
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
            "${_perm_flags[@]}" \
            --max-turns "$max_turns" \
            --output-format json \
            -p "$prompt" \
            < /dev/null \
            2>&1 | tee -a "$log_file" | (
                local turns=0
                local last_line=""
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
        local agent_exit=${PIPESTATUS[0]}
    fi

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

    # Detect overshoot — Claude CLI's --max-turns is a soft cap
    local turns_display="${turns_used}/${max_turns}"
    if [ "$turns_used" -gt "$max_turns" ] 2>/dev/null; then
        turns_display="${turns_used}/${max_turns} (overshot by $(( turns_used - max_turns )))"
    fi

    log "[$label] Turns: ${turns_display} | Time: ${mins}m${secs}s"

    # Accumulate run totals
    TOTAL_TURNS=$(( TOTAL_TURNS + turns_used ))
    TOTAL_TIME=$(( TOTAL_TIME + elapsed ))

    # Store per-stage for summary
    STAGE_SUMMARY="${STAGE_SUMMARY}\n  ${label}: ${turns_display} turns, ${mins}m${secs}s"

    # --- Agent exit detection ------------------------------------------------
    # Populate LAST_AGENT_* globals so callers can check for null runs.
    #
    # Milestone 0.5: Before declaring a null run, check for file-system changes
    # and CODER_SUMMARY.md existence. JSON output mode agents may complete work
    # silently (no FIFO output, no extractable turn count) but still modify
    # files successfully. File changes override the null-run heuristic.

    export LAST_AGENT_TURNS="$turns_used"
    export LAST_AGENT_EXIT_CODE="$agent_exit"
    export LAST_AGENT_ELAPSED="$elapsed"
    LAST_AGENT_NULL_RUN=false

    # Check for file-system changes SINCE THE AGENT STARTED as a secondary
    # productivity signal. Uses the pre-run marker so we only detect changes
    # made during this agent run, not pre-existing uncommitted changes.
    local _has_file_changes=false
    if [ -f "$_prerun_marker" ] && _detect_file_changes "$_prerun_marker"; then
        _has_file_changes=true
    fi

    # Check for CODER_SUMMARY.md as a completion signal — if the agent wrote
    # its summary file during this run, it completed meaningful work regardless
    # of turn count. Only counts if the file is newer than the pre-run marker.
    local _has_summary=false
    local _summary_path="${PROJECT_DIR:-.}/CODER_SUMMARY.md"
    if [ -f "$_summary_path" ] && [ -f "$_prerun_marker" ]; then
        if [ "$_summary_path" -nt "$_prerun_marker" ]; then
            local _summary_lines
            _summary_lines=$(wc -l < "$_summary_path" 2>/dev/null | tr -d '[:space:]')
            if [ "${_summary_lines:-0}" -ge 3 ]; then
                _has_summary=true
            fi
        fi
    fi

    # Null run heuristic: agent used very few turns (≤2) OR exited non-zero
    # with zero turns. This typically means it died during discovery/search.
    # Exit 124 = timeout — always a null run regardless of turn count,
    # UNLESS files were modified (indicating the agent did productive work).
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
}

# =============================================================================
# FILE-CHANGE DETECTION HELPERS
# Used by the FIFO monitoring loop and null-run detection to check whether
# the agent is actively modifying files, even when producing no FIFO output
# (e.g., --output-format json which is non-streaming).
# =============================================================================

# _detect_file_changes — checks if any tracked or untracked files changed since
# the marker was last touched. Uses `find -newer` on PROJECT_DIR for speed
# (avoids full `git status` which can be slow in large repos).
# Returns 0 if changes detected, 1 if no changes.
_detect_file_changes() {
    local marker="$1"
    local project_dir="${PROJECT_DIR:-.}"
    local log_dir="${LOG_DIR:-${project_dir}/.claude/logs}"

    # Check for any file newer than the marker in the project directory.
    # Exclude .git, session temp dir, and pipeline log directory (logs are
    # written by the FIFO reader, not the agent — they're not agent work).
    # Limit to 1 match — we only need to know if ANY file changed.
    local changed
    changed=$(find "$project_dir" -maxdepth 4 -newer "$marker" \
        -not -path '*/.git/*' \
        -not -path '*/.git' \
        -not -path "${TEKHTON_SESSION_DIR:-/nonexistent}/*" \
        -not -path "${log_dir}/*" \
        -type f 2>/dev/null | head -1)

    if [ -n "$changed" ]; then
        return 0
    fi
    return 1
}

# _count_changed_files_since — returns the count of files modified since a
# marker file's timestamp. Uses `find -newer` for speed.
_count_changed_files_since() {
    local marker="$1"
    local project_dir="${PROJECT_DIR:-.}"
    local log_dir="${LOG_DIR:-${project_dir}/.claude/logs}"
    local count
    count=$(find "$project_dir" -maxdepth 4 -newer "$marker" \
        -not -path '*/.git/*' \
        -not -path '*/.git' \
        -not -path "${TEKHTON_SESSION_DIR:-/nonexistent}/*" \
        -not -path "${log_dir}/*" \
        -type f 2>/dev/null | wc -l | tr -d '[:space:]')
    echo "${count:-0}"
}

# =============================================================================
# NULL RUN DETECTION HELPERS
# Call these after run_agent() to check if the agent accomplished anything.
# =============================================================================

# was_null_run — returns 0 (true) if the last agent invocation was a null run.
# A null run is one where the agent died before accomplishing meaningful work.
was_null_run() {
    [ "$LAST_AGENT_NULL_RUN" = true ]
}

# check_agent_output — verifies an agent produced its expected output file and
# made git changes. Returns 0 if the agent produced meaningful work.
#
# Usage:  check_agent_output "CODER_SUMMARY.md" "Coder"
# Returns: 0 if output file exists AND (git has changes OR output file has content)
#          1 if null run or no meaningful output
check_agent_output() {
    local expected_file="$1"
    local label="$2"

    # If the agent was already flagged as a null run, fail immediately
    if was_null_run; then
        warn "[$label] Agent was a null run — no output expected."
        return 1
    fi

    # Check for expected output file
    if [ ! -f "$expected_file" ]; then
        warn "[$label] Expected output file '${expected_file}' not found."
        return 1
    fi

    # Check if the file has meaningful content (more than just a header)
    local line_count
    line_count=$(wc -l < "$expected_file" | tr -d '[:space:]')
    if [ "$line_count" -lt 3 ]; then
        warn "[$label] Output file '${expected_file}' has only ${line_count} line(s) — likely a stub."
        return 1
    fi

    # Check for git changes (the agent might have produced a report but changed no code)
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

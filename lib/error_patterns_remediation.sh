#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# error_patterns_remediation.sh — Auto-remediation engine for classified errors
#
# Sourced by tekhton.sh after error_patterns.sh — do not run directly.
# Provides: attempt_remediation(), _run_safe_remediation(),
#           _remediation_already_attempted(), reset_remediation_state(),
#           get_remediation_log()
#
# Milestone 54: Auto-Remediation Engine.
#
# Safety: only safe-rated commands execute. Blocklist enforced.
# Max 2 remediation attempts per gate invocation.
# All actions logged to causal event log.
# =============================================================================

# --- Remediation state (per gate invocation) ---------------------------------
_REMEDIATION_ATTEMPTED=()      # Commands already attempted
_REMEDIATION_ATTEMPT_COUNT=0   # Total attempts this gate invocation
_REMEDIATION_MAX_ATTEMPTS="${REMEDIATION_MAX_ATTEMPTS:-2}"
_REMEDIATION_TIMEOUT="${REMEDIATION_TIMEOUT:-60}"

# Structured log of all remediation actions for RUN_SUMMARY.json
_REMEDIATION_LOG=()

# --- Blocklist ---------------------------------------------------------------
# Commands containing any of these fragments are rejected unconditionally.
_REMEDIATION_BLOCKLIST=(
    "rm -rf"
    "rm -fr"
    "drop "
    "delete "
    "destroy"
    "reset --hard"
    "--force"
    "force push"
    "truncate "
)

# --- reset_remediation_state -------------------------------------------------
# Call at the start of each gate invocation to reset per-gate tracking.
reset_remediation_state() {
    _REMEDIATION_ATTEMPTED=()
    _REMEDIATION_ATTEMPT_COUNT=0
    _REMEDIATION_LOG=()
}

# --- get_remediation_log -----------------------------------------------------
# Returns the remediation log as JSON array for RUN_SUMMARY.json.
get_remediation_log() {
    if [[ ${#_REMEDIATION_LOG[@]} -eq 0 ]]; then
        echo "[]"
        return 0
    fi

    local json="["
    local first=true
    local entry
    for entry in "${_REMEDIATION_LOG[@]}"; do
        if [[ "$first" = true ]]; then
            first=false
        else
            json="${json},"
        fi
        json="${json}${entry}"
    done
    json="${json}]"
    echo "$json"
}

# --- _remediation_already_attempted -----------------------------------------
# Returns 0 if the command was already attempted, 1 otherwise.
_remediation_already_attempted() {
    local cmd="$1"
    local tried
    for tried in "${_REMEDIATION_ATTEMPTED[@]}"; do
        if [[ "$tried" == "$cmd" ]]; then
            return 0
        fi
    done
    return 1
}

# --- _is_blocklisted_command -------------------------------------------------
# Returns 0 if the command contains a blocklisted fragment.
_is_blocklisted_command() {
    local cmd="$1"
    local fragment
    local cmd_lower
    cmd_lower=$(printf '%s' "$cmd" | tr '[:upper:]' '[:lower:]')
    for fragment in "${_REMEDIATION_BLOCKLIST[@]}"; do
        if [[ "$cmd_lower" == *"$fragment"* ]]; then
            return 0
        fi
    done
    return 1
}

# --- _run_safe_remediation ---------------------------------------------------
# Executes a single remediation command with timeout in a subshell.
# Runs from $PROJECT_DIR. Captures output.
# Returns: 0 on success, 1 on failure/blocklist/timeout.
# Outputs: captured stdout+stderr on stdout (for logging).
_run_safe_remediation() {
    local cmd="$1"
    local remed_timeout="${_REMEDIATION_TIMEOUT}"

    # Blocklist check
    if _is_blocklisted_command "$cmd"; then
        echo "BLOCKED: Command contains blocklisted fragment"
        return 1
    fi

    local project_dir="${PROJECT_DIR:-.}"
    local output=""
    local exit_code=0

    # Run in subshell from PROJECT_DIR with timeout
    output=$(cd "$project_dir" && timeout "$remed_timeout" bash -c "$cmd" 2>&1) || exit_code=$?

    if [[ "$exit_code" -eq 124 ]]; then
        echo "TIMEOUT: Command exceeded ${remed_timeout}s timeout"
        return 1
    fi

    echo "$output"
    return "$exit_code"
}

# --- _log_remediation --------------------------------------------------------
# Appends a JSON entry to the remediation log.
_log_remediation() {
    local action="$1"    # attempted, skipped, blocked, human_action
    local category="$2"
    local command="$3"
    local exit_code="$4"
    local duration="$5"
    local diagnosis="$6"

    # Escape strings for JSON
    local safe_cmd safe_diag
    safe_cmd=$(printf '%s' "$command" | sed 's/\\/\\\\/g; s/"/\\"/g')
    safe_diag=$(printf '%s' "$diagnosis" | sed 's/\\/\\\\/g; s/"/\\"/g')

    local entry
    entry=$(printf '{"action":"%s","category":"%s","command":"%s","exit_code":%s,"duration_s":%s,"diagnosis":"%s"}' \
        "$action" "$category" "$safe_cmd" "$exit_code" "$duration" "$safe_diag")
    _REMEDIATION_LOG+=("$entry")
}

# --- _emit_remediation_event -------------------------------------------------
# Emits a causal event if emit_event is available.
_emit_remediation_event() {
    local event_type="$1"
    local category="$2"
    local command="$3"
    local exit_code="$4"
    local duration="$5"
    local phase="$6"

    if command -v emit_event &>/dev/null; then
        emit_event "$event_type" "build_gate" \
            "category=${category} command=${command} exit_code=${exit_code} duration_s=${duration}" \
            "" "" "phase=${phase}" > /dev/null 2>&1 || true
    fi
}

# --- _route_to_human_action --------------------------------------------------
# Writes non-automatable issues to HUMAN_ACTION_REQUIRED.md.
_route_to_human_action() {
    local category="$1"
    local safety="$2"
    local diagnosis="$3"
    local remediation="$4"

    if ! command -v append_human_action &>/dev/null; then
        return 0
    fi

    local oneline
    oneline="Environment issue (${category}): ${diagnosis}"
    if [[ -n "$remediation" ]]; then
        oneline="${oneline} — Fix: \`${remediation}\`"
    fi
    append_human_action "build_gate" "$oneline"
}

# --- attempt_remediation -----------------------------------------------------
# Takes classified error output (from classify_build_errors_all), executes
# safe remediation commands. Returns 0 if at least one remediation succeeded,
# 1 if none succeeded or none were safe.
#
# Usage: attempt_remediation "$classifications" "$phase_label"
attempt_remediation() {
    local classifications="$1"
    local phase_label="${2:-build_gate}"

    [[ -z "$classifications" ]] && return 1

    local any_succeeded=false
    local cat safety remed diag

    while IFS='|' read -r cat safety remed diag; do
        [[ -z "$cat" ]] && continue

        # Skip code errors — they need the build-fix agent
        [[ "$cat" == "code" ]] && continue

        # Check max attempts
        if [[ "$_REMEDIATION_ATTEMPT_COUNT" -ge "$_REMEDIATION_MAX_ATTEMPTS" ]]; then
            if [[ -n "$remed" ]] && [[ "$safety" == "safe" ]]; then
                _log_remediation "skipped" "$cat" "$remed" "-1" "0" "${diag} (max attempts reached)"
                _emit_remediation_event "remediation_skipped" "$cat" "$remed" "-1" "0" "$phase_label"
            fi
            continue
        fi

        case "$safety" in
            safe)
                [[ -z "$remed" ]] && continue

                # Already attempted?
                if _remediation_already_attempted "$remed"; then
                    continue
                fi

                # Blocklist check
                if _is_blocklisted_command "$remed"; then
                    _log_remediation "blocked" "$cat" "$remed" "-1" "0" "${diag} (blocklisted)"
                    _emit_remediation_event "remediation_skipped" "$cat" "$remed" "-1" "0" "$phase_label"
                    continue
                fi

                # Execute
                log "Auto-remediation [${cat}]: ${remed}"
                local start_time end_time duration output exit_code=0
                start_time=$(date +%s)
                output=$(_run_safe_remediation "$remed") || exit_code=$?
                end_time=$(date +%s)
                duration=$((end_time - start_time))

                _REMEDIATION_ATTEMPTED+=("$remed")
                _REMEDIATION_ATTEMPT_COUNT=$((_REMEDIATION_ATTEMPT_COUNT + 1))

                if [[ "$exit_code" -eq 0 ]]; then
                    log "Remediation succeeded: ${remed} (${duration}s)"
                    _log_remediation "attempted" "$cat" "$remed" "0" "$duration" "$diag"
                    _emit_remediation_event "remediation_attempted" "$cat" "$remed" "0" "$duration" "$phase_label"
                    any_succeeded=true
                else
                    warn "Remediation failed (exit ${exit_code}): ${remed}"
                    _log_remediation "attempted" "$cat" "$remed" "$exit_code" "$duration" "$diag"
                    _emit_remediation_event "remediation_attempted" "$cat" "$remed" "$exit_code" "$duration" "$phase_label"
                fi
                ;;

            prompt)
                # Route to human action
                _route_to_human_action "$cat" "$safety" "$diag" "$remed"
                _log_remediation "human_action" "$cat" "${remed:-none}" "-1" "0" "$diag"
                _emit_remediation_event "human_action_required" "$cat" "${remed:-none}" "-1" "0" "$phase_label"
                ;;

            manual)
                # Route to human action
                _route_to_human_action "$cat" "$safety" "$diag" "$remed"
                _log_remediation "human_action" "$cat" "${remed:-none}" "-1" "0" "$diag"
                _emit_remediation_event "human_action_required" "$cat" "${remed:-none}" "-1" "0" "$phase_label"
                ;;
        esac
    done <<< "$classifications"

    if [[ "$any_succeeded" = true ]]; then
        return 0
    fi
    return 1
}

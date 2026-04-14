#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# specialists.sh — Specialist review framework (Milestone 7)
#
# Sourced by tekhton.sh — do not run directly.
# Expects all pipeline globals to be set (TASK, LOG_FILE, etc.)
# Expects: run_agent(), render_prompt(), log(), warn(), success() from libs
# Expects: _ensure_nonblocking_log() from drift.sh; _append_specialist_notes() defined locally
#
# Runs opt-in specialist review passes (security, performance, API contract)
# AFTER the main reviewer approves. Findings tagged [BLOCKER] re-enter the
# rework loop; [NOTE] items go to ${NON_BLOCKING_LOG_FILE}.
# =============================================================================

# run_specialist_reviews — Iterates over all enabled specialists.
# Returns 0 if no blockers found, 1 if any specialist reported [BLOCKER] items.
# Sets SPECIALIST_BLOCKERS (global) with blocker text for rework routing.
run_specialist_reviews() {
    # Resolve tool profile at call time so AGENT_TOOLS_REVIEWER changes after
    # sourcing are picked up (avoids frozen-at-source-time fragility).
    export AGENT_TOOLS_SPECIALIST="${AGENT_TOOLS_REVIEWER:-Read Glob Grep Write}"
    local has_blockers=false
    SPECIALIST_BLOCKERS=""

    # Collect all enabled built-in specialists
    local -a specialists=()
    if [ "${SPECIALIST_SECURITY_ENABLED:-false}" = "true" ]; then
        specialists+=("security")
    fi
    if [ "${SPECIALIST_PERFORMANCE_ENABLED:-false}" = "true" ]; then
        specialists+=("performance")
    fi
    if [ "${SPECIALIST_API_ENABLED:-false}" = "true" ]; then
        specialists+=("api")
    fi

    # UI specialist: auto-enable when UI project detected
    local ui_enabled="${SPECIALIST_UI_ENABLED:-auto}"
    if [[ "$ui_enabled" == "auto" ]]; then
        if [[ "${UI_PROJECT_DETECTED:-}" == "true" ]]; then
            ui_enabled="true"
        else
            ui_enabled="false"
        fi
    fi
    if [[ "$ui_enabled" == "true" ]]; then
        specialists+=("ui")
    fi

    # Collect custom specialists (SPECIALIST_CUSTOM_*_ENABLED=true)
    _collect_custom_specialists specialists

    if [ ${#specialists[@]} -eq 0 ]; then
        return 0
    fi

    # M48: Filter out specialists whose diff doesn't touch relevant files
    if [[ "${SPECIALIST_SKIP_IRRELEVANT:-true}" == "true" ]]; then
        local -a filtered=()
        for spec_name in "${specialists[@]}"; do
            if _specialist_diff_relevant "$spec_name"; then
                filtered+=("$spec_name")
            else
                log "[Specialist ${spec_name}] Skipped — diff does not touch relevant files."
            fi
        done
        specialists=("${filtered[@]+"${filtered[@]}"}")
    fi

    if [ ${#specialists[@]} -eq 0 ]; then
        log "All specialists skipped (no relevant files in diff)."
        return 0
    fi

    header "Specialist Reviews"
    log "Running ${#specialists[@]} specialist review(s)..."

    # Archive any previous specialist report
    if [ -f "${SPECIALIST_REPORT_FILE}" ]; then
        if [ -n "${LOG_DIR:-}" ] && [ -n "${TIMESTAMP:-}" ]; then
            mv "${SPECIALIST_REPORT_FILE}" "${LOG_DIR}/${TIMESTAMP}_prev_$(basename "${SPECIALIST_REPORT_FILE}")" 2>/dev/null || true
        else
            rm -f "${SPECIALIST_REPORT_FILE}"
        fi
    fi

    # Initialize combined report
    cat > "${SPECIALIST_REPORT_FILE}" << 'EOF'
# Specialist Review Report

EOF

    for spec_name in "${specialists[@]}"; do
        _run_single_specialist "$spec_name" || true

        # Check for blockers in this specialist's output
        local spec_blockers
        spec_blockers=$(_extract_specialist_blockers "$spec_name")
        if [ -n "$spec_blockers" ]; then
            has_blockers=true
            SPECIALIST_BLOCKERS="${SPECIALIST_BLOCKERS}${spec_blockers}"$'\n'
        fi

        # Append notes to ${NON_BLOCKING_LOG_FILE}
        _append_specialist_notes "$spec_name"
    done

    # Populate UI_FINDINGS_BLOCK for downstream reviewer prompt injection
    export UI_FINDINGS_BLOCK=""
    if [[ -f "${TEKHTON_DIR}/SPECIALIST_UI_FINDINGS.md" ]]; then
        UI_FINDINGS_BLOCK=$(cat "${TEKHTON_DIR}/SPECIALIST_UI_FINDINGS.md")
    fi

    if [ "$has_blockers" = true ]; then
        warn "Specialist review(s) found blocker(s). Routing to rework."
        return 1
    fi

    success "All specialist reviews passed (no blockers)."
    return 0
}

# _run_single_specialist — Runs one specialist review agent.
# Args: $1 = specialist name (e.g. "security", "performance", "api", or custom name)
_run_single_specialist() {
    local spec_name="$1"

    local model max_turns prompt_template
    _resolve_specialist_config "$spec_name" model max_turns prompt_template

    log "Running specialist: ${spec_name} (model: ${model}, max turns: ${max_turns})"

    # Export specialist name and findings file path for prompt rendering
    export SPECIALIST_NAME="$spec_name"
    export SPECIALIST_FINDINGS_FILE="${TEKHTON_DIR}/SPECIALIST_${spec_name^^}_FINDINGS.md"

    local spec_prompt
    spec_prompt=$(render_prompt "$prompt_template")

    local _spec_start="$SECONDS"
    run_agent \
        "Specialist (${spec_name})" \
        "$model" \
        "$max_turns" \
        "$spec_prompt" \
        "$LOG_FILE" \
        "$AGENT_TOOLS_SPECIALIST"
    # Record specialist sub-step (M66)
    if declare -p _STAGE_DURATION &>/dev/null; then
        _STAGE_DURATION["specialist_${spec_name}"]="$(( SECONDS - _spec_start ))"
        _STAGE_TURNS["specialist_${spec_name}"]="${LAST_AGENT_TURNS:-0}"
    fi

    if was_null_run; then
        warn "[Specialist ${spec_name}] Null run — no findings produced."
        return 0
    fi

    # Append to combined report
    if [ -f "${SPECIALIST_REPORT_FILE}" ]; then
        {
            echo "## ${spec_name} Review"
            echo ""
            # Extract findings from the specialist's output file
            if [ -f "${TEKHTON_DIR}/SPECIALIST_${spec_name^^}_FINDINGS.md" ]; then
                cat "${TEKHTON_DIR}/SPECIALIST_${spec_name^^}_FINDINGS.md"
            else
                echo "(No structured findings file produced)"
            fi
            echo ""
        } >> "${SPECIALIST_REPORT_FILE}"
    fi

    log "[Specialist ${spec_name}] Review complete."
}

# _resolve_specialist_config — Resolves model, turns, and prompt for a specialist.
# Args: $1 = spec_name, $2-$4 = output var names for model, turns, prompt_template
_resolve_specialist_config() {
    local spec_name="$1"
    local -n _out_model="$2"
    local -n _out_turns="$3"
    local -n _out_prompt="$4"

    local upper_name
    upper_name=$(echo "$spec_name" | tr '[:lower:]' '[:upper:]')

    # Check for custom specialist first
    local custom_model_var="SPECIALIST_CUSTOM_${upper_name}_MODEL"
    local custom_turns_var="SPECIALIST_CUSTOM_${upper_name}_MAX_TURNS"
    local custom_prompt_var="SPECIALIST_CUSTOM_${upper_name}_PROMPT"

    if [ -n "${!custom_prompt_var:-}" ]; then
        # Custom specialist
        _out_model="${!custom_model_var:-${CLAUDE_STANDARD_MODEL}}"
        _out_turns="${!custom_turns_var:-8}"
        _out_prompt="${!custom_prompt_var}"
        return 0
    fi

    # Built-in specialist
    local model_var="SPECIALIST_${upper_name}_MODEL"
    local turns_var="SPECIALIST_${upper_name}_MAX_TURNS"

    _out_model="${!model_var:-${CLAUDE_STANDARD_MODEL}}"
    _out_turns="${!turns_var:-8}"
    _out_prompt="specialist_${spec_name}"
}

# _collect_custom_specialists — Finds all SPECIALIST_CUSTOM_*_ENABLED=true keys.
# Args: $1 = nameref to array to append custom specialist names to
_collect_custom_specialists() {
    local -n _out_array="$1"

    # Scan environment for SPECIALIST_CUSTOM_*_ENABLED=true
    while IFS='=' read -r key value; do
        if [[ "$key" =~ ^SPECIALIST_CUSTOM_([A-Z0-9_]+)_ENABLED$ ]] && [ "$value" = "true" ]; then
            local custom_name="${BASH_REMATCH[1]}"
            # Convert to lowercase for consistency
            custom_name=$(echo "$custom_name" | tr '[:upper:]' '[:lower:]')
            _out_array+=("$custom_name")
        fi
    done < <(env | grep "^SPECIALIST_CUSTOM_" | grep "_ENABLED=" || true)
}

# has_specialist_blockers — Returns 0 if SPECIALIST_BLOCKERS is non-empty.
has_specialist_blockers() {
    [ -n "${SPECIALIST_BLOCKERS:-}" ]
}

# Source extracted helpers
# shellcheck source=lib/specialists_helpers.sh
source "${TEKHTON_HOME}/lib/specialists_helpers.sh"

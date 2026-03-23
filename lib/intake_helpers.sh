#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# lib/intake_helpers.sh — Intake stage helper functions
#
# Content hash, report parsing, tweak application, and PM metadata annotation.
# Extracted from stages/intake.sh to stay within the 300-line ceiling.
#
# Sourced by tekhton.sh — do not run directly.
# Expects: TEKHTON_SESSION_DIR, MILESTONE_DIR, MILESTONE_DAG_ENABLED,
#          TASK, PROJECT_DIR from the pipeline environment.
# Expects: log(), warn() from common.sh
# Expects: dag_number_to_id(), dag_get_file(), has_milestone_manifest()
#          from milestone_dag.sh (when DAG enabled)
# =============================================================================

# --- Content hash for skip-on-resume -----------------------------------------

# _intake_content_hash — SHA256 hash of milestone file or task string.
# Used to skip re-evaluation on resume when content hasn't changed.
_intake_content_hash() {
    local content="$1"
    printf '%s' "$content" | sha256sum | cut -d' ' -f1
}

# _intake_should_skip — Returns 0 if intake already evaluated this content.
_intake_should_skip() {
    local hash="$1"
    local hash_file="${TEKHTON_SESSION_DIR}/intake_content_hash"
    if [[ -f "$hash_file" ]] && [[ "$(cat "$hash_file")" == "$hash" ]]; then
        return 0
    fi
    return 1
}

# _intake_save_hash — Record the content hash after evaluation.
_intake_save_hash() {
    local hash="$1"
    echo "$hash" > "${TEKHTON_SESSION_DIR}/intake_content_hash"
}

# --- Report parsing ----------------------------------------------------------

# _intake_parse_verdict — Extract verdict from INTAKE_REPORT.md
_intake_parse_verdict() {
    local report="$1"
    if [[ ! -f "$report" ]]; then
        echo "PASS"
        return
    fi
    local verdict
    verdict=$(awk '/^## Verdict/{getline; gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print; exit}' "$report" 2>/dev/null || true)
    # Normalize to uppercase and validate
    verdict=$(echo "$verdict" | tr '[:lower:]' '[:upper:]' | tr -d '[:space:]')
    case "$verdict" in
        PASS|TWEAKED|SPLIT_RECOMMENDED|NEEDS_CLARITY) echo "$verdict" ;;
        *) echo "PASS" ;;
    esac
}

# _intake_parse_confidence — Extract confidence score from INTAKE_REPORT.md
_intake_parse_confidence() {
    local report="$1"
    if [[ ! -f "$report" ]]; then
        echo "100"
        return
    fi
    local score
    score=$(awk '/^## Confidence/{getline; gsub(/[^0-9]/, ""); print; exit}' "$report" 2>/dev/null || true)
    # Validate 0-100
    if [[ "$score" =~ ^[0-9]+$ ]] && [[ "$score" -ge 0 ]] && [[ "$score" -le 100 ]]; then
        echo "$score"
    else
        echo "100"
    fi
}

# _intake_parse_tweaks — Extract tweaked content block from INTAKE_REPORT.md
_intake_parse_tweaks() {
    local report="$1"
    if [[ ! -f "$report" ]]; then
        return
    fi
    awk '/^## Tweaked Content/{found=1; next} found && /^## /{exit} found{print}' "$report" 2>/dev/null || true
}

# _intake_parse_questions — Extract questions from INTAKE_REPORT.md
_intake_parse_questions() {
    local report="$1"
    if [[ ! -f "$report" ]]; then
        return
    fi
    awk '/^## Questions/{found=1; next} found && /^## /{exit} found{print}' "$report" 2>/dev/null || true
}

# --- Tweak application -------------------------------------------------------

# _intake_apply_tweak_milestone — Update milestone file with tweaked content.
# Uses atomic tmpfile+mv pattern.
_intake_apply_tweak_milestone() {
    local tweaked_content="$1"
    local ms_num="$2"

    if [[ -z "$tweaked_content" ]]; then
        warn "Intake: no tweaked content to apply"
        return 1
    fi

    # DAG mode: update milestone file
    if [[ "${MILESTONE_DAG_ENABLED:-true}" == "true" ]] \
       && declare -f has_milestone_manifest &>/dev/null \
       && has_milestone_manifest; then
        local ms_id
        ms_id=$(dag_number_to_id "$ms_num" 2>/dev/null) || true
        local ms_file="${MILESTONE_DIR}/${ms_id}.md"
        if [[ ! -f "$ms_file" ]]; then
            local ms_file_name
            ms_file_name=$(dag_get_file "$ms_id" 2>/dev/null) || true
            [[ -n "$ms_file_name" ]] && ms_file="${MILESTONE_DIR}/${ms_file_name}"
        fi
        if [[ -f "$ms_file" ]]; then
            local tmpfile
            tmpfile=$(mktemp "${MILESTONE_DIR}/intake_tweak.XXXXXX")
            echo "$tweaked_content" > "$tmpfile"
            mv -f "$tmpfile" "$ms_file"
            log "Intake: updated milestone file ${ms_file}"

            # Add PM-tweaked metadata comment
            if declare -f _intake_add_pm_metadata &>/dev/null; then
                _intake_add_pm_metadata "$ms_file"
            fi
            return 0
        fi
    fi

    warn "Intake: could not locate milestone file for ${ms_num}"
    return 1
}

# _intake_apply_tweak_task — Update TASK variable and persist for resume.
_intake_apply_tweak_task() {
    local tweaked_content="$1"
    local original_task="$TASK"

    if [[ -z "$tweaked_content" ]]; then
        return 1
    fi

    # Extract first non-empty line as the new task string
    local new_task
    new_task=$(echo "$tweaked_content" | sed '/^$/d' | head -1)
    if [[ -n "$new_task" ]]; then
        log "Intake: original task: ${original_task}"
        TASK="$new_task"
        export TASK
        log "Intake: tweaked task: ${TASK}"

        # Persist tweaked task for resume
        echo "$TASK" > "${TEKHTON_SESSION_DIR}/INTAKE_TWEAKED_TASK.md"
    fi
}

# --- Milestone content reader --------------------------------------------------

# _intake_get_milestone_content — Returns the milestone file content or task string.
_intake_get_milestone_content() {
    if [[ "$MILESTONE_MODE" == true ]] && [[ -n "${_CURRENT_MILESTONE:-}" ]]; then
        # DAG mode: read milestone file
        if [[ "${MILESTONE_DAG_ENABLED:-true}" == "true" ]] \
           && declare -f has_milestone_manifest &>/dev/null \
           && has_milestone_manifest; then
            local ms_id
            ms_id=$(dag_number_to_id "$_CURRENT_MILESTONE" 2>/dev/null) || true
            local ms_file="${MILESTONE_DIR}/${ms_id}.md"
            # Fallback: try with milestone file from manifest
            if [[ ! -f "$ms_file" ]]; then
                ms_file=$(dag_get_file "$ms_id" 2>/dev/null) || true
                [[ -n "$ms_file" ]] && ms_file="${MILESTONE_DIR}/${ms_file}"
            fi
            if [[ -f "$ms_file" ]]; then
                cat "$ms_file"
                return
            fi
        fi
        # Inline mode: extract from CLAUDE.md
        local claude_md="${PROJECT_RULES_FILE:-CLAUDE.md}"
        if [[ -f "$claude_md" ]]; then
            awk -v num="$_CURRENT_MILESTONE" '
                /^#{1,5}[[:space:]]+(M|m)ilestone[[:space:]]+/ {
                    match($0, /[0-9]+([.][0-9]+)*/)
                    if (substr($0, RSTART, RLENGTH) == num) { found=1; print; next }
                }
                found && /^#{1,5}[[:space:]]/ { exit }
                found { print }
            ' "$claude_md"
            return
        fi
    fi
    # Non-milestone mode: use task string
    echo "$TASK"
}

# --- PM metadata annotation ---------------------------------------------------

_intake_add_pm_metadata() {
    local ms_file="$1"
    local date_str
    date_str=$(date '+%Y-%m-%d')
    # Check if PM-tweaked comment already exists
    if grep -q '<!-- PM-tweaked:' "$ms_file" 2>/dev/null; then
        # Update existing — atomic write
        local tmpfile
        tmpfile=$(mktemp)
        sed "s/<!-- PM-tweaked: [0-9-]* -->/<!-- PM-tweaked: ${date_str} -->/" "$ms_file" > "$tmpfile"
        mv -f "$tmpfile" "$ms_file"
    else
        # Add after milestone-meta block or at top
        if grep -q 'milestone-meta' "$ms_file" 2>/dev/null; then
            local tmpfile
            tmpfile=$(mktemp)
            sed "/^-->/a <!-- PM-tweaked: ${date_str} -->" "$ms_file" > "$tmpfile"
            mv -f "$tmpfile" "$ms_file"
        else
            local tmpfile
            tmpfile=$(mktemp)
            {
                head -1 "$ms_file"
                echo "<!-- PM-tweaked: ${date_str} -->"
                tail -n +2 "$ms_file"
            } > "$tmpfile"
            mv -f "$tmpfile" "$ms_file"
        fi
    fi
}

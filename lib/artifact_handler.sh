#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# artifact_handler.sh — User-facing AI artifact handling workflow (Milestone 11)
#
# Presents detected AI artifacts to the user with interactive menu per group:
#   (A) Archive — move to .claude/archived-ai-config/ with manifest
#   (M) Merge   — extract useful content into $MERGE_CONTEXT_FILE via agent
#   (T) Tidy    — remove files with confirmation and optional git commit
#   (I) Ignore  — leave in place, proceed with warning
#
# Sourced by lib/init.sh — do not run directly.
# Depends on: common.sh (log, warn, success, error, header)
#             prompts_interactive.sh (prompt_confirm, prompt_artifact_menu)
#             artifact_handler_ops.sh (strategy implementations)
# =============================================================================

# Source operation implementations
_HANDLER_DIR="${BASH_SOURCE[0]%/*}"
# shellcheck source=lib/artifact_handler_ops.sh
source "${_HANDLER_DIR}/artifact_handler_ops.sh"

# --- Main entry point ---------------------------------------------------------

# handle_ai_artifacts — Processes detected AI artifacts with user-chosen strategy.
#
# Args: $1 = project directory, $2 = artifacts list (TOOL|PATH|TYPE|CONFIDENCE)
# Returns: 0 always
# Side effects: May move/delete files, may create $MERGE_CONTEXT_FILE
handle_ai_artifacts() {
    local project_dir="$1"
    local artifacts_list="$2"

    [[ -z "$artifacts_list" ]] && return 0

    header "AI Artifact Detection"
    log "Found existing AI tool configurations in this project."
    echo

    # Group artifacts by tool
    local -A tool_artifacts=()
    local tool path atype confidence
    while IFS='|' read -r tool path atype confidence; do
        [[ -z "$tool" ]] && continue
        if [[ -n "${tool_artifacts[$tool]+x}" ]]; then
            tool_artifacts[$tool]+=$'\n'"${path}|${atype}|${confidence}"
        else
            tool_artifacts[$tool]="${path}|${atype}|${confidence}"
        fi
    done <<< "$artifacts_list"

    # Display summary
    _display_artifact_summary tool_artifacts

    # Check non-interactive mode
    local default_action="${ARTIFACT_HANDLING_DEFAULT:-}"

    # Process each tool group
    local tool_name
    for tool_name in "${!tool_artifacts[@]}"; do
        local group_artifacts="${tool_artifacts[$tool_name]}"

        # Prior Tekhton install — offer reinit path
        if [[ "$tool_name" == "Tekhton" ]]; then
            _handle_tekhton_reinit "$project_dir" "$group_artifacts"
            continue
        fi

        local action
        if [[ -n "$default_action" ]]; then
            action="$default_action"
            log "Using default action '${action}' for ${tool_name} artifacts"
        else
            action=$(prompt_artifact_menu "$tool_name" "$group_artifacts")
        fi

        case "$action" in
            archive)  _archive_artifact_group "$project_dir" "$tool_name" "$group_artifacts" ;;
            merge)    _merge_artifact_group "$project_dir" "$tool_name" "$group_artifacts" ;;
            tidy)     _tidy_artifact_group "$project_dir" "$tool_name" "$group_artifacts" ;;
            ignore)   _ignore_artifact_group "$tool_name" ;;
        esac
    done

    echo
}

# --- Display helpers ----------------------------------------------------------

# _display_artifact_summary — Shows a summary of detected artifacts by tool.
# Args: $1 = nameref to tool_artifacts associative array
_display_artifact_summary() {
    local -n _artifacts="$1"

    echo -e "  ${BOLD}${CYAN}Detected AI Tool Configurations${NC}" >&2
    echo -e "  ─────────────────────────────────" >&2

    local tool_name
    for tool_name in "${!_artifacts[@]}"; do
        local group="${_artifacts[$tool_name]}"
        local count=0
        while IFS= read -r _line; do
            [[ -n "$_line" ]] && count=$(( count + 1 ))
        done <<< "$group"
        local suffix=""
        [[ "$count" -gt 1 ]] && suffix="s"
        echo -e "  ${BOLD}${tool_name}${NC} (${count} artifact${suffix})" >&2

        local path atype confidence
        while IFS='|' read -r path atype confidence; do
            [[ -z "$path" ]] && continue
            local icon="${GREEN}●${NC}"
            [[ "$confidence" == "medium" ]] && icon="${YELLOW}●${NC}"
            [[ "$confidence" == "low" ]] && icon="${RED}●${NC}"
            echo -e "    ${icon} ${path} (${atype}, ${confidence})" >&2
        done <<< "$group"
    done
    echo >&2
}

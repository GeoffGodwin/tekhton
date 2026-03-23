#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# init.sh — Smart init orchestrator (Milestone 19)
#
# Replaces the bare scaffold --init with an intelligent, interactive
# initialization flow that uses tech stack detection and the project crawler
# to auto-populate pipeline.conf, generate PROJECT_INDEX.md, and guide the
# user to the appropriate next step (--plan or --replan).
#
# Sourced by tekhton.sh — do not run directly.
# Depends on: common.sh, detect.sh, detect_commands.sh, detect_report.sh,
#             crawler.sh, init_config.sh, init_helpers.sh
# =============================================================================

# Source companion files
_INIT_DIR="${BASH_SOURCE[0]%/*}"
# shellcheck source=lib/init_config.sh
source "${_INIT_DIR}/init_config.sh"
# shellcheck source=lib/init_helpers.sh
source "${_INIT_DIR}/init_helpers.sh"
# shellcheck source=lib/prompts_interactive.sh
source "${_INIT_DIR}/prompts_interactive.sh"
# shellcheck source=lib/detect_ai_artifacts.sh
source "${_INIT_DIR}/detect_ai_artifacts.sh"
# shellcheck source=lib/artifact_handler.sh
source "${_INIT_DIR}/artifact_handler.sh"

# --- Main entry point ---------------------------------------------------------

# run_smart_init — Orchestrates the full smart init flow.
# Args: $1 = project directory, $2 = tekhton home directory
#       $3 = "reinit" to force re-initialization (optional)
run_smart_init() {
    local project_dir="$1"
    local tekhton_home="$2"
    local reinit_mode="${3:-}"

    local conf_dir="${project_dir}/.claude"
    local conf_file="${conf_dir}/pipeline.conf"

    # Phase 1: Pre-flight
    if [[ -f "$conf_file" ]]; then
        if [[ "$reinit_mode" != "reinit" ]]; then
            warn "pipeline.conf already exists at ${conf_file}"
            echo "  Use --reinit to re-initialize (destructive — overwrites config)." >&2
            _TEKHTON_CLEAN_EXIT=true
            exit 1
        fi
        if ! prompt_confirm "Re-initialize will overwrite pipeline.conf and agent roles. Continue?" "n"; then
            log "Aborted."
            _TEKHTON_CLEAN_EXIT=true
            exit 0
        fi
    fi

    header "Tekhton Smart Init"

    # Create directories
    mkdir -p "${conf_dir}/agents"
    mkdir -p "${conf_dir}/logs/archive"

    # Phase 1.5: AI artifact detection
    if [[ "${ARTIFACT_DETECTION_ENABLED:-true}" == "true" ]]; then
        local ai_artifacts=""
        ai_artifacts=$(detect_ai_artifacts "$project_dir")
        if [[ -n "$ai_artifacts" ]]; then
            handle_ai_artifacts "$project_dir" "$ai_artifacts"
        fi
    fi

    # Phase 2: Detection
    log "Detecting tech stack..."
    local languages frameworks commands entry_points project_type
    languages=$(detect_languages "$project_dir")
    frameworks=$(detect_frameworks "$project_dir")
    commands=$(detect_commands "$project_dir")
    entry_points=$(detect_entry_points "$project_dir")
    project_type=$(detect_project_type "$project_dir" "$languages" "$frameworks" "$entry_points")

    # Milestone 12: Extended detection
    local workspaces="" services="" ci_config="" doc_quality=""
    if type -t detect_workspaces &>/dev/null; then
        workspaces=$(detect_workspaces "$project_dir" 2>/dev/null || true)
    fi
    if type -t detect_services &>/dev/null; then
        services=$(detect_services "$project_dir" 2>/dev/null || true)
    fi
    if type -t detect_ci_config &>/dev/null; then
        ci_config=$(detect_ci_config "$project_dir" 2>/dev/null || true)
    fi
    if type -t assess_doc_quality &>/dev/null; then
        doc_quality=$(assess_doc_quality "$project_dir" 2>/dev/null || true)
    fi

    # Display detection results
    _display_detection_results "$languages" "$frameworks" "$commands" "$entry_points" "$project_type"

    # Milestone 12: Monorepo routing
    local workspace_scope=""
    if [[ -n "$workspaces" ]]; then
        workspace_scope=$(_offer_monorepo_choice "$project_dir" "$workspaces")
    fi

    # Offer interactive correction
    if [[ -n "$languages" ]] && prompt_confirm "Would you like to correct any detections?" "n"; then
        project_type=$(_correct_project_type "$project_type")
    fi

    # Phase 3: Crawl (with progress indicator)
    local tracked_file_count
    tracked_file_count=$(_count_tracked_files "$project_dir")
    log "Crawling project (${tracked_file_count} files)..."
    crawl_project "$project_dir" 120000

    # Phase 4: Config generation
    log "Generating pipeline.conf..."
    # Export M12 detection results for config generation
    export _INIT_WORKSPACES="$workspaces"
    export _INIT_SERVICES="$services"
    export _INIT_CI_CONFIG="$ci_config"
    export _INIT_DOC_QUALITY="$doc_quality"
    export _INIT_WORKSPACE_SCOPE="$workspace_scope"
    _generate_smart_config "$project_dir" "$conf_file" \
        "$languages" "$frameworks" "$commands" "$tracked_file_count"
    success "Created ${conf_file}"

    # Phase 5: Agent role customization
    _install_agent_roles "$project_dir" "$tekhton_home" "$languages"

    # Phase 6: Stub CLAUDE.md
    if [[ ! -f "${project_dir}/CLAUDE.md" ]]; then
        local detection_report
        detection_report=$(format_detection_report "$project_dir")
        local merge_context=""
        if [[ -f "${project_dir}/MERGE_CONTEXT.md" ]]; then
            merge_context=$(cat "${project_dir}/MERGE_CONTEXT.md")
        fi
        _seed_claude_md "$project_dir" "$detection_report" "$project_type" "$merge_context"
        success "Created CLAUDE.md (seeded with detection results)"
    else
        log "CLAUDE.md already exists — skipping stub generation"
    fi

    # Phase 7: Next-step routing
    echo
    header "Init Complete"
    echo "  Tekhton home: ${tekhton_home}"
    echo "  Project:      ${project_dir}"
    echo

    if [[ "$tracked_file_count" -gt 50 ]]; then
        log "Brownfield project detected (${tracked_file_count} tracked files)"
        echo
        echo "  Next steps:"
        echo "  1. Review .claude/pipeline.conf — verify detected commands (look for # VERIFY:)"
        echo "  2. Review .claude/agents/*.md — customize agent role definitions"
        echo "  3. Run: tekhton --plan-from-index"
        echo "     (uses PROJECT_INDEX.md to synthesize DESIGN.md + CLAUDE.md)"
    else
        log "Greenfield project detected (${tracked_file_count} tracked files)"
        echo
        echo "  Next steps:"
        echo "  1. Review .claude/pipeline.conf — verify detected commands (look for # VERIFY:)"
        echo "  2. Review .claude/agents/*.md — customize agent role definitions"
        echo "  3. Run: tekhton --plan"
        echo "     (interactive planning to build DESIGN.md + CLAUDE.md)"
    fi
    echo
}

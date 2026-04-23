#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# init.sh — Smart init orchestrator (Milestone 19)
#
# Replaces the bare scaffold --init with an intelligent, interactive
# initialization flow that uses tech stack detection and the project crawler
# to auto-populate pipeline.conf, generate $PROJECT_INDEX_FILE, and guide the
# user to the appropriate next step (--plan or --replan).
#
# Sourced by tekhton.sh — do not run directly.
# Depends on: common.sh, detect.sh, detect_commands.sh, detect_report.sh,
#             crawler.sh, init_config.sh, init_helpers.sh
# =============================================================================

# --- File-written tracking (Milestone 81) ---
# Global array: each entry is "path|description". Populated during init,
# consumed by emit_init_summary to render "What Tekhton wrote" section.
_INIT_FILES_WRITTEN=()

# Source companion files
_INIT_DIR="${BASH_SOURCE[0]%/*}"
# shellcheck source=lib/init_config.sh
source "${_INIT_DIR}/init_config.sh"
# shellcheck source=lib/init_helpers.sh
source "${_INIT_DIR}/init_helpers.sh"
# shellcheck source=lib/init_report.sh
source "${_INIT_DIR}/init_report.sh"
# shellcheck source=lib/init_config_sections.sh
source "${_INIT_DIR}/init_config_sections.sh"
# shellcheck source=lib/prompts_interactive.sh
source "${_INIT_DIR}/prompts_interactive.sh"
# shellcheck source=lib/init_wizard.sh
source "${_INIT_DIR}/init_wizard.sh"
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
    local _REINIT_PRESERVED=""

    # Phase 1: Pre-flight
    if [[ -f "$conf_file" ]]; then
        if [[ "$reinit_mode" != "reinit" ]]; then
            warn "pipeline.conf already exists at ${conf_file}"
            echo "  Use --reinit to re-initialize (destructive — overwrites config)." >&2
            _TEKHTON_CLEAN_EXIT=true
            exit 1
        fi
        if ! prompt_confirm "Re-initialize will regenerate pipeline.conf (user values preserved). Continue?" "n"; then
            log "Aborted."
            _TEKHTON_CLEAN_EXIT=true
            exit 0
        fi
        # Preserve existing user config values for merging after regeneration
        _REINIT_PRESERVED=$(_preserve_user_config "$conf_file")
    fi

    header "Tekhton Smart Init"

    # Create directories
    mkdir -p "${conf_dir}/agents"
    mkdir -p "${conf_dir}/logs/archive"
    mkdir -p "${project_dir}/${TEKHTON_DIR:-.tekhton}"

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
    crawl_project "$project_dir" "${PROJECT_INDEX_BUDGET:-120000}"
    _INIT_FILES_WRITTEN+=("$(basename "${PROJECT_INDEX_FILE}")|structured project index")

    # Phase 3.5: Feature wizard (M109) — runs after detection so guidance is
    # informed by tech stack, before config generation so answers flow into
    # _emit_section_features() via env vars.
    run_feature_wizard "${reinit_mode:-}"

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

    # Reinit: merge preserved user values back into the new sectioned config
    if [[ -n "${_REINIT_PRESERVED:-}" ]]; then
        _merge_preserved_values "$conf_file" "$_REINIT_PRESERVED"
        success "Updated ${conf_file} (user values preserved, section headers added)"
    else
        success "Created ${conf_file}"
    fi
    _INIT_FILES_WRITTEN+=(".claude/pipeline.conf|primary config — edit this first")

    # Phase 4.5: Python venv setup (M109) — runs only when wizard enabled a
    # Python feature interactively. Failure is non-fatal: features degrade
    # gracefully at runtime and the user can retry with --setup-indexer.
    _run_wizard_venv_setup "$project_dir" "$tekhton_home" "$conf_dir"
    if [[ "${_WIZARD_VENV_CREATED:-}" == "true" ]]; then
        _INIT_FILES_WRITTEN+=(".claude/indexer-venv/|Python environment for enhanced features")
    fi

    # Phase 5: Agent role customization
    _install_agent_roles "$project_dir" "$tekhton_home" "$languages"
    _ensure_init_gitignore "$project_dir" "$languages"
    _INIT_FILES_WRITTEN+=(".gitignore|tech-stack and sensitive-file patterns")

    # Phase 6: Stub CLAUDE.md
    if [[ ! -f "${project_dir}/CLAUDE.md" ]]; then
        local detection_report
        detection_report=$(format_detection_report "$project_dir")
        local merge_context=""
        local _mcf="${project_dir}/${MERGE_CONTEXT_FILE}"
        if [[ -f "${_mcf}" ]]; then
            merge_context=$(cat "${_mcf}")
        fi
        _seed_claude_md "$project_dir" "$detection_report" "$merge_context"
        success "Created CLAUDE.md (seeded with detection results)"
        _INIT_FILES_WRITTEN+=("CLAUDE.md|project rules — seeded with detection results")
    else
        log "CLAUDE.md already exists — skipping stub generation"
    fi

    # Phase 6b: CHANGELOG.md stub (Milestone 77)
    if [[ "${CHANGELOG_ENABLED:-true}" == "true" ]] && [[ ! -f "${project_dir}/${CHANGELOG_FILE:-CHANGELOG.md}" ]]; then
        if command -v changelog_init_if_missing &>/dev/null; then
            changelog_init_if_missing "$project_dir"
        else
            # Inline fallback when changelog.sh is not sourced (init early-exit path)
            cat > "${project_dir}/${CHANGELOG_FILE:-CHANGELOG.md}" <<'CHANGELOG_EOF'
# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]
CHANGELOG_EOF
            success "Created ${CHANGELOG_FILE:-CHANGELOG.md}"
        fi
        _INIT_FILES_WRITTEN+=("${CHANGELOG_FILE:-CHANGELOG.md}|changelog stub")
    fi

    # Phase 7: Report and next-step routing (Milestone 22)
    emit_init_report_file "$project_dir" "$languages" "$frameworks" \
        "$commands" "$entry_points" "$project_type" "$tracked_file_count"
    _INIT_FILES_WRITTEN+=("INIT_REPORT.md|full detection report")

    # Emit dashboard init data if available
    if type -t emit_dashboard_init &>/dev/null; then
        emit_dashboard_init "$project_dir" 2>/dev/null || true
    fi

    echo
    header "Init Complete"
    emit_init_summary "$project_dir" "$languages" "$frameworks" \
        "$commands" "$project_type" "$tracked_file_count"

    # M120 Goal 4: branch-aware next-step hint.
    # has_design → silent; greenfield → push --plan; brownfield → no --plan push.
    local _m120_design_file=""
    if [[ -f "${project_dir}/.tekhton/DESIGN.md" ]]; then
        _m120_design_file=".tekhton/DESIGN.md"
    elif [[ -f "${project_dir}/DESIGN.md" ]]; then
        _m120_design_file="DESIGN.md"
    fi
    local _m120_has_commands=0
    if [[ -n "$commands" ]]; then
        _m120_has_commands=1
    fi
    local _m120_classification
    _m120_classification=$(_classify_project_maturity \
        "$project_dir" "$_m120_design_file" \
        "$tracked_file_count" "$_m120_has_commands")
    _print_init_next_step "$_m120_classification"
}

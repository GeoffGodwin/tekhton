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
#             crawler.sh, init_config.sh
# =============================================================================

# Source companion files
_INIT_DIR="${BASH_SOURCE[0]%/*}"
# shellcheck source=lib/init_config.sh
source "${_INIT_DIR}/init_config.sh"
# shellcheck source=lib/prompts_interactive.sh
source "${_INIT_DIR}/prompts_interactive.sh"

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

    # Phase 2: Detection
    log "Detecting tech stack..."
    local languages frameworks commands entry_points project_type
    languages=$(detect_languages "$project_dir")
    frameworks=$(detect_frameworks "$project_dir")
    commands=$(detect_commands "$project_dir")
    entry_points=$(detect_entry_points "$project_dir")
    project_type=$(detect_project_type "$project_dir" "$languages" "$frameworks" "$entry_points")

    # Display detection results
    _display_detection_results "$languages" "$frameworks" "$commands" "$entry_points" "$project_type"

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
    _generate_smart_config "$project_dir" "$conf_file" \
        "$languages" "$frameworks" "$commands" "$tracked_file_count"
    success "Created ${conf_file}"

    # Phase 5: Agent role customization
    _install_agent_roles "$project_dir" "$tekhton_home" "$languages"

    # Phase 6: Stub CLAUDE.md
    if [[ ! -f "${project_dir}/CLAUDE.md" ]]; then
        local detection_report
        detection_report=$(format_detection_report "$project_dir")
        _seed_claude_md "$project_dir" "$detection_report" "$project_type"
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

# --- Display detection results -----------------------------------------------

_display_detection_results() {
    local languages="$1"
    local frameworks="$2"
    local commands="$3"
    local entry_points="$4"
    local project_type="$5"

    echo >&2
    echo -e "${BOLD}${CYAN}  Detection Results${NC}" >&2
    echo -e "  ────────────────────────────────────" >&2
    echo -e "  Project type: ${BOLD}${project_type}${NC}" >&2

    if [[ -n "$languages" ]]; then
        echo -e "  ${BOLD}Languages:${NC}" >&2
        while IFS='|' read -r lang conf manifest; do
            local icon="  "
            [[ "$conf" == "high" ]] && icon="${GREEN}✓${NC}"
            [[ "$conf" == "medium" ]] && icon="${YELLOW}~${NC}"
            [[ "$conf" == "low" ]] && icon="${RED}?${NC}"
            echo -e "    ${icon} ${lang} (${conf}) — ${manifest}" >&2
        done <<< "$languages"
    else
        echo -e "  ${YELLOW}No languages detected${NC}" >&2
    fi

    if [[ -n "$frameworks" ]]; then
        echo -e "  ${BOLD}Frameworks:${NC}" >&2
        while IFS='|' read -r fw lang _evidence; do
            echo -e "    ${GREEN}✓${NC} ${fw} (${lang})" >&2
        done <<< "$frameworks"
    fi

    if [[ -n "$commands" ]]; then
        echo -e "  ${BOLD}Commands:${NC}" >&2
        while IFS='|' read -r cmd_type cmd _source conf; do
            local icon="${GREEN}✓${NC}"
            [[ "$conf" == "medium" ]] && icon="${YELLOW}~${NC}"
            [[ "$conf" == "low" ]] && icon="${RED}?${NC}"
            echo -e "    ${icon} ${cmd_type}: ${cmd}" >&2
        done <<< "$commands"
    fi

    if [[ -n "$entry_points" ]]; then
        echo -e "  ${BOLD}Entry points:${NC}" >&2
        while IFS= read -r ep; do
            echo -e "    ${ep}" >&2
        done <<< "$entry_points"
    fi
    echo >&2
}

# --- Interactive correction ---------------------------------------------------

_correct_project_type() {
    local current="$1"
    local types=("web-app" "web-game" "cli-tool" "api-service" "mobile-app" "library" "custom")
    echo "Current project type: ${current}" >&2
    local new_type
    new_type=$(prompt_choice "Select correct project type:" "${types[@]}")
    echo "$new_type"
}

# --- File counting helper -----------------------------------------------------

_count_tracked_files() {
    local project_dir="$1"
    if git -C "$project_dir" rev-parse --git-dir &>/dev/null 2>&1; then
        git -C "$project_dir" ls-files 2>/dev/null | wc -l | tr -d '[:space:]'
    else
        find "$project_dir" -maxdepth 4 -type f \
            -not -path '*/.git/*' \
            -not -path '*/node_modules/*' \
            -not -path '*/__pycache__/*' \
            -not -path '*/vendor/*' \
            -not -path '*/build/*' \
            -not -path '*/dist/*' \
            -not -path '*/target/*' \
            2>/dev/null | wc -l | tr -d '[:space:]'
    fi
}

# --- Agent role installation --------------------------------------------------

_install_agent_roles() {
    local project_dir="$1"
    local tekhton_home="$2"
    local languages="$3"
    local conf_dir="${project_dir}/.claude"

    for role in coder reviewer tester jr-coder architect; do
        local target="${conf_dir}/agents/${role}.md"
        if [[ ! -f "$target" ]] && [[ -f "${tekhton_home}/templates/${role}.md" ]]; then
            cp "${tekhton_home}/templates/${role}.md" "$target"

            # Append tech-stack addenda if available
            _append_addenda "$target" "$tekhton_home" "$languages"
            success "Created agent role file: .claude/agents/${role}.md"
        else
            log "Skipped .claude/agents/${role}.md (already exists)"
        fi
    done
}

# _append_addenda — Appends language-specific addenda to an agent role file.
_append_addenda() {
    local target="$1"
    local tekhton_home="$2"
    local languages="$3"

    [[ -z "$languages" ]] && return 0

    local -A _appended_langs=()
    local lang
    while IFS='|' read -r lang _conf _manifest; do
        # Deduplicate: skip if this language was already appended
        [[ -n "${_appended_langs[$lang]+x}" ]] && continue
        _appended_langs[$lang]=1

        local addendum="${tekhton_home}/templates/agents/addenda/${lang}.md"
        if [[ -f "$addendum" ]]; then
            printf '\n' >> "$target"
            cat "$addendum" >> "$target"
        fi
    done <<< "$languages"
}

# --- CLAUDE.md stub seeding ---------------------------------------------------

_seed_claude_md() {
    local project_dir="$1"
    local detection_report="$2"
    local project_type="$3"
    local project_name
    project_name=$(basename "$project_dir")

    cat > "${project_dir}/CLAUDE.md" << CLAUDE_EOF
# ${project_name} — Project Rules

This file contains the non-negotiable rules for this project.
All agents read this file. Keep it authoritative and concise.

## Detected Tech Stack

${detection_report}

## Architecture Rules
<!-- TODO: Add your architecture rules here -->

## Code Style
<!-- TODO: Add your code style rules here -->

## Testing Requirements
<!-- TODO: Add your testing requirements here -->

## Milestone Plan
<!-- TODO: Add milestones here, or run tekhton --plan to generate them -->

CLAUDE_EOF
}

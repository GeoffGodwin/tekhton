#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# detect_report.sh — Detection report formatting (updated Milestone 12)
#
# Sourced by tekhton.sh — do not run directly.
# Depends on: detect.sh, detect_commands.sh, detect_workspaces.sh,
#             detect_services.sh, detect_ci.sh, detect_infrastructure.sh,
#             detect_test_frameworks.sh, detect_doc_quality.sh
# =============================================================================

# --- Detection report formatting ----------------------------------------------

# format_detection_report — Renders all detection results as structured markdown.
# Args: $1 = project directory (defaults to PROJECT_DIR)
# Output: Markdown block suitable for inclusion in $PROJECT_INDEX_FILE or agent prompts
format_detection_report() {
    local proj_dir="${1:-${PROJECT_DIR:-.}}"

    local languages frameworks commands entry_points project_type
    languages=$(detect_languages "$proj_dir")
    frameworks=$(detect_frameworks "$proj_dir")
    commands=$(detect_commands "$proj_dir")
    entry_points=$(detect_entry_points "$proj_dir")
    # Pass pre-computed results to avoid redundant detection calls
    project_type=$(detect_project_type "$proj_dir" "$languages" "$frameworks" "$entry_points")

    echo "## Tech Stack Detection Report"
    echo ""
    echo "### Project Type: ${project_type}"
    echo ""

    echo "### Languages"
    echo "| Language | Confidence | Manifest |"
    echo "|----------|------------|----------|"
    if [[ -n "$languages" ]]; then
        while IFS='|' read -r lang conf manifest; do
            echo "| ${lang} | ${conf} | ${manifest} |"
        done <<< "$languages"
    else
        echo "| (none detected) | — | — |"
    fi
    echo ""

    echo "### Frameworks"
    if [[ -n "$frameworks" ]]; then
        echo "| Framework | Language | Evidence |"
        echo "|-----------|----------|----------|"
        while IFS='|' read -r fw lang evidence; do
            echo "| ${fw} | ${lang} | ${evidence} |"
        done <<< "$frameworks"
    else
        echo "(none detected)"
    fi
    echo ""

    echo "### Detected Commands"
    if [[ -n "$commands" ]]; then
        echo "| Type | Command | Source | Confidence |"
        echo "|------|---------|--------|------------|"
        while IFS='|' read -r cmd_type cmd source conf; do
            echo "| ${cmd_type} | \`${cmd}\` | ${source} | ${conf} |"
        done <<< "$commands"
    else
        echo "(none detected)"
    fi
    echo ""

    echo "### Entry Points"
    if [[ -n "$entry_points" ]]; then
        while IFS= read -r ep; do
            echo "- \`${ep}\`"
        done <<< "$entry_points"
    else
        echo "(none detected)"
    fi
    echo ""

    # --- Milestone 12: Extended sections ---
    _format_workspace_section "$proj_dir"
    _format_services_section "$proj_dir"
    _format_ci_section "$proj_dir"
    _format_infrastructure_section "$proj_dir"
    _format_test_frameworks_section "$proj_dir"
    _format_doc_quality_section "$proj_dir"
}

# --- Structured detection summary (Milestone 22) -----------------------------

# format_detection_summary — Returns machine-parseable detection summary.
# Output: KEY|VALUE|CONFIDENCE|SOURCE per line
# Consumed by emit_init_summary() and emit_init_report_file().
format_detection_summary() {
    local proj_dir="${1:-${PROJECT_DIR:-.}}"

    local languages commands
    languages=$(detect_languages "$proj_dir")
    commands=$(detect_commands "$proj_dir")

    # Language entries
    if [[ -n "$languages" ]]; then
        local lang conf manifest
        while IFS='|' read -r lang conf manifest; do
            [[ -z "$lang" ]] && continue
            echo "LANGUAGE|${lang}|${conf}|${manifest}"
        done <<< "$languages"
    fi

    # Command entries (already in TYPE|CMD|SOURCE|CONF format)
    if [[ -n "$commands" ]]; then
        local cmd_type cmd source conf
        while IFS='|' read -r cmd_type cmd source conf; do
            [[ -z "$cmd_type" ]] && continue
            echo "COMMAND_${cmd_type}|${cmd}|${conf}|${source}"
        done <<< "$commands"
    fi
}

# --- Extended section formatters (Milestone 12) ------------------------------

_format_workspace_section() {
    local proj_dir="$1"
    if ! type -t detect_workspaces &>/dev/null; then return 0; fi
    local workspaces
    workspaces=$(detect_workspaces "$proj_dir" 2>/dev/null || true)
    [[ -z "$workspaces" ]] && return 0

    echo "### Workspaces / Monorepo"
    echo "| Type | Manifest | Subprojects |"
    echo "|------|----------|-------------|"
    while IFS='|' read -r ws_type manifest subs; do
        [[ -z "$ws_type" ]] && continue
        # Count subprojects
        local count
        count=$(echo "$subs" | tr ',' '\n' | grep -cv '\.\.\.' || echo "0")
        echo "| ${ws_type} | ${manifest} | ${count} (${subs}) |"
    done <<< "$workspaces"
    echo ""
}

_format_services_section() {
    local proj_dir="$1"
    if ! type -t detect_services &>/dev/null; then return 0; fi
    local services
    services=$(detect_services "$proj_dir" 2>/dev/null || true)
    [[ -z "$services" ]] && return 0

    echo "### Services"
    echo "| Service | Directory | Tech Stack | Source |"
    echo "|---------|-----------|------------|--------|"
    while IFS='|' read -r name dir tech source; do
        [[ -z "$name" ]] && continue
        echo "| ${name} | ${dir} | ${tech} | ${source} |"
    done <<< "$services"
    echo ""
}

_format_ci_section() {
    local proj_dir="$1"
    if ! type -t detect_ci_config &>/dev/null; then return 0; fi
    local ci_data
    ci_data=$(detect_ci_config "$proj_dir" 2>/dev/null || true)
    [[ -z "$ci_data" ]] && return 0

    echo "### CI/CD Configuration"
    echo "| CI System | Build | Test | Lint | Deploy | Confidence |"
    echo "|-----------|-------|------|------|--------|------------|"
    while IFS='|' read -r ci_sys build_cmd test_cmd lint_cmd deploy_tgt _lang conf; do
        [[ -z "$ci_sys" ]] && continue
        echo "| ${ci_sys} | ${build_cmd:--} | ${test_cmd:--} | ${lint_cmd:--} | ${deploy_tgt:--} | ${conf:--} |"
    done <<< "$ci_data"
    echo ""
}

_format_infrastructure_section() {
    local proj_dir="$1"
    if ! type -t detect_infrastructure &>/dev/null; then return 0; fi
    local infra
    infra=$(detect_infrastructure "$proj_dir" 2>/dev/null || true)
    [[ -z "$infra" ]] && return 0

    echo "### Infrastructure as Code"
    echo "| Tool | Path | Provider | Confidence |"
    echo "|------|------|----------|------------|"
    while IFS='|' read -r tool path provider conf; do
        [[ -z "$tool" ]] && continue
        echo "| ${tool} | ${path} | ${provider} | ${conf} |"
    done <<< "$infra"
    echo ""
}

_format_test_frameworks_section() {
    local proj_dir="$1"
    if ! type -t detect_test_frameworks &>/dev/null; then return 0; fi
    local test_fws
    test_fws=$(detect_test_frameworks "$proj_dir" 2>/dev/null || true)
    [[ -z "$test_fws" ]] && return 0

    echo "### Test Frameworks"
    echo "| Framework | Config File | Confidence |"
    echo "|-----------|-------------|------------|"
    while IFS='|' read -r fw config conf; do
        [[ -z "$fw" ]] && continue
        echo "| ${fw} | ${config} | ${conf} |"
    done <<< "$test_fws"
    echo ""
}

_format_doc_quality_section() {
    local proj_dir="$1"
    if ! type -t assess_doc_quality &>/dev/null; then return 0; fi
    local dq_output
    dq_output=$(assess_doc_quality "$proj_dir" 2>/dev/null || true)
    [[ -z "$dq_output" ]] && return 0

    local score details
    score=$(echo "$dq_output" | cut -d'|' -f1)
    details=$(echo "$dq_output" | cut -d'|' -f2)

    echo "### Documentation Quality"
    echo ""
    echo "**Score: ${score}/100**"
    echo ""
    # Break down details
    echo "$details" | tr ';' '\n' | while IFS= read -r item; do
        [[ -z "$item" ]] && continue
        echo "- ${item}"
    done
    echo ""
}

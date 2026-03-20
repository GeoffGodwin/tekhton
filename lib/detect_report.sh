#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# detect_report.sh — Detection report formatting
#
# Sourced by tekhton.sh — do not run directly.
# Depends on: detect.sh, detect_commands.sh
# =============================================================================

# --- Detection report formatting ----------------------------------------------

# format_detection_report — Renders all detection results as structured markdown.
# Args: $1 = project directory (defaults to PROJECT_DIR)
# Output: Markdown block suitable for inclusion in PROJECT_INDEX.md or agent prompts
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
}

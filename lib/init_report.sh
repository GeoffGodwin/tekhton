#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# init_report.sh — Post-init report generator (Milestone 22, rewritten M81)
#
# Provides focused terminal summary and persistent INIT_REPORT.md after init.
# Terminal banner uses three-part narrative: learned / wrote / next.
#
# Sourced by init.sh — do not run directly.
# Depends on: common.sh (log, warn, success, header, colors)
# =============================================================================

# Source the banner renderer (split to stay under 300 lines)
_INIT_REPORT_DIR="${BASH_SOURCE[0]%/*}"
# shellcheck source=lib/init_report_banner.sh
source "${_INIT_REPORT_DIR}/init_report_banner.sh"

# _is_watchtower_enabled — Checks if Watchtower/dashboard is enabled.
_is_watchtower_enabled() {
    [[ "${DASHBOARD_ENABLED:-false}" == "true" ]] || [[ "${WATCHTOWER_ENABLED:-false}" == "true" ]]
}

# --- Report file generation ---------------------------------------------------

# emit_init_report_file — Writes INIT_REPORT.md with complete detection results.
# Args: $1 = project_dir, $2 = languages, $3 = frameworks, $4 = commands,
#        $5 = entry_points, $6 = project_type, $7 = file_count
emit_init_report_file() {
    local project_dir="$1"
    local languages="$2"
    local frameworks="$3"
    local commands="$4"
    local entry_points="$5"
    local project_type="$6"
    local file_count="${7:-0}"

    local report_file="${project_dir}/INIT_REPORT.md"
    local project_name
    project_name=$(basename "$project_dir")
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    {
        echo "# Tekhton Init Report"
        echo ""
        echo "<!-- init-report-meta"
        echo "project: ${project_name}"
        echo "timestamp: ${timestamp}"
        echo "tekhton_version: ${TEKHTON_VERSION:-unknown}"
        echo "file_count: ${file_count}"
        echo "project_type: ${project_type}"
        echo "-->"
        echo ""

        # Detection results
        echo "## Detection Results"
        echo ""
        _report_languages "$languages"
        _report_frameworks "$frameworks"
        _report_commands "$commands"
        _report_entry_points "$entry_points"

        # Config decisions
        echo "## Config Decisions"
        echo ""
        echo "| Key | Value | Source | Confidence |"
        echo "|-----|-------|--------|------------|"
        _report_config_decisions "$commands"
        echo ""

        # Attention items
        echo "## Items Needing Review"
        echo ""
        _report_attention_items "$project_dir" "$commands" "$file_count" "$languages"

        # Summary stats
        echo "## Project Summary"
        echo ""
        echo "- **Project name:** ${project_name}"
        echo "- **Project type:** ${project_type}"
        echo "- **Tracked files:** ${file_count}"
        echo "- **Init timestamp:** ${timestamp}"
        echo ""
    } > "$report_file"
}

# --- Report section helpers ---------------------------------------------------

_report_languages() {
    local languages="$1"
    echo "### Languages"
    echo ""
    echo "| Language | Confidence | Source |"
    echo "|----------|------------|--------|"
    if [[ -n "$languages" ]]; then
        local lang conf manifest
        while IFS='|' read -r lang conf manifest; do
            [[ -z "$lang" ]] && continue
            echo "| ${lang} | ${conf} | ${manifest} |"
        done <<< "$languages"
    else
        echo "| (none detected) | - | - |"
    fi
    echo ""
}

_report_frameworks() {
    local frameworks="$1"
    echo "### Frameworks"
    echo ""
    if [[ -n "$frameworks" ]]; then
        echo "| Framework | Language | Evidence |"
        echo "|-----------|----------|----------|"
        local fw lang evidence
        while IFS='|' read -r fw lang evidence; do
            [[ -z "$fw" ]] && continue
            echo "| ${fw} | ${lang} | ${evidence} |"
        done <<< "$frameworks"
    else
        echo "(none detected)"
    fi
    echo ""
}

_report_commands() {
    local commands="$1"
    echo "### Commands"
    echo ""
    if [[ -n "$commands" ]]; then
        echo "| Type | Command | Source | Confidence |"
        echo "|------|---------|--------|------------|"
        local cmd_type cmd source conf
        while IFS='|' read -r cmd_type cmd source conf; do
            [[ -z "$cmd_type" ]] && continue
            echo "| ${cmd_type} | \`${cmd}\` | ${source} | ${conf} |"
        done <<< "$commands"
    else
        echo "(none detected)"
    fi
    echo ""
}

_report_entry_points() {
    local entry_points="$1"
    echo "### Entry Points"
    echo ""
    if [[ -n "$entry_points" ]]; then
        while IFS= read -r ep; do
            [[ -z "$ep" ]] && continue
            echo "- \`${ep}\`"
        done <<< "$entry_points"
    else
        echo "(none detected)"
    fi
    echo ""
}

_report_config_decisions() {
    local commands="$1"
    if [[ -n "$commands" ]]; then
        local cmd_type cmd source conf
        while IFS='|' read -r cmd_type cmd source conf; do
            [[ -z "$cmd_type" ]] && continue
            local key=""
            case "$cmd_type" in
                test) key="TEST_CMD" ;;
                analyze) key="ANALYZE_CMD" ;;
                build) key="BUILD_CHECK_CMD" ;;
                *) key="${cmd_type}" ;;
            esac
            echo "| ${key} | \`${cmd}\` | ${source} | ${conf} |"
        done <<< "$commands"
    fi
}

_report_attention_items() {
    local project_dir="$1"
    local commands="$2"
    local file_count="${3:-0}"
    local languages="${4:-}"
    local has_items=false

    # Same code-evidence logic as emit_init_summary: skip brownfield checks when
    # all language detection came from CLAUDE.md (plan-only, no source files yet).
    local _code_evidence=false
    if [[ -z "$languages" ]] || echo "$languages" | grep -qvF '|CLAUDE.md'; then
        _code_evidence=true
    fi

    # Check ARCHITECTURE_FILE — only warn if explicitly set to a path that doesn't exist
    # (broken reference). Empty/unset is the normal default; agents create the file organically.
    if [[ -f "${project_dir}/.claude/pipeline.conf" ]]; then
        local _conf_arch=""
        _conf_arch=$(grep '^ARCHITECTURE_FILE=' "${project_dir}/.claude/pipeline.conf" 2>/dev/null | head -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'" || true)
        if [[ -n "$_conf_arch" ]] && [[ ! -f "${project_dir}/${_conf_arch}" ]]; then
            echo "- ARCHITECTURE_FILE=\"${_conf_arch}\" not found — create it or set to \"\" in pipeline.conf"
            has_items=true
        fi
    fi

    if [[ "$file_count" -gt 0 ]] && [[ "$_code_evidence" == "true" ]]; then
        local test_cmd
        test_cmd=$(echo "$commands" | grep "^test|" | head -1 | cut -d'|' -f2 || true)
        if [[ -z "$test_cmd" ]] || [[ "$test_cmd" == "true" ]]; then
            echo "- No test command detected — set TEST_CMD in pipeline.conf"
            has_items=true
        fi
    fi

    if [[ -n "$commands" ]]; then
        local cmd_type cmd_val _cmd_src cmd_conf
        while IFS='|' read -r cmd_type cmd_val _cmd_src cmd_conf; do
            [[ -z "$cmd_type" ]] && continue
            if [[ "$cmd_conf" == "low" ]] || [[ "$cmd_conf" == "medium" ]]; then
                echo "- ${cmd_type} command (\`${cmd_val}\`) detected with ${cmd_conf} confidence — verify before first run"
                has_items=true
            fi
        done <<< "$commands"
    fi

    if [[ "$has_items" != "true" ]]; then
        echo "(none — all detections look good)"
    fi
    echo ""
}

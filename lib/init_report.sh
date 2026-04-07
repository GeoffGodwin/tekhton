#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# init_report.sh — Post-init report generator (Milestone 22)
#
# Provides focused terminal summary and persistent INIT_REPORT.md after init.
#
# Sourced by init.sh — do not run directly.
# Depends on: common.sh (log, warn, success, header, colors)
# =============================================================================

# --- Terminal summary ---------------------------------------------------------

# emit_init_summary — Prints focused, color-coded post-init summary to terminal.
# Args: $1 = project_dir, $2 = languages, $3 = frameworks, $4 = commands,
#        $5 = project_type, $6 = file_count
# Globals read: WATCHTOWER_ENABLED, DASHBOARD_ENABLED
emit_init_summary() {
    local project_dir="$1"
    local languages="$2"
    local frameworks="$3"
    local commands="$4"
    local project_type="$5"
    local file_count="${6:-0}"

    local project_name
    project_name=$(basename "$project_dir")

    echo
    echo -e "  ${GREEN}${BOLD}Tekhton initialized for: ${project_name}${NC}"
    echo

    # --- Detected section ---
    echo -e "  ${BOLD}Detected:${NC}"

    # Primary language
    if [[ -n "$languages" ]]; then
        local first_lang first_conf first_manifest
        first_lang=$(echo "$languages" | head -1 | cut -d'|' -f1)
        first_conf=$(echo "$languages" | head -1 | cut -d'|' -f2)
        first_manifest=$(echo "$languages" | head -1 | cut -d'|' -f3)
        echo -e "    Language:    ${BOLD}${first_lang}${NC} (${first_conf} confidence — from ${first_manifest})"
        # Additional languages
        local extra_count
        extra_count=$(echo "$languages" | wc -l | tr -d '[:space:]')
        if [[ "$extra_count" -gt 1 ]]; then
            local others
            others=$(echo "$languages" | tail -n +2 | cut -d'|' -f1 | tr '\n' ', ' | sed 's/,$//')
            echo -e "                 also: ${others}"
        fi
    else
        echo -e "    Language:    ${YELLOW}(not detected)${NC}"
    fi

    # Framework
    if [[ -n "$frameworks" ]]; then
        local first_fw first_fw_src
        first_fw=$(echo "$frameworks" | head -1 | cut -d'|' -f1)
        first_fw_src=$(echo "$frameworks" | head -1 | cut -d'|' -f3)
        echo -e "    Framework:   ${BOLD}${first_fw}${NC} (from ${first_fw_src})"
    fi

    # Commands
    _emit_summary_command "$commands" "build" "Build"
    _emit_summary_command "$commands" "test" "Test"
    _emit_summary_command "$commands" "analyze" "Lint"

    echo -e "    Type:        ${project_type}"
    echo

    # --- Needs attention section ---
    local attention_items=0
    local attention_lines=""

    # Check ARCHITECTURE_FILE
    if [[ ! -f "${project_dir}/ARCHITECTURE.md" ]]; then
        attention_lines+="    ARCHITECTURE_FILE not detected — create one or set to \"\" to skip\n"
        attention_items=$((attention_items + 1))
    fi

    # Check for pre-existing tests
    local test_cmd
    test_cmd=$(_best_command "$commands" "test" 2>/dev/null || true)
    if [[ -z "$test_cmd" ]] || [[ "$test_cmd" == "true" ]]; then
        attention_lines+="    No test command detected — tester will generate from scratch\n"
        attention_items=$((attention_items + 1))
    fi

    # Check for low-confidence commands
    local cmd_type cmd_val cmd_src cmd_conf
    if [[ -n "$commands" ]]; then
        while IFS='|' read -r cmd_type cmd_val cmd_src cmd_conf; do
            [[ -z "$cmd_type" ]] && continue
            if [[ "$cmd_conf" == "low" ]] || [[ "$cmd_conf" == "medium" ]]; then
                attention_lines+="    ${cmd_type} command needs verification (${cmd_conf} confidence from ${cmd_src})\n"
                attention_items=$((attention_items + 1))
            fi
        done <<< "$commands"
    fi

    if [[ "$attention_items" -gt 0 ]]; then
        echo -e "  ${YELLOW}${BOLD}Needs attention:${NC}"
        echo -e "$attention_lines"
    fi

    # --- Health score (M15 graceful skip) ---
    if type -t compute_health_score &>/dev/null; then
        local health_score
        health_score=$(compute_health_score "$project_dir" 2>/dev/null || echo "")
        if [[ -n "$health_score" ]]; then
            echo -e "  Health score: ${BOLD}${health_score}/100${NC} (see INIT_REPORT.md for details)"
            echo
        fi
    fi

    # --- Next steps ---
    echo -e "  ${BOLD}Next steps:${NC}"
    echo "    1. Review essential config: .claude/pipeline.conf (lines 1-20)"

    # Detect whether milestones already exist (from a prior --plan run).
    # Strongest signal: MANIFEST.cfg with entries. Fallback: non-stub CLAUDE.md
    # with milestone headers.
    local _has_milestones=false
    local _milestone_dir="${project_dir}/.claude/milestones"
    local _claude_md="${project_dir}/CLAUDE.md"
    if [[ -f "${_milestone_dir}/MANIFEST.cfg" ]] \
        && grep -q '|' "${_milestone_dir}/MANIFEST.cfg" 2>/dev/null; then
        _has_milestones=true
    elif [[ -f "$_claude_md" ]] \
        && ! grep -q '<!-- TODO:.*--plan' "$_claude_md" 2>/dev/null \
        && grep -q '^#### Milestone' "$_claude_md" 2>/dev/null; then
        _has_milestones=true
    fi

    if [[ "$_has_milestones" == "true" ]]; then
        echo "    2. Run: tekhton \"Implement Milestone 1: <title>\""
    elif [[ "$file_count" -gt 50 ]]; then
        echo "    2. Start planning:  tekhton --plan-from-index"
        echo "       (uses PROJECT_INDEX.md to synthesize DESIGN.md + CLAUDE.md)"
    else
        echo "    2. Start planning:  tekhton --plan \"Describe your project goals\""
    fi

    # Watchtower-aware report pointer
    if _is_watchtower_enabled; then
        echo "    3. Open dashboard:  open .claude/dashboard/index.html"
        echo
        echo -e "  Full report: ${CYAN}.claude/dashboard/index.html${NC}"
    else
        echo
        echo -e "  Full report: ${CYAN}INIT_REPORT.md${NC}"
    fi
    echo
}

# _emit_summary_command — Prints a single detected command in the summary.
# Args: $1 = commands output, $2 = type (test/build/analyze), $3 = label
_emit_summary_command() {
    local commands="$1"
    local cmd_type="$2"
    local label="$3"
    [[ -z "$commands" ]] && return 0

    local cmd conf source
    cmd=$(echo "$commands" | grep "^${cmd_type}|" | head -1 | cut -d'|' -f2 || true)
    conf=$(echo "$commands" | grep "^${cmd_type}|" | head -1 | cut -d'|' -f4 || true)
    source=$(echo "$commands" | grep "^${cmd_type}|" | head -1 | cut -d'|' -f3 || true)

    if [[ -n "$cmd" ]]; then
        local marker=""
        [[ "$conf" == "medium" ]] && marker=" ${YELLOW}[VERIFY]${NC}"
        [[ "$conf" == "low" ]] && marker=" ${RED}[VERIFY]${NC}"
        # Pad label to 12 chars
        printf "    %-12s %s%b\n" "${label}:" "${cmd}" "$marker"
    fi
}

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
        _report_attention_items "$project_dir" "$commands"

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
    local has_items=false

    if [[ ! -f "${project_dir}/ARCHITECTURE.md" ]]; then
        echo "- ARCHITECTURE_FILE not detected — create one or set to \"\" in pipeline.conf"
        has_items=true
    fi

    local test_cmd
    test_cmd=$(echo "$commands" | grep "^test|" | head -1 | cut -d'|' -f2 || true)
    if [[ -z "$test_cmd" ]] || [[ "$test_cmd" == "true" ]]; then
        echo "- No test command detected — set TEST_CMD in pipeline.conf"
        has_items=true
    fi

    if [[ -n "$commands" ]]; then
        local cmd_type cmd_val cmd_src cmd_conf
        while IFS='|' read -r cmd_type cmd_val cmd_src cmd_conf; do
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

#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# report.sh — CLI report summary for tekhton report / --report
#
# Sourced by tekhton.sh — do not run directly.
# Expects: PROJECT_DIR, LOG_DIR (set by caller/config)
# Expects: Color codes (RED, GREEN, YELLOW, CYAN, BOLD, NC) from common.sh
#
# Provides:
#   print_run_report — one-screen summary of the last pipeline run
# =============================================================================

# _report_colorize STATUS
# Returns the color code for a status string.
_report_colorize() {
    local status="$1"
    case "$status" in
        PASS*|APPROVED*|success*) echo -e "${GREEN}" ;;
        FAIL*|REJECTED*|failure*|HALT*) echo -e "${RED}" ;;
        PARTIAL*|CHANGES*|TWEAKED*) echo -e "${YELLOW}" ;;
        *) echo -e "${NC}" ;;
    esac
}

# _report_extract_field FILE PATTERN
# Extracts a value matching a pattern from a file.
_report_extract_field() {
    local file="$1"
    local pattern="$2"
    grep -oP "$pattern" "$file" 2>/dev/null | head -1 || true
}

# print_run_report
# Reads latest run's report files and prints a structured one-screen summary.
print_run_report() {
    local summary_file="${PROJECT_DIR:-.}/.claude/logs/RUN_SUMMARY.json"

    # Find the latest archive directory for timestamp
    local archive_dir="${PROJECT_DIR:-.}/.claude/logs/archive"
    local latest_archive=""
    if [[ -d "$archive_dir" ]]; then
        latest_archive=$(find "$archive_dir" -maxdepth 1 -type d ! -name archive 2>/dev/null | head -1 || true)
    fi

    # Determine run timestamp
    local run_timestamp=""
    if [[ -f "$summary_file" ]]; then
        run_timestamp=$(_report_extract_field "$summary_file" '"timestamp"\s*:\s*"\K[^"]+')
    fi
    if [[ -z "$run_timestamp" ]] && [[ -n "$latest_archive" ]]; then
        local dir_name
        dir_name=$(basename "$latest_archive")
        run_timestamp="${dir_name:0:8} ${dir_name:9:6}"
    fi
    : "${run_timestamp:=unknown}"

    # Extract outcome
    local outcome=""
    if [[ -f "$summary_file" ]]; then
        outcome=$(_report_extract_field "$summary_file" '"outcome"\s*:\s*"\K[^"]+')
    fi
    : "${outcome:=unknown}"

    # Extract milestone
    local milestone=""
    if [[ -f "$summary_file" ]]; then
        milestone=$(_report_extract_field "$summary_file" '"milestone"\s*:\s*"\K[^"]+')
    fi

    # Header
    echo ""
    echo -e "${BOLD}════════════════════════════════════════${NC}"
    local outcome_color
    outcome_color=$(_report_colorize "$outcome")
    echo -e "${BOLD}  Last run:${NC} ${run_timestamp} ${outcome_color}${outcome}${NC}"
    if [[ -n "$milestone" ]] && [[ "$milestone" != "none" ]]; then
        echo -e "${BOLD}  Milestone:${NC} ${milestone}"
    fi
    echo -e "${BOLD}════════════════════════════════════════${NC}"
    echo ""

    # --- Per-stage summaries ------------------------------------------------

    # Intake
    _report_stage_intake

    # Scout
    _report_stage_scout

    # Coder
    _report_stage_coder "$summary_file"

    # Security
    _report_stage_security "$summary_file"

    # Reviewer
    _report_stage_reviewer

    # Tester
    _report_stage_tester

    echo ""

    # Action items
    local action_count=0
    if [[ -f "${PROJECT_DIR:-.}/HUMAN_ACTION_REQUIRED.md" ]] && [[ -s "${PROJECT_DIR:-.}/HUMAN_ACTION_REQUIRED.md" ]]; then
        local ha_count
        ha_count=$(grep -c '^- \[ \]' "${PROJECT_DIR:-.}/HUMAN_ACTION_REQUIRED.md" 2>/dev/null || echo "0")
        ha_count="${ha_count//[!0-9]/}"
        : "${ha_count:=0}"
        if [[ "$ha_count" -gt 0 ]]; then
            echo -e "  ${YELLOW}Action items: ${ha_count} in HUMAN_ACTION_REQUIRED.md${NC}"
            action_count=$(( action_count + ha_count ))
        fi
    fi

    if [[ -n "$latest_archive" ]]; then
        echo -e "  Full reports: ${latest_archive}"
    fi

    # Suggest --diagnose for failed runs
    if [[ "$outcome" = "failure" ]] || [[ "$outcome" = "stuck" ]] || [[ "$outcome" = "timeout" ]]; then
        echo ""
        echo -e "  ${CYAN}Run 'tekhton --diagnose' for recovery suggestions.${NC}"
    fi

    echo ""
}

# --- Per-stage report helpers -----------------------------------------------

_report_stage_intake() {
    local intake_file="${PROJECT_DIR:-.}/INTAKE_REPORT.md"
    [[ -f "$intake_file" ]] || return 0

    local verdict
    verdict=$(awk '/^## Verdict/{getline; print; exit}' "$intake_file" 2>/dev/null || true)
    verdict="${verdict## }"; verdict="${verdict%% }"
    [[ -n "$verdict" ]] || return 0

    local confidence
    confidence=$(grep -oP '[Cc]onfidence[: ]*\K[0-9]+' "$intake_file" 2>/dev/null | head -1 || true)

    local color
    color=$(_report_colorize "$verdict")
    echo -e "  Intake:    ${color}${verdict}${NC}${confidence:+ (confidence ${confidence})}"
}

_report_stage_scout() {
    local scout_file="${PROJECT_DIR:-.}/.claude/logs"
    local latest_scout
    latest_scout=$(find "$scout_file" -maxdepth 1 -name '*SCOUT_REPORT*.md' -type f 2>/dev/null | head -1 || true)
    [[ -n "$latest_scout" ]] || return 0

    local file_count
    file_count=$(grep -c '^- \*\*' "$latest_scout" 2>/dev/null || echo "0")
    file_count="${file_count//[!0-9]/}"
    : "${file_count:=0}"

    echo -e "  Scout:     ${file_count} files identified"
}

_report_stage_coder() {
    local summary_file="$1"
    local coder_file="${PROJECT_DIR:-.}/CODER_SUMMARY.md"
    [[ -f "$coder_file" ]] || return 0

    local status
    status=$(awk '/^## Status/{getline; print; exit}' "$coder_file" 2>/dev/null || true)
    status="${status## }"; status="${status%% }"

    # Count files changed from RUN_SUMMARY.json
    local files_changed=""
    if [[ -f "$summary_file" ]]; then
        files_changed=$(_report_extract_field "$summary_file" '"files_changed"\s*:\s*\[')
        if [[ -n "$files_changed" ]]; then
            local count
            count=$(grep -oP '"files_changed"\s*:\s*\[[^\]]*\]' "$summary_file" 2>/dev/null \
                | tr ',' '\n' | grep -c '"' 2>/dev/null || echo "0")
            count="${count//[!0-9]/}"
            : "${count:=0}"
            files_changed="${count} files modified"
        fi
    fi
    : "${files_changed:=status ${status:-unknown}}"

    local color
    color=$(_report_colorize "${status:-unknown}")
    echo -e "  Coder:     ${color}${files_changed}${NC}"
}

_report_stage_security() {
    local summary_file="$1"
    local security_file="${PROJECT_DIR:-.}/SECURITY_REPORT.md"
    [[ -f "$security_file" ]] || return 0

    local findings_count=0
    if [[ -f "$summary_file" ]]; then
        findings_count=$(_report_extract_field "$summary_file" '"security_findings_count"\s*:\s*\K[0-9]+')
    fi
    findings_count="${findings_count//[!0-9]/}"
    : "${findings_count:=0}"

    local color="$GREEN"
    [[ "$findings_count" -gt 0 ]] && color="$YELLOW"

    if [[ "$findings_count" -eq 0 ]]; then
        echo -e "  Security:  ${color}PASS (no findings)${NC}"
    else
        echo -e "  Security:  ${color}${findings_count} finding(s) (see SECURITY_REPORT.md)${NC}"
    fi
}

_report_stage_reviewer() {
    local reviewer_file="${PROJECT_DIR:-.}/REVIEWER_REPORT.md"
    [[ -f "$reviewer_file" ]] || return 0

    local verdict
    verdict=$(awk '/^## Verdict/{getline; print; exit}' "$reviewer_file" 2>/dev/null || true)
    verdict="${verdict## }"; verdict="${verdict%% }"
    [[ -n "$verdict" ]] || return 0

    local color
    color=$(_report_colorize "$verdict")
    echo -e "  Reviewer:  ${color}${verdict}${NC}"
}

_report_stage_tester() {
    local tester_file="${PROJECT_DIR:-.}/TESTER_REPORT.md"
    [[ -f "$tester_file" ]] || return 0

    local test_count
    test_count=$(awk '/^## Tests Written/{f=1;next} /^## /{f=0} f && /^[0-9]+\./{c++} END{print c+0}' "$tester_file" 2>/dev/null || echo "0")
    test_count="${test_count//[!0-9]/}"
    : "${test_count:=0}"

    local bug_count
    bug_count=$(awk '/^## Bugs Found/{f=1;next} /^## /{f=0} f && /^-?[[:space:]]*[Nn]one/{next} f && /^- /{c++} END{print c+0}' "$tester_file" 2>/dev/null || echo "0")
    bug_count="${bug_count//[!0-9]/}"
    : "${bug_count:=0}"

    local color="$GREEN"
    [[ "$bug_count" -gt 0 ]] && color="$YELLOW"

    if [[ "$bug_count" -eq 0 ]]; then
        echo -e "  Tester:    ${color}${test_count} tests written, all passing${NC}"
    else
        echo -e "  Tester:    ${color}${test_count} tests written, ${bug_count} bug(s) found${NC}"
    fi
}

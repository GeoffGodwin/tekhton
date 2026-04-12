#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# ui_validate_report.sh — UI validation report parser and formatter (Milestone 29)
#
# Sourced by tekhton.sh — do not run directly.
# Expects: ui_validate.sh sourced first.
#
# Provides:
#   generate_ui_validation_report — parse JSON results, write report
#   get_ui_validation_summary     — one-line pass/fail summary for banners
# =============================================================================

# generate_ui_validation_report RESULTS...
# Reads JSON output lines from ui_smoke_test.js and produces
# ${UI_VALIDATION_REPORT_FILE} with structured results.
generate_ui_validation_report() {
    local results=("$@")
    local report_file="${UI_VALIDATION_REPORT_FILE}"
    local pass_count=0
    local fail_count=0
    local warn_count=0
    local console_errors=""
    local missing_resources=""
    local flicker_warnings=""
    local screenshot_dir="${PROJECT_DIR:-.}/.claude/ui-validation/screenshots"

    {
        echo "## UI Validation Report"
        echo ""
        echo "### Results"
        echo "| Target | Load | Console | Resources | Rendering | Verdict |"
        echo "|--------|------|---------|-----------|-----------|---------|"

        for result_json in "${results[@]}"; do
            [[ -z "$result_json" ]] && continue

            # Parse JSON fields (simple grep-based extraction for shell)
            local target label verdict load_ok console_ok resources_ok render_ok
            label=$(_json_field "$result_json" "label")
            verdict=$(_json_field "$result_json" "verdict")
            load_ok=$(_json_field "$result_json" "load")
            console_ok=$(_json_field "$result_json" "console")
            resources_ok=$(_json_field "$result_json" "resources")
            render_ok=$(_json_field "$result_json" "rendering")
            local viewport
            viewport=$(_json_field "$result_json" "viewport")
            target="${label} (${viewport})"

            local load_icon console_icon resources_icon render_icon
            load_icon=$(_status_icon "$load_ok")
            console_icon=$(_status_icon "$console_ok")
            resources_icon=$(_status_icon "$resources_ok")
            render_icon=$(_status_icon "$render_ok")

            local verdict_display="PASS"
            if [[ "$verdict" = "FAIL" ]]; then
                verdict_display="**FAIL**"
                fail_count=$((fail_count + 1))
            elif [[ "$verdict" = "WARN" ]]; then
                verdict_display="WARN"
                warn_count=$((warn_count + 1))
            else
                pass_count=$((pass_count + 1))
            fi

            echo "| ${target} | ${load_icon} | ${console_icon} | ${resources_icon} | ${render_icon} | ${verdict_display} |"

            # Collect console errors
            local errors
            errors=$(_json_field "$result_json" "console_errors")
            if [[ -n "$errors" ]] && [[ "$errors" != "[]" ]] && [[ "$errors" != "none" ]]; then
                console_errors="${console_errors}${target}: ${errors}
"
            fi

            # Collect missing resources
            local missing
            missing=$(_json_field "$result_json" "missing_resources")
            if [[ -n "$missing" ]] && [[ "$missing" != "[]" ]] && [[ "$missing" != "none" ]]; then
                missing_resources="${missing_resources}${target}: ${missing}
"
            fi

            # Collect flicker warnings
            local flicker
            flicker=$(_json_field "$result_json" "flicker")
            if [[ "$flicker" = "true" ]] || [[ "$flicker" = "detected" ]]; then
                flicker_warnings="${flicker_warnings}- ${target}: page content changes between frames (possible auto-refresh or animation)
"
            fi
        done

        echo ""
        echo "### Console Errors"
        if [[ -n "$console_errors" ]]; then
            echo '```'
            echo "$console_errors"
            echo '```'
        else
            echo "(none)"
        fi

        echo ""
        echo "### Missing Resources"
        if [[ -n "$missing_resources" ]]; then
            echo '```'
            echo "$missing_resources"
            echo '```'
        else
            echo "(none)"
        fi

        echo ""
        echo "### Flicker Detection"
        if [[ -n "$flicker_warnings" ]]; then
            echo "$flicker_warnings"
        else
            echo "(none detected)"
        fi

        echo ""
        echo "### Screenshots"
        if [[ "${UI_VALIDATION_SCREENSHOTS:-true}" = "true" ]] && [[ -d "$screenshot_dir" ]]; then
            echo "Saved to ${screenshot_dir}/"
        else
            echo "(screenshots disabled)"
        fi

    } > "$report_file"

    log "UI validation report: ${pass_count} passed, ${fail_count} failed, ${warn_count} warnings"
    log "Report written to ${report_file}"

    # Export counts for finalize_display and finalize_summary
    export UI_VALIDATION_PASS_COUNT="$pass_count"
    export UI_VALIDATION_FAIL_COUNT="$fail_count"
    export UI_VALIDATION_WARN_COUNT="$warn_count"
}

# get_ui_validation_summary
# Returns a one-line summary string for use in banners.
get_ui_validation_summary() {
    local pass="${UI_VALIDATION_PASS_COUNT:-0}"
    local fail="${UI_VALIDATION_FAIL_COUNT:-0}"
    local warns="${UI_VALIDATION_WARN_COUNT:-0}"

    if [[ "$fail" -gt 0 ]]; then
        echo "${pass} passed, ${fail} failed, ${warns} warnings"
    elif [[ "$warns" -gt 0 ]]; then
        echo "${pass} passed, ${warns} warnings"
    elif [[ "$pass" -gt 0 ]]; then
        echo "${pass} passed"
    else
        echo "not run"
    fi
}

# --- JSON helpers (simple grep-based, no jq dependency) ----------------------

# _json_field JSON KEY
# Extracts a simple string value from a flat JSON object.
_json_field() {
    local json="$1"
    local key="$2"
    # Requires grep with PCRE support (-P). On minimal images (Alpine) without
    # PCRE, this silently returns empty → report cells show "?". Acceptable tradeoff.
    echo "$json" | grep -oP "\"${key}\"\\s*:\\s*\"?\\K[^\",}]+" | head -1 || true
}

# _status_icon VALUE
# Returns a status emoji for report table.
_status_icon() {
    local val="$1"
    case "$val" in
        pass|true|ok) echo "pass" ;;
        warn|warning) echo "warn" ;;
        fail|false|error) echo "FAIL" ;;
        *) echo "?" ;;
    esac
}

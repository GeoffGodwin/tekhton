#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# plan_browser.sh — Browser-based planning interview orchestrator
#
# Generates an HTML form from the planning template, serves it via a local
# HTTP server, and waits for submission. Answers are written to the shared
# plan_answers.yaml file from M31.
#
# Sourced by tekhton.sh when --plan is passed. Do not run directly.
# Expects: PLAN_TEMPLATE_FILE, PLAN_PROJECT_TYPE, PROJECT_DIR, TEKHTON_HOME
# Expects: PLAN_ANSWER_FILE from lib/plan_answers.sh
# Expects: init_answer_file(), has_answer_file(), load_answer(),
#          _slugify_section() from lib/plan_answers.sh
# Expects: _extract_template_sections() from lib/plan.sh
# Expects: _start_plan_server(), _stop_plan_server(), _open_plan_browser(),
#          _wait_for_plan_submit(), _plan_server_port() from lib/plan_server.sh
# Expects: log(), warn(), error(), success(), header() from common.sh
# =============================================================================

# _html_escape — Escape HTML special characters.
# Args: $1 — text to escape (required; pass "" for empty)
_html_escape() {
    local text="$1"
    text="${text//&/&amp;}"
    text="${text//</&lt;}"
    text="${text//>/&gt;}"
    text="${text//\"/&quot;}"
    text="${text//\'/&#39;}"
    echo "$text"
}

# _build_sections_html — Write section card HTML to a file.
# Used by _generate_plan_form to avoid bash string expansion issues.
# Args: output_file
_build_sections_html() {
    local output_file="$1"
    local current_phase=0
    local phase_labels=("" "Phase 1: Concept Capture" "Phase 2: System Deep-Dive" "Phase 3: Architecture &amp; Constraints")

    : > "$output_file"

    while IFS='|' read -r s_name s_req s_guide s_phase; do
        local sid
        sid=$(_slugify_section "$s_name")
        local phase="${s_phase:-1}"

        # Phase heading on transition
        if [[ "$phase" -ne "$current_phase" ]]; then
            current_phase="$phase"
            local phase_label="${phase_labels[$phase]:-Phase ${phase}}"
            echo "<div class=\"phase-heading\">${phase_label}</div>" >> "$output_file"
        fi

        # Required indicator
        local req_mark=""
        local req_attr="false"
        if [[ "$s_req" == "true" ]]; then
            req_mark="<span class=\"required-mark\">*</span>"
            req_attr="true"
        fi

        # Load existing answer for pre-population
        local existing_answer=""
        if has_answer_file; then
            existing_answer=$(load_answer "$sid" 2>/dev/null || true)
            if [[ "$existing_answer" == "TBD" ]] || [[ "$existing_answer" == "SKIP" ]]; then
                existing_answer=""
            fi
        fi
        local escaped_answer
        escaped_answer=$(_html_escape "$existing_answer")

        # Status class
        local status_class="empty"
        local badge_text="Required"
        if [[ -n "$existing_answer" ]]; then
            status_class="complete"
            badge_text="Done"
        elif [[ "$s_req" != "true" ]]; then
            badge_text="Optional"
            status_class="empty"
        fi

        # Guidance block
        local guidance_html=""
        if [[ -n "${s_guide:-}" ]]; then
            local escaped_guide
            escaped_guide=$(_html_escape "$s_guide")
            guidance_html="<details class=\"guidance\"><summary>Guidance</summary>"
            guidance_html+="<div class=\"guidance-content\">${escaped_guide}</div></details>"
        fi

        # Escaped section title
        local escaped_name
        escaped_name=$(_html_escape "$s_name")

        # Write section card
        {
            echo "<div class=\"section-card ${status_class}\" data-required=\"${req_attr}\">"
            echo "  <div class=\"section-header\">"
            echo "    <h3 class=\"section-title\">${escaped_name}${req_mark}</h3>"
            echo "    <span class=\"section-badge ${status_class}\">${badge_text}</span>"
            echo "  </div>"
            echo "${guidance_html}"
            printf '  <textarea class="section-textarea" name="%s" ' "$sid"
            echo "rows=\"8\" placeholder=\"Enter your answer here...\">${escaped_answer}</textarea>"
            echo "  <div class=\"char-count\">${#existing_answer} chars</div>"
            echo "</div>"
        } >> "$output_file"
    done < <(_extract_template_sections "$PLAN_TEMPLATE_FILE")
}

# _generate_plan_form — Generate HTML form from template sections.
#
# Reads the planning template, extracts sections, and produces a complete
# HTML form. Pre-populates textareas from existing answers if resuming.
#
# Args: form_output_dir
# Writes: index.html into form_output_dir (with sections filled in)
_generate_plan_form() {
    local form_dir="$1"

    # Copy static assets from template
    cp "${TEKHTON_HOME}/templates/plan_form/style.css" "${form_dir}/style.css"

    # Build the output HTML by writing the template in parts around placeholders.
    # Bash parameter expansion truncates multi-line replacements, so we write
    # sections directly to a temp file and use awk to stitch the template.
    local project_name
    project_name=$(_html_escape "$(basename "$PROJECT_DIR")")
    local project_type
    project_type=$(_html_escape "$PLAN_PROJECT_TYPE")

    # Write sections HTML to a temp file
    local sections_file="${form_dir}/_sections.html"
    _build_sections_html "$sections_file"

    # Assemble the final HTML: substitute simple vars, then splice sections
    local template_file="${TEKHTON_HOME}/templates/plan_form/index.html"
    awk -v pname="$project_name" -v ptype="$project_type" -v sfile="$sections_file" '
    BEGIN {
        # Escape & for awk gsub replacement strings (& means "matched text" in awk)
        gsub(/&/, "\\\\&", pname)
        gsub(/&/, "\\\\&", ptype)
    }
    {
        gsub(/\{\{PROJECT_NAME\}\}/, pname)
        gsub(/\{\{PROJECT_TYPE\}\}/, ptype)
        if (index($0, "{{SECTIONS_HTML}}")) {
            while ((getline line < sfile) > 0) print line
            close(sfile)
        } else {
            print
        }
    }' "$template_file" > "${form_dir}/index.html"

    rm -f "$sections_file"
}

# run_browser_interview — Main entry point for browser-based interview.
#
# Generates the form, starts the server, opens the browser, waits for
# submission, then cleans up. Answers are written to plan_answers.yaml
# by the server's POST handler.
#
# Returns 0 on successful submission, 1 on failure or interrupt.
run_browser_interview() {
    header "Browser-Based Planning Interview"
    log "Template: ${PLAN_TEMPLATE_FILE}"
    log "Project type: ${PLAN_PROJECT_TYPE}"
    echo

    # Initialize or resume answer file
    if has_answer_file; then
        log "Resuming from saved answers in ${PLAN_ANSWER_FILE}"
    else
        init_answer_file "$PLAN_PROJECT_TYPE" "$PLAN_TEMPLATE_FILE"
    fi

    # Generate form into session directory
    local session_dir="${TEKHTON_SESSION_DIR:-${PROJECT_DIR}/.claude/logs}"
    local form_dir="${session_dir}/plan-form"
    mkdir -p "$form_dir"

    log "Generating planning form..."
    _generate_plan_form "$form_dir"

    # Start server
    if ! _start_plan_server "$form_dir"; then
        error "Failed to start planning form server."
        return 1
    fi

    # Ensure cleanup on exit
    trap '_stop_plan_server' EXIT

    # Open browser
    local port
    port=$(_plan_server_port)
    _open_plan_browser "$port"

    echo
    # Wait for submission
    if _wait_for_plan_submit; then
        _stop_plan_server
        trap - EXIT
        return 0
    else
        _stop_plan_server
        trap - EXIT
        return 1
    fi
}

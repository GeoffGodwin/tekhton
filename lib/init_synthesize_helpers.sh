#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC2153
# =============================================================================
# init_synthesize_helpers.sh — Helpers for project synthesis (--plan-from-index)
#
# Extracted from stages/init_synthesize.sh to stay under the 300-line ceiling.
# Sourced by init_synthesize.sh — do not run directly.
# Expects: log(), warn(), error(), success(), header() from common.sh
# Expects: check_context_budget(), measure_context_size() from lib/context.sh
# Expects: compress_context() from lib/context_compiler.sh
# Expects: format_detection_report() from lib/detect_report.sh
#
# Provides:
#   _assemble_synthesis_context   — load project artifacts into context vars
#   _compress_synthesis_context   — budget-driven context compression
#   _check_synthesis_completeness — validate synthesized ${DESIGN_FILE} depth
#   _get_section_content_simple   — extract section content between headings
#
# Sources: lib/init_synthesize_ui.sh for UI menu functions
# =============================================================================

# Source UI functions (review menu + next steps)
# shellcheck source=/dev/null
source "${TEKHTON_HOME:-.}/lib/init_synthesize_ui.sh"

# --- Context assembly --------------------------------------------------------

# _assemble_synthesis_context — Builds agent prompt context from project artifacts.
#
# Loads $PROJECT_INDEX_FILE, detection report, README, existing ARCHITECTURE.md,
# and git log summary. Applies context budget — compresses if over budget.
#
# Sets exported variables: PROJECT_INDEX_CONTENT, DETECTION_REPORT_CONTENT,
#   README_CONTENT, EXISTING_ARCHITECTURE_CONTENT, GIT_LOG_SUMMARY
#
# Args: $1 = project directory
# Returns: 0 on success, 1 if $PROJECT_INDEX_FILE is missing
_assemble_synthesis_context() {
    local project_dir="$1"
    local index_file="${project_dir}/${PROJECT_INDEX_FILE}"

    if [[ ! -f "$index_file" ]] && [[ ! -f "${project_dir}/.claude/index/meta.json" ]]; then
        error "${PROJECT_INDEX_FILE} not found at ${index_file}"
        error "Run 'tekhton --init' first to generate the project index."
        return 1
    fi

    # Load project index via structured reader (M68). The reader produces a
    # bounded summary (60KB) — rich enough for synthesis but prevents unbounded
    # context injection. Falls back to legacy $PROJECT_INDEX_FILE for pre-M67 projects.
    export PROJECT_INDEX_CONTENT
    PROJECT_INDEX_CONTENT=$(read_index_summary "$project_dir" 60000)
    log "Loaded project index summary ($(echo "$PROJECT_INDEX_CONTENT" | wc -c | tr -d '[:space:]') chars)"

    # Generate detection report
    export DETECTION_REPORT_CONTENT
    DETECTION_REPORT_CONTENT=$(format_detection_report "$project_dir")
    log "Generated detection report ($(echo "$DETECTION_REPORT_CONTENT" | wc -c | tr -d '[:space:]') chars)"

    # Load README if present
    export README_CONTENT=""
    local readme_file=""
    for candidate in README.md README.rst README.txt README; do
        if [[ -f "${project_dir}/${candidate}" ]]; then
            readme_file="${project_dir}/${candidate}"
            break
        fi
    done
    if [[ -n "$readme_file" ]]; then
        README_CONTENT=$(cat "$readme_file")
        log "Loaded ${readme_file##*/} ($(echo "$README_CONTENT" | wc -c | tr -d '[:space:]') chars)"
    fi

    # Load existing architecture doc if present
    export EXISTING_ARCHITECTURE_CONTENT=""
    if [[ -f "${project_dir}/ARCHITECTURE.md" ]]; then
        EXISTING_ARCHITECTURE_CONTENT=$(cat "${project_dir}/ARCHITECTURE.md")
        log "Loaded ARCHITECTURE.md ($(echo "$EXISTING_ARCHITECTURE_CONTENT" | wc -c | tr -d '[:space:]') chars)"
    fi

    # Git log summary (last 30 commits)
    export GIT_LOG_SUMMARY=""
    if git -C "$project_dir" rev-parse --git-dir &>/dev/null; then
        GIT_LOG_SUMMARY=$(git -C "$project_dir" log --oneline -30 2>/dev/null || true)
        if [[ -n "$GIT_LOG_SUMMARY" ]]; then
            log "Loaded git log ($(echo "$GIT_LOG_SUMMARY" | wc -l | tr -d '[:space:]') commits)"
        fi
    fi

    # Load $MERGE_CONTEXT_FILE if present (from artifact merge — Milestone 11)
    export MERGE_CONTEXT=""
    local _mcf="${project_dir}/${MERGE_CONTEXT_FILE}"
    if [[ -f "${_mcf}" ]]; then
        MERGE_CONTEXT=$(cat "${_mcf}")
        log "Loaded ${MERGE_CONTEXT_FILE} ($(echo "$MERGE_CONTEXT" | wc -c | tr -d '[:space:]') chars)"
    fi

    # Milestone 12: Doc quality score for synthesis calibration
    export DOC_QUALITY_SCORE="0"
    export DOC_QUALITY_GUIDANCE=""
    if type -t assess_doc_quality &>/dev/null; then
        local dq_output
        dq_output=$(assess_doc_quality "$project_dir" 2>/dev/null || true)
        if [[ -n "$dq_output" ]]; then
            DOC_QUALITY_SCORE=$(echo "$dq_output" | cut -d'|' -f1)
            if [[ "${DOC_QUALITY_SCORE:-0}" -gt 70 ]]; then
                DOC_QUALITY_GUIDANCE="High documentation quality (${DOC_QUALITY_SCORE}/100). Extract and preserve existing architectural decisions rather than inferring new ones."
            elif [[ "${DOC_QUALITY_SCORE:-0}" -lt 30 ]]; then
                DOC_QUALITY_GUIDANCE="Low documentation quality (${DOC_QUALITY_SCORE}/100). Infer aggressively from code patterns and generate detailed architecture documentation."
            else
                DOC_QUALITY_GUIDANCE="Moderate documentation quality (${DOC_QUALITY_SCORE}/100). Balance between extracting existing docs and inferring from code."
            fi
            log "Doc quality score: ${DOC_QUALITY_SCORE}/100"
        fi
    fi

    # --- Context budget check and compression ---
    _compress_synthesis_context

    return 0
}

# _compress_synthesis_context — Applies compression if total context exceeds budget.
#
# Compression priority (compress first → last):
#   1. Sampled file content in PROJECT_INDEX (truncate to headings only)
#   2. README (truncate to 50 lines)
#   3. Existing ARCHITECTURE.md (truncate to 50 lines)
#   4. Git log (truncate to 10 entries)
_compress_synthesis_context() {
    local cpt="${CHARS_PER_TOKEN:-4}"
    local _merge_ctx="${MERGE_CONTEXT:-}"
    local total_chars=0
    total_chars=$(( ${#PROJECT_INDEX_CONTENT} + ${#DETECTION_REPORT_CONTENT} \
        + ${#README_CONTENT} + ${#EXISTING_ARCHITECTURE_CONTENT} \
        + ${#GIT_LOG_SUMMARY} + ${#_merge_ctx} ))
    local total_tokens=$(( (total_chars + cpt - 1) / cpt ))

    if check_context_budget "$total_tokens" "$SYNTHESIS_MODEL"; then
        log "[synthesis] Context within budget (${total_tokens} est. tokens)"
        return
    fi

    log "[synthesis] Over budget (${total_tokens} est. tokens) — applying compression"

    # M68: PROJECT_INDEX_CONTENT is already bounded by read_index_summary().
    # No summarize_headings compression needed — the reader produces prioritized,
    # budget-aware output that preserves inventory and dependency details.

    # Truncate README
    if [[ -n "$README_CONTENT" ]]; then
        README_CONTENT=$(compress_context "$README_CONTENT" "truncate" 50)
        log "[synthesis] Truncated README to 50 lines"
    fi

    # Truncate architecture doc
    if [[ -n "$EXISTING_ARCHITECTURE_CONTENT" ]]; then
        EXISTING_ARCHITECTURE_CONTENT=$(compress_context "$EXISTING_ARCHITECTURE_CONTENT" "truncate" 50)
        log "[synthesis] Truncated ARCHITECTURE.md to 50 lines"
    fi

    # Truncate git log
    if [[ -n "$GIT_LOG_SUMMARY" ]]; then
        GIT_LOG_SUMMARY=$(echo "$GIT_LOG_SUMMARY" | head -10)
        log "[synthesis] Truncated git log to 10 entries"
    fi

    total_chars=$(( ${#PROJECT_INDEX_CONTENT} + ${#DETECTION_REPORT_CONTENT} \
        + ${#README_CONTENT} + ${#EXISTING_ARCHITECTURE_CONTENT} \
        + ${#GIT_LOG_SUMMARY} + ${#_merge_ctx} ))
    total_tokens=$(( (total_chars + cpt - 1) / cpt ))
    if ! check_context_budget "$total_tokens" "$SYNTHESIS_MODEL"; then
        warn "[synthesis] Still over budget after compression (${total_tokens} est. tokens)"
        warn "[synthesis] Proceeding anyway — model may truncate internally"
    fi
}

# --- Completeness check for synthesized ${DESIGN_FILE} ----------------------------

# _check_synthesis_completeness — Validates synthesized ${DESIGN_FILE} and re-synthesizes
# thin sections if needed.
#
# Args: $1 = project directory
# Returns: 0 always (best-effort — does not block on incomplete sections)
_check_synthesis_completeness() {
    local project_dir="$1"
    local design_file="${project_dir}/${DESIGN_FILE:-}"

    if [[ ! -f "$design_file" ]]; then
        return 0
    fi

    # Use a lightweight check: count sections with headers and minimal content
    local section_count
    section_count=$(grep -c '^## ' "$design_file" || true)

    if [[ "$section_count" -lt 5 ]]; then
        warn "${DESIGN_FILE} has only ${section_count} sections — running re-synthesis pass"
    fi

    # Check individual section depth regardless of total section count
    local thin_sections=""
    local section_name section_content line_count
    while IFS= read -r section_name; do
        [[ -z "$section_name" ]] && continue
        section_content=$(_get_section_content_simple "$design_file" "$section_name")
        line_count=$(echo "$section_content" | grep -c '[^[:space:]]' || true)
        if [[ "$line_count" -lt 3 ]]; then
            thin_sections="${thin_sections}${section_name}"$'\n'
        fi
    done < <(grep '^## ' "$design_file" | sed 's/^## //')

    if [[ -n "$thin_sections" ]]; then
        warn "Thin sections found:"
        echo "$thin_sections" | while IFS= read -r s; do
            [[ -n "$s" ]] && warn "  - ${s}"
        done

        # Set PLAN_INCOMPLETE_SECTIONS so the prompt can target these sections
        export PLAN_INCOMPLETE_SECTIONS
        PLAN_INCOMPLETE_SECTIONS=$(echo "$thin_sections" | sed '/^$/d' | sed 's/^/- /')

        # Re-synthesize with thin sections flagged
        log "Running second synthesis pass for thin sections..."
        _synthesize_design "$project_dir" || true

        # Clear after use
        unset PLAN_INCOMPLETE_SECTIONS
    else
        success "${DESIGN_FILE} has ${section_count} sections — completeness OK."
    fi

    return 0
}

# _get_section_content_simple — Extract content between ## heading and next ## or EOF.
# Simpler version of _get_section_content from plan_completeness.sh.
_get_section_content_simple() {
    local file="$1"
    local section_name="$2"
    local in_section=0
    local content=""
    while IFS= read -r line; do
        if [[ "$in_section" -eq 1 ]]; then
            if [[ "$line" =~ ^##\  ]]; then
                break
            fi
            content="${content}${line}"$'\n'
        fi
        if [[ "$line" == "## ${section_name}" ]]; then
            in_section=1
        fi
    done < "$file"
    echo "$content"
}

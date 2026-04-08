#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# plan_answers_helpers.sh — Helper functions for plan_answers.sh
#
# Extracted from plan_answers.sh to keep both files under the 300-line ceiling.
# Contains: YAML escape/unescape, slugify, answer parsing, and secondary
# public functions (export, import, build block, rename).
#
# Sourced by plan_answers.sh — do not run directly.
# Expects: PLAN_ANSWER_FILE, PROJECT_DIR from plan_answers.sh
# Expects: log(), warn(), error(), success() from common.sh
# Expects: _extract_template_sections() from plan_batch.sh
# =============================================================================

# --- YAML Helpers -------------------------------------------------------------

# _yaml_escape_dq — Escape a string for use inside YAML double quotes.
# Escapes backslashes first, then double quotes.
# Args: $1 — raw string
# Prints escaped string to stdout.
_yaml_escape_dq() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    echo "$s"
}

# _yaml_unescape_dq — Reverse _yaml_escape_dq: unescape \" and \\.
# Args: $1 — escaped string
# Prints unescaped string to stdout.
_yaml_unescape_dq() {
    local s="$1"
    s="${s//\\\"/\"}"
    s="${s//\\\\/\\}"
    echo "$s"
}

# _slugify_section — Convert section title to a YAML-safe key.
# "Developer Philosophy & Constraints" → "developer_philosophy_constraints"
_slugify_section() {
    local title="$1"
    local slug
    # Lowercase, replace non-alnum with underscore, collapse multiples, trim
    slug=$(echo "$title" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g; s/__*/_/g; s/^_//; s/_$//')
    echo "$slug"
}

# --- Internal Parsing ---------------------------------------------------------

# _emit_answer_line — Helper to print a single answer record.
_emit_answer_line() {
    local id="$1" title="$2" phase="$3" required="$4" answer="$5"
    echo "${id}|${title}|${phase}|${required}|${answer}"
}

# _parse_answer_field — Extract the answer value for a given section_id.
# Handles both inline quoted and block scalar formats.
# Args: yaml_file, section_id
_parse_answer_field() {
    local yaml_file="$1"
    local section_id="$2"

    local in_section=0 in_answer=0 answer=""

    while IFS= read -r line; do
        # Match section start
        if [[ "$line" =~ ^[[:space:]]{2}${section_id}:$ ]]; then
            in_section=1
            continue
        fi

        # Different section — stop if we were in our section
        if [[ "$in_section" -eq 1 ]] && [[ "$line" =~ ^[[:space:]]{2}[a-z_][a-z0-9_]*:$ ]]; then
            break
        fi

        [[ "$in_section" -eq 0 ]] && continue

        # Block scalar answer
        if [[ "$line" =~ ^[[:space:]]{4}answer:[[:space:]]*\|[[:space:]]*$ ]]; then
            in_answer=1
            continue
        fi

        # Inline quoted answer
        if [[ "$line" =~ ^[[:space:]]{4}answer:[[:space:]]*\"(.*)\"$ ]]; then
            _yaml_unescape_dq "${BASH_REMATCH[1]}"
            return 0
        fi

        # Block scalar continuation
        if [[ "$in_answer" -eq 1 ]] && [[ "$line" =~ ^[[:space:]]{6} ]]; then
            local content="${line#"      "}"
            if [[ -z "$answer" ]]; then
                answer="$content"
            else
                answer="${answer}"$'\n'"${content}"
            fi
            continue
        fi

        # End of block scalar
        if [[ "$in_answer" -eq 1 ]]; then
            break
        fi
    done < "$yaml_file"

    if [[ -n "$answer" ]]; then
        echo "$answer"
    fi
}

# --- Module-level Internal Functions -----------------------------------------------

# _generate_question_yaml — Helper to generate YAML template content.
# Accessed by export_question_template. Extracted to module level to avoid
# nested function scoping issues (bash doesn't scope nested function defs).
# Args: template_path
_generate_question_yaml() {
    local template_path="$1"

    echo "# Tekhton Planning Answers"
    echo "# Project: $(basename "${PROJECT_DIR:-unknown}")"
    echo "# Template: $(basename "$template_path" .md)"
    echo "# Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S')"
    echo "# Tekhton: ${TEKHTON_VERSION:-unknown}"
    echo "#"
    echo "# Instructions:"
    echo "#   Fill in the 'answer' field for each section below."
    echo "#   For multi-line answers, use YAML block scalar syntax:"
    echo "#     answer: |"
    echo "#       First line of your answer."
    echo "#       Second line of your answer."
    echo "#   Leave answer empty or \"\" to skip optional sections."
    echo "#   Sections marked 'required: true' must have answers."
    echo ""
    echo "sections:"

    while IFS='|' read -r s_name s_req s_guide s_phase; do
        local section_id
        section_id=$(_slugify_section "$s_name")
        local esc_name
        esc_name=$(_yaml_escape_dq "$s_name")
        echo "  ${section_id}:"
        echo "    title: \"${esc_name}\""
        echo "    phase: ${s_phase:-1}"
        echo "    required: ${s_req:-false}"
        if [[ -n "${s_guide:-}" ]]; then
            # Sanitize guidance for YAML comment: collapse newlines to spaces
            local safe_guide="${s_guide//$'\n'/ }"
            safe_guide="${safe_guide//$'\r'/ }"
            echo "    # Guidance: ${safe_guide}"
        fi
        echo "    answer: \"\""
    done < <(_extract_template_sections "$template_path")
}

# --- Secondary Public Functions -----------------------------------------------

# export_question_template — Generate a YAML file with sections from template.
# Guidance appears as comments, values are empty for user to fill.
# Args: template_path [output_path]  (omit output_path to write to stdout)
export_question_template() {
    local template_path="$1"
    local output_path="${2:-}"

    if [[ -n "$output_path" ]]; then
        local output_dir
        output_dir="$(dirname "$output_path")"
        local tmp_file
        tmp_file="$(mktemp "${output_dir}/plan_export.XXXXXX" 2>/dev/null || mktemp /tmp/plan_export.XXXXXX)"
        _generate_question_yaml "$template_path" > "$tmp_file"
        mv -f "$tmp_file" "$output_path"
    else
        _generate_question_yaml "$template_path"
    fi
}

# import_answer_file — Parse a user-filled YAML file and load into the answer layer.
# Validates structure and required sections.
# Args: source_path
# Returns 0 on success, 1 if required sections are missing.
import_answer_file() {
    local source_path="$1"

    if [[ ! -f "$source_path" ]]; then
        error "Answer file not found: ${source_path}"
        return 1
    fi

    # Validate header
    if ! head -1 "$source_path" 2>/dev/null | grep -q '^# Tekhton Planning Answers'; then
        error "Invalid answer file — missing Tekhton header."
        return 1
    fi

    # Copy to answer file location
    local answer_dir
    answer_dir="$(dirname "$PLAN_ANSWER_FILE")"
    mkdir -p "$answer_dir" 2>/dev/null || true

    cp -f "$source_path" "$PLAN_ANSWER_FILE"

    # Validate required sections have answers
    if ! answer_file_complete; then
        warn "Imported answer file has unanswered required sections."
        return 1
    fi

    return 0
}

# build_answers_block — Construct INTERVIEW_ANSWERS_BLOCK from the YAML file.
# Output matches the format the existing synthesis prompt expects.
build_answers_block() {
    local block=""

    while IFS='|' read -r _id title _phase required answer; do
        # Decode %%NL%% back to newlines
        answer="${answer//%%NL%%/$'\n'}"

        local req_label=""
        [[ "$required" == "true" ]] && req_label=" [REQUIRED]"

        if [[ -z "$answer" ]] || [[ "$answer" == "SKIP" ]]; then
            block+="**${title}${req_label}**: (skipped — write a placeholder)"$'\n\n'
        else
            block+="**${title}${req_label}**: ${answer}"$'\n\n'
        fi
    done < <(load_all_answers)

    echo "$block"
}

# rename_answer_file_done — Move answer file to .done after successful synthesis.
rename_answer_file_done() {
    if [[ -f "$PLAN_ANSWER_FILE" ]]; then
        mv -f "$PLAN_ANSWER_FILE" "${PLAN_ANSWER_FILE}.done"
    fi
}

# --- Core Helper Functions -------------------------------------------------------

# has_answer_file — Check if plan_answers.yaml exists with valid header.
# Returns 0 if valid, 1 otherwise.
has_answer_file() {
    [[ -f "$PLAN_ANSWER_FILE" ]] && head -1 "$PLAN_ANSWER_FILE" 2>/dev/null | grep -q '^# Tekhton Planning Answers'
}

# answer_file_complete — Check if all REQUIRED sections have non-empty, non-TBD answers.
# Returns 0 if complete, 1 otherwise.
answer_file_complete() {
    if [[ ! -f "$PLAN_ANSWER_FILE" ]]; then
        return 1
    fi

    local has_incomplete=0
    while IFS='|' read -r _id _title _phase required answer; do
        if [[ "$required" == "true" ]]; then
            local clean_answer="${answer//%%NL%%/}"
            clean_answer="${clean_answer#"${clean_answer%%[![:space:]]*}"}"
            clean_answer="${clean_answer%"${clean_answer##*[![:space:]]}"}"
            if [[ -z "$clean_answer" ]] || [[ "$clean_answer" == "TBD" ]] || \
               [[ "$clean_answer" == "SKIP" ]]; then
                has_incomplete=1
                break
            fi
        fi
    done < <(load_all_answers)

    return "$has_incomplete"
}

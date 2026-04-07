#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# plan_answers.sh — Answer persistence layer for planning interviews
#
# Provides YAML-backed read/write for planning answers. The YAML schema is
# intentionally flat — no nested objects beyond sections → section_id → fields.
# Multi-line answers use YAML block scalar (|) parsed with a simple state machine.
#
# Sourced by tekhton.sh when --plan is passed. Do not run directly.
# Expects: PROJECT_DIR, TEKHTON_HOME from tekhton.sh
# Expects: PLAN_TEMPLATE_FILE, PLAN_PROJECT_TYPE from plan.sh
# Expects: log(), warn(), error() from common.sh
# Expects: _extract_template_sections() from plan.sh
# =============================================================================

# Default answer file location
PLAN_ANSWER_FILE="${PROJECT_DIR:-}/.claude/plan_answers.yaml"

# --- Core Functions ---------------------------------------------------------

# has_answer_file — Check if plan_answers.yaml exists with valid header.
# Returns 0 if valid, 1 otherwise.
has_answer_file() {
    [[ -f "$PLAN_ANSWER_FILE" ]] && head -1 "$PLAN_ANSWER_FILE" 2>/dev/null | grep -q '^# Tekhton Planning Answers'
}

# init_answer_file — Create plan_answers.yaml with header metadata.
# Args: project_type, template_path
init_answer_file() {
    local project_type="$1"
    local template_path="$2"

    local answer_dir
    answer_dir="$(dirname "$PLAN_ANSWER_FILE")"
    mkdir -p "$answer_dir" 2>/dev/null || true

    local tmp_file
    tmp_file="$(mktemp "${answer_dir}/plan_answers.XXXXXX" 2>/dev/null || mktemp /tmp/plan_answers.XXXXXX)"

    {
        echo "# Tekhton Planning Answers"
        echo "# Project: $(basename "${PROJECT_DIR:-unknown}")"
        echo "# Template: ${project_type}"
        echo "# Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S')"
        echo "# Tekhton: ${TEKHTON_VERSION:-unknown}"
        echo ""
        echo "sections:"
    } > "$tmp_file"

    # Parse template sections and create entries
    while IFS='|' read -r s_name s_req s_guide s_phase; do
        local section_id
        section_id=$(_slugify_section "$s_name")
        {
            echo "  ${section_id}:"
            echo "    title: \"${s_name}\""
            echo "    phase: ${s_phase:-1}"
            echo "    required: ${s_req:-false}"
            echo "    guidance: \"${s_guide:-}\""
            echo "    answer: \"\""
        } >> "$tmp_file"
    done < <(_extract_template_sections "$template_path")

    mv -f "$tmp_file" "$PLAN_ANSWER_FILE"
}

# save_answer — Write/update a single section's answer to the YAML file.
# Uses atomic tmpfile+mv to prevent corruption on interrupt.
# Args: section_id, answer_text
save_answer() {
    local section_id="$1"
    local answer_text="$2"

    if [[ ! -f "$PLAN_ANSWER_FILE" ]]; then
        warn "Answer file not found: ${PLAN_ANSWER_FILE}"
        return 1
    fi

    local answer_dir
    answer_dir="$(dirname "$PLAN_ANSWER_FILE")"
    local tmp_file
    tmp_file="$(mktemp "${answer_dir}/plan_answers.XXXXXX" 2>/dev/null || mktemp /tmp/plan_answers.XXXXXX)"

    # State machine: copy file, replacing the answer field for matching section_id
    local in_target_section=0
    local in_answer_field=0
    local answer_written=0

    while IFS= read -r line; do
        # Detect section start: "  section_id:"
        if [[ "$line" =~ ^[[:space:]]{2}[a-z_][a-z0-9_]*:$ ]]; then
            local current_id="${line#"${line%%[![:space:]]*}"}"
            current_id="${current_id%:}"
            if [[ "$current_id" == "$section_id" ]]; then
                in_target_section=1
            else
                in_target_section=0
            fi
            in_answer_field=0
            echo "$line" >> "$tmp_file"
            continue
        fi

        # Inside target section, detect answer field
        if [[ "$in_target_section" -eq 1 ]] && [[ "$line" =~ ^[[:space:]]{4}answer: ]]; then
            in_answer_field=1
            answer_written=1
            # Write new answer
            if [[ -z "$answer_text" ]]; then
                echo "    answer: \"\"" >> "$tmp_file"
            elif [[ "$answer_text" == *$'\n'* ]] || [[ "$answer_text" == *":"* ]] || \
                 [[ "$answer_text" == *"#"* ]] || [[ "$answer_text" == *"\""* ]] || \
                 [[ "$answer_text" == *"'"* ]] || [[ "$answer_text" == *"|"* ]] || \
                 [[ "$answer_text" == *">"* ]] || [[ "$answer_text" == *"["* ]] || \
                 [[ "$answer_text" == *"]"* ]] || [[ "$answer_text" == *"{"* ]] || \
                 [[ "$answer_text" == *"}"* ]]; then
                echo "    answer: |" >> "$tmp_file"
                while IFS= read -r aline; do
                    echo "      ${aline}" >> "$tmp_file"
                done <<< "$answer_text"
            else
                echo "    answer: \"${answer_text}\"" >> "$tmp_file"
            fi
            continue
        fi

        # Skip old multi-line answer content (indented deeper than answer field)
        if [[ "$in_answer_field" -eq 1 ]]; then
            if [[ "$line" =~ ^[[:space:]]{6} ]] && [[ ! "$line" =~ ^[[:space:]]{4}[a-z] ]]; then
                continue
            fi
            # Line is not continuation of block scalar — stop skipping
            in_answer_field=0
        fi

        # Detect next field in section (stops block scalar reading)
        if [[ "$in_target_section" -eq 1 ]] && [[ "$line" =~ ^[[:space:]]{4}[a-z] ]]; then
            in_answer_field=0
        fi

        echo "$line" >> "$tmp_file"
    done < "$PLAN_ANSWER_FILE"

    if [[ "$answer_written" -eq 0 ]]; then
        warn "Section '${section_id}' not found in answer file."
        rm -f "$tmp_file"
        return 1
    fi

    mv -f "$tmp_file" "$PLAN_ANSWER_FILE"
}

# load_answer — Read a single section's answer from the YAML file.
# Prints the answer to stdout. Returns empty string if not answered.
# Args: section_id
load_answer() {
    local section_id="$1"

    if [[ ! -f "$PLAN_ANSWER_FILE" ]]; then
        return 0
    fi

    _parse_answer_field "$PLAN_ANSWER_FILE" "$section_id"
}

# load_all_answers — Read all answers into stdout as section_id|title|phase|required|answer lines.
# Multi-line answers have newlines replaced with %%NL%% for transport.
load_all_answers() {
    if [[ ! -f "$PLAN_ANSWER_FILE" ]]; then
        return 0
    fi

    local current_id="" current_title="" current_phase="" current_required=""
    local current_answer="" in_answer=0 in_sections=0

    while IFS= read -r line; do
        # Start of sections block
        if [[ "$line" == "sections:" ]]; then
            in_sections=1
            continue
        fi

        [[ "$in_sections" -eq 0 ]] && continue

        # New section: "  section_id:"
        if [[ "$line" =~ ^[[:space:]]{2}([a-z_][a-z0-9_]*):$ ]]; then
            # Emit previous section if any
            if [[ -n "$current_id" ]]; then
                _emit_answer_line "$current_id" "$current_title" "$current_phase" "$current_required" "$current_answer"
            fi
            current_id="${BASH_REMATCH[1]}"
            current_title=""
            current_phase=""
            current_required=""
            current_answer=""
            in_answer=0
            continue
        fi

        # Title field
        if [[ "$line" =~ ^[[:space:]]{4}title:[[:space:]]*\"(.*)\"$ ]]; then
            current_title="${BASH_REMATCH[1]}"
            in_answer=0
            continue
        fi

        # Phase field
        if [[ "$line" =~ ^[[:space:]]{4}phase:[[:space:]]*(.+)$ ]]; then
            current_phase="${BASH_REMATCH[1]}"
            in_answer=0
            continue
        fi

        # Required field
        if [[ "$line" =~ ^[[:space:]]{4}required:[[:space:]]*(.+)$ ]]; then
            current_required="${BASH_REMATCH[1]}"
            in_answer=0
            continue
        fi

        # Guidance field (skip, not needed for output)
        if [[ "$line" =~ ^[[:space:]]{4}guidance: ]]; then
            in_answer=0
            continue
        fi

        # Answer field — block scalar
        if [[ "$line" =~ ^[[:space:]]{4}answer:[[:space:]]*\|[[:space:]]*$ ]]; then
            in_answer=1
            current_answer=""
            continue
        fi

        # Answer field — inline quoted
        if [[ "$line" =~ ^[[:space:]]{4}answer:[[:space:]]*\"(.*)\"$ ]]; then
            current_answer="${BASH_REMATCH[1]}"
            in_answer=0
            continue
        fi

        # Answer field — inline unquoted
        if [[ "$line" =~ ^[[:space:]]{4}answer:[[:space:]]*(.+)$ ]]; then
            current_answer="${BASH_REMATCH[1]}"
            in_answer=0
            continue
        fi

        # Block scalar continuation (6+ space indent)
        if [[ "$in_answer" -eq 1 ]] && [[ "$line" =~ ^[[:space:]]{6} ]]; then
            local content="${line#"      "}"
            if [[ -z "$current_answer" ]]; then
                current_answer="$content"
            else
                current_answer="${current_answer}%%NL%%${content}"
            fi
            continue
        fi

        # Any other 4-space field ends block scalar
        if [[ "$in_answer" -eq 1 ]] && [[ "$line" =~ ^[[:space:]]{4}[a-z] ]]; then
            in_answer=0
        fi
    done < "$PLAN_ANSWER_FILE"

    # Emit last section
    if [[ -n "$current_id" ]]; then
        _emit_answer_line "$current_id" "$current_title" "$current_phase" "$current_required" "$current_answer"
    fi
}

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
            echo "${BASH_REMATCH[1]}"
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

# export_question_template — Generate a YAML file with sections from template.
# Guidance appears as comments, values are empty for user to fill.
# Args: template_path [output_path]  (omit output_path to write to stdout)
export_question_template() {
    local template_path="$1"
    local output_path="${2:-}"

    local project_type
    project_type=$(basename "$template_path" .md)

    _generate_question_yaml() {
        echo "# Tekhton Planning Answers"
        echo "# Project: $(basename "${PROJECT_DIR:-unknown}")"
        echo "# Template: ${project_type}"
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
            echo "  ${section_id}:"
            echo "    title: \"${s_name}\""
            echo "    phase: ${s_phase:-1}"
            echo "    required: ${s_req:-false}"
            if [[ -n "${s_guide:-}" ]]; then
                echo "    # Guidance: ${s_guide}"
            fi
            echo "    answer: \"\""
        done < <(_extract_template_sections "$template_path")
    }

    if [[ -n "$output_path" ]]; then
        local output_dir
        output_dir="$(dirname "$output_path")"
        local tmp_file
        tmp_file="$(mktemp "${output_dir}/plan_export.XXXXXX" 2>/dev/null || mktemp /tmp/plan_export.XXXXXX)"
        _generate_question_yaml > "$tmp_file"
        mv -f "$tmp_file" "$output_path"
    else
        _generate_question_yaml
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

# --- Helpers ----------------------------------------------------------------

# _slugify_section — Convert section title to a YAML-safe key.
# "Developer Philosophy & Constraints" → "developer_philosophy_constraints"
_slugify_section() {
    local title="$1"
    local slug
    # Lowercase, replace non-alnum with underscore, collapse multiples, trim
    slug=$(echo "$title" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g; s/__*/_/g; s/^_//; s/_$//')
    echo "$slug"
}

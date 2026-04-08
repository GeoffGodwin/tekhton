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

# Source extracted helper functions (_yaml_escape_dq, _yaml_unescape_dq,
# _slugify_section, _emit_answer_line, _parse_answer_field, export_question_template,
# import_answer_file, build_answers_block, rename_answer_file_done,
# has_answer_file, answer_file_complete).
# shellcheck source=lib/plan_answers_helpers.sh
source "${TEKHTON_HOME}/lib/plan_answers_helpers.sh"

# --- Core Functions ---------------------------------------------------------

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
        local esc_name esc_guide
        esc_name=$(_yaml_escape_dq "$s_name")
        esc_guide=$(_yaml_escape_dq "${s_guide:-}")
        {
            echo "  ${section_id}:"
            echo "    title: \"${esc_name}\""
            echo "    phase: ${s_phase:-1}"
            echo "    required: ${s_req:-false}"
            echo "    guidance: \"${esc_guide}\""
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
                local esc_answer
                esc_answer=$(_yaml_escape_dq "$answer_text")
                echo "    answer: \"${esc_answer}\"" >> "$tmp_file"
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
            current_title=$(_yaml_unescape_dq "${BASH_REMATCH[1]}")
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
            current_answer=$(_yaml_unescape_dq "${BASH_REMATCH[1]}")
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


#!/usr/bin/env bash
# =============================================================================
# prompts.sh — Template engine for agent prompt files
#
# Sourced by tekhton.sh — do not run directly.
# Expects: TEKHTON_HOME (set by caller, points to tekhton repo root)
# =============================================================================

# Directory containing .prompt.md template files — lives in the Tekhton repo
PROMPTS_DIR="${TEKHTON_HOME}/prompts"

# --- Template renderer -------------------------------------------------------
#
# Usage:
#   render_prompt "template_name"
#
# Reads ${PROMPTS_DIR}/<template_name>.prompt.md and replaces all {{VAR_NAME}}
# placeholders with the value of the corresponding shell variable.
#
# Supported placeholder syntax:
#   {{VAR}}              — replaced with the value of $VAR (empty string if unset)
#   {{IF:VAR}} ... {{ENDIF:VAR}}
#                        — block is included only if $VAR is non-empty
#
# Shell variables must be exported or set in the calling scope before invoking
# render_prompt. The function writes the rendered result to stdout.
# =============================================================================

render_prompt() {
    local template_name="$1"
    local template_file="${PROMPTS_DIR}/${template_name}.prompt.md"

    if [ ! -f "$template_file" ]; then
        error "Prompt template not found: ${template_file}"
        exit 1
    fi

    local content
    content=$(cat "$template_file")

    # --- Pass 1: Conditional blocks ---
    # Process {{IF:VAR}} ... {{ENDIF:VAR}} blocks
    # If $VAR is non-empty, include the block contents; otherwise remove it.
    # Uses a loop to handle all conditional blocks.
    local max_iterations=50
    local i=0
    while echo "$content" | grep -q '{{IF:'; do
        i=$((i + 1))
        if [ "$i" -gt "$max_iterations" ]; then
            warn "render_prompt: max iterations reached processing conditionals in ${template_name}"
            break
        fi

        # Extract the first conditional variable name
        local cond_var
        cond_var=$(echo "$content" | grep -o '{{IF:[A-Za-z_][A-Za-z0-9_]*}}' | head -1)
        local var_name="${cond_var#\{\{IF:}"
        var_name="${var_name%\}\}}"

        if [ -n "${!var_name:-}" ]; then
            # Variable is set and non-empty — keep block contents, strip markers
            content=$(echo "$content" | sed "/{{IF:${var_name}}}/d" | sed "/{{ENDIF:${var_name}}}/d")
        else
            # Variable is empty/unset — remove entire block including markers
            content=$(echo "$content" | sed "/{{IF:${var_name}}}/,/{{ENDIF:${var_name}}}/d")
        fi
    done

    # --- Pass 2: Variable substitution ---
    # Find all {{VAR_NAME}} placeholders and replace with shell variable values.
    local var_names
    var_names=$(echo "$content" | grep -oE '\{\{[A-Za-z_][A-Za-z0-9_]*\}\}' | sort -u || true)

    for placeholder in $var_names; do
        local var_name="${placeholder#\{\{}"
        var_name="${var_name%\}\}}"

        local value="${!var_name:-}"

        # Use awk for replacement to avoid sed delimiter issues with complex content
        content=$(echo "$content" | awk -v pat="{{${var_name}}}" -v rep="$value" '{
            idx = index($0, pat)
            while (idx > 0) {
                $0 = substr($0, 1, idx-1) rep substr($0, idx + length(pat))
                idx = index($0, pat)
            }
            print
        }')
    done

    echo "$content"
}

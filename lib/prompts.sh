#!/usr/bin/env bash
# =============================================================================
# prompts.sh — m15 wedge shim for the Tekhton agent-prompt template engine.
#
# Sourced by tekhton.sh. The template engine itself (the {{VAR}} substituter
# and {{IF:VAR}}…{{ENDIF:VAR}} conditional handler) lives in Go under
# internal/prompt and is reached via `tekhton prompt render`. This file is
# only the bash entry point: it locates the template, exports every
# referenced placeholder so the subprocess can read it, and execs the binary.
# File-content helpers (_safe_read_file, _wrap_file_content,
# load_intake_template_vars) are sourced from lib/prompts_io.sh.
# =============================================================================

PROMPTS_DIR="${TEKHTON_HOME}/prompts"

# shellcheck source=lib/prompts_io.sh
source "${TEKHTON_HOME}/lib/prompts_io.sh"

# render_prompt — Render <template_name>.prompt.md to stdout via the Go engine.
# Variable values come from the calling shell: every placeholder name found in
# the template (both {{VAR}} and {{IF:VAR}}/{{ENDIF:VAR}}) is exported before
# exec so the subprocess can read it via os.Environ. The regex constrains
# names to a safe identifier shape, so `export -- "$name"` cannot inject flags.
render_prompt() {
    local template_name="$1"
    local template_file="${PROMPTS_DIR}/${template_name}.prompt.md"
    if [ ! -f "$template_file" ]; then
        error "Prompt template not found: ${template_file}"
        exit 1
    fi

    local _pn
    while IFS= read -r _pn; do
        # shellcheck disable=SC2163 # name-as-string export is intentional
        [ -n "$_pn" ] && export -- "$_pn"
    done < <(
        grep -hoE '\{\{(IF:|ENDIF:)?[A-Za-z_][A-Za-z0-9_]*\}\}' "$template_file" 2>/dev/null \
            | sed -E 's/^\{\{(IF:|ENDIF:)?//; s/\}\}$//' \
            | sort -u
    )

    local _bin="${TEKHTON_BIN:-}"
    if [ -z "$_bin" ]; then
        if [ -x "${TEKHTON_HOME}/bin/tekhton" ]; then
            _bin="${TEKHTON_HOME}/bin/tekhton"
        elif command -v tekhton >/dev/null 2>&1; then
            _bin="tekhton"
        else
            error "tekhton binary not found; run 'make build' or set TEKHTON_BIN."
            exit 1
        fi
    fi

    "$_bin" prompt render --template "$template_name" --prompts-dir "$PROMPTS_DIR"
}

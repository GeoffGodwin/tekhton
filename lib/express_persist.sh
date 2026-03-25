#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# express_persist.sh — Express mode config/role persistence
#
# Sourced by tekhton.sh — do not run directly.
# Extracted from express.sh to keep it under the 300-line ceiling.
# Depends on: common.sh (log, warn), express.sh globals (TEKHTON_HOME, etc.)
# Provides: persist_express_config(), persist_express_roles()
# =============================================================================

# --- Config persistence (called from finalize.sh on success) -----------------

# persist_express_config — Write detected config to .claude/pipeline.conf.
# Args: $1 = project directory
persist_express_config() {
    local proj_dir="$1"
    local conf_path="${proj_dir}/.claude/pipeline.conf"

    # Never overwrite an existing pipeline.conf
    if [[ -f "$conf_path" ]]; then
        return 0
    fi

    mkdir -p "${proj_dir}/.claude" 2>/dev/null || true

    # Build config from template with detected values
    local template="${TEKHTON_HOME}/templates/express_pipeline.conf"
    if [[ ! -f "$template" ]]; then
        warn "Express config template not found — writing inline config."
        _write_inline_express_config "$conf_path"
        return 0
    fi

    # Read template and substitute detected values
    local content
    content=$(cat "$template")

    # Substitute template variables
    content="${content//\{\{PROJECT_NAME\}\}/${PROJECT_NAME}}"
    content="${content//\{\{TEST_CMD\}\}/${TEST_CMD}}"
    content="${content//\{\{ANALYZE_CMD\}\}/${ANALYZE_CMD}}"
    content="${content//\{\{BUILD_CHECK_CMD\}\}/${BUILD_CHECK_CMD:-}}"
    content="${content//\{\{CLAUDE_STANDARD_MODEL\}\}/${CLAUDE_STANDARD_MODEL}}"

    # Write atomically (tmpfile + mv) with cleanup trap
    local tmpfile
    tmpfile=$(mktemp "${proj_dir}/.claude/express_conf_XXXXXX")
    trap 'rm -f "$tmpfile"' EXIT INT TERM
    echo "$content" > "$tmpfile"
    mv "$tmpfile" "$conf_path"
    trap - EXIT INT TERM

    log "Express config saved to ${conf_path}"
}

# _write_inline_express_config — Fallback: write config without template.
_write_inline_express_config() {
    local conf_path="$1"
    cat > "$conf_path" << CONFEOF
# Auto-detected by Tekhton Express Mode.
# Run 'tekhton --init' for full configuration with planning interview.

PROJECT_NAME="${PROJECT_NAME}"
CLAUDE_STANDARD_MODEL="${CLAUDE_STANDARD_MODEL}"
TEST_CMD="${TEST_CMD}"
ANALYZE_CMD="${ANALYZE_CMD}"
BUILD_CHECK_CMD="${BUILD_CHECK_CMD:-}"
CONFEOF
}

# persist_express_roles — Copy built-in role templates to project.
# Args: $1 = project directory
persist_express_roles() {
    local proj_dir="$1"
    local agents_dir="${proj_dir}/.claude/agents"

    mkdir -p "$agents_dir" 2>/dev/null || true

    local template_name
    for template_name in coder.md reviewer.md tester.md jr-coder.md architect.md security.md intake.md; do
        local src="${TEKHTON_HOME}/templates/${template_name}"
        local dst="${agents_dir}/${template_name}"
        if [[ -f "$src" ]] && [[ ! -f "$dst" ]]; then
            cp "$src" "$dst"
        fi
    done
}

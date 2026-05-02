#!/usr/bin/env bash
# =============================================================================
# 031_to_032.sh — V3.1 → V3.2 migration
#
# Adds resilience arc config section to pipeline.conf (m126–m136):
#   - Build-fix continuation loop keys
#   - UI gate non-interactive enforcement keys
#   - Preflight UI config audit keys
# Updates .gitignore with new arc artifact paths.
# Creates .claude/preflight_bak/ directory.
#
# Part of Tekhton migration framework — sourced by lib/migrate.sh
# =============================================================================
set -euo pipefail

migration_version() { echo "3.2"; }

migration_description() {
    echo "Add resilience arc config (m126–m136): build-fix, UI gate, preflight audit"
}

# migration_check PROJECT_DIR
# Returns 0 if migration needed, 1 if already applied or not applicable.
migration_check() {
    local project_dir="$1"
    local conf_file="${project_dir}/.claude/pipeline.conf"

    [[ -f "$conf_file" ]] || return 1

    if grep -q '^BUILD_FIX_ENABLED=' "$conf_file" 2>/dev/null; then
        return 1
    fi
    return 0
}

# migration_apply PROJECT_DIR
# Returns 0 on success, non-zero on failure.
migration_apply() {
    local project_dir="$1"
    local conf_file="${project_dir}/.claude/pipeline.conf"
    local gitignore_file="${project_dir}/.gitignore"

    [[ -f "$conf_file" ]] || return 1

    _032_append_arc_config_section "$conf_file"
    _032_update_gitignore "$gitignore_file"
    _032_create_preflight_bak_dir "$project_dir"

    return 0
}

# _032_append_arc_config_section CONF_FILE
# Appends the resilience arc commented section to pipeline.conf. The sentinel
# key BUILD_FIX_ENABLED=true is the first line so migration_check detects it
# on the next call.
_032_append_arc_config_section() {
    local conf_file="$1"

    cat >> "$conf_file" << 'EOF'

# ═══════════════════════════════════════════════════════════════════════════════
# V3.2 Resilience Arc (added by migration: m126–m136)
# UI gate robustness, build-fix continuation, and causal failure context
# ═══════════════════════════════════════════════════════════════════════════════

# === Build-Fix Continuation Loop (m128) ===
BUILD_FIX_ENABLED=true
# BUILD_FIX_MAX_ATTEMPTS=3          # Max fix attempts per pipeline cycle
# BUILD_FIX_BASE_TURN_DIVISOR=3     # Attempt-1 budget divisor
# BUILD_FIX_MAX_TURN_MULTIPLIER=100 # Upper cap multiplier as integer percent (100 = 1.0×)
# BUILD_FIX_REQUIRE_PROGRESS=true   # Stop continuation when attempts show no progress
# BUILD_FIX_TOTAL_TURN_CAP=120      # Cumulative turn cap across the build-fix loop
# BUILD_FIX_CLASSIFICATION_REQUIRED=true  # Require code_dominant classification

# === UI Gate Non-Interactive Enforcement (m126) ===
# UI_GATE_ENV_RETRY_ENABLED=true    # Retry with non-interactive env on timeout
# UI_GATE_ENV_RETRY_TIMEOUT_FACTOR=0.5  # Retry timeout as fraction of UI_TEST_TIMEOUT
# TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=0  # 0=auto 1=always force non-interactive

# === Preflight UI Config Audit (m131) ===
# PREFLIGHT_UI_CONFIG_AUDIT_ENABLED=true  # Scan test framework configs for interactive-mode
# PREFLIGHT_UI_CONFIG_AUTO_FIX=true  # Auto-patch reporter: 'html' to CI-guarded form
# PREFLIGHT_BAK_RETAIN_COUNT=10      # Backup files to keep in .claude/preflight_bak/
EOF
}

# _032_update_gitignore GITIGNORE_FILE
# Adds the two new arc artifact paths if not already present. Idempotent.
_032_update_gitignore() {
    local gi_file="$1"

    [[ -f "$gi_file" ]] || touch "$gi_file"

    local _added=0
    local -a _new_entries=(
        ".tekhton/BUILD_FIX_REPORT.md"
        ".claude/preflight_bak/"
    )
    local entry
    for entry in "${_new_entries[@]}"; do
        if ! grep -qF "$entry" "$gi_file" 2>/dev/null; then
            if (( _added == 0 )) && ! grep -qF "# Tekhton runtime artifacts" "$gi_file" 2>/dev/null; then
                if [[ -s "$gi_file" ]] && [[ "$(tail -c1 "$gi_file" | wc -l)" -eq 0 ]]; then
                    printf '\n' >> "$gi_file"
                fi
                printf '\n# Tekhton runtime artifacts (added by V3.2 migration)\n' >> "$gi_file"
            fi
            printf '%s\n' "$entry" >> "$gi_file"
            _added=$(( _added + 1 ))
        fi
    done

    (( _added > 0 )) && log "Added ${_added} gitignore entry/entries for resilience arc artifacts."
    return 0
}

# _032_create_preflight_bak_dir PROJECT_DIR
# Creates .claude/preflight_bak/ for preflight auto-fix backups. Idempotent.
_032_create_preflight_bak_dir() {
    local project_dir="$1"
    local bak_dir="${project_dir}/.claude/preflight_bak"

    [[ -d "$bak_dir" ]] && return 0

    mkdir -p "$bak_dir"
    log "Created .claude/preflight_bak/ for preflight auto-fix backups."
    return 0
}

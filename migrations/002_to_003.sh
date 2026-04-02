#!/usr/bin/env bash
# =============================================================================
# 002_to_003.sh — V2 → V3 migration
#
# Adds V3 config keys (security agent, intake agent, DAG milestones, repo map,
# Serena, causal log, dashboard, health scoring, test baseline, test audit),
# new agent roles, milestone DAG migration, and pipeline.conf section headers.
#
# Part of Tekhton migration framework — sourced by lib/migrate.sh
# =============================================================================
set -euo pipefail

migration_version() { echo "3.0"; }

migration_description() {
    echo "Add V3 config keys, agent roles (security, intake), milestone DAG, dashboard"
}

# migration_check PROJECT_DIR
# Returns 0 if migration needed, 1 if already applied.
migration_check() {
    local project_dir="$1"
    local conf_file="${project_dir}/.claude/pipeline.conf"

    # No conf file means nothing to migrate (express mode or bare .claude/)
    [[ -f "$conf_file" ]] || return 1

    # If V3-era key exists, consider it already applied
    if grep -q '^SECURITY_AGENT_ENABLED=' "$conf_file" 2>/dev/null; then
        return 1
    fi
    return 0
}

# migration_apply PROJECT_DIR
# Returns 0 on success, non-zero on failure.
migration_apply() {
    local project_dir="$1"
    local conf_file="${project_dir}/.claude/pipeline.conf"

    [[ -f "$conf_file" ]] || return 1

    # Append V3 config keys with section headers
    cat >> "$conf_file" << 'EOF'

# ═══════════════════════════════════════════════════════════════════════════════
# V3 Configuration (added by migration)
# ═══════════════════════════════════════════════════════════════════════════════

# === Security Agent ===
SECURITY_AGENT_ENABLED=true
# CLAUDE_SECURITY_MODEL — defaults to CLAUDE_STANDARD_MODEL
# SECURITY_MAX_TURNS=15
# SECURITY_BLOCK_SEVERITY=HIGH
# SECURITY_UNFIXABLE_POLICY=escalate

# === Task Intake / PM Agent ===
INTAKE_AGENT_ENABLED=true
# CLAUDE_INTAKE_MODEL — defaults to CLAUDE_STANDARD_MODEL
# INTAKE_MAX_TURNS=10
# INTAKE_CLARITY_THRESHOLD=40
# INTAKE_TWEAK_THRESHOLD=70

# === Milestone DAG (file-based milestones) ===
MILESTONE_DAG_ENABLED=true
# MILESTONE_DIR=".claude/milestones"
# MILESTONE_MANIFEST="MANIFEST.cfg"
# MILESTONE_AUTO_MIGRATE=true
# MILESTONE_WINDOW_PCT=30

# === Milestone Pre-flight Sizing ===
MILESTONE_SPLIT_ENABLED=true
# MILESTONE_SPLIT_THRESHOLD_PCT=120
# MILESTONE_AUTO_RETRY=true
# MILESTONE_MAX_SPLIT_DEPTH=6

# === Repo Map / Indexer (tree-sitter) ===
# REPO_MAP_ENABLED=false
# REPO_MAP_TOKEN_BUDGET=2048
# REPO_MAP_CACHE_DIR=".claude/index"
# REPO_MAP_LANGUAGES="auto"

# === Serena LSP / MCP ===
# SERENA_ENABLED=false
# SERENA_PATH=".claude/serena"

# === Causal Event Log ===
CAUSAL_LOG_ENABLED=true
# CAUSAL_LOG_FILE=".claude/logs/CAUSAL_LOG.jsonl"
# CAUSAL_LOG_RETENTION_RUNS=50

# === Dashboard / Watchtower ===
DASHBOARD_ENABLED=true
# DASHBOARD_VERBOSITY="normal"
# DASHBOARD_HISTORY_DEPTH=50

# === Test Baseline ===
TEST_BASELINE_ENABLED=true
# TEST_BASELINE_PASS_ON_PREEXISTING=true

# === Test Audit ===
TEST_AUDIT_ENABLED=true
# TEST_AUDIT_MAX_TURNS=8

# === Health Scoring ===
HEALTH_ENABLED=true
# HEALTH_REASSESS_ON_COMPLETE=false

# === Quota Management ===
# QUOTA_RETRY_INTERVAL=300
# QUOTA_RESERVE_PCT=10

# === Update Check ===
TEKHTON_UPDATE_CHECK=true
# TEKHTON_PIN_VERSION=
EOF

    # Add new agent role files if missing
    mkdir -p "${project_dir}/.claude/agents"
    local tekhton_home="${TEKHTON_HOME:-.}"
    local role src dest
    for role in security intake; do
        dest="${project_dir}/.claude/agents/${role}.md"
        src="${tekhton_home}/templates/${role}.md"
        if [[ ! -f "$dest" ]] && [[ -f "$src" ]]; then
            cp "$src" "$dest"
            log "  Created agent role: .claude/agents/${role}.md"
        fi
    done

    # Milestone DAG migration: if inline milestones exist and no manifest,
    # call migrate_inline_milestones (reuse M01/M02 infrastructure)
    if [[ -f "${project_dir}/CLAUDE.md" ]] && \
       [[ ! -f "${project_dir}/.claude/milestones/MANIFEST.cfg" ]]; then
        # Check if there are inline milestones to migrate
        if grep -q '#### Milestone [0-9]' "${project_dir}/CLAUDE.md" 2>/dev/null; then
            if command -v migrate_inline_milestones &>/dev/null; then
                local milestone_dir="${project_dir}/.claude/milestones"
                log "  Migrating inline milestones to DAG format..."
                migrate_inline_milestones "${project_dir}/CLAUDE.md" "$milestone_dir" 2>/dev/null || {
                    warn "  Milestone DAG migration failed — can be done later with 'tekhton --migrate-dag'"
                }
            fi
        fi
    fi

    # Dashboard: create .claude/dashboard/ if enabled and missing
    if [[ ! -d "${project_dir}/.claude/dashboard" ]]; then
        if command -v init_dashboard &>/dev/null; then
            init_dashboard "$project_dir" 2>/dev/null || true
            log "  Created dashboard directory."
        else
            mkdir -p "${project_dir}/.claude/dashboard" 2>/dev/null || true
        fi
    fi

    return 0
}

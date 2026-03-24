#!/usr/bin/env bash
# =============================================================================
# 001_to_002.sh — V1 → V2 migration
#
# Adds V2 config keys (context budget, milestones, clarification, specialist,
# metrics, cleanup, replan) and ensures agent role files exist.
#
# Part of Tekhton migration framework — sourced by lib/migrate.sh
# =============================================================================
set -euo pipefail

migration_version() { echo "2.0"; }

migration_description() {
    echo "Add V2 config keys (context budget, milestones, clarification, metrics, cleanup)"
}

# migration_check PROJECT_DIR
# Returns 0 if migration needed, 1 if already applied.
migration_check() {
    local project_dir="$1"
    local conf_file="${project_dir}/.claude/pipeline.conf"

    [[ -f "$conf_file" ]] || return 0

    # If any V2-era key exists, consider it already applied
    if grep -q '^CONTEXT_BUDGET_PCT=' "$conf_file" 2>/dev/null; then
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

    # Append V2 config keys
    cat >> "$conf_file" << 'EOF'

# === V2: Context Budget (added by migration) ===
CONTEXT_BUDGET_ENABLED=true
CONTEXT_BUDGET_PCT=50
CHARS_PER_TOKEN=4
CONTEXT_COMPILER_ENABLED=false

# === V2: Clarification & Replan ===
CLARIFICATION_ENABLED=true
REPLAN_ENABLED=true

# === V2: Auto-Advance ===
# AUTO_ADVANCE_ENABLED=false
# AUTO_ADVANCE_LIMIT=3
# AUTO_ADVANCE_CONFIRM=true

# === V2: Milestone Archival ===
# MILESTONE_TAG_ON_COMPLETE=false
# MILESTONE_ARCHIVE_FILE=MILESTONE_ARCHIVE.md

# === V2: Autonomous Debt Sweep ===
# CLEANUP_ENABLED=false
# CLEANUP_BATCH_SIZE=5
# CLEANUP_MAX_TURNS=15
# CLEANUP_TRIGGER_THRESHOLD=5

# === V2: Specialist Reviewers ===
# SPECIALIST_SECURITY_ENABLED=false
# SPECIALIST_PERFORMANCE_ENABLED=false
# SPECIALIST_API_ENABLED=false

# === V2: Run Metrics ===
METRICS_ENABLED=true
# METRICS_MIN_RUNS=5
# METRICS_ADAPTIVE_TURNS=true

# === V2: Turn Exhaustion Continuation ===
CONTINUATION_ENABLED=true
# MAX_CONTINUATION_ATTEMPTS=3

# === V2: Transient Error Retry ===
TRANSIENT_RETRY_ENABLED=true
# MAX_TRANSIENT_RETRIES=3

# === V2: Orchestration Loop (--complete) ===
COMPLETE_MODE_ENABLED=true
# MAX_PIPELINE_ATTEMPTS=5
# AUTONOMOUS_TIMEOUT=7200
EOF

    # Ensure .claude/agents/ directory exists
    mkdir -p "${project_dir}/.claude/agents"

    # Copy agent role templates if missing (never overwrite existing)
    local tekhton_home="${TEKHTON_HOME:-.}"
    local role
    for role in coder reviewer tester jr-coder architect; do
        local dest="${project_dir}/.claude/agents/${role}.md"
        local src="${tekhton_home}/templates/${role}.md"
        if [[ ! -f "$dest" ]] && [[ -f "$src" ]]; then
            cp "$src" "$dest"
            log "  Created agent role: .claude/agents/${role}.md"
        fi
    done

    return 0
}

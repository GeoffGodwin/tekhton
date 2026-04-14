#!/usr/bin/env bash
# Test: --init creates expected project scaffold
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# M84: Variable defaults (normally set by common.sh / config_defaults.sh)
: "${TEKHTON_DIR:=.tekhton}"
: "${SCOUT_REPORT_FILE:=${TEKHTON_DIR}/SCOUT_REPORT.md}"
: "${ARCHITECT_PLAN_FILE:=${TEKHTON_DIR}/ARCHITECT_PLAN.md}"
: "${CLEANUP_REPORT_FILE:=${TEKHTON_DIR}/CLEANUP_REPORT.md}"
: "${DRIFT_ARCHIVE_FILE:=${TEKHTON_DIR}/DRIFT_ARCHIVE.md}"
: "${PROJECT_INDEX_FILE:=${TEKHTON_DIR}/PROJECT_INDEX.md}"
: "${REPLAN_DELTA_FILE:=${TEKHTON_DIR}/REPLAN_DELTA.md}"
: "${MERGE_CONTEXT_FILE:=${TEKHTON_DIR}/MERGE_CONTEXT.md}"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

cd "$TMPDIR"

# Run --init
TEKHTON_NON_INTERACTIVE=true bash "${TEKHTON_HOME}/tekhton.sh" --init > /dev/null 2>&1

# Verify pipeline.conf was created
[ -f ".claude/pipeline.conf" ] || { echo "pipeline.conf not created"; exit 1; }

# Verify agent roles were created
[ -f ".claude/agents/coder.md" ] || { echo "coder.md not created"; exit 1; }
[ -f ".claude/agents/reviewer.md" ] || { echo "reviewer.md not created"; exit 1; }
[ -f ".claude/agents/tester.md" ] || { echo "tester.md not created"; exit 1; }
[ -f ".claude/agents/jr-coder.md" ] || { echo "jr-coder.md not created"; exit 1; }

# Verify CLAUDE.md stub was created
[ -f "CLAUDE.md" ] || { echo "CLAUDE.md not created"; exit 1; }

# Verify logs directory was created
[ -d ".claude/logs/archive" ] || { echo "logs/archive dir not created"; exit 1; }

# Verify NO pipeline internals were copied (standalone model)
[ ! -d ".claude/pipeline/lib" ] || { echo "lib/ should NOT be copied to project"; exit 1; }
[ ! -d ".claude/pipeline/stages" ] || { echo "stages/ should NOT be copied to project"; exit 1; }
[ ! -d ".claude/pipeline/prompts" ] || { echo "prompts/ should NOT be copied to project"; exit 1; }

# Verify re-running --init warns and exits
if TEKHTON_NON_INTERACTIVE=true bash "${TEKHTON_HOME}/tekhton.sh" --init > /dev/null 2>&1; then
    echo "Re-init should have exited with error"
    exit 1
fi

echo "Init scaffold test passed"

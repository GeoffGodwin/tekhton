#!/usr/bin/env bash
# Test: DESIGN_FILE auto-set in --init when DESIGN.md exists
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

# Test 1: --init with DESIGN.md present should set DESIGN_FILE="DESIGN.md"
TMPDIR1=$(mktemp -d)
trap 'rm -rf "$TMPDIR1"' EXIT

PROJECT_DIR="$TMPDIR1"
export TEKHTON_HOME PROJECT_DIR

# Create DESIGN.md in the project directory
touch "${PROJECT_DIR}/DESIGN.md"

# Run --init
cd "$PROJECT_DIR"
TEKHTON_NON_INTERACTIVE=true bash "${TEKHTON_HOME}/tekhton.sh" --init >/dev/null 2>&1 || true

# Check that pipeline.conf was created
[ -f "${PROJECT_DIR}/.claude/pipeline.conf" ] || { echo "FAIL: pipeline.conf not created"; exit 1; }

# Check that DESIGN_FILE is set to DESIGN.md
DESIGN_FILE_VALUE=$(grep "^DESIGN_FILE=" "${PROJECT_DIR}/.claude/pipeline.conf" | cut -d= -f2 | tr -d '"')
[ "$DESIGN_FILE_VALUE" = "DESIGN.md" ] || { echo "FAIL: DESIGN_FILE should be 'DESIGN.md', got '$DESIGN_FILE_VALUE'"; exit 1; }

# Test 2: --init without any design doc should emit the canonical default
# DESIGN_FILE=".tekhton/DESIGN.md" (M120: no longer emits empty-string landmine)
TMPDIR2=$(mktemp -d)
trap 'rm -rf "$TMPDIR2"' EXIT

PROJECT_DIR="$TMPDIR2"
export PROJECT_DIR

# Do NOT create DESIGN.md

cd "$PROJECT_DIR"
TEKHTON_NON_INTERACTIVE=true bash "${TEKHTON_HOME}/tekhton.sh" --init >/dev/null 2>&1 || true

# Check that pipeline.conf was created
[ -f "${PROJECT_DIR}/.claude/pipeline.conf" ] || { echo "FAIL: pipeline.conf not created"; exit 1; }

# Check that DESIGN_FILE is set to the canonical default (M120)
DESIGN_FILE_VALUE=$(grep "^DESIGN_FILE=" "${PROJECT_DIR}/.claude/pipeline.conf" | cut -d= -f2 | tr -d '"')
[ "$DESIGN_FILE_VALUE" = ".tekhton/DESIGN.md" ] || { echo "FAIL: DESIGN_FILE should be '.tekhton/DESIGN.md' (M120 default), got '$DESIGN_FILE_VALUE'"; exit 1; }

echo "PASS: DESIGN_FILE auto-set tests passed"

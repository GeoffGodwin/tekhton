#!/usr/bin/env bash
# =============================================================================
# artifact_defaults.sh — Default paths for transient Tekhton artifact files.
#
# Pure `:=` assignments: idempotent, empty-string-safe, and safe to source
# multiple times in the same shell. No functions, no side effects beyond
# variable assignment. Sourced by common.sh (every pipeline entry point) and
# by plan.sh (after load_plan_config) so planning mode restores any artifact
# path that a pipeline.conf overwrote with an empty string.
#
# Originally extracted from common.sh per Milestone 120.
# =============================================================================

set -euo pipefail

: "${TEKHTON_DIR:=.tekhton}"
: "${DESIGN_FILE:=${TEKHTON_DIR:-.tekhton}/DESIGN.md}"
: "${CODER_SUMMARY_FILE:=${TEKHTON_DIR:-.tekhton}/CODER_SUMMARY.md}"
: "${REVIEWER_REPORT_FILE:=${TEKHTON_DIR:-.tekhton}/REVIEWER_REPORT.md}"
: "${TESTER_REPORT_FILE:=${TEKHTON_DIR:-.tekhton}/TESTER_REPORT.md}"
: "${JR_CODER_SUMMARY_FILE:=${TEKHTON_DIR:-.tekhton}/JR_CODER_SUMMARY.md}"
: "${BUILD_ERRORS_FILE:=${TEKHTON_DIR:-.tekhton}/BUILD_ERRORS.md}"
: "${BUILD_RAW_ERRORS_FILE:=${TEKHTON_DIR:-.tekhton}/BUILD_RAW_ERRORS.txt}"
: "${BUILD_ROUTING_DIAGNOSIS_FILE:=${TEKHTON_DIR:-.tekhton}/BUILD_ROUTING_DIAGNOSIS.md}"
: "${BUILD_FIX_REPORT_FILE:=${TEKHTON_DIR:-.tekhton}/BUILD_FIX_REPORT.md}"
: "${UI_TEST_ERRORS_FILE:=${TEKHTON_DIR:-.tekhton}/UI_TEST_ERRORS.md}"
: "${PREFLIGHT_ERRORS_FILE:=${TEKHTON_DIR:-.tekhton}/PREFLIGHT_ERRORS.md}"
: "${DIAGNOSIS_FILE:=${TEKHTON_DIR:-.tekhton}/DIAGNOSIS.md}"
: "${CLARIFICATIONS_FILE:=${TEKHTON_DIR:-.tekhton}/CLARIFICATIONS.md}"
: "${HUMAN_NOTES_FILE:=${TEKHTON_DIR:-.tekhton}/HUMAN_NOTES.md}"
: "${SPECIALIST_REPORT_FILE:=${TEKHTON_DIR:-.tekhton}/SPECIALIST_REPORT.md}"
: "${UI_VALIDATION_REPORT_FILE:=${TEKHTON_DIR:-.tekhton}/UI_VALIDATION_REPORT.md}"
: "${PREFLIGHT_REPORT_FILE:=${TEKHTON_DIR:-.tekhton}/PREFLIGHT_REPORT.md}"
: "${SCOUT_REPORT_FILE:=${TEKHTON_DIR:-.tekhton}/SCOUT_REPORT.md}"
: "${ARCHITECT_PLAN_FILE:=${TEKHTON_DIR:-.tekhton}/ARCHITECT_PLAN.md}"
: "${CLEANUP_REPORT_FILE:=${TEKHTON_DIR:-.tekhton}/CLEANUP_REPORT.md}"
: "${DRIFT_ARCHIVE_FILE:=${TEKHTON_DIR:-.tekhton}/DRIFT_ARCHIVE.md}"
: "${PROJECT_INDEX_FILE:=${TEKHTON_DIR:-.tekhton}/PROJECT_INDEX.md}"
: "${REPLAN_DELTA_FILE:=${TEKHTON_DIR:-.tekhton}/REPLAN_DELTA.md}"
: "${MERGE_CONTEXT_FILE:=${TEKHTON_DIR:-.tekhton}/MERGE_CONTEXT.md}"
: "${ARCHITECTURE_LOG_FILE:=${TEKHTON_DIR:-.tekhton}/ARCHITECTURE_LOG.md}"
: "${DRIFT_LOG_FILE:=${TEKHTON_DIR:-.tekhton}/DRIFT_LOG.md}"
: "${HUMAN_ACTION_FILE:=${TEKHTON_DIR:-.tekhton}/HUMAN_ACTION_REQUIRED.md}"
: "${NON_BLOCKING_LOG_FILE:=${TEKHTON_DIR:-.tekhton}/NON_BLOCKING_LOG.md}"
: "${SECURITY_NOTES_FILE:=${TEKHTON_DIR:-.tekhton}/SECURITY_NOTES.md}"
: "${SECURITY_REPORT_FILE:=${TEKHTON_DIR:-.tekhton}/SECURITY_REPORT.md}"
: "${INTAKE_REPORT_FILE:=${TEKHTON_DIR:-.tekhton}/INTAKE_REPORT.md}"
: "${TDD_PREFLIGHT_FILE:=${TEKHTON_DIR:-.tekhton}/TESTER_PREFLIGHT.md}"
: "${TEST_AUDIT_REPORT_FILE:=${TEKHTON_DIR:-.tekhton}/TEST_AUDIT_REPORT.md}"
: "${HEALTH_REPORT_FILE:=${TEKHTON_DIR:-.tekhton}/HEALTH_REPORT.md}"
: "${DOCS_AGENT_REPORT_FILE:=${TEKHTON_DIR:-.tekhton}/DOCS_AGENT_REPORT.md}"

# --- Resilience arc operational artifacts (m135) ----------------------------
# Stays empty when PROJECT_DIR is unset at source time so m131's per-project
# fallback `${PREFLIGHT_BAK_DIR:-${proj}/.claude/preflight_bak}` resolves
# correctly. A re-source after load_config sets PROJECT_DIR bakes the value.
: "${PREFLIGHT_BAK_DIR:=${PROJECT_DIR:+${PROJECT_DIR}/.claude/preflight_bak}}"

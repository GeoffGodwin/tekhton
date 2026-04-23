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
: "${DESIGN_FILE:=${TEKHTON_DIR}/DESIGN.md}"
: "${CODER_SUMMARY_FILE:=${TEKHTON_DIR}/CODER_SUMMARY.md}"
: "${REVIEWER_REPORT_FILE:=${TEKHTON_DIR}/REVIEWER_REPORT.md}"
: "${TESTER_REPORT_FILE:=${TEKHTON_DIR}/TESTER_REPORT.md}"
: "${JR_CODER_SUMMARY_FILE:=${TEKHTON_DIR}/JR_CODER_SUMMARY.md}"
: "${BUILD_ERRORS_FILE:=${TEKHTON_DIR}/BUILD_ERRORS.md}"
: "${BUILD_RAW_ERRORS_FILE:=${TEKHTON_DIR}/BUILD_RAW_ERRORS.txt}"
: "${UI_TEST_ERRORS_FILE:=${TEKHTON_DIR}/UI_TEST_ERRORS.md}"
: "${PREFLIGHT_ERRORS_FILE:=${TEKHTON_DIR}/PREFLIGHT_ERRORS.md}"
: "${DIAGNOSIS_FILE:=${TEKHTON_DIR}/DIAGNOSIS.md}"
: "${CLARIFICATIONS_FILE:=${TEKHTON_DIR}/CLARIFICATIONS.md}"
: "${HUMAN_NOTES_FILE:=${TEKHTON_DIR}/HUMAN_NOTES.md}"
: "${SPECIALIST_REPORT_FILE:=${TEKHTON_DIR}/SPECIALIST_REPORT.md}"
: "${UI_VALIDATION_REPORT_FILE:=${TEKHTON_DIR}/UI_VALIDATION_REPORT.md}"
: "${PREFLIGHT_REPORT_FILE:=${TEKHTON_DIR}/PREFLIGHT_REPORT.md}"
: "${SCOUT_REPORT_FILE:=${TEKHTON_DIR}/SCOUT_REPORT.md}"
: "${ARCHITECT_PLAN_FILE:=${TEKHTON_DIR}/ARCHITECT_PLAN.md}"
: "${CLEANUP_REPORT_FILE:=${TEKHTON_DIR}/CLEANUP_REPORT.md}"
: "${DRIFT_ARCHIVE_FILE:=${TEKHTON_DIR}/DRIFT_ARCHIVE.md}"
: "${PROJECT_INDEX_FILE:=${TEKHTON_DIR}/PROJECT_INDEX.md}"
: "${REPLAN_DELTA_FILE:=${TEKHTON_DIR}/REPLAN_DELTA.md}"
: "${MERGE_CONTEXT_FILE:=${TEKHTON_DIR}/MERGE_CONTEXT.md}"
: "${ARCHITECTURE_LOG_FILE:=${TEKHTON_DIR}/ARCHITECTURE_LOG.md}"
: "${DRIFT_LOG_FILE:=${TEKHTON_DIR}/DRIFT_LOG.md}"
: "${HUMAN_ACTION_FILE:=${TEKHTON_DIR}/HUMAN_ACTION_REQUIRED.md}"
: "${NON_BLOCKING_LOG_FILE:=${TEKHTON_DIR}/NON_BLOCKING_LOG.md}"
: "${MILESTONE_ARCHIVE_FILE:=${TEKHTON_DIR}/MILESTONE_ARCHIVE.md}"
: "${SECURITY_NOTES_FILE:=${TEKHTON_DIR}/SECURITY_NOTES.md}"
: "${SECURITY_REPORT_FILE:=${TEKHTON_DIR}/SECURITY_REPORT.md}"
: "${INTAKE_REPORT_FILE:=${TEKHTON_DIR}/INTAKE_REPORT.md}"
: "${TDD_PREFLIGHT_FILE:=${TEKHTON_DIR}/TESTER_PREFLIGHT.md}"
: "${TEST_AUDIT_REPORT_FILE:=${TEKHTON_DIR}/TEST_AUDIT_REPORT.md}"
: "${HEALTH_REPORT_FILE:=${TEKHTON_DIR}/HEALTH_REPORT.md}"
: "${DOCS_AGENT_REPORT_FILE:=${TEKHTON_DIR}/DOCS_AGENT_REPORT.md}"

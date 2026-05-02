#!/usr/bin/env bash
# tests/report_fixtures.sh — shared fixtures for the
# tests/test_report*.sh suite.
#
# Sourced by test_report.sh and test_report_color.sh. Not auto-discovered
# by run_tests.sh (no `test_` prefix).
#
# Provides:
#   pass / fail counters (PASS, FAIL globals)
#   assert_eq / assert_contains / assert_not_contains / assert_exit0
#   _reset_report_fixture / _create_run_summary
#   summary_and_exit
#   sets PROJECT_DIR, LOG_DIR, TEKHTON_HOME, sources lib/common.sh + lib/report.sh

set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_DIR="$TMPDIR"
LOG_DIR="$TMPDIR/.claude/logs"
PIPELINE_STATE_FILE="$TMPDIR/.claude/PIPELINE_STATE.md"

export PROJECT_DIR LOG_DIR PIPELINE_STATE_FILE TEKHTON_HOME

mkdir -p "$LOG_DIR/archive"
mkdir -p "${PROJECT_DIR}/${TEKHTON_DIR:-.tekhton}"

# Read by lib/report.sh after the shared common.sh source — shellcheck can't
# see the cross-file usage so disable SC2034 for the whole block.
# shellcheck disable=SC2034
{
HUMAN_ACTION_FILE="${TEKHTON_DIR}/HUMAN_ACTION_REQUIRED.md"
INTAKE_REPORT_FILE="${TEKHTON_DIR}/INTAKE_REPORT.md"
CODER_SUMMARY_FILE="${TEKHTON_DIR}/CODER_SUMMARY.md"
SECURITY_REPORT_FILE="${TEKHTON_DIR}/SECURITY_REPORT.md"
REVIEWER_REPORT_FILE="${TEKHTON_DIR}/REVIEWER_REPORT.md"
TESTER_REPORT_FILE="${TEKHTON_DIR}/TESTER_REPORT.md"
}

# shellcheck source=../lib/common.sh
source "${TEKHTON_HOME}/lib/common.sh"
# shellcheck source=../lib/report.sh
source "${TEKHTON_HOME}/lib/report.sh"

PASS=0
FAIL=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc — expected '$expected', got '$actual'"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if echo "$haystack" | grep -q "$needle" 2>/dev/null; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc — expected to find '$needle' in output"
        FAIL=$((FAIL + 1))
    fi
}

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if echo "$haystack" | grep -q "$needle" 2>/dev/null; then
        echo "  FAIL: $desc — did not expect to find '$needle' in output"
        FAIL=$((FAIL + 1))
    else
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    fi
}

assert_exit0() {
    local desc="$1"
    if eval "$2" > /dev/null 2>&1; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc — command exited non-zero"
        FAIL=$((FAIL + 1))
    fi
}

_reset_report_fixture() {
    rm -f "$TMPDIR/.claude/logs/RUN_SUMMARY.json"
    rm -f "$TMPDIR/${TEKHTON_DIR}/INTAKE_REPORT.md"
    rm -f "$TMPDIR/${TEKHTON_DIR}/REVIEWER_REPORT.md"
    rm -f "$TMPDIR/${TEKHTON_DIR}/TESTER_REPORT.md"
    rm -f "$TMPDIR/${TEKHTON_DIR}/CODER_SUMMARY.md"
    rm -f "$TMPDIR/${TEKHTON_DIR}/SECURITY_REPORT.md"
    rm -f "$TMPDIR/${TEKHTON_DIR}/HUMAN_ACTION_REQUIRED.md"
}

_create_run_summary() {
    local outcome="$1"
    local milestone="${2:-none}"
    mkdir -p "$TMPDIR/.claude/logs"
    cat > "$TMPDIR/.claude/logs/RUN_SUMMARY.json" << EOF
{
  "milestone": "${milestone}",
  "outcome": "${outcome}",
  "attempts": 1,
  "total_agent_calls": 5,
  "wall_clock_seconds": 300,
  "files_changed": [],
  "timestamp": "2026-03-23T10:45:00Z"
}
EOF
}

summary_and_exit() {
    echo
    echo "════════════════════════════════════════"
    echo "  report tests: ${PASS} passed, ${FAIL} failed"
    echo "════════════════════════════════════════"
    [ "$FAIL" -eq 0 ] || exit 1
    echo "All report tests passed"
}

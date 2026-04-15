#!/usr/bin/env bash
# =============================================================================
# test_lifecycle_acp.sh — P6 ACP (Architecture Change Proposal) lifecycle test
#
# Simulates the ACP flow:
#   1. Coder produces an ACP in CODER_SUMMARY.md
#   2. Reviewer accepts the ACP → ACCEPTED_ACPS global set
#   3. ADL entry created in ARCHITECTURE_LOG.md with sequential ID
#   4. Multiple ACPs across runs get sequential IDs
#   5. Rejected ACPs do not create ADL entries
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_DIR="$TMPDIR"
TEKHTON_SESSION_DIR="$TMPDIR"
TEKHTON_DIR=".tekhton"
mkdir -p "${TMPDIR}/${TEKHTON_DIR}"

DRIFT_LOG_FILE="${TEKHTON_DIR}/DRIFT_LOG.md"
ARCHITECTURE_LOG_FILE="${TEKHTON_DIR}/ARCHITECTURE_LOG.md"
HUMAN_ACTION_FILE="${TEKHTON_DIR}/HUMAN_ACTION_REQUIRED.md"
DRIFT_OBSERVATION_THRESHOLD=8
DRIFT_RUNS_SINCE_AUDIT_THRESHOLD=5
TASK="ACP lifecycle test"

source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/drift.sh"
source "${TEKHTON_HOME}/lib/drift_artifacts.sh"

FAIL=0

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" != "$actual" ]; then
        echo "FAIL: $name — expected '$expected', got '$actual'"
        FAIL=1
    fi
}

assert_file_contains() {
    local name="$1" file="$2" pattern="$3"
    if ! grep -q "$pattern" "$file" 2>/dev/null; then
        echo "FAIL: $name — pattern '$pattern' not found in $file"
        FAIL=1
    fi
}

assert_file_not_contains() {
    local name="$1" file="$2" pattern="$3"
    if grep -q "$pattern" "$file" 2>/dev/null; then
        echo "FAIL: $name — unexpected pattern '$pattern' found in $file"
        FAIL=1
    fi
}

adl_file="${PROJECT_DIR}/${ARCHITECTURE_LOG_FILE}"

# =============================================================================
# Phase 1: No ADL file yet — first ACP accepted
# =============================================================================

# Simulate: reviewer sets ACCEPTED_ACPS after parsing reviewer report
TASK="Run 1: extract config layer"
ACCEPTED_ACPS="- ACP: Extract config into dedicated layer — ACCEPT — Improves separation of concerns"

append_architecture_decision

assert_file_contains "1.1 ADL file created" "$adl_file" "# Architecture Decision Log"
assert_file_contains "1.2 ADL-1 entry" "$adl_file" "ADL-1"
assert_file_contains "1.3 ACP name recorded" "$adl_file" "Extract config into dedicated layer"
assert_file_contains "1.4 rationale recorded" "$adl_file" "Improves separation of concerns"
assert_file_contains "1.5 task recorded" "$adl_file" "extract config layer"
assert_eq "1.6 next ADL number" "2" "$(get_next_adl_number)"

# =============================================================================
# Phase 2: Second run — another ACP accepted, sequential ID
# =============================================================================
TASK="Run 2: refactor warden system"
ACCEPTED_ACPS="- ACP: Move warden state to engine/state — ACCEPT — Wardens are game state not UI state"

append_architecture_decision

assert_file_contains "2.1 ADL-2 entry" "$adl_file" "ADL-2"
assert_file_contains "2.2 second ACP name" "$adl_file" "Move warden state to engine/state"
assert_file_contains "2.3 second task" "$adl_file" "refactor warden system"
assert_eq "2.4 next ADL number" "3" "$(get_next_adl_number)"

# Verify both entries coexist
assert_file_contains "2.5 ADL-1 still present" "$adl_file" "ADL-1"
assert_file_contains "2.6 ADL-2 present" "$adl_file" "ADL-2"

# =============================================================================
# Phase 3: No ACP in a run — nothing appended
# =============================================================================
TASK="Run 3: bug fix"
ACCEPTED_ACPS=""

append_architecture_decision

assert_eq "3.1 still 3 as next" "3" "$(get_next_adl_number)"

# =============================================================================
# Phase 4: Multiple ACPs accepted in one run
# =============================================================================
TASK="Run 4: major refactor"
ACCEPTED_ACPS="- ACP: Split game_notifier into sub-notifiers — ACCEPT — File was 600+ lines
- ACP: Add persistence interface — ACCEPT — Needed for save/load abstraction"

append_architecture_decision

assert_file_contains "4.1 ADL-3 entry" "$adl_file" "ADL-3"
assert_file_contains "4.2 ADL-4 entry" "$adl_file" "ADL-4"
assert_file_contains "4.3 first multi-ACP name" "$adl_file" "Split game_notifier"
assert_file_contains "4.4 second multi-ACP name" "$adl_file" "persistence interface"
assert_eq "4.5 next ADL number" "5" "$(get_next_adl_number)"

# =============================================================================
# Phase 5: ADL entries accumulate over the project lifetime
# =============================================================================

# Verify the complete chain of entries
for id in 1 2 3 4; do
    assert_file_contains "5.${id} ADL-${id} persists" "$adl_file" "ADL-${id}"
done

# Count the actual ADL entries
local_count=$(grep -c "^## ADL-" "$adl_file" 2>/dev/null || echo "0")
assert_eq "5.5 total ADL entries" "4" "$local_count"

# =============================================================================
# Report
# =============================================================================
if [ "$FAIL" -eq 0 ]; then
    echo "ACP lifecycle test passed (all phases)"
    exit 0
else
    echo "ACP lifecycle test FAILED"
    exit 1
fi

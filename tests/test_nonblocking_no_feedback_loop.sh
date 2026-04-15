#!/usr/bin/env bash
# Test: Feedback loop prevention in --fix-nonblockers and --fix-drift modes.
# Verifies that process_drift_artifacts() skips appending new notes/observations
# when the corresponding fix mode is active, breaking the self-feeding cycle.

set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_DIR="$TMPDIR"
TEKHTON_SESSION_DIR="$TMPDIR"
mkdir -p "${TMPDIR}/${TEKHTON_DIR}"

DRIFT_LOG_FILE="${TEKHTON_DIR}/DRIFT_LOG.md"
ARCHITECTURE_LOG_FILE="${TEKHTON_DIR}/ARCHITECTURE_LOG.md"
HUMAN_ACTION_FILE="${TEKHTON_DIR}/HUMAN_ACTION_REQUIRED.md"
NON_BLOCKING_LOG_FILE="${TEKHTON_DIR}/NON_BLOCKING_LOG.md"
REVIEWER_REPORT_FILE="${TEKHTON_DIR}/REVIEWER_REPORT.md"
CODER_SUMMARY_FILE="${TEKHTON_DIR}/CODER_SUMMARY.md"
DRIFT_OBSERVATION_THRESHOLD=8
DRIFT_RUNS_SINCE_AUDIT_THRESHOLD=5
TASK="Test task"
ACCEPTED_ACPS=""

source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/drift.sh"
source "${TEKHTON_HOME}/lib/drift_cleanup.sh"
source "${TEKHTON_HOME}/lib/drift_artifacts.sh"

PASS=0
FAIL=0

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "✓ PASS: $label"
        PASS=$((PASS + 1))
    else
        echo "✗ FAIL: $label (expected='$expected', actual='$actual')"
        FAIL=$((FAIL + 1))
    fi
}

# Helper: create fixture files for a test run
setup_fixtures() {
    # Reviewer report with both drift observations and non-blocking notes
    cat > "${TMPDIR}/${REVIEWER_REPORT_FILE}" << 'EOREVW'
# Reviewer Report

## Drift Observations
- Some new drift observation from the reviewer about code duplication

## Non-Blocking Notes
- `lib/foo.sh:10` — Minor style issue worth noting

## Verdict
APPROVED_WITH_NOTES
EOREVW

    # Empty coder summary (so _process_design_observations no-ops)
    cat > "${TMPDIR}/${CODER_SUMMARY_FILE}" << 'EOCODER'
# Coder Summary

## Status
COMPLETE
EOCODER

    # Drift log with standard structure (needed by increment_runs_since_audit)
    cat > "${TMPDIR}/${DRIFT_LOG_FILE}" << 'EODRIFT'
# Architectural Drift Log

## Unresolved Observations
(none)

## Resolved

## Runs Since Last Audit
0
EODRIFT

    # Non-blocking log with standard structure
    cat > "${TMPDIR}/${NON_BLOCKING_LOG_FILE}" << 'EONB'
# Non-Blocking Notes Log

## Open
(none)

## Resolved
EONB
}

# ============================================================================
# Test 1: FIX_NONBLOCKERS_MODE suppresses append_nonblocking_notes
# ============================================================================
echo "--- Test 1: FIX_NONBLOCKERS_MODE suppresses non-blocking note append ---"

setup_fixtures
FIX_NONBLOCKERS_MODE=true
FIX_DRIFT_MODE=false
process_drift_artifacts

nb_count=$(count_open_nonblocking_notes)
assert_eq "No non-blocking notes appended" "0" "$nb_count"

# Drift observations SHOULD still be appended (only NB is suppressed)
drift_count=$(count_drift_observations)
assert_eq "Drift observations still appended" "1" "$drift_count"

# ============================================================================
# Test 2: FIX_DRIFT_MODE suppresses append_drift_observations
# ============================================================================
echo ""
echo "--- Test 2: FIX_DRIFT_MODE suppresses drift observation append ---"

setup_fixtures
FIX_NONBLOCKERS_MODE=false
FIX_DRIFT_MODE=true
process_drift_artifacts

local_drift_count=$(count_drift_observations)
assert_eq "No drift observations appended" "0" "$local_drift_count"

# Non-blocking notes SHOULD still be appended (only drift is suppressed)
local_nb_count=$(count_open_nonblocking_notes)
assert_eq "Non-blocking notes still appended" "1" "$local_nb_count"

# ============================================================================
# Test 3: Both modes false — both appends proceed normally
# ============================================================================
echo ""
echo "--- Test 3: Normal mode — both appends proceed ---"

setup_fixtures
FIX_NONBLOCKERS_MODE=false
FIX_DRIFT_MODE=false
process_drift_artifacts

local_nb_count=$(count_open_nonblocking_notes)
assert_eq "Non-blocking notes appended normally" "1" "$local_nb_count"

local_drift_count=$(count_drift_observations)
assert_eq "Drift observations appended normally" "1" "$local_drift_count"

# ============================================================================
# Test 4: Both modes true — both appends suppressed
# ============================================================================
echo ""
echo "--- Test 4: Both modes true — both appends suppressed ---"

setup_fixtures
FIX_NONBLOCKERS_MODE=true
FIX_DRIFT_MODE=true
process_drift_artifacts

local_nb_count=$(count_open_nonblocking_notes)
assert_eq "No non-blocking notes when both modes on" "0" "$local_nb_count"

local_drift_count=$(count_drift_observations)
assert_eq "No drift observations when both modes on" "0" "$local_drift_count"

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "Test Results:"
echo "  Passed: $PASS"
echo "  Failed: $FAIL"

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi

exit 0

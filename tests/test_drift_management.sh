#!/usr/bin/env bash
# Test: Drift log management functions
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_DIR="$TMPDIR"

# Set config defaults that drift.sh expects
DRIFT_LOG_FILE="DRIFT_LOG.md"
ARCHITECTURE_LOG_FILE="ARCHITECTURE_LOG.md"
HUMAN_ACTION_FILE="HUMAN_ACTION_REQUIRED.md"
DRIFT_OBSERVATION_THRESHOLD=3
DRIFT_RUNS_SINCE_AUDIT_THRESHOLD=5
TASK="Implement test feature"

source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/drift.sh"

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

# ============================================================
# Test 1: _ensure_drift_log creates file with correct structure
# ============================================================
_ensure_drift_log
assert_file_contains "drift log created" "${PROJECT_DIR}/DRIFT_LOG.md" "# Drift Log"
assert_file_contains "drift log metadata" "${PROJECT_DIR}/DRIFT_LOG.md" "Runs since audit: 0"
assert_file_contains "drift log unresolved section" "${PROJECT_DIR}/DRIFT_LOG.md" "## Unresolved Observations"
assert_file_contains "drift log resolved section" "${PROJECT_DIR}/DRIFT_LOG.md" "## Resolved"

# ============================================================
# Test 2: count_drift_observations returns 0 on empty log
# ============================================================
assert_eq "empty drift count" "0" "$(count_drift_observations)"

# ============================================================
# Test 3: append_drift_observations adds entries
# ============================================================
cat > "${PROJECT_DIR}/REVIEWER_REPORT.md" << 'EOF'
## Verdict
APPROVED_WITH_NOTES

## Drift Observations
- warden_processor.dart:45 — duplicate rank lookup pattern
- general — naming inconsistency: columnLock vs column_lock

## Non-Blocking Notes
- None
EOF

append_drift_observations
assert_eq "drift count after append" "2" "$(count_drift_observations)"
assert_file_contains "first observation" "${PROJECT_DIR}/DRIFT_LOG.md" "duplicate rank lookup"
assert_file_contains "second observation" "${PROJECT_DIR}/DRIFT_LOG.md" "naming inconsistency"
assert_file_contains "task tag in observation" "${PROJECT_DIR}/DRIFT_LOG.md" "Implement test feature"

# ============================================================
# Test 4: append_drift_observations skips "None"
# ============================================================
cat > "${PROJECT_DIR}/REVIEWER_REPORT.md" << 'EOF'
## Verdict
APPROVED

## Drift Observations
- None
EOF

append_drift_observations
assert_eq "drift count unchanged for None" "2" "$(count_drift_observations)"

# ============================================================
# Test 5: append_drift_observations skips missing section
# ============================================================
cat > "${PROJECT_DIR}/REVIEWER_REPORT.md" << 'EOF'
## Verdict
APPROVED
EOF

append_drift_observations
assert_eq "drift count unchanged for missing section" "2" "$(count_drift_observations)"

# ============================================================
# Test 6: increment_runs_since_audit / get_runs_since_audit
# ============================================================
assert_eq "initial runs count" "0" "$(get_runs_since_audit)"
increment_runs_since_audit
assert_eq "runs after 1 increment" "1" "$(get_runs_since_audit)"
increment_runs_since_audit
increment_runs_since_audit
assert_eq "runs after 3 increments" "3" "$(get_runs_since_audit)"

# ============================================================
# Test 7: reset_runs_since_audit
# ============================================================
reset_runs_since_audit
assert_eq "runs after reset" "0" "$(get_runs_since_audit)"
assert_file_not_contains "last audit not never" "${PROJECT_DIR}/DRIFT_LOG.md" "Last audit: never"

# ============================================================
# Test 8: should_trigger_audit — observation threshold
# ============================================================
# We have 2 observations, threshold is 3 — should NOT trigger
if should_trigger_audit; then
    echo "FAIL: should_trigger_audit fired below threshold"
    FAIL=1
fi

# Add one more observation to hit threshold (3)
cat > "${PROJECT_DIR}/REVIEWER_REPORT.md" << 'EOF'
## Drift Observations
- config.dart — unused field "spectral_enabled"
EOF

append_drift_observations
assert_eq "drift count now 3" "3" "$(count_drift_observations)"

if ! should_trigger_audit; then
    echo "FAIL: should_trigger_audit did not fire at threshold"
    FAIL=1
fi

# ============================================================
# Test 9: should_trigger_audit — run count threshold
# ============================================================
# Reset observations by replacing drift log, test run count
cat > "${PROJECT_DIR}/DRIFT_LOG.md" << 'EOF'
# Drift Log

## Metadata
- Last audit: never
- Runs since audit: 0

## Unresolved Observations

## Resolved
EOF

# Below threshold
if should_trigger_audit; then
    echo "FAIL: should_trigger_audit fired with 0 obs and 0 runs"
    FAIL=1
fi

# Bump runs to threshold
for _ in 1 2 3 4 5; do
    increment_runs_since_audit
done

if ! should_trigger_audit; then
    echo "FAIL: should_trigger_audit did not fire at run threshold"
    FAIL=1
fi

# ============================================================
# Test 10: resolve_drift_observations
# ============================================================
# Rebuild a drift log with known observations
cat > "${PROJECT_DIR}/DRIFT_LOG.md" << 'EOF'
# Drift Log

## Metadata
- Last audit: never
- Runs since audit: 0

## Unresolved Observations
- [2026-03-06 | "test"] file_a.dart — duplicate pattern
- [2026-03-06 | "test"] file_b.dart — naming mismatch

## Resolved
EOF

assert_eq "pre-resolve count" "2" "$(count_drift_observations)"
resolve_drift_observations "file_a.dart"
assert_eq "post-resolve count" "1" "$(count_drift_observations)"
assert_file_contains "resolved entry" "${PROJECT_DIR}/DRIFT_LOG.md" "RESOLVED.*duplicate pattern"

# ============================================================
# Test 11: ADL — get_next_adl_number on empty/missing file
# ============================================================
rm -f "${PROJECT_DIR}/ARCHITECTURE_LOG.md"
assert_eq "first ADL number" "1" "$(get_next_adl_number)"

# ============================================================
# Test 12: ADL — append_architecture_decision
# ============================================================
ACCEPTED_ACPS="- ACP: Layer boundary change — ACCEPT — Needed for cross-system access"
append_architecture_decision

assert_file_contains "ADL entry created" "${PROJECT_DIR}/ARCHITECTURE_LOG.md" "ADL-1"
assert_file_contains "ADL name" "${PROJECT_DIR}/ARCHITECTURE_LOG.md" "Layer boundary change"
assert_eq "next ADL number" "2" "$(get_next_adl_number)"

# Append a second
ACCEPTED_ACPS="- ACP: Config restructure — ACCEPT — Simplifies loading"
append_architecture_decision
assert_file_contains "ADL-2 created" "${PROJECT_DIR}/ARCHITECTURE_LOG.md" "ADL-2"
assert_eq "next ADL number after 2" "3" "$(get_next_adl_number)"

# ============================================================
# Test 13: Human Action — append + count
# ============================================================
rm -f "${PROJECT_DIR}/HUMAN_ACTION_REQUIRED.md"
assert_eq "no actions initially" "0" "$(count_human_actions)"

append_human_action "coder" "GDD says X but code does Y"
assert_eq "1 action after append" "1" "$(count_human_actions)"
assert_file_contains "action content" "${PROJECT_DIR}/HUMAN_ACTION_REQUIRED.md" "GDD says X but code does Y"
assert_file_contains "action source" "${PROJECT_DIR}/HUMAN_ACTION_REQUIRED.md" "Source: coder"

append_human_action "reviewer" "Architecture doc section 3.2 is stale"
assert_eq "2 actions after second append" "2" "$(count_human_actions)"

# ============================================================
# Test 14: has_human_actions
# ============================================================
if ! has_human_actions; then
    echo "FAIL: has_human_actions should return true with 2 items"
    FAIL=1
fi

rm -f "${PROJECT_DIR}/HUMAN_ACTION_REQUIRED.md"
if has_human_actions; then
    echo "FAIL: has_human_actions should return false with no file"
    FAIL=1
fi

# ============================================================
# Test 15: _process_design_observations
# ============================================================
cat > "${PROJECT_DIR}/CODER_SUMMARY.md" << 'EOF'
# Coder Summary
## Status: COMPLETE
## What Was Implemented
- Thing A
## Design Observations
- GDD §4.2 says wardens lock columns but we changed to danger zone
- GDD §5.1 references timer mechanic that was removed
## Files Created or Modified
- file.dart
EOF

_process_design_observations
assert_eq "2 actions from design obs" "2" "$(count_human_actions)"
assert_file_contains "design obs 1" "${PROJECT_DIR}/HUMAN_ACTION_REQUIRED.md" "danger zone"
assert_file_contains "design obs 2" "${PROJECT_DIR}/HUMAN_ACTION_REQUIRED.md" "timer mechanic"

# ============================================================
# Summary
# ============================================================
if [ "$FAIL" -eq 0 ]; then
    echo "All drift management tests passed."
else
    exit 1
fi

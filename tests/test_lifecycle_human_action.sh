#!/usr/bin/env bash
# =============================================================================
# test_lifecycle_human_action.sh — P6 Human Action Required lifecycle test
#
# Simulates the human action flow:
#   1. Coder produces design observations → HUMAN_ACTION_REQUIRED.md created
#   2. Architect audit also surfaces items → same file
#   3. Items accumulate across runs
#   4. Human checks off items (simulated edit)
#   5. Partial check-off → file persists, count decreases
#   6. All items checked → count reaches 0, has_human_actions returns false
# =============================================================================
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
CODER_SUMMARY_FILE="${TEKHTON_DIR}/CODER_SUMMARY.md"
REVIEWER_REPORT_FILE="${TEKHTON_DIR}/REVIEWER_REPORT.md"
DRIFT_OBSERVATION_THRESHOLD=8
DRIFT_RUNS_SINCE_AUDIT_THRESHOLD=5
TASK="human action lifecycle test"

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

action_file="${PROJECT_DIR}/${HUMAN_ACTION_FILE}"

# =============================================================================
# Phase 1: No action file — verify clean state
# =============================================================================
assert_eq "1.1 no actions initially" "0" "$(count_human_actions)"

if has_human_actions; then
    echo "FAIL: 1.2 has_human_actions should be false with no file"
    FAIL=1
fi

# =============================================================================
# Phase 2: Coder design observations create action items
# =============================================================================
TASK="Run 1: implement wardens"
cat > "${PROJECT_DIR}/${CODER_SUMMARY_FILE}" << 'EOF'
# Coder Summary
## Status: COMPLETE
## What Was Implemented
- Warden processor
## Design Observations
- GDD §4.2 says wardens lock columns but we changed to danger zone pattern
- GDD §5.1 references 30-second timer for boss encounters — code uses turn limits instead
## Files Created or Modified
- lib/engine/rules/warden_processor.dart
EOF

_process_design_observations

assert_eq "2.1 two actions from design obs" "2" "$(count_human_actions)"
assert_file_contains "2.2 file created" "$action_file" "# Human Action Required"
assert_file_contains "2.3 danger zone item" "$action_file" "danger zone"
assert_file_contains "2.4 timer item" "$action_file" "30-second timer"
assert_file_contains "2.5 source is coder" "$action_file" "Source: coder"

if ! has_human_actions; then
    echo "FAIL: 2.6 has_human_actions should be true"
    FAIL=1
fi

# =============================================================================
# Phase 3: Architect audit also surfaces items — they accumulate
# =============================================================================
append_human_action "architect" "ARCHITECTURE.md §3 — Layer diagram missing persistence layer"
append_human_action "architect" "GDD §7.3 — Lodestone formula changed but doc still shows old formula"

assert_eq "3.1 four total actions" "4" "$(count_human_actions)"
assert_file_contains "3.2 architect source" "$action_file" "Source: architect"
assert_file_contains "3.3 persistence layer item" "$action_file" "persistence layer"
assert_file_contains "3.4 lodestone formula item" "$action_file" "Lodestone formula"

# =============================================================================
# Phase 4: Second coder run — more items added without disturbing existing ones
# =============================================================================
TASK="Run 2: boss system"
cat > "${PROJECT_DIR}/${CODER_SUMMARY_FILE}" << 'EOF'
# Coder Summary
## Status: COMPLETE
## Design Observations
- GDD §6.1 boss flee mechanic says 10/20/mandatory but config has 15/25/mandatory
EOF

_process_design_observations

assert_eq "4.1 five total actions" "5" "$(count_human_actions)"
assert_file_contains "4.2 boss flee item" "$action_file" "flee mechanic"

# =============================================================================
# Phase 5: Human checks off some items (simulate manual edit)
# =============================================================================

# Replace first two "- [ ]" with "- [x]" to simulate human checking them off
local_tmpfile=$(mktemp)
local_count=0
while IFS= read -r line; do
    if echo "$line" | grep -q "^- \[ \]" && [ "$local_count" -lt 2 ]; then
        echo "$line" | sed 's/^- \[ \]/- [x]/' >> "$local_tmpfile"
        local_count=$((local_count + 1))
    else
        echo "$line" >> "$local_tmpfile"
    fi
done < "$action_file"
mv "$local_tmpfile" "$action_file"

assert_eq "5.1 three unchecked after checking 2" "3" "$(count_human_actions)"

if ! has_human_actions; then
    echo "FAIL: 5.2 has_human_actions should still be true (3 remaining)"
    FAIL=1
fi

# =============================================================================
# Phase 6: Human checks off remaining items → count reaches 0
# =============================================================================
sed -i 's/^- \[ \]/- [x]/' "$action_file"

assert_eq "6.1 zero unchecked" "0" "$(count_human_actions)"

if has_human_actions; then
    echo "FAIL: 6.2 has_human_actions should be false (all checked)"
    FAIL=1
fi

# =============================================================================
# Phase 7: New items can be added after all previous are checked
# =============================================================================
append_human_action "reviewer" "ARCHITECTURE.md needs P5 constraint section update"

assert_eq "7.1 one new action" "1" "$(count_human_actions)"

if ! has_human_actions; then
    echo "FAIL: 7.2 has_human_actions should be true again"
    FAIL=1
fi

# =============================================================================
# Phase 8: No design observations → nothing added
# =============================================================================
cat > "${PROJECT_DIR}/${CODER_SUMMARY_FILE}" << 'EOF'
# Coder Summary
## Status: COMPLETE
## What Was Implemented
- No changes to game design boundary
EOF

_process_design_observations

assert_eq "8.1 still one action (no new obs)" "1" "$(count_human_actions)"

# =============================================================================
# Report
# =============================================================================
if [ "$FAIL" -eq 0 ]; then
    echo "Human action lifecycle test passed (all phases)"
    exit 0
else
    echo "Human action lifecycle test FAILED"
    exit 1
fi

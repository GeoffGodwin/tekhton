#!/usr/bin/env bash
# Test: clear/get completed nonblocking notes and resolved drift observations
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_DIR="$TMPDIR"
TEKHTON_SESSION_DIR="$TMPDIR"

DRIFT_LOG_FILE="DRIFT_LOG.md"
ARCHITECTURE_LOG_FILE="ARCHITECTURE_LOG.md"
HUMAN_ACTION_FILE="HUMAN_ACTION_REQUIRED.md"
NON_BLOCKING_LOG_FILE="NON_BLOCKING_LOG.md"
NON_BLOCKING_INJECTION_THRESHOLD=3
DRIFT_OBSERVATION_THRESHOLD=8
DRIFT_RUNS_SINCE_AUDIT_THRESHOLD=5
TASK="Test task"

source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/drift.sh"
source "${TEKHTON_HOME}/lib/drift_cleanup.sh"
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

NB_FILE="${PROJECT_DIR}/${NON_BLOCKING_LOG_FILE}"
DRIFT_FILE="${PROJECT_DIR}/${DRIFT_LOG_FILE}"

# ============================================================
# Test 1: clear_completed_nonblocking_notes — missing file is safe
# ============================================================
rm -f "$NB_FILE"
clear_completed_nonblocking_notes
assert_eq "no-op on missing nb file" "false" "$([ -f "$NB_FILE" ] && echo true || echo false)"

# ============================================================
# Test 2: get_completed_nonblocking_notes — missing file returns empty
# ============================================================
RESULT=$(get_completed_nonblocking_notes)
assert_eq "empty result on missing file" "" "$RESULT"

# ============================================================
# Test 3: clear_completed_nonblocking_notes — no [x] items, file unchanged
# ============================================================
cat > "$NB_FILE" << 'EOF'
# Non-Blocking Log

## Open
- [ ] [2026-03-18 | "task"] lib/foo.sh — refactor needed
- [ ] [2026-03-18 | "task"] lib/bar.sh — rename variable

## Resolved
EOF

clear_completed_nonblocking_notes
COUNT=$(count_open_nonblocking_notes)
assert_eq "open items preserved when no completed" "2" "$COUNT"

# ============================================================
# Test 4: get_completed_nonblocking_notes — no [x] items returns empty
# ============================================================
RESULT=$(get_completed_nonblocking_notes)
assert_eq "no completed items returns empty" "" "$RESULT"

# ============================================================
# Test 5: clear_completed_nonblocking_notes — moves [x] items to Resolved
# ============================================================
cat > "$NB_FILE" << 'EOF'
# Non-Blocking Log

## Open
- [x] [2026-03-18 | "task"] lib/foo.sh — refactor needed
- [ ] [2026-03-18 | "task"] lib/bar.sh — rename variable
- [x] [2026-03-18 | "task"] lib/baz.sh — add docstring

## Resolved
EOF

clear_completed_nonblocking_notes
COUNT=$(count_open_nonblocking_notes)
assert_eq "only open items remain after clear" "1" "$COUNT"
assert_file_contains "open bar preserved" "$NB_FILE" "bar.sh"
# Items moved to ## Resolved for traceability
RESOLVED_SECTION=$(awk '/^## Resolved/{f=1; next} f && /^## [^#]/{exit} f{print}' "$NB_FILE")
if ! echo "$RESOLVED_SECTION" | grep -q "foo.sh"; then
    echo "FAIL: completed foo.sh should be in ## Resolved"
    FAIL=1
fi
if ! echo "$RESOLVED_SECTION" | grep -q "baz.sh"; then
    echo "FAIL: completed baz.sh should be in ## Resolved"
    FAIL=1
fi
# Verify they are NOT in the ## Open section
OPEN_SECTION=$(awk '/^## Open/{f=1; next} f && /^## [^#]/{exit} f{print}' "$NB_FILE")
if echo "$OPEN_SECTION" | grep -q "foo.sh"; then
    echo "FAIL: completed foo.sh should not be in ## Open"
    FAIL=1
fi

# ============================================================
# Test 6: get_completed_nonblocking_notes — returns [x] items before clear
# ============================================================
cat > "$NB_FILE" << 'EOF'
# Non-Blocking Log

## Open
- [x] [2026-03-18 | "task"] lib/alpha.sh — refactor
- [ ] [2026-03-18 | "task"] lib/beta.sh — rename
- [x] [2026-03-18 | "task"] lib/gamma.sh — docstring

## Resolved
EOF

COMPLETED=$(get_completed_nonblocking_notes)
LINE_COUNT=$(echo "$COMPLETED" | grep -c '\[x\]' || true)
assert_eq "get returns 2 completed items" "2" "$LINE_COUNT"
if ! echo "$COMPLETED" | grep -q "alpha.sh"; then
    echo "FAIL: get_completed_nonblocking_notes — alpha.sh not in output"
    FAIL=1
fi
if ! echo "$COMPLETED" | grep -q "gamma.sh"; then
    echo "FAIL: get_completed_nonblocking_notes — gamma.sh not in output"
    FAIL=1
fi

# ============================================================
# Test 7: get_completed_nonblocking_notes — does NOT return open items
# ============================================================
if echo "$COMPLETED" | grep -q "beta.sh"; then
    echo "FAIL: get_completed_nonblocking_notes — open item beta.sh should not appear"
    FAIL=1
fi

# ============================================================
# Test 8: clear_completed_nonblocking_notes — all items completed, Open section empty
# ============================================================
cat > "$NB_FILE" << 'EOF'
# Non-Blocking Log

## Open
- [x] [2026-03-18 | "task"] lib/only.sh — the one item

## Resolved
EOF

clear_completed_nonblocking_notes
COUNT=$(count_open_nonblocking_notes)
assert_eq "all completed cleared, Open section empty" "0" "$COUNT"
assert_file_contains "Open section header preserved" "$NB_FILE" "## Open"
assert_file_contains "Resolved section preserved" "$NB_FILE" "## Resolved"
# Verify the item was moved to Resolved
RESOLVED_SECTION=$(awk '/^## Resolved/{f=1; next} f && /^## [^#]/{exit} f{print}' "$NB_FILE")
if ! echo "$RESOLVED_SECTION" | grep -q "only.sh"; then
    echo "FAIL: completed only.sh should be in ## Resolved"
    FAIL=1
fi

# ============================================================
# Test 9: clear_resolved_drift_observations — missing file is safe
# ============================================================
rm -f "$DRIFT_FILE"
clear_resolved_drift_observations
assert_eq "no-op on missing drift file" "false" "$([ -f "$DRIFT_FILE" ] && echo true || echo false)"

# ============================================================
# Test 10: get_resolved_drift_observations — missing file returns empty
# ============================================================
RESULT=$(get_resolved_drift_observations)
assert_eq "empty result on missing drift file" "" "$RESULT"

# ============================================================
# Test 11: clear_resolved_drift_observations — no resolved items, file unchanged
# ============================================================
cat > "$DRIFT_FILE" << 'EOF'
# Drift Log

## Unresolved Observations
- [2026-03-18 | "task"] file.sh — inconsistency

## Resolved
EOF

clear_resolved_drift_observations
assert_file_contains "unresolved preserved when no resolved" "$DRIFT_FILE" "inconsistency"

# ============================================================
# Test 12: get_resolved_drift_observations — no resolved items returns empty
# ============================================================
RESULT=$(get_resolved_drift_observations)
assert_eq "no resolved items returns empty" "" "$RESULT"

# ============================================================
# Test 13: clear_resolved_drift_observations — removes [RESOLVED] items only
# ============================================================
cat > "$DRIFT_FILE" << 'EOF'
# Drift Log

## Unresolved Observations
- [2026-03-18 | "task"] file_a.sh — duplicate pattern

## Resolved
- [RESOLVED 2026-03-18] [2026-03-17 | "task"] file_b.sh — naming mismatch
- [RESOLVED 2026-03-18] [2026-03-17 | "task"] file_c.sh — dead code
EOF

clear_resolved_drift_observations
assert_file_contains "unresolved section preserved" "$DRIFT_FILE" "## Unresolved Observations"
assert_file_contains "Resolved section header preserved" "$DRIFT_FILE" "## Resolved"
assert_file_not_contains "file_b resolved removed" "$DRIFT_FILE" "file_b.sh"
assert_file_not_contains "file_c resolved removed" "$DRIFT_FILE" "file_c.sh"
assert_file_contains "unresolved item preserved" "$DRIFT_FILE" "file_a.sh"

# ============================================================
# Test 14: get_resolved_drift_observations — returns [RESOLVED] items
# ============================================================
cat > "$DRIFT_FILE" << 'EOF'
# Drift Log

## Unresolved Observations
- [2026-03-18 | "task"] unresolved.sh — still open

## Resolved
- [RESOLVED 2026-03-18] [2026-03-17 | "task"] resolved_x.sh — done
- [RESOLVED 2026-03-18] [2026-03-17 | "task"] resolved_y.sh — also done
EOF

RESOLVED=$(get_resolved_drift_observations)
LINE_COUNT=$(echo "$RESOLVED" | grep -c '\[RESOLVED' || true)
assert_eq "get returns 2 resolved items" "2" "$LINE_COUNT"
if ! echo "$RESOLVED" | grep -q "resolved_x.sh"; then
    echo "FAIL: get_resolved_drift_observations — resolved_x.sh not in output"
    FAIL=1
fi
if ! echo "$RESOLVED" | grep -q "resolved_y.sh"; then
    echo "FAIL: get_resolved_drift_observations — resolved_y.sh not in output"
    FAIL=1
fi

# ============================================================
# Test 15: get_resolved_drift_observations — does NOT return unresolved items
# ============================================================
if echo "$RESOLVED" | grep -q "unresolved.sh"; then
    echo "FAIL: get_resolved_drift_observations — unresolved item should not appear"
    FAIL=1
fi

# ============================================================
# Summary
# ============================================================
if [ "$FAIL" -eq 0 ]; then
    echo "All drift cleanup tests passed."
else
    exit 1
fi

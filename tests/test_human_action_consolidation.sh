#!/usr/bin/env bash
# =============================================================================
# test_human_action_consolidation.sh — Regression coverage for
# consolidate_legacy_human_action(). Verifies that a stale root-level
# HUMAN_ACTION_REQUIRED.md left behind by pre-v3.1 projects (or by an old
# pipeline.conf override) is merged into the canonical .tekhton/ location at
# startup, so subsequent writes don't fork into two files.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

export PROJECT_DIR="$TMPDIR"
export TEKHTON_SESSION_DIR="$TMPDIR"
export TEKHTON_DIR=".tekhton"
mkdir -p "${TMPDIR}/${TEKHTON_DIR}"

HUMAN_ACTION_FILE="${TEKHTON_DIR}/HUMAN_ACTION_REQUIRED.md"

# shellcheck source=lib/common.sh
source "${TEKHTON_HOME}/lib/common.sh"
# shellcheck source=lib/drift.sh
source "${TEKHTON_HOME}/lib/drift.sh"
# shellcheck source=lib/drift_artifacts.sh
source "${TEKHTON_HOME}/lib/drift_artifacts.sh"

PASS=0; FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL+1)); }

assert_file_exists() {
    local label="$1" path="$2"
    if [[ -f "$path" ]]; then
        pass "$label"
    else
        fail "$label" "expected file at $path"
    fi
}

assert_file_missing() {
    local label="$1" path="$2"
    if [[ ! -e "$path" ]]; then
        pass "$label"
    else
        fail "$label" "file unexpectedly present at $path"
    fi
}

assert_file_contains() {
    local label="$1" path="$2" pattern="$3"
    if grep -Fq -- "$pattern" "$path" 2>/dev/null; then
        pass "$label"
    else
        fail "$label" "pattern '$pattern' not found in $path"
    fi
}

assert_file_not_contains() {
    local label="$1" path="$2" pattern="$3"
    if grep -Fq -- "$pattern" "$path" 2>/dev/null; then
        fail "$label" "pattern '$pattern' unexpectedly found in $path"
    else
        pass "$label"
    fi
}

reset_state() {
    rm -f -- "${TMPDIR}/HUMAN_ACTION_REQUIRED.md"
    rm -f -- "${TMPDIR}/${HUMAN_ACTION_FILE}"
}

# ============================================================================
echo "=== Test 1: Root file present, canonical missing → moved to canonical ==="
reset_state
cat > "${TMPDIR}/HUMAN_ACTION_REQUIRED.md" << 'EOF'
# Human Action Required
- [ ] [2026-04-26 | Source: coder] Stale root item one
- [ ] [2026-04-26 | Source: coder] Stale root item two
EOF

consolidate_legacy_human_action

assert_file_missing "Test 1: root file removed" "${TMPDIR}/HUMAN_ACTION_REQUIRED.md"
assert_file_exists "Test 1: canonical file created" "${TMPDIR}/${HUMAN_ACTION_FILE}"
assert_file_contains "Test 1: item one preserved" "${TMPDIR}/${HUMAN_ACTION_FILE}" "Stale root item one"
assert_file_contains "Test 1: item two preserved" "${TMPDIR}/${HUMAN_ACTION_FILE}" "Stale root item two"

# ============================================================================
echo "=== Test 2: Both files exist → unchecked items merged, root deleted ==="
reset_state
cat > "${TMPDIR}/HUMAN_ACTION_REQUIRED.md" << 'EOF'
# Human Action Required
- [ ] [2026-04-26 | Source: coder] New root item
- [x] [2026-04-26 | Source: coder] Already-completed root item
EOF
cat > "${TMPDIR}/${HUMAN_ACTION_FILE}" << 'EOF'
# Human Action Required
- [ ] [2026-04-25 | Source: coder] Existing canonical item
EOF

consolidate_legacy_human_action

assert_file_missing "Test 2: root file removed" "${TMPDIR}/HUMAN_ACTION_REQUIRED.md"
assert_file_contains "Test 2: canonical preserved" "${TMPDIR}/${HUMAN_ACTION_FILE}" "Existing canonical item"
assert_file_contains "Test 2: root unchecked merged" "${TMPDIR}/${HUMAN_ACTION_FILE}" "New root item"
assert_file_not_contains "Test 2: completed item not merged" "${TMPDIR}/${HUMAN_ACTION_FILE}" "Already-completed root item"

# ============================================================================
echo "=== Test 3: Duplicate items not double-appended ==="
reset_state
cat > "${TMPDIR}/HUMAN_ACTION_REQUIRED.md" << 'EOF'
- [ ] [2026-04-26 | Source: coder] Duplicate line
EOF
cat > "${TMPDIR}/${HUMAN_ACTION_FILE}" << 'EOF'
# Human Action Required
- [ ] [2026-04-26 | Source: coder] Duplicate line
EOF

consolidate_legacy_human_action

dup_count=$(grep -Fc -- "Duplicate line" "${TMPDIR}/${HUMAN_ACTION_FILE}" || true)
if [[ "$dup_count" -eq 1 ]]; then
    pass "Test 3: duplicate line not re-appended"
else
    fail "Test 3: duplicate line not re-appended" "expected 1 occurrence, got ${dup_count}"
fi

# ============================================================================
echo "=== Test 4: No-op when canonical path equals legacy root path ==="
reset_state
HUMAN_ACTION_FILE="HUMAN_ACTION_REQUIRED.md"
cat > "${TMPDIR}/HUMAN_ACTION_REQUIRED.md" << 'EOF'
- [ ] User explicitly opted into root path
EOF

consolidate_legacy_human_action

assert_file_exists "Test 4: root file untouched" "${TMPDIR}/HUMAN_ACTION_REQUIRED.md"
assert_file_contains "Test 4: content untouched" "${TMPDIR}/HUMAN_ACTION_REQUIRED.md" "User explicitly opted into root path"

# Restore canonical for any later assertions
HUMAN_ACTION_FILE="${TEKHTON_DIR}/HUMAN_ACTION_REQUIRED.md"

# ============================================================================
echo "=== Test 5: No-op when only canonical exists ==="
reset_state
cat > "${TMPDIR}/${HUMAN_ACTION_FILE}" << 'EOF'
# Human Action Required
- [ ] Canonical-only item
EOF

consolidate_legacy_human_action

assert_file_missing "Test 5: no root file created" "${TMPDIR}/HUMAN_ACTION_REQUIRED.md"
assert_file_contains "Test 5: canonical untouched" "${TMPDIR}/${HUMAN_ACTION_FILE}" "Canonical-only item"

# ============================================================================
echo "=== Test 6: No-op when neither file exists ==="
reset_state

consolidate_legacy_human_action

assert_file_missing "Test 6: no root file" "${TMPDIR}/HUMAN_ACTION_REQUIRED.md"
assert_file_missing "Test 6: no canonical file" "${TMPDIR}/${HUMAN_ACTION_FILE}"

# ============================================================================
echo ""
echo "=== Summary: ${PASS} passed, ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]]

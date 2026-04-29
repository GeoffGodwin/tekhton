#!/usr/bin/env bash
# Test: migrations/032_to_033.sh — V3.2 → V3.3 stale-override cleanup migration
# Verifies the four-function contract and confirms idempotency, value
# matching, and preservation of user-customized paths.
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATION_SCRIPT="${TEKHTON_HOME}/migrations/032_to_033.sh"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# Stub logging functions before sourcing the migration.
log()     { :; }
warn()    { :; }
error()   { :; }
success() { :; }
header()  { :; }

# shellcheck source=../migrations/032_to_033.sh disable=SC1091
source "$MIGRATION_SCRIPT"

# =============================================================================
# Section 0: Static analysis
# =============================================================================

if bash -n "$MIGRATION_SCRIPT" 2>/dev/null; then
    pass "bash -n migrations/032_to_033.sh passes"
else
    fail "bash -n migrations/032_to_033.sh: syntax error"
fi

if command -v shellcheck &>/dev/null; then
    if shellcheck "$MIGRATION_SCRIPT" 2>/dev/null; then
        pass "shellcheck migrations/032_to_033.sh passes"
    else
        fail "shellcheck migrations/032_to_033.sh: warnings or errors"
    fi
else
    echo "  SKIP: shellcheck not installed"
fi

# =============================================================================
# Section 1: Contract — migration_version returns "3.3"
# =============================================================================

ver=$(migration_version)
if [[ "$ver" == "3.3" ]]; then
    pass "migration_version returns '3.3'"
else
    fail "migration_version returns '$ver' (expected '3.3')"
fi

# =============================================================================
# Helper: build a project fixture with stale overrides
# =============================================================================

_make_stale_project() {
    local proj="$1"
    mkdir -p "${proj}/.claude"
    cat > "${proj}/.claude/pipeline.conf" << 'EOF'
PROJECT_NAME="test-project"
TEKHTON_CONFIG_VERSION="3.2"
TEKHTON_DIR=".tekhton"
TEST_CMD="npm test"

# --- Architecture drift configuration ----------------------------------------
ARCHITECTURE_LOG_FILE="ARCHITECTURE_LOG.md"
DRIFT_LOG_FILE="DRIFT_LOG.md"
HUMAN_ACTION_FILE="HUMAN_ACTION_REQUIRED.md"
NON_BLOCKING_LOG_FILE="NON_BLOCKING_LOG.md"
NON_BLOCKING_INJECTION_THRESHOLD=8

# --- Design document ---------------------------------------------------------
DESIGN_FILE="DESIGN.md"
EOF
}

_make_clean_project() {
    local proj="$1"
    mkdir -p "${proj}/.claude"
    cat > "${proj}/.claude/pipeline.conf" << 'EOF'
PROJECT_NAME="test-project"
TEKHTON_CONFIG_VERSION="3.2"
TEKHTON_DIR=".tekhton"
TEST_CMD="npm test"
NON_BLOCKING_INJECTION_THRESHOLD=8
EOF
}

# =============================================================================
# T1: migration_check returns 0 on a project with stale overrides
# =============================================================================
PROJ_T1="${TEST_TMPDIR}/t1_stale"
_make_stale_project "$PROJ_T1"
if migration_check "$PROJ_T1"; then
    pass "T1: migration_check returns 0 on conf with stale overrides"
else
    fail "T1: migration_check returned non-zero on conf with stale overrides"
fi

# =============================================================================
# T2: migration_check returns 1 on a clean project (no stale overrides)
# =============================================================================
PROJ_T2="${TEST_TMPDIR}/t2_clean"
_make_clean_project "$PROJ_T2"
if migration_check "$PROJ_T2"; then
    fail "T2: migration_check returned 0 on clean conf (no stale overrides)"
else
    pass "T2: migration_check returns 1 on clean conf"
fi

# =============================================================================
# T3: migration_check returns 1 when pipeline.conf is absent
# =============================================================================
PROJ_T3="${TEST_TMPDIR}/t3_no_conf"
mkdir -p "${PROJ_T3}/.claude"
if migration_check "$PROJ_T3"; then
    fail "T3: migration_check returned 0 with no pipeline.conf"
else
    pass "T3: migration_check returns 1 when pipeline.conf is absent"
fi

# =============================================================================
# T4: migration_apply comments out all five stale overrides
# =============================================================================
PROJ_T4="${TEST_TMPDIR}/t4_apply"
_make_stale_project "$PROJ_T4"
migration_apply "$PROJ_T4" >/dev/null
conf="${PROJ_T4}/.claude/pipeline.conf"
expected_keys=(
    NON_BLOCKING_LOG_FILE
    HUMAN_ACTION_FILE
    DRIFT_LOG_FILE
    ARCHITECTURE_LOG_FILE
    DESIGN_FILE
)
all_commented=true
for k in "${expected_keys[@]}"; do
    # The active line must be gone; only commented form should remain
    if grep -qE "^${k}=" "$conf"; then
        fail "T4: ${k} still active in conf after migration_apply"
        all_commented=false
    fi
    if ! grep -qE "^# ${k}=" "$conf"; then
        fail "T4: ${k} not present in commented form after migration_apply"
        all_commented=false
    fi
done
if [[ "$all_commented" = true ]]; then
    pass "T4: all five stale overrides commented out (NON_BLOCKING_LOG_FILE, HUMAN_ACTION_FILE, DRIFT_LOG_FILE, ARCHITECTURE_LOG_FILE, DESIGN_FILE)"
fi

# =============================================================================
# T5: marker comment present above each commented-out override
# =============================================================================
marker_count=$(grep -c '^# V3.3 migration: stale root-path override removed' "$conf" || true)
if [[ "$marker_count" -eq 5 ]]; then
    pass "T5: V3.3 marker comment present above each of 5 commented overrides"
else
    fail "T5: expected 5 V3.3 marker comments, got $marker_count"
fi

# =============================================================================
# T6: idempotency — migration_check returns 1 after migration_apply
# =============================================================================
if migration_check "$PROJ_T4"; then
    fail "T6: migration_check returned 0 after apply (would re-run)"
else
    pass "T6: migration_check returns 1 after apply (re-run blocked)"
fi

# =============================================================================
# T7: user-customized paths preserved (containing slash, custom basename)
# =============================================================================
PROJ_T7="${TEST_TMPDIR}/t7_custom_paths"
mkdir -p "${PROJ_T7}/.claude"
cat > "${PROJ_T7}/.claude/pipeline.conf" << 'EOF'
PROJECT_NAME="custom"
TEKHTON_DIR=".tekhton"
NON_BLOCKING_LOG_FILE="docs/MY_NOTES.md"
DRIFT_LOG_FILE=".tekhton/DRIFT_LOG.md"
DESIGN_FILE="custom_design.md"
EOF
if migration_check "$PROJ_T7"; then
    fail "T7: migration_check returned 0 on conf with custom paths (no stale)"
else
    pass "T7a: migration_check returns 1 — custom paths not flagged as stale"
fi
migration_apply "$PROJ_T7" >/dev/null
if grep -qE '^NON_BLOCKING_LOG_FILE="docs/MY_NOTES.md"$' "${PROJ_T7}/.claude/pipeline.conf" \
   && grep -qE '^DRIFT_LOG_FILE=".tekhton/DRIFT_LOG.md"$' "${PROJ_T7}/.claude/pipeline.conf" \
   && grep -qE '^DESIGN_FILE="custom_design.md"$' "${PROJ_T7}/.claude/pipeline.conf"; then
    pass "T7b: user-customized paths preserved verbatim"
else
    fail "T7b: a user-customized path was modified by migration_apply"
fi

# =============================================================================
# T8: unrelated keys preserved (NON_BLOCKING_INJECTION_THRESHOLD, TEST_CMD)
# =============================================================================
if grep -qE '^NON_BLOCKING_INJECTION_THRESHOLD=8$' "$conf" \
   && grep -qE '^TEST_CMD="npm test"$' "$conf"; then
    pass "T8: unrelated config keys preserved untouched"
else
    fail "T8: unrelated config keys were modified or removed"
fi

# =============================================================================
# T9: unquoted value (KEY=NON_BLOCKING_LOG.md without quotes) also flagged
# =============================================================================
PROJ_T9="${TEST_TMPDIR}/t9_unquoted"
mkdir -p "${PROJ_T9}/.claude"
cat > "${PROJ_T9}/.claude/pipeline.conf" << 'EOF'
PROJECT_NAME="unquoted"
NON_BLOCKING_LOG_FILE=NON_BLOCKING_LOG.md
EOF
if migration_check "$PROJ_T9"; then
    pass "T9a: migration_check flags unquoted stale value"
else
    fail "T9a: unquoted stale value not detected"
fi
migration_apply "$PROJ_T9" >/dev/null
if grep -qE '^# NON_BLOCKING_LOG_FILE=NON_BLOCKING_LOG.md$' "${PROJ_T9}/.claude/pipeline.conf"; then
    pass "T9b: unquoted stale value commented out by apply"
else
    fail "T9b: unquoted stale value not commented after apply"
fi

# =============================================================================
# T10: already-commented stale line is not re-processed
# =============================================================================
PROJ_T10="${TEST_TMPDIR}/t10_already_commented"
mkdir -p "${PROJ_T10}/.claude"
cat > "${PROJ_T10}/.claude/pipeline.conf" << 'EOF'
PROJECT_NAME="cmt"
# NON_BLOCKING_LOG_FILE="NON_BLOCKING_LOG.md"
EOF
if migration_check "$PROJ_T10"; then
    fail "T10: migration_check flagged an already-commented stale line"
else
    pass "T10: already-commented stale line not flagged"
fi

# =============================================================================
# T11: line count preserved + 1 marker per commented override (T4 reuse)
# =============================================================================
src_lines=$(grep -cE '^(NON_BLOCKING_LOG_FILE|HUMAN_ACTION_FILE|DRIFT_LOG_FILE|ARCHITECTURE_LOG_FILE|DESIGN_FILE)=' \
    "${TEST_TMPDIR}/t1_stale/.claude/pipeline.conf" || true)
dst_active=$(grep -cE '^(NON_BLOCKING_LOG_FILE|HUMAN_ACTION_FILE|DRIFT_LOG_FILE|ARCHITECTURE_LOG_FILE|DESIGN_FILE)=' \
    "$conf" || true)
dst_commented=$(grep -cE '^# (NON_BLOCKING_LOG_FILE|HUMAN_ACTION_FILE|DRIFT_LOG_FILE|ARCHITECTURE_LOG_FILE|DESIGN_FILE)=' \
    "$conf" || true)
if [[ "$src_lines" -eq 5 ]] && [[ "$dst_active" -eq 0 ]] && [[ "$dst_commented" -eq 5 ]]; then
    pass "T11: 5 active overrides → 0 active + 5 commented after apply"
else
    fail "T11: expected 5/0/5, got source=$src_lines active=$dst_active commented=$dst_commented"
fi

# =============================================================================
# T12: applying twice on already-clean conf is a no-op
# =============================================================================
before_md5=$(md5sum "$conf" | awk '{print $1}')
migration_apply "$PROJ_T4" >/dev/null
after_md5=$(md5sum "$conf" | awk '{print $1}')
if [[ "$before_md5" == "$after_md5" ]]; then
    pass "T12: re-applying migration on cleaned conf is a no-op (md5 stable)"
else
    fail "T12: re-applying migration changed the conf (not idempotent)"
fi

# =============================================================================
# Summary
# =============================================================================
echo
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0

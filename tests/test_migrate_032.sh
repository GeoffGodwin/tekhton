#!/usr/bin/env bash
# Test: migrations/031_to_032.sh — V3.1 → V3.2 resilience arc migration
# Verifies the four-function contract: migration_version, migration_description,
# migration_check, migration_apply. Confirms idempotency and edge cases.
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATION_SCRIPT="${TEKHTON_HOME}/migrations/031_to_032.sh"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# Stub logging functions before sourcing the migration (it calls log).
log()     { :; }
warn()    { :; }
error()   { :; }
success() { :; }
header()  { :; }

# shellcheck source=../migrations/031_to_032.sh disable=SC1091
source "$MIGRATION_SCRIPT"

# =============================================================================
# Section 0: Static analysis
# =============================================================================

if bash -n "$MIGRATION_SCRIPT" 2>/dev/null; then
    pass "bash -n migrations/031_to_032.sh passes"
else
    fail "bash -n migrations/031_to_032.sh: syntax error"
fi

if command -v shellcheck &>/dev/null; then
    if shellcheck "$MIGRATION_SCRIPT" 2>/dev/null; then
        pass "shellcheck migrations/031_to_032.sh passes"
    else
        fail "shellcheck migrations/031_to_032.sh: warnings or errors"
    fi
else
    echo "  SKIP: shellcheck not installed"
fi

# =============================================================================
# Section 1: Contract — migration_version returns "3.2"
# =============================================================================

ver=$(migration_version)
if [[ "$ver" == "3.2" ]]; then
    pass "migration_version returns '3.2'"
else
    fail "migration_version returns '$ver' (expected '3.2')"
fi

# =============================================================================
# Helper: build a fresh V3.1 project fixture
# =============================================================================

_make_v31_project() {
    local proj="$1"
    mkdir -p "${proj}/.claude"
    cat > "${proj}/.claude/pipeline.conf" << 'EOF'
PROJECT_NAME="test-project"
TEKHTON_CONFIG_VERSION=3.1
TEKHTON_DIR=".tekhton"
BUILD_CHECK_CMD="npm run build"
TEST_CMD="npm test"
SECURITY_AGENT_ENABLED=true
MILESTONE_DAG_ENABLED=true
EOF
}

# =============================================================================
# T1: migration_check on V3.1 conf without BUILD_FIX_ENABLED → returns 0
# =============================================================================
PROJ_T1="${TEST_TMPDIR}/t1_needs_migration"
_make_v31_project "$PROJ_T1"
if migration_check "$PROJ_T1"; then
    pass "T1: migration_check returns 0 (needs migration) on V3.1 conf"
else
    fail "T1: migration_check returned non-zero on V3.1 conf"
fi

# =============================================================================
# T2: migration_check on conf with BUILD_FIX_ENABLED → returns 1
# =============================================================================
PROJ_T2="${TEST_TMPDIR}/t2_already_migrated"
_make_v31_project "$PROJ_T2"
echo "BUILD_FIX_ENABLED=true" >> "${PROJ_T2}/.claude/pipeline.conf"
if migration_check "$PROJ_T2"; then
    fail "T2: migration_check returned 0 even though BUILD_FIX_ENABLED present"
else
    pass "T2: migration_check returns 1 (already migrated) when BUILD_FIX_ENABLED is set"
fi

# =============================================================================
# T3: migration_check with no pipeline.conf → returns 1
# =============================================================================
PROJ_T3="${TEST_TMPDIR}/t3_no_conf"
mkdir -p "${PROJ_T3}/.claude"
if migration_check "$PROJ_T3"; then
    fail "T3: migration_check returned 0 even though no pipeline.conf exists"
else
    pass "T3: migration_check returns 1 when pipeline.conf is absent (express mode)"
fi

# =============================================================================
# T4: migration_apply adds BUILD_FIX_ENABLED=true to pipeline.conf
# =============================================================================
PROJ_T4="${TEST_TMPDIR}/t4_apply_basic"
_make_v31_project "$PROJ_T4"
migration_apply "$PROJ_T4" >/dev/null
if grep -q '^BUILD_FIX_ENABLED=true$' "${PROJ_T4}/.claude/pipeline.conf"; then
    pass "T4: migration_apply added BUILD_FIX_ENABLED=true to pipeline.conf"
else
    fail "T4: BUILD_FIX_ENABLED=true not found after migration_apply"
fi

# =============================================================================
# T5: migration_apply adds commented BUILD_FIX_MAX_ATTEMPTS line
# =============================================================================
if grep -q '^# BUILD_FIX_MAX_ATTEMPTS=' "${PROJ_T4}/.claude/pipeline.conf"; then
    pass "T5: commented '# BUILD_FIX_MAX_ATTEMPTS=' line present after migration_apply"
else
    fail "T5: commented '# BUILD_FIX_MAX_ATTEMPTS=' line missing"
fi

# =============================================================================
# T6: migration_apply adds .tekhton/BUILD_FIX_REPORT.md to .gitignore
# =============================================================================
if grep -qF '.tekhton/BUILD_FIX_REPORT.md' "${PROJ_T4}/.gitignore" 2>/dev/null; then
    pass "T6: .gitignore gained .tekhton/BUILD_FIX_REPORT.md"
else
    fail "T6: .tekhton/BUILD_FIX_REPORT.md not found in .gitignore after migration"
fi

# =============================================================================
# T7: migration_apply adds .claude/preflight_bak/ to .gitignore
# =============================================================================
if grep -qF '.claude/preflight_bak/' "${PROJ_T4}/.gitignore" 2>/dev/null; then
    pass "T7: .gitignore gained .claude/preflight_bak/"
else
    fail "T7: .claude/preflight_bak/ not found in .gitignore after migration"
fi

# =============================================================================
# T8: idempotency — migration_apply twice does not duplicate BUILD_FIX_ENABLED
# =============================================================================
PROJ_T8="${TEST_TMPDIR}/t8_idempotent"
_make_v31_project "$PROJ_T8"
migration_apply "$PROJ_T8" >/dev/null
# Per the run_migrations contract: if check returns 1, apply is skipped.
if migration_check "$PROJ_T8"; then
    fail "T8: migration_check returned 0 on already-migrated conf (would re-apply)"
else
    pass "T8a: migration_check returns 1 on already-migrated conf (re-apply blocked)"
fi
# Even if apply were called twice unconditionally, the count must stay at 1.
# We verify the post-apply state has exactly one BUILD_FIX_ENABLED= line.
count=$(grep -c '^BUILD_FIX_ENABLED=' "${PROJ_T8}/.claude/pipeline.conf" || true)
if [[ "$count" -eq 1 ]]; then
    pass "T8b: exactly 1 BUILD_FIX_ENABLED= line in conf (got $count)"
else
    fail "T8b: expected 1 BUILD_FIX_ENABLED= line, got $count"
fi

# =============================================================================
# T9: existing "# Tekhton runtime artifacts" header is reused, not duplicated
# =============================================================================
PROJ_T9="${TEST_TMPDIR}/t9_existing_header"
_make_v31_project "$PROJ_T9"
cat > "${PROJ_T9}/.gitignore" << 'EOF'
node_modules/

# Tekhton runtime artifacts
.claude/PIPELINE.lock
.claude/logs/
EOF
migration_apply "$PROJ_T9" >/dev/null
header_count=$(grep -c '^# Tekhton runtime artifacts' "${PROJ_T9}/.gitignore" || true)
new_header_count=$(grep -cF '# Tekhton runtime artifacts (added by V3.2 migration)' "${PROJ_T9}/.gitignore" || true)
# The original header should remain. The V3.2-tagged header should NOT have been added,
# since the inner guard in _032_update_gitignore detects the original header.
if [[ "$header_count" -eq 1 ]] && [[ "$new_header_count" -eq 0 ]]; then
    pass "T9: existing '# Tekhton runtime artifacts' header reused; new tagged header not added"
else
    fail "T9: header count=$header_count tagged_count=$new_header_count (expected 1 / 0)"
fi
# But the new entries themselves must still have been appended.
if grep -qF '.tekhton/BUILD_FIX_REPORT.md' "${PROJ_T9}/.gitignore"; then
    pass "T9b: .tekhton/BUILD_FIX_REPORT.md still added under existing header"
else
    fail "T9b: .tekhton/BUILD_FIX_REPORT.md missing"
fi

# =============================================================================
# T10: migration_apply creates .claude/preflight_bak/ on a fresh project
# =============================================================================
PROJ_T10="${TEST_TMPDIR}/t10_bak_dir_created"
_make_v31_project "$PROJ_T10"
migration_apply "$PROJ_T10" >/dev/null
if [[ -d "${PROJ_T10}/.claude/preflight_bak" ]]; then
    pass "T10: .claude/preflight_bak/ directory created by migration"
else
    fail "T10: .claude/preflight_bak/ directory not created"
fi

# =============================================================================
# T11: pre-existing preflight_bak/ → migration_apply still succeeds (idempotent)
# =============================================================================
PROJ_T11="${TEST_TMPDIR}/t11_bak_dir_exists"
_make_v31_project "$PROJ_T11"
mkdir -p "${PROJ_T11}/.claude/preflight_bak"
echo "sentinel" > "${PROJ_T11}/.claude/preflight_bak/existing.bak"
if migration_apply "$PROJ_T11" >/dev/null; then
    pass "T11a: migration_apply succeeds when .claude/preflight_bak/ pre-exists"
else
    fail "T11a: migration_apply failed with pre-existing .claude/preflight_bak/"
fi
if [[ -f "${PROJ_T11}/.claude/preflight_bak/existing.bak" ]]; then
    pass "T11b: pre-existing file in preflight_bak/ preserved"
else
    fail "T11b: pre-existing file in preflight_bak/ destroyed"
fi

# =============================================================================
# T12: migration_apply on a project with no .gitignore creates one with entries
# =============================================================================
PROJ_T12="${TEST_TMPDIR}/t12_no_gitignore"
_make_v31_project "$PROJ_T12"
[[ -f "${PROJ_T12}/.gitignore" ]] && rm "${PROJ_T12}/.gitignore"
migration_apply "$PROJ_T12" >/dev/null
if [[ -f "${PROJ_T12}/.gitignore" ]] && \
   grep -qF '.tekhton/BUILD_FIX_REPORT.md' "${PROJ_T12}/.gitignore" && \
   grep -qF '.claude/preflight_bak/' "${PROJ_T12}/.gitignore"; then
    pass "T12: .gitignore created from scratch with both new entries"
else
    fail "T12: .gitignore not created or missing entries"
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

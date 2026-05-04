#!/usr/bin/env bash
# Test: migrations/031_to_032.sh — completeness checks not covered by test_migrate_032.sh
# Verifies: all 13 arc vars present, plan-deviation values, migration chain,
# VERSION file, and MANIFEST.cfg M137 row.
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATION_SCRIPT="${TEKHTON_HOME}/migrations/031_to_032.sh"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

log()     { :; }
warn()    { :; }
error()   { :; }
success() { :; }
header()  { :; }

# shellcheck source=../migrations/031_to_032.sh disable=SC1091
source "$MIGRATION_SCRIPT"

_make_v31_project() {
    local proj="$1"
    mkdir -p "${proj}/.claude"
    cat > "${proj}/.claude/pipeline.conf" << 'PEOF'
PROJECT_NAME="test-project"
TEKHTON_CONFIG_VERSION=3.1
TEKHTON_DIR=".tekhton"
BUILD_CHECK_CMD="npm run build"
TEST_CMD="npm test"
SECURITY_AGENT_ENABLED=true
MILESTONE_DAG_ENABLED=true
PEOF
}

# =============================================================================
# Section 1: All 13 arc vars are present after migration_apply
# =============================================================================

PROJ_VARS="${TEST_TMPDIR}/vars_check"
_make_v31_project "$PROJ_VARS"
migration_apply "$PROJ_VARS" >/dev/null
CONF="${PROJ_VARS}/.claude/pipeline.conf"

_assert_var_present() {
    local var="$1" pattern="$2"
    if grep -qF "$pattern" "$CONF" 2>/dev/null; then
        pass "V1: ${var} present in appended section"
    else
        fail "V1: ${var} missing from appended section (pattern: '${pattern}')"
    fi
}

# 1 active key
_assert_var_present "BUILD_FIX_ENABLED" "BUILD_FIX_ENABLED=true"
# 12 commented keys (match the comment prefix so we confirm they are commented)
_assert_var_present "BUILD_FIX_MAX_ATTEMPTS"          "# BUILD_FIX_MAX_ATTEMPTS="
_assert_var_present "BUILD_FIX_BASE_TURN_DIVISOR"     "# BUILD_FIX_BASE_TURN_DIVISOR="
_assert_var_present "BUILD_FIX_MAX_TURN_MULTIPLIER"   "# BUILD_FIX_MAX_TURN_MULTIPLIER="
_assert_var_present "BUILD_FIX_REQUIRE_PROGRESS"      "# BUILD_FIX_REQUIRE_PROGRESS="
_assert_var_present "BUILD_FIX_TOTAL_TURN_CAP"        "# BUILD_FIX_TOTAL_TURN_CAP="
_assert_var_present "BUILD_FIX_CLASSIFICATION_REQUIRED" "# BUILD_FIX_CLASSIFICATION_REQUIRED="
_assert_var_present "UI_GATE_ENV_RETRY_ENABLED"        "# UI_GATE_ENV_RETRY_ENABLED="
_assert_var_present "UI_GATE_ENV_RETRY_TIMEOUT_FACTOR" "# UI_GATE_ENV_RETRY_TIMEOUT_FACTOR="
_assert_var_present "TEKHTON_UI_GATE_FORCE_NONINTERACTIVE" "# TEKHTON_UI_GATE_FORCE_NONINTERACTIVE="
_assert_var_present "PREFLIGHT_UI_CONFIG_AUDIT_ENABLED" "# PREFLIGHT_UI_CONFIG_AUDIT_ENABLED="
_assert_var_present "PREFLIGHT_UI_CONFIG_AUTO_FIX"    "# PREFLIGHT_UI_CONFIG_AUTO_FIX="
_assert_var_present "PREFLIGHT_BAK_RETAIN_COUNT"      "# PREFLIGHT_BAK_RETAIN_COUNT="

# =============================================================================
# Section 2: Plan-deviation values — 100 not 1.0, 10 not 5
# =============================================================================

if grep -qF 'BUILD_FIX_MAX_TURN_MULTIPLIER=100' "$CONF" 2>/dev/null; then
    pass "V2: BUILD_FIX_MAX_TURN_MULTIPLIER documented as 100 (integer-percent encoding)"
else
    fail "V2: BUILD_FIX_MAX_TURN_MULTIPLIER not '100' (check for plan-deviation regression)"
fi

if grep -qF 'PREFLIGHT_BAK_RETAIN_COUNT=10' "$CONF" 2>/dev/null; then
    pass "V3: PREFLIGHT_BAK_RETAIN_COUNT documented as 10 (matches config_defaults.sh default)"
else
    fail "V3: PREFLIGHT_BAK_RETAIN_COUNT not '10' (check for plan-deviation regression)"
fi

# Guard: confirm the incorrect plan-spec values do NOT appear
if grep -qF 'BUILD_FIX_MAX_TURN_MULTIPLIER=1.0' "$CONF" 2>/dev/null; then
    fail "V4: BUILD_FIX_MAX_TURN_MULTIPLIER=1.0 found (stale plan-spec value leaked in)"
else
    pass "V4: BUILD_FIX_MAX_TURN_MULTIPLIER=1.0 not present (correct)"
fi

if grep -qF 'PREFLIGHT_BAK_RETAIN_COUNT=5' "$CONF" 2>/dev/null; then
    fail "V5: PREFLIGHT_BAK_RETAIN_COUNT=5 found (stale plan-spec value leaked in)"
else
    pass "V5: PREFLIGHT_BAK_RETAIN_COUNT=5 not present (correct)"
fi

# =============================================================================
# Section 3: migration_description is non-empty
# =============================================================================

desc=$(migration_description)
if [[ -n "$desc" ]]; then
    pass "D1: migration_description returns non-empty string ('${desc}')"
else
    fail "D1: migration_description returned empty string"
fi

# =============================================================================
# Section 4: VERSION file is at least 3.137.0 (M137 or later)
# =============================================================================

version_file="${TEKHTON_HOME}/VERSION"
if [[ -f "$version_file" ]]; then
    ver=$(tr -d '[:space:]' < "$version_file")
    # Extract major.minor version (e.g., "3.137" from "3.137.0")
    ver_major_minor="${ver%.*}"
    expected_major_minor="3.137"
    if [[ "$ver_major_minor" > "$expected_major_minor" ]] || [[ "$ver_major_minor" == "$expected_major_minor" ]]; then
        pass "VER: VERSION file contains '${ver}' (>= 3.137.0)"
    else
        fail "VER: VERSION file contains '${ver}' (expected >= 3.137.0)"
    fi
else
    fail "VER: VERSION file does not exist"
fi

# =============================================================================
# Section 5: MANIFEST.cfg has M137 row with correct depends_on and group
# (M137 is in the archived V3 manifest, since V4 started fresh)
# =============================================================================

# Check archived V3 MANIFEST first
manifest_v3="${TEKHTON_HOME}/.claude/milestones-v3/v3-final/MANIFEST.cfg"
if [[ -f "$manifest_v3" ]]; then
    m137_row=$(grep '^m137|' "$manifest_v3" || true)
    if [[ -n "$m137_row" ]]; then
        pass "MAN1: Archived V3 MANIFEST.cfg contains m137 row"
    else
        fail "MAN1: Archived V3 MANIFEST.cfg missing m137 row"
        m137_row=""
    fi

    if [[ "$m137_row" == *"m135,m136"* ]]; then
        pass "MAN2: m137 row has depends_on=m135,m136"
    else
        fail "MAN2: m137 row depends_on not 'm135,m136' (got: '${m137_row}')"
    fi

    if [[ "$m137_row" == *"|resilience"* ]]; then
        pass "MAN3: m137 row has group=resilience"
    else
        fail "MAN3: m137 row missing group=resilience (got: '${m137_row}')"
    fi
else
    fail "MAN1/2/3: Archived V3 MANIFEST.cfg does not exist at ${manifest_v3}"
fi

# =============================================================================
# Section 6: V3.0 → V3.2 migration chain
# A V3.0 project (no TEKHTON_DIR, no BUILD_FIX_ENABLED) successfully receives
# both migrations. We apply 003_to_031.sh first (in a subshell to avoid
# overriding current migration_* functions), then apply 031_to_032.sh.
# End state: BUILD_FIX_ENABLED=true in pipeline.conf.
# =============================================================================

PROJ_CHAIN="${TEST_TMPDIR}/chain_v30"
mkdir -p "${PROJ_CHAIN}/.claude"
cat > "${PROJ_CHAIN}/.claude/pipeline.conf" << 'PEOF'
PROJECT_NAME="legacy-project"
TEKHTON_CONFIG_VERSION=3.0
BUILD_CHECK_CMD="npm run build"
TEST_CMD="npm test"
PEOF

# Apply 3.1 migration in a subshell so its function definitions do not
# override the already-sourced 3.2 functions in this shell.
(
    log()     { :; }
    warn()    { :; }
    error()   { :; }
    success() { :; }
    header()  { :; }
    # shellcheck source=../migrations/003_to_031.sh disable=SC1091
    source "${TEKHTON_HOME}/migrations/003_to_031.sh"
    migration_apply "$PROJ_CHAIN" >/dev/null
)

# Verify 3.1 check would have passed (V3.0 project needs 3.1 migration)
(
    log()     { :; }
    warn()    { :; }
    error()   { :; }
    success() { :; }
    header()  { :; }
    # shellcheck source=../migrations/003_to_031.sh disable=SC1091
    source "${TEKHTON_HOME}/migrations/003_to_031.sh"
    if migration_check "$PROJ_CHAIN"; then
        echo "chain_31_check:needed"
    else
        echo "chain_31_check:skipped"
    fi
) > "${TEST_TMPDIR}/chain_31_check.txt" 2>/dev/null
# After 3.1 apply, the bare fixture has no tracked TEKHTON_DIR files, so
# migration_check may still return 0 (migration runner handles watermark).
# The important check is that 3.1 did not inject BUILD_FIX_ENABLED.
if grep -q '^BUILD_FIX_ENABLED=' "${PROJ_CHAIN}/.claude/pipeline.conf" 2>/dev/null; then
    fail "CHAIN1: BUILD_FIX_ENABLED already present after 3.1-only apply (unexpected)"
else
    pass "CHAIN1: BUILD_FIX_ENABLED not yet present after 3.1 apply (3.2 still needed)"
fi

# Now apply 3.2 migration (functions already sourced in this shell)
migration_apply "$PROJ_CHAIN" >/dev/null
if grep -q '^BUILD_FIX_ENABLED=true$' "${PROJ_CHAIN}/.claude/pipeline.conf" 2>/dev/null; then
    pass "CHAIN2: BUILD_FIX_ENABLED=true present after V3.0→V3.2 chain migration"
else
    fail "CHAIN2: BUILD_FIX_ENABLED=true missing after V3.0→V3.2 chain migration"
fi

# Verify 3.2 idempotency still works on a chained project
if migration_check "$PROJ_CHAIN"; then
    fail "CHAIN3: migration_check returned 0 (needs migration) after chain complete"
else
    pass "CHAIN3: migration_check returns 1 (already migrated) after chain complete"
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

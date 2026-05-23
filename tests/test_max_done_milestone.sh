#!/usr/bin/env bash
# Test: _max_done_milestone_in_manifest — MILESTONE_DIR override, sub-milestone exclusion, HWM logic
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Isolate from any parent-shell pipeline state (mirrors run_tests.sh hygiene).
unset PROJECT_DIR MILESTONE_DIR MILESTONE_MANIFEST 2>/dev/null || true

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# Stub logging functions
log()     { :; }
warn()    { :; }
error()   { :; }
success() { :; }
header()  { :; }

# Source version libraries
# shellcheck source=../lib/project_version.sh
source "${TEKHTON_HOME}/lib/project_version.sh"
# shellcheck source=../lib/project_version_bump.sh
source "${TEKHTON_HOME}/lib/project_version_bump.sh"

# =============================================================================
# _max_done_milestone_in_manifest — happy path
# Manifest has several done entries; function must return highest numeric ID.
# =============================================================================
echo "=== _max_done_milestone_in_manifest: happy path ==="

PROJ="${TEST_TMPDIR}/happy"
mkdir -p "${PROJ}/.claude/milestones"
cat > "${PROJ}/.claude/milestones/MANIFEST.cfg" <<'EOF'
# id|title|status|depends_on|file|parallel_group
m10|Ten|done||m10.md|phase5
m12|Twelve|done|m10|m12.md|phase5
m15|Fifteen|todo|m12|m15.md|phase5
m08|Eight|done|m07|m08.md|phase5
EOF

result=$(PROJECT_DIR="$PROJ" _max_done_milestone_in_manifest)
if [[ "$result" == "12" ]]; then
    pass "happy path: HWM is 12 (highest done=m12, ignores todo m15)"
else
    fail "happy path: got $result (want 12)"
fi

# =============================================================================
# _max_done_milestone_in_manifest — no done entries → returns 0
# =============================================================================
echo "=== _max_done_milestone_in_manifest: no done entries ==="

PROJ="${TEST_TMPDIR}/no_done"
mkdir -p "${PROJ}/.claude/milestones"
cat > "${PROJ}/.claude/milestones/MANIFEST.cfg" <<'EOF'
# id|title|status|depends_on|file|parallel_group
m01|First|todo||m01.md|phase5
m02|Second|in_progress|m01|m02.md|phase5
EOF

result=$(PROJECT_DIR="$PROJ" _max_done_milestone_in_manifest)
if [[ "$result" == "0" ]]; then
    pass "no done entries → 0"
else
    fail "no done entries: got $result (want 0)"
fi

# =============================================================================
# _max_done_milestone_in_manifest — missing manifest → returns 0
# =============================================================================
echo "=== _max_done_milestone_in_manifest: missing manifest ==="

PROJ="${TEST_TMPDIR}/no_manifest"
mkdir -p "${PROJ}/.claude/milestones"
# No MANIFEST.cfg written

result=$(PROJECT_DIR="$PROJ" _max_done_milestone_in_manifest)
if [[ "$result" == "0" ]]; then
    pass "missing manifest → 0"
else
    fail "missing manifest: got $result (want 0)"
fi

# =============================================================================
# _max_done_milestone_in_manifest — MILESTONE_DIR override
# When MILESTONE_DIR is set, the function must read from that directory
# instead of PROJECT_DIR/.claude/milestones/.
# =============================================================================
echo "=== _max_done_milestone_in_manifest: MILESTONE_DIR override ==="

# Create a project-level manifest that says HWM=5 — this is the "wrong" source.
PROJ="${TEST_TMPDIR}/milestone_dir_proj"
mkdir -p "${PROJ}/.claude/milestones"
cat > "${PROJ}/.claude/milestones/MANIFEST.cfg" <<'EOF'
m05|Five|done||m05.md|phase5
EOF

# Create the override directory with a different manifest that says HWM=42.
OVERRIDE_DIR="${TEST_TMPDIR}/milestone_dir_override"
mkdir -p "$OVERRIDE_DIR"
cat > "${OVERRIDE_DIR}/MANIFEST.cfg" <<'EOF'
m42|Forty-two|done||m42.md|phase5
m30|Thirty|done|m29|m30.md|phase5
EOF

# With MILESTONE_DIR set, should read 42 from the override, NOT 5 from PROJ.
result=$(MILESTONE_DIR="$OVERRIDE_DIR" PROJECT_DIR="$PROJ" _max_done_milestone_in_manifest)
if [[ "$result" == "42" ]]; then
    pass "MILESTONE_DIR override: reads from override dir (HWM=42, not 5)"
else
    fail "MILESTONE_DIR override: got $result (want 42)"
fi

# Confirm that WITHOUT the override the project manifest is used (sanity check).
result=$(PROJECT_DIR="$PROJ" _max_done_milestone_in_manifest)
if [[ "$result" == "5" ]]; then
    pass "MILESTONE_DIR unset: falls back to PROJECT_DIR manifest (HWM=5)"
else
    fail "MILESTONE_DIR unset fallback: got $result (want 5)"
fi

# =============================================================================
# _max_done_milestone_in_manifest — sub-milestone ID exclusion
# Entries like m05.1 must NOT be counted; only pure integer IDs (m05) count.
# =============================================================================
echo "=== _max_done_milestone_in_manifest: sub-milestone ID exclusion ==="

PROJ="${TEST_TMPDIR}/sub_milestones"
mkdir -p "${PROJ}/.claude/milestones"
cat > "${PROJ}/.claude/milestones/MANIFEST.cfg" <<'EOF'
# id|title|status|depends_on|file|parallel_group
m05|Five|done||m05.md|phase5
m05.1|Five-point-one|done|m05|m05.1.md|phase5
m05.2|Five-point-two|done|m05.1|m05.2.md|phase5
m10|Ten|todo||m10.md|phase5
EOF

result=$(PROJECT_DIR="$PROJ" _max_done_milestone_in_manifest)
if [[ "$result" == "5" ]]; then
    pass "sub-milestone exclusion: m05.1/m05.2 done entries do not inflate HWM beyond m05 (got 5)"
else
    fail "sub-milestone exclusion: got $result (want 5, sub-milestones must not count)"
fi

# Verify a manifest with ONLY sub-milestone done entries yields 0.
PROJ2="${TEST_TMPDIR}/only_sub"
mkdir -p "${PROJ2}/.claude/milestones"
cat > "${PROJ2}/.claude/milestones/MANIFEST.cfg" <<'EOF'
m03.1|Three-A|done||m03.1.md|phase5
m03.2|Three-B|done||m03.2.md|phase5
EOF

result=$(PROJECT_DIR="$PROJ2" _max_done_milestone_in_manifest)
if [[ "$result" == "0" ]]; then
    pass "only sub-milestones done → HWM is 0 (no top-level entries)"
else
    fail "only sub-milestones: got $result (want 0)"
fi

# =============================================================================
# _max_done_milestone_in_manifest — MILESTONE_DIR + custom MILESTONE_MANIFEST
# Both vars together should point to the right file.
# =============================================================================
echo "=== _max_done_milestone_in_manifest: MILESTONE_DIR + custom MILESTONE_MANIFEST ==="

CUSTOM_DIR="${TEST_TMPDIR}/custom_mdir"
mkdir -p "$CUSTOM_DIR"
cat > "${CUSTOM_DIR}/custom.cfg" <<'EOF'
m99|Ninety-nine|done||m99.md|phase5
EOF

result=$(MILESTONE_DIR="$CUSTOM_DIR" MILESTONE_MANIFEST="custom.cfg" \
    PROJECT_DIR="${TEST_TMPDIR}" _max_done_milestone_in_manifest)
if [[ "$result" == "99" ]]; then
    pass "MILESTONE_DIR + MILESTONE_MANIFEST: reads from custom filename (HWM=99)"
else
    fail "MILESTONE_DIR + MILESTONE_MANIFEST: got $result (want 99)"
fi

# =============================================================================
# Summary
# =============================================================================
echo
echo "Results: ${PASS} passed, ${FAIL} failed"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi

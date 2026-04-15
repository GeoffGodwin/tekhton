#!/usr/bin/env bash
# Test: Milestone 76 — get_version_bump_hint
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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
# Test: Breaking Changes → major
# =============================================================================
echo "=== get_version_bump_hint: Breaking Changes ==="

PROJ="${TEST_TMPDIR}/breaking"
mkdir -p "$PROJ/${TEKHTON_DIR}"
cat > "$PROJ/${TEKHTON_DIR}/CODER_SUMMARY.md" <<'EOF'
# Coder Summary
## Status: COMPLETE
## What Was Implemented
- Removed deprecated API endpoint
## Breaking Changes
- Removed /api/v1/legacy endpoint
## Files Modified
- src/api.ts
EOF

result=$(PROJECT_DIR="$PROJ" CODER_SUMMARY_FILE="${TEKHTON_DIR}/CODER_SUMMARY.md" get_version_bump_hint)
if [[ "$result" == "major" ]]; then pass "Breaking Changes → major"; else fail "Breaking Changes: got $result"; fi

# =============================================================================
# Test: New Public Surface → minor
# =============================================================================
echo "=== get_version_bump_hint: New Public Surface ==="

PROJ="${TEST_TMPDIR}/minor"
mkdir -p "$PROJ/${TEKHTON_DIR}"
cat > "$PROJ/${TEKHTON_DIR}/CODER_SUMMARY.md" <<'EOF'
# Coder Summary
## Status: COMPLETE
## What Was Implemented
- Added version detection library
## New Public Surface
- detect_project_version_files()
- parse_current_version()
## Files Modified
- lib/project_version.sh (NEW)
EOF

result=$(PROJECT_DIR="$PROJ" CODER_SUMMARY_FILE="${TEKHTON_DIR}/CODER_SUMMARY.md" get_version_bump_hint)
if [[ "$result" == "minor" ]]; then pass "New Public Surface → minor"; else fail "New Public Surface: got $result"; fi

# =============================================================================
# Test: Neither → default (patch)
# =============================================================================
echo "=== get_version_bump_hint: default patch ==="

PROJ="${TEST_TMPDIR}/patch"
mkdir -p "$PROJ/${TEKHTON_DIR}"
cat > "$PROJ/${TEKHTON_DIR}/CODER_SUMMARY.md" <<'EOF'
# Coder Summary
## Status: COMPLETE
## What Was Implemented
- Fixed a bug in the parser
## Files Modified
- lib/parser.sh
EOF

result=$(PROJECT_DIR="$PROJ" CODER_SUMMARY_FILE="${TEKHTON_DIR}/CODER_SUMMARY.md" get_version_bump_hint)
if [[ "$result" == "patch" ]]; then pass "no match → patch"; else fail "default: got $result"; fi

# =============================================================================
# Test: Custom default bump
# =============================================================================
echo "=== get_version_bump_hint: custom default ==="

PROJ="${TEST_TMPDIR}/custom"
mkdir -p "$PROJ/${TEKHTON_DIR}"
cat > "$PROJ/${TEKHTON_DIR}/CODER_SUMMARY.md" <<'EOF'
# Coder Summary
## Status: COMPLETE
## What Was Implemented
- Minor cleanup
EOF

result=$(PROJECT_DIR="$PROJ" CODER_SUMMARY_FILE="${TEKHTON_DIR}/CODER_SUMMARY.md" \
    PROJECT_VERSION_DEFAULT_BUMP="minor" get_version_bump_hint)
if [[ "$result" == "minor" ]]; then pass "custom default → minor"; else fail "custom default: got $result"; fi

# =============================================================================
# Test: Missing CODER_SUMMARY.md → fallback
# =============================================================================
echo "=== get_version_bump_hint: missing summary ==="

PROJ="${TEST_TMPDIR}/missing"
mkdir -p "$PROJ/${TEKHTON_DIR}"

result=$(PROJECT_DIR="$PROJ" CODER_SUMMARY_FILE="${TEKHTON_DIR}/CODER_SUMMARY.md" get_version_bump_hint)
if [[ "$result" == "patch" ]]; then pass "missing summary → patch"; else fail "missing summary: got $result"; fi

# =============================================================================
# Test: Breaking Changes takes priority over New Public Surface
# =============================================================================
echo "=== get_version_bump_hint: priority ==="

PROJ="${TEST_TMPDIR}/priority"
mkdir -p "$PROJ/${TEKHTON_DIR}"
cat > "$PROJ/${TEKHTON_DIR}/CODER_SUMMARY.md" <<'EOF'
# Coder Summary
## Status: COMPLETE
## Breaking Changes
- Changed signature of init()
## New Public Surface
- Added configure()
EOF

result=$(PROJECT_DIR="$PROJ" CODER_SUMMARY_FILE="${TEKHTON_DIR}/CODER_SUMMARY.md" get_version_bump_hint)
if [[ "$result" == "major" ]]; then pass "breaking takes priority over minor"; else fail "priority: got $result"; fi

# =============================================================================
# Summary
# =============================================================================
echo
echo "Results: ${PASS} passed, ${FAIL} failed"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi

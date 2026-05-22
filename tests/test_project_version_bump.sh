#!/usr/bin/env bash
# Test: Milestone 76 — compute_next_version + bump_version_files
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
# compute_next_version — semver tests
# =============================================================================
echo "=== compute_next_version: semver ==="

result=$(compute_next_version "1.2.3" "semver" "patch")
if [[ "$result" == "1.2.4" ]]; then pass "semver patch 1.2.3 → 1.2.4"; else fail "semver patch: got $result"; fi

result=$(compute_next_version "1.2.3" "semver" "minor")
if [[ "$result" == "1.3.0" ]]; then pass "semver minor 1.2.3 → 1.3.0"; else fail "semver minor: got $result"; fi

result=$(compute_next_version "1.2.3" "semver" "major")
if [[ "$result" == "2.0.0" ]]; then pass "semver major 1.2.3 → 2.0.0"; else fail "semver major: got $result"; fi

result=$(compute_next_version "0.0.0" "semver" "patch")
if [[ "$result" == "0.0.1" ]]; then pass "semver patch 0.0.0 → 0.0.1"; else fail "semver patch 0.0.0: got $result"; fi

result=$(compute_next_version "1.2.3-rc.1" "semver" "patch")
if [[ "$result" == "1.2.4" ]]; then pass "semver patch strips prerelease suffix"; else fail "semver prerelease: got $result"; fi

# =============================================================================
# compute_next_version — calver tests
# =============================================================================
echo "=== compute_next_version: calver ==="

today_year=$(date +%Y)
today_month=$(date +%-m)

# Same month → patch increment
result=$(compute_next_version "${today_year}.${today_month}.3" "calver" "patch")
expected="${today_year}.${today_month}.4"
if [[ "$result" == "$expected" ]]; then pass "calver same-month patch → $expected"; else fail "calver same-month: got $result, expected $expected"; fi

# Different month → reset to .0
result=$(compute_next_version "2020.1.5" "calver" "patch")
expected="${today_year}.${today_month}.0"
if [[ "$result" == "$expected" ]]; then pass "calver new-month → $expected"; else fail "calver new-month: got $result, expected $expected"; fi

# =============================================================================
# compute_next_version — datestamp
# =============================================================================
echo "=== compute_next_version: datestamp ==="

result=$(compute_next_version "2020-01-01" "datestamp" "patch")
expected=$(date +%Y-%m-%d)
if [[ "$result" == "$expected" ]]; then pass "datestamp → $expected"; else fail "datestamp: got $result, expected $expected"; fi

# =============================================================================
# compute_next_version — none
# =============================================================================
echo "=== compute_next_version: none ==="

result=$(compute_next_version "1.2.3" "none" "patch")
if [[ "$result" == "1.2.3" ]]; then pass "strategy=none is no-op"; else fail "strategy=none: got $result"; fi

# =============================================================================
# compute_next_version — milestone
# =============================================================================
echo "=== compute_next_version: milestone ==="

result=$(compute_next_version "3.111.0" "milestone" "milestone:119")
if [[ "$result" == "3.119.0" ]]; then pass "milestone completion sets MINOR to milestone and resets patch"; else fail "milestone completion: got $result"; fi

result=$(compute_next_version "3.119.0" "milestone" "patch")
if [[ "$result" == "3.119.1" ]]; then pass "milestone strategy patch increments PATCH only"; else fail "milestone patch: got $result"; fi

result=$(compute_next_version "3.119.7" "milestone" "milestone:120")
if [[ "$result" == "3.120.0" ]]; then pass "next milestone resets patch after note runs"; else fail "milestone reset: got $result"; fi

# =============================================================================
# bump_version_files — package.json
# =============================================================================
echo "=== bump_version_files: package.json ==="

PROJ="${TEST_TMPDIR}/bump_npm"
mkdir -p "$PROJ/.claude"
echo '{"name":"test","version":"1.0.0"}' > "$PROJ/package.json"
cat > "$PROJ/.claude/project_version.cfg" <<'EOF'
VERSION_STRATEGY=semver
VERSION_FILES=package.json:.version
CURRENT_VERSION=1.0.0
EOF

PROJECT_DIR="$PROJ" PROJECT_VERSION_CONFIG=".claude/project_version.cfg" \
    PROJECT_VERSION_ENABLED="true" bump_version_files "patch"

new_ver=$(python3 -c "import json,sys; print(json.load(sys.stdin).get('version',''))" < "$PROJ/package.json")
if [[ "$new_ver" == "1.0.1" ]]; then pass "package.json bumped to 1.0.1"; else fail "package.json bump: got $new_ver"; fi

cached=$(grep 'CURRENT_VERSION=' "$PROJ/.claude/project_version.cfg" | sed 's/CURRENT_VERSION=//')
if [[ "$cached" == "1.0.1" ]]; then pass "cache updated to 1.0.1"; else fail "cache not updated: $cached"; fi

# =============================================================================
# bump_version_files — VERSION plain text
# =============================================================================
echo "=== bump_version_files: VERSION file ==="

PROJ="${TEST_TMPDIR}/bump_plain"
mkdir -p "$PROJ/.claude"
echo "2.5.0" > "$PROJ/VERSION"
cat > "$PROJ/.claude/project_version.cfg" <<'EOF'
VERSION_STRATEGY=semver
VERSION_FILES=VERSION:.
CURRENT_VERSION=2.5.0
EOF

PROJECT_DIR="$PROJ" PROJECT_VERSION_CONFIG=".claude/project_version.cfg" \
    PROJECT_VERSION_ENABLED="true" bump_version_files "minor"

new_ver=$(tr -d '[:space:]' < "$PROJ/VERSION")
if [[ "$new_ver" == "2.6.0" ]]; then pass "VERSION bumped to 2.6.0"; else fail "VERSION bump: got $new_ver"; fi

# =============================================================================
# bump_version_files — user pre-bump detection
# =============================================================================
echo "=== bump_version_files: user pre-bump ==="

PROJ="${TEST_TMPDIR}/prebump"
mkdir -p "$PROJ/.claude"
echo "3.0.0" > "$PROJ/VERSION"
cat > "$PROJ/.claude/project_version.cfg" <<'EOF'
VERSION_STRATEGY=semver
VERSION_FILES=VERSION:.
CURRENT_VERSION=2.0.0
EOF

PROJECT_DIR="$PROJ" PROJECT_VERSION_CONFIG=".claude/project_version.cfg" \
    PROJECT_VERSION_ENABLED="true" bump_version_files "patch"

# Should NOT overwrite user bump; should update cache to 3.0.0
file_ver=$(tr -d '[:space:]' < "$PROJ/VERSION")
cached=$(grep 'CURRENT_VERSION=' "$PROJ/.claude/project_version.cfg" | sed 's/CURRENT_VERSION=//')
if [[ "$file_ver" == "3.0.0" ]]; then pass "user pre-bump preserved"; else fail "user pre-bump overwritten: $file_ver"; fi
if [[ "$cached" == "3.0.0" ]]; then pass "cache updated to user version"; else fail "cache not updated to user version: $cached"; fi

# =============================================================================
# bump_version_files — strategy=none is no-op
# =============================================================================
echo "=== bump_version_files: strategy=none ==="

PROJ="${TEST_TMPDIR}/noop"
mkdir -p "$PROJ/.claude"
echo "1.0.0" > "$PROJ/VERSION"
cat > "$PROJ/.claude/project_version.cfg" <<'EOF'
VERSION_STRATEGY=none
VERSION_FILES=VERSION:.
CURRENT_VERSION=1.0.0
EOF

PROJECT_DIR="$PROJ" PROJECT_VERSION_CONFIG=".claude/project_version.cfg" \
    PROJECT_VERSION_ENABLED="true" bump_version_files "patch"

file_ver=$(tr -d '[:space:]' < "$PROJ/VERSION")
if [[ "$file_ver" == "1.0.0" ]]; then pass "strategy=none no-op"; else fail "strategy=none modified file: $file_ver"; fi

# =============================================================================
# bump_version_files — milestone strategy
# =============================================================================
echo "=== bump_version_files: milestone strategy ==="

PROJ="${TEST_TMPDIR}/bump_milestone"
mkdir -p "$PROJ/.claude"
echo "3.118.2" > "$PROJ/VERSION"
cat > "$PROJ/.claude/project_version.cfg" <<'EOF'
VERSION_STRATEGY=milestone
VERSION_FILES=VERSION:.
CURRENT_VERSION=3.118.2
EOF

PROJECT_DIR="$PROJ" PROJECT_VERSION_CONFIG=".claude/project_version.cfg" \
    PROJECT_VERSION_ENABLED="true" bump_version_files "milestone:119"

new_ver=$(tr -d '[:space:]' < "$PROJ/VERSION")
if [[ "$new_ver" == "3.119.0" ]]; then pass "milestone strategy writes 3.119.0"; else fail "milestone strategy: got $new_ver"; fi

PROJECT_DIR="$PROJ" PROJECT_VERSION_CONFIG=".claude/project_version.cfg" \
    PROJECT_VERSION_ENABLED="true" bump_version_files "patch"

new_ver=$(tr -d '[:space:]' < "$PROJ/VERSION")
if [[ "$new_ver" == "3.119.1" ]]; then pass "milestone strategy patch writes 3.119.1"; else fail "milestone patch write: got $new_ver"; fi

# =============================================================================
# bump_version_files — pyproject.toml
# =============================================================================
echo "=== bump_version_files: pyproject.toml ==="

PROJ="${TEST_TMPDIR}/bump_toml"
mkdir -p "$PROJ/.claude"
cat > "$PROJ/pyproject.toml" <<'TOML'
[project]
name = "myapp"
version = "0.9.0"
TOML
cat > "$PROJ/.claude/project_version.cfg" <<'EOF'
VERSION_STRATEGY=semver
VERSION_FILES=pyproject.toml:.project.version
CURRENT_VERSION=0.9.0
EOF

PROJECT_DIR="$PROJ" PROJECT_VERSION_CONFIG=".claude/project_version.cfg" \
    PROJECT_VERSION_ENABLED="true" bump_version_files "minor"

if grep -q 'version = "0.10.0"' "$PROJ/pyproject.toml"; then
    pass "pyproject.toml bumped to 0.10.0"
else
    fail "pyproject.toml not bumped: $(grep version "$PROJ/pyproject.toml")"
fi

# =============================================================================
# bump_version_files — setup.py (single-quoted)
# =============================================================================
echo "=== bump_version_files: setup.py single-quoted ==="

PROJ="${TEST_TMPDIR}/bump_setup_sq"
mkdir -p "$PROJ/.claude"
cat > "$PROJ/setup.py" <<'PY'
from setuptools import setup
setup(
    name='myapp',
    version='1.0.5',
)
PY
cat > "$PROJ/.claude/project_version.cfg" <<'EOF'
VERSION_STRATEGY=semver
VERSION_FILES=setup.py:.version
CURRENT_VERSION=1.0.5
EOF

PROJECT_DIR="$PROJ" PROJECT_VERSION_CONFIG=".claude/project_version.cfg" \
    PROJECT_VERSION_ENABLED="true" bump_version_files "patch"

if grep -q "version='1.0.6'" "$PROJ/setup.py"; then
    pass "setup.py single-quoted bumped to 1.0.6"
else
    fail "setup.py single-quoted not bumped: $(grep version "$PROJ/setup.py")"
fi

# =============================================================================
# bump_version_files — setup.py (double-quoted)
# =============================================================================
echo "=== bump_version_files: setup.py double-quoted ==="

PROJ="${TEST_TMPDIR}/bump_setup_dq"
mkdir -p "$PROJ/.claude"
cat > "$PROJ/setup.py" <<'PY'
from setuptools import setup
setup(
    name="myapp",
    version="1.0.5",
)
PY
cat > "$PROJ/.claude/project_version.cfg" <<'EOF'
VERSION_STRATEGY=semver
VERSION_FILES=setup.py:.version
CURRENT_VERSION=1.0.5
EOF

PROJECT_DIR="$PROJ" PROJECT_VERSION_CONFIG=".claude/project_version.cfg" \
    PROJECT_VERSION_ENABLED="true" bump_version_files "patch"

if grep -q 'version="1.0.6"' "$PROJ/setup.py"; then
    pass "setup.py double-quoted bumped to 1.0.6"
else
    fail "setup.py double-quoted not bumped or mangled: $(grep version "$PROJ/setup.py")"
fi

# =============================================================================
# bump_version_files — Cargo.toml
# =============================================================================
echo "=== bump_version_files: Cargo.toml ==="

PROJ="${TEST_TMPDIR}/bump_cargo"
mkdir -p "$PROJ/.claude"
cat > "$PROJ/Cargo.toml" <<'TOML'
[package]
name = "myapp"
version = "0.5.0"
edition = "2021"
TOML
cat > "$PROJ/.claude/project_version.cfg" <<'EOF'
VERSION_STRATEGY=semver
VERSION_FILES=Cargo.toml:.package.version
CURRENT_VERSION=0.5.0
EOF

PROJECT_DIR="$PROJ" PROJECT_VERSION_CONFIG=".claude/project_version.cfg" \
    PROJECT_VERSION_ENABLED="true" bump_version_files "minor"

if grep -q 'version = "0.6.0"' "$PROJ/Cargo.toml"; then
    pass "Cargo.toml bumped to 0.6.0"
else
    fail "Cargo.toml not bumped: $(grep version "$PROJ/Cargo.toml")"
fi

cached=$(grep 'CURRENT_VERSION=' "$PROJ/.claude/project_version.cfg" | sed 's/CURRENT_VERSION=//')
if [[ "$cached" == "0.6.0" ]]; then pass "cache updated to 0.6.0"; else fail "cache not updated: $cached"; fi

# =============================================================================
# bump_version_files — Chart.yaml
# =============================================================================
echo "=== bump_version_files: Chart.yaml ==="

PROJ="${TEST_TMPDIR}/bump_chart"
mkdir -p "$PROJ/.claude"
cat > "$PROJ/Chart.yaml" <<'YAML'
apiVersion: v2
name: myapp
description: My Helm chart
version: 2.1.0
appVersion: "1.0"
YAML
cat > "$PROJ/.claude/project_version.cfg" <<'EOF'
VERSION_STRATEGY=semver
VERSION_FILES=Chart.yaml:.version
CURRENT_VERSION=2.1.0
EOF

PROJECT_DIR="$PROJ" PROJECT_VERSION_CONFIG=".claude/project_version.cfg" \
    PROJECT_VERSION_ENABLED="true" bump_version_files "patch"

if grep -q 'version: 2.1.1' "$PROJ/Chart.yaml"; then
    pass "Chart.yaml bumped to 2.1.1"
else
    fail "Chart.yaml not bumped: $(grep version "$PROJ/Chart.yaml")"
fi

cached=$(grep 'CURRENT_VERSION=' "$PROJ/.claude/project_version.cfg" | sed 's/CURRENT_VERSION=//')
if [[ "$cached" == "2.1.1" ]]; then pass "cache updated to 2.1.1"; else fail "cache not updated: $cached"; fi

# =============================================================================
# compute_next_version — MINOR regression guard (post-M23 fix)
# Guards against completing a lower-numbered milestone rewinding VERSION MINOR.
# e.g. completing M23 when M27 was already done must NOT produce 4.23.0.
# =============================================================================
echo "=== compute_next_version: MINOR regression guard ==="

# target_milestone < current_minor → PATCH bump, never rewind MINOR
result=$(compute_next_version "4.27.3" "milestone" "milestone:23")
if [[ "$result" == "4.27.4" ]]; then pass "minor guard: lower milestone produces PATCH not MINOR rewind"; else fail "minor guard lower: got $result (want 4.27.4)"; fi

# target_milestone == current_minor → PATCH bump, not reset-to-zero
result=$(compute_next_version "4.23.0" "milestone" "milestone:23")
if [[ "$result" == "4.23.1" ]]; then pass "minor guard: same milestone number produces PATCH not 0-reset"; else fail "minor guard equal: got $result (want 4.23.1)"; fi

# Non-numeric milestone suffix → version unchanged (guard also covers this)
result=$(compute_next_version "4.23.1" "milestone" "milestone:foo")
if [[ "$result" == "4.23.1" ]]; then pass "minor guard: non-numeric milestone ID leaves version unchanged"; else fail "minor guard non-numeric: got $result (want 4.23.1)"; fi



# =============================================================================
# Summary
# =============================================================================
echo
echo "Results: ${PASS} passed, ${FAIL} failed"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi

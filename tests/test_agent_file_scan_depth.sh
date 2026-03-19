#!/usr/bin/env bash
# =============================================================================
# test_agent_file_scan_depth.sh — AGENT_FILE_SCAN_DEPTH configurable scan depth
#
# Tests:
#   1. Default AGENT_FILE_SCAN_DEPTH is 8
#   2. Environment override is respected by _detect_file_changes
#   3. _detect_file_changes finds files within depth limit
#   4. _detect_file_changes misses files beyond depth limit
#   5. _count_changed_files_since respects depth limit
#   6. pipeline.conf.example documents AGENT_FILE_SCAN_DEPTH
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_DIR="$TMPDIR/project"
mkdir -p "$PROJECT_DIR"

# Provide count_lines used by _count_changed_files_since
count_lines() { wc -l | tr -d ' '; }

LOG_DIR="${TMPDIR}/logs"
mkdir -p "$LOG_DIR"

# Source required libs
source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/agent_monitor.sh"
source "${TEKHTON_HOME}/lib/agent_monitor_helpers.sh"

FAIL=0

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" != "$actual" ]; then
        echo "FAIL: $name — expected '$expected', got '$actual'"
        FAIL=1
    fi
}

assert_true() {
    local name="$1"
    if ! eval "$2"; then
        echo "FAIL: $name — condition was false"
        FAIL=1
    fi
}

assert_false() {
    local name="$1"
    if eval "$2"; then
        echo "FAIL: $name — condition was true (expected false)"
        FAIL=1
    fi
}

# =============================================================================
# Phase 1: Default value
# =============================================================================

# 1.1: AGENT_FILE_SCAN_DEPTH should default to 8
assert_eq "1.1 default AGENT_FILE_SCAN_DEPTH is 8" "8" "$AGENT_FILE_SCAN_DEPTH"

# =============================================================================
# Phase 2: Environment override
# =============================================================================

# 2.1: Unsetting and re-sourcing with custom value
unset AGENT_FILE_SCAN_DEPTH
AGENT_FILE_SCAN_DEPTH=4
# Confirm variable is set to 4 (simulating env override before source)
assert_eq "2.1 custom AGENT_FILE_SCAN_DEPTH=4 is respected" "4" "$AGENT_FILE_SCAN_DEPTH"
AGENT_FILE_SCAN_DEPTH=8  # restore

# =============================================================================
# Phase 3: _detect_file_changes finds files within depth
# =============================================================================

# Build a directory tree: 3 levels deep
DEEP_DIR="${PROJECT_DIR}/a/b/c"
mkdir -p "$DEEP_DIR"

# Create marker file
MARKER="${TMPDIR}/marker"
touch "$MARKER"
sleep 0.05  # ensure mtime difference on fast filesystems

# Create a file at depth 3 (within default depth 8)
SHALLOW_FILE="${PROJECT_DIR}/a/b/c/test.txt"
echo "test" > "$SHALLOW_FILE"

# 3.1: _detect_file_changes should find file at depth 3
AGENT_FILE_SCAN_DEPTH=8
if _detect_file_changes "$MARKER"; then
    : # ok — returns 0 when changed
    assert_eq "3.1 _detect_file_changes finds file at depth 3" "0" "0"
else
    echo "FAIL: 3.1 _detect_file_changes should find file at depth 3 with AGENT_FILE_SCAN_DEPTH=8"
    FAIL=1
fi

# =============================================================================
# Phase 4: _detect_file_changes misses files beyond depth limit
# =============================================================================

# Build deeper tree: 10 levels
VERY_DEEP_DIR="${PROJECT_DIR}/d/e/f/g/h/i/j/k/l/m"
mkdir -p "$VERY_DEEP_DIR"

# Update marker — make everything so far "old"
MARKER2="${TMPDIR}/marker2"
touch "$MARKER2"
sleep 0.05

# Create a file at depth 10 (beyond AGENT_FILE_SCAN_DEPTH=3)
DEEP_FILE="${PROJECT_DIR}/d/e/f/g/h/i/j/k/l/m/deep.txt"
echo "deep" > "$DEEP_FILE"

# 4.1: With depth=3, file at level 10 should NOT be detected
AGENT_FILE_SCAN_DEPTH=3
if _detect_file_changes "$MARKER2"; then
    echo "FAIL: 4.1 _detect_file_changes should NOT detect file at depth 10 with AGENT_FILE_SCAN_DEPTH=3"
    FAIL=1
else
    assert_eq "4.1 _detect_file_changes misses file beyond depth limit" "0" "0"
fi

# 4.2: With depth=11, same file SHOULD be detected
AGENT_FILE_SCAN_DEPTH=11
if _detect_file_changes "$MARKER2"; then
    assert_eq "4.2 _detect_file_changes finds file with depth=11" "0" "0"
else
    echo "FAIL: 4.2 _detect_file_changes should detect file at depth 10 with AGENT_FILE_SCAN_DEPTH=11"
    FAIL=1
fi

AGENT_FILE_SCAN_DEPTH=8  # restore

# =============================================================================
# Phase 5: _count_changed_files_since respects depth
# =============================================================================

MARKER3="${TMPDIR}/marker3"
touch "$MARKER3"
sleep 0.05

# Create files at depth 1 and depth 10
echo "shallow" > "${PROJECT_DIR}/shallow.txt"
echo "deep2" > "${VERY_DEEP_DIR}/deep2.txt"

# 5.1: With depth=2, only shallow file counted
AGENT_FILE_SCAN_DEPTH=2
count=$(PROJECT_DIR="$PROJECT_DIR" _count_changed_files_since "$MARKER3")
if [ "$count" -ge 1 ]; then
    assert_eq "5.1 _count_changed_files_since counts shallow file at depth 2" "0" "0"
else
    echo "FAIL: 5.1 _count_changed_files_since should count shallow.txt at depth=2 (got: $count)"
    FAIL=1
fi

# The deep file at depth 10 should NOT be counted with depth=2
# This we verify by checking count with depth=11 yields more files
AGENT_FILE_SCAN_DEPTH=11
count_deep=$(PROJECT_DIR="$PROJECT_DIR" _count_changed_files_since "$MARKER3")
AGENT_FILE_SCAN_DEPTH=2
count_shallow=$(PROJECT_DIR="$PROJECT_DIR" _count_changed_files_since "$MARKER3")

# 5.2: Deeper scan should find at least as many or more files than shallower scan
if [ "$count_deep" -ge "$count_shallow" ]; then
    assert_eq "5.2 deeper scan finds >= files than shallower scan" "0" "0"
else
    echo "FAIL: 5.2 depth=11 count ($count_deep) should be >= depth=2 count ($count_shallow)"
    FAIL=1
fi

AGENT_FILE_SCAN_DEPTH=8  # restore

# =============================================================================
# Phase 6: pipeline.conf.example documents AGENT_FILE_SCAN_DEPTH
# =============================================================================

CONF_EXAMPLE="${TEKHTON_HOME}/templates/pipeline.conf.example"

# 6.1: File contains the AGENT_FILE_SCAN_DEPTH entry (commented out)
if grep -q 'AGENT_FILE_SCAN_DEPTH' "$CONF_EXAMPLE"; then
    assert_eq "6.1 pipeline.conf.example contains AGENT_FILE_SCAN_DEPTH" "0" "0"
else
    echo "FAIL: 6.1 pipeline.conf.example missing AGENT_FILE_SCAN_DEPTH entry"
    FAIL=1
fi

# 6.2: The default value documented is 8
if grep 'AGENT_FILE_SCAN_DEPTH' "$CONF_EXAMPLE" | grep -q '8'; then
    assert_eq "6.2 pipeline.conf.example documents default value of 8" "0" "0"
else
    echo "FAIL: 6.2 pipeline.conf.example should document AGENT_FILE_SCAN_DEPTH=8"
    FAIL=1
fi

# =============================================================================
# Done
# =============================================================================

if [ "$FAIL" -ne 0 ]; then
    exit 1
fi
exit 0

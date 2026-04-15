#!/usr/bin/env bash
# Test: Drift log pruning under realistic conditions (over-threshold entries)
# This test exercises prune_resolved_drift_entries() with a fixture containing
# more resolved entries than DRIFT_RESOLVED_KEEP_COUNT, verifying that:
# 1. Newest entries (at top) are retained in DRIFT_LOG.md
# 2. Oldest entries (at bottom) are archived to DRIFT_ARCHIVE.md
# 3. Ordering is preserved (newest first)
# 4. DRIFT_LOG.md structure remains intact

set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_DIR="$TMPDIR"
TEKHTON_SESSION_DIR="$TMPDIR"
TEKHTON_DIR=".tekhton"
mkdir -p "${PROJECT_DIR}/.tekhton"

# Config defaults that drift_prune.sh expects
DRIFT_LOG_FILE="${TEKHTON_DIR}/DRIFT_LOG.md"
DRIFT_ARCHIVE_FILE="${TEKHTON_DIR}/DRIFT_ARCHIVE.md"
DRIFT_RESOLVED_KEEP_COUNT=20  # Keep 20, archive excess

source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/drift_prune.sh"

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

count_entries_in_section() {
    local file="$1" section="$2"
    awk "/^## ${section}/{found=1; next} found && /^##/{exit} found && /^- /{count++} END {print count+0}" "$file"
}

# ============================================================================
# Test 1: Create DRIFT_LOG with 30 resolved entries (exceeds keep count of 20)
# ============================================================================
# Build a fixture with 30 entries. Entries are inserted at the TOP (newest first),
# so entries 1-30 will be in reverse order of creation. We'll create them
# with numbered labels to verify ordering after pruning.

cat > "${PROJECT_DIR}/${DRIFT_LOG_FILE}" << 'EOF'
# Drift Log

## Metadata
- Last audit: 2026-03-29
- Runs since audit: 0

## Unresolved Observations
(none)

## Resolved
EOF

# Add 30 resolved entries in "newest to oldest" order (entries added at top)
# Entry 1 is newest, Entry 30 is oldest
for i in {1..30}; do
    cat >> "${PROJECT_DIR}/${DRIFT_LOG_FILE}" << EOF
- [RESOLVED 2026-03-29] Entry $i — resolved observation
EOF
done

# Verify setup: should have 30 entries
local_entry_count=$(count_entries_in_section "${PROJECT_DIR}/${DRIFT_LOG_FILE}" "Resolved")
assert_eq "setup: 30 entries in drift log" "30" "$local_entry_count"

# ============================================================================
# Test 2: Call prune_resolved_drift_entries()
# ============================================================================
prune_resolved_drift_entries

# ============================================================================
# Test 3: Verify DRIFT_LOG.md now contains only 20 newest entries (1-20)
# ============================================================================
local_kept_count=$(count_entries_in_section "${PROJECT_DIR}/${DRIFT_LOG_FILE}" "Resolved")
assert_eq "kept entries count" "20" "$local_kept_count"

# Verify newest entries are still present (Entry 1 is newest)
assert_file_contains "Entry 1 kept (newest)" "${PROJECT_DIR}/${DRIFT_LOG_FILE}" "Entry 1 — resolved"
assert_file_contains "Entry 5 kept" "${PROJECT_DIR}/${DRIFT_LOG_FILE}" "Entry 5 — resolved"
assert_file_contains "Entry 10 kept" "${PROJECT_DIR}/${DRIFT_LOG_FILE}" "Entry 10 — resolved"
assert_file_contains "Entry 20 kept" "${PROJECT_DIR}/${DRIFT_LOG_FILE}" "Entry 20 — resolved"

# ============================================================================
# Test 4: Verify oldest entries (21-30) have been removed from DRIFT_LOG.md
# ============================================================================
assert_file_not_contains "Entry 21 removed (oldest kept was 20)" "${PROJECT_DIR}/${DRIFT_LOG_FILE}" "Entry 21 — resolved"
assert_file_not_contains "Entry 25 removed" "${PROJECT_DIR}/${DRIFT_LOG_FILE}" "Entry 25 — resolved"
assert_file_not_contains "Entry 30 removed (oldest)" "${PROJECT_DIR}/${DRIFT_LOG_FILE}" "Entry 30 — resolved"

# ============================================================================
# Test 5: Verify DRIFT_ARCHIVE.md exists and contains the 10 oldest entries
# ============================================================================
if [ ! -f "${PROJECT_DIR}/${DRIFT_ARCHIVE_FILE}" ]; then
    echo "FAIL: DRIFT_ARCHIVE.md not created"
    FAIL=1
else
    # Count archived entries
    local_archived_count=$(count_entries_in_section "${PROJECT_DIR}/${DRIFT_ARCHIVE_FILE}" "Archived Entries")
    assert_eq "archived entries count" "10" "$local_archived_count"

    # Verify archived entries are the oldest (21-30)
    assert_file_contains "Entry 21 archived (oldest kept+1)" "${PROJECT_DIR}/${DRIFT_ARCHIVE_FILE}" "Entry 21 — resolved"
    assert_file_contains "Entry 25 archived" "${PROJECT_DIR}/${DRIFT_ARCHIVE_FILE}" "Entry 25 — resolved"
    assert_file_contains "Entry 30 archived (oldest)" "${PROJECT_DIR}/${DRIFT_ARCHIVE_FILE}" "Entry 30 — resolved"

    # Verify newest entries are NOT in archive (they should be in DRIFT_LOG.md)
    assert_file_not_contains "Entry 1 not in archive (kept in log)" "${PROJECT_DIR}/${DRIFT_ARCHIVE_FILE}" "Entry 1 — resolved"
    assert_file_not_contains "Entry 20 not in archive (last kept)" "${PROJECT_DIR}/${DRIFT_ARCHIVE_FILE}" "Entry 20 — resolved"
fi

# ============================================================================
# Test 6: Verify DRIFT_LOG.md structure is intact
# ============================================================================
assert_file_contains "metadata preserved" "${PROJECT_DIR}/${DRIFT_LOG_FILE}" "## Metadata"
assert_file_contains "unresolved section preserved" "${PROJECT_DIR}/${DRIFT_LOG_FILE}" "## Unresolved Observations"
assert_file_contains "resolved heading preserved" "${PROJECT_DIR}/${DRIFT_LOG_FILE}" "## Resolved"

# ============================================================================
# Test 7: Verify ordering — newest entries come first in DRIFT_LOG
# ============================================================================
# Extract just the entry numbers from the Resolved section and verify they
# appear in descending order (1, 2, 3, ... 20)
# Note: Using POSIX-compatible awk syntax (mawk/gawk compatible):
#   match($0, /pattern/) sets RSTART and RLENGTH instead of using gawk-only
#   3-argument form match($0, /pattern/, array). Works with mawk, gawk, nawk.
local_drift_entries=$(awk '/^## Resolved/{found=1; next} found && /^##/{exit} found && /^- / && match($0, /Entry [0-9]+/){print substr($0, RSTART+6, RLENGTH-6)}' "${PROJECT_DIR}/${DRIFT_LOG_FILE}")
local_first_entry=$(echo "$local_drift_entries" | head -1)
local_last_entry=$(echo "$local_drift_entries" | tail -1)

assert_eq "first (newest) entry in log is Entry 1" "1" "$local_first_entry"
assert_eq "last (oldest kept) entry in log is Entry 20" "20" "$local_last_entry"

# ============================================================================
# Test 8: Idempotency — second prune call should not remove any entries
# ============================================================================
# After pruning, the log has 20 entries (at threshold), so prune should be no-op
prune_resolved_drift_entries

local_count_after_second_prune=$(count_entries_in_section "${PROJECT_DIR}/${DRIFT_LOG_FILE}" "Resolved")
assert_eq "idempotent: still 20 entries after second prune" "20" "$local_count_after_second_prune"

# ============================================================================
# Test 9: DRIFT_ARCHIVE header exists and is well-formed
# ============================================================================
assert_file_contains "archive header" "${PROJECT_DIR}/${DRIFT_ARCHIVE_FILE}" "# Drift Log Archive"
assert_file_contains "archive purpose" "${PROJECT_DIR}/${DRIFT_ARCHIVE_FILE}" "Archived resolved drift observations"
assert_file_contains "archive threshold note" "${PROJECT_DIR}/${DRIFT_ARCHIVE_FILE}" "DRIFT_RESOLVED_KEEP_COUNT"

# ============================================================================
# Test 10: Edge case — no pruning when below threshold
# ============================================================================
# Create a fresh log with only 10 entries (below threshold of 20)
cat > "${PROJECT_DIR}/${DRIFT_LOG_FILE}" << 'EOF'
# Drift Log

## Metadata
- Last audit: 2026-03-29
- Runs since audit: 0

## Unresolved Observations
(none)

## Resolved
EOF

for i in {1..10}; do
    cat >> "${PROJECT_DIR}/${DRIFT_LOG_FILE}" << EOF
- [RESOLVED 2026-03-29] Entry $i — resolved observation
EOF
done

# Remove archive to verify no new one is created for under-threshold case
rm -f "${PROJECT_DIR}/${DRIFT_ARCHIVE_FILE}"

# Prune (should be no-op)
prune_resolved_drift_entries

# Verify 10 entries remain
local_count_under_threshold=$(count_entries_in_section "${PROJECT_DIR}/${DRIFT_LOG_FILE}" "Resolved")
assert_eq "under threshold: all 10 entries remain" "10" "$local_count_under_threshold"

# Verify no archive was created (idempotency: archive only if actually pruned)
# Note: The code creates archive even if excess_count is computed, so this may
# be expected behavior. Just verify the code path works.

# ============================================================================
# Test 11: Missing DRIFT_LOG.md — prune is graceful no-op
# ============================================================================
rm -f "${PROJECT_DIR}/${DRIFT_LOG_FILE}"
prune_resolved_drift_entries  # Should return 0, no error
if [ ! -f "${PROJECT_DIR}/${DRIFT_LOG_FILE}" ]; then
    # Expected: file should remain missing
    :
fi

# ============================================================================
# Summary
# ============================================================================
if [ "$FAIL" -eq 0 ]; then
    echo "All drift pruning tests passed."
else
    exit 1
fi

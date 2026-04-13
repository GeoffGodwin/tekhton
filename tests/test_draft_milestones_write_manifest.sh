#!/usr/bin/env bash
# =============================================================================
# test_draft_milestones_write_manifest.sh — Tests draft_milestones_write_manifest()
#
# Tests:
#   1. Single milestone appended → correct pipe-delimited row format
#   2. First milestone depends on highest existing manifest entry
#   3. Two milestones → second depends on first (linear chain)
#   4. Idempotent — already-present ID is skipped
#   5. Missing milestone file → row skipped, no crash
#   6. Pipe character in title → stripped before write
#   7. Missing MANIFEST.cfg → returns non-zero
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=$(( FAIL + 1 )); }

# Stubs for common.sh functions required by draft_milestones_write.sh
log()     { :; }
warn()    { :; }
error()   { echo "ERROR: $*" >&2; }
success() { :; }
header()  { :; }

# Source the library under test (provides draft_milestones_write_manifest)
# shellcheck source=lib/draft_milestones_write.sh
source "${TEKHTON_HOME}/lib/draft_milestones_write.sh"

export MILESTONE_DIR=".claude/milestones"
export MILESTONE_MANIFEST="MANIFEST.cfg"

# --- Helper: build a minimal MANIFEST.cfg with a header only ----------------
_make_empty_manifest() {
    local dir="$1"
    mkdir -p "${dir}/${MILESTONE_DIR}"
    cat > "${dir}/${MILESTONE_DIR}/${MILESTONE_MANIFEST}" << 'EOF'
# Tekhton Milestone Manifest v1
# id|title|status|depends_on|file|parallel_group
EOF
}

# --- Helper: build a MANIFEST.cfg with existing entries ---------------------
_make_populated_manifest() {
    local dir="$1"
    mkdir -p "${dir}/${MILESTONE_DIR}"
    cat > "${dir}/${MILESTONE_DIR}/${MILESTONE_MANIFEST}" << 'EOF'
# Tekhton Milestone Manifest v1
# id|title|status|depends_on|file|parallel_group
m01|First Milestone|done||m01-first.md|devx
m02|Second Milestone|done|m01|m02-second.md|devx
m10|Tenth Milestone|done|m02|m10-tenth.md|devx
EOF
}

# --- Helper: create a valid milestone file -----------------------------------
_make_milestone_file() {
    local dir="$1"
    local id="$2"
    local title="$3"
    local slug="${4:-test}"
    local ms_dir="${dir}/${MILESTONE_DIR}"
    mkdir -p "$ms_dir"
    local fname="m${id}-${slug}.md"
    cat > "${ms_dir}/${fname}" << EOF
# Milestone ${id}: ${title}
<!-- milestone-meta
id: "${id}"
status: "pending"
-->

## Overview
Test milestone.
EOF
    echo "$fname"
}

# =============================================================================
# Test 1: Single milestone appended → correct pipe-delimited row format
# =============================================================================
{
    local_dir="${TMPDIR}/t1"
    _make_empty_manifest "$local_dir"
    fname=$(_make_milestone_file "$local_dir" "81" "My New Feature" "my-new-feature")

    export PROJECT_DIR="$local_dir"
    draft_milestones_write_manifest "81" "devx"

    manifest="${local_dir}/${MILESTONE_DIR}/${MILESTONE_MANIFEST}"
    if grep -q "^m81|" "$manifest"; then
        pass "Single milestone row appended to manifest"
    else
        fail "Expected m81 row in manifest — not found"
    fi

    # Verify pipe-delimited format: id|title|status|depends_on|file|group
    row=$(grep "^m81|" "$manifest")
    IFS='|' read -r r_id r_title r_status r_dep r_file r_group <<< "$row"
    if [[ "$r_id" == "m81" ]]; then
        pass "Row id field is m81"
    else
        fail "Row id field expected 'm81', got '${r_id}'"
    fi
    if [[ "$r_title" == "My New Feature" ]]; then
        pass "Row title extracted from H1"
    else
        fail "Row title expected 'My New Feature', got '${r_title}'"
    fi
    if [[ "$r_status" == "pending" ]]; then
        pass "Row status is 'pending'"
    else
        fail "Row status expected 'pending', got '${r_status}'"
    fi
    if [[ "$r_file" == "$fname" ]]; then
        pass "Row file field matches milestone filename"
    else
        fail "Row file expected '${fname}', got '${r_file}'"
    fi
    if [[ "$r_group" == "devx" ]]; then
        pass "Row group is 'devx'"
    else
        fail "Row group expected 'devx', got '${r_group}'"
    fi
}

# =============================================================================
# Test 2: First new milestone depends on highest existing manifest entry
# =============================================================================
{
    local_dir="${TMPDIR}/t2"
    _make_populated_manifest "$local_dir"  # highest is m10
    _make_milestone_file "$local_dir" "11" "Eleven" "eleven" > /dev/null

    export PROJECT_DIR="$local_dir"
    draft_milestones_write_manifest "11" "devx"

    manifest="${local_dir}/${MILESTONE_DIR}/${MILESTONE_MANIFEST}"
    row=$(grep "^m11|" "$manifest")
    IFS='|' read -r _ _ _ r_dep _ _ <<< "$row"
    if [[ "$r_dep" == "m10" ]]; then
        pass "First new milestone depends on highest existing (m10)"
    else
        fail "Expected depends_on=m10, got '${r_dep}'"
    fi
}

# =============================================================================
# Test 3: Two milestones → second depends on first (linear chain)
# =============================================================================
{
    local_dir="${TMPDIR}/t3"
    _make_populated_manifest "$local_dir"  # highest is m10
    _make_milestone_file "$local_dir" "11" "Eleven" "eleven" > /dev/null
    _make_milestone_file "$local_dir" "12" "Twelve" "twelve" > /dev/null

    export PROJECT_DIR="$local_dir"
    draft_milestones_write_manifest "11 12" "devx"

    manifest="${local_dir}/${MILESTONE_DIR}/${MILESTONE_MANIFEST}"

    row11=$(grep "^m11|" "$manifest")
    IFS='|' read -r _ _ _ dep11 _ _ <<< "$row11"
    row12=$(grep "^m12|" "$manifest")
    IFS='|' read -r _ _ _ dep12 _ _ <<< "$row12"

    if [[ "$dep11" == "m10" ]]; then
        pass "m11 depends on m10 (highest existing)"
    else
        fail "m11 should depend on m10, got '${dep11}'"
    fi
    if [[ "$dep12" == "m11" ]]; then
        pass "m12 depends on m11 (linear chain)"
    else
        fail "m12 should depend on m11, got '${dep12}'"
    fi
}

# =============================================================================
# Test 4: Idempotent — already-present ID is skipped, no duplicate row
# =============================================================================
{
    local_dir="${TMPDIR}/t4"
    _make_populated_manifest "$local_dir"  # contains m01, m02, m10
    _make_milestone_file "$local_dir" "02" "Second Milestone" "second" > /dev/null

    export PROJECT_DIR="$local_dir"
    draft_milestones_write_manifest "02" "devx"

    manifest="${local_dir}/${MILESTONE_DIR}/${MILESTONE_MANIFEST}"
    row_count=$(grep -c "^m02|" "$manifest" || true)
    if [[ "$row_count" -eq 1 ]]; then
        pass "Existing milestone m02 skipped — no duplicate row"
    else
        fail "Expected 1 row for m02, got ${row_count}"
    fi
}

# =============================================================================
# Test 5: Missing milestone file → row skipped, function exits cleanly
# =============================================================================
{
    local_dir="${TMPDIR}/t5"
    _make_empty_manifest "$local_dir"
    # Do NOT create the milestone file for id 99

    export PROJECT_DIR="$local_dir"
    draft_milestones_write_manifest "99" "devx"

    manifest="${local_dir}/${MILESTONE_DIR}/${MILESTONE_MANIFEST}"
    if grep -q "^m99|" "$manifest"; then
        fail "No milestone file for m99 — row should not appear"
    else
        pass "Missing milestone file → row skipped"
    fi
}

# =============================================================================
# Test 6: Pipe character in title → stripped before write
# =============================================================================
{
    local_dir="${TMPDIR}/t6"
    _make_empty_manifest "$local_dir"

    # Write a milestone file whose H1 contains a pipe in the title
    ms_dir="${local_dir}/${MILESTONE_DIR}"
    mkdir -p "$ms_dir"
    cat > "${ms_dir}/m82-pipe-test.md" << 'EOF'
# Milestone 82: Title With | Pipe Character
<!-- milestone-meta
id: "82"
status: "pending"
-->

## Overview
Test.
EOF

    export PROJECT_DIR="$local_dir"
    draft_milestones_write_manifest "82" "devx"

    manifest="${local_dir}/${MILESTONE_DIR}/${MILESTONE_MANIFEST}"
    row=$(grep "^m82|" "$manifest")
    IFS='|' read -r _ r_title _ _ _ _ <<< "$row"
    if echo "$r_title" | grep -q "|"; then
        fail "Pipe character found in title field after sanitization: '${r_title}'"
    else
        pass "Pipe character stripped from title (got: '${r_title}')"
    fi
    # The row should still have the right number of fields (6 pipes total → 6 delimiters)
    field_count=$(echo "$row" | awk -F'|' '{print NF}')
    if [[ "$field_count" -eq 6 ]]; then
        pass "Pipe-sanitized row has correct field count (6)"
    else
        fail "Expected 6 fields in row after pipe sanitization, got ${field_count}: '${row}'"
    fi
}

# =============================================================================
# Test 7: Missing MANIFEST.cfg → returns non-zero
# =============================================================================
{
    local_dir="${TMPDIR}/t7"
    mkdir -p "${local_dir}/${MILESTONE_DIR}"
    # Do NOT create the manifest file

    export PROJECT_DIR="$local_dir"
    if draft_milestones_write_manifest "81" "devx" 2>/dev/null; then
        fail "Missing MANIFEST.cfg should return non-zero"
    else
        pass "Missing MANIFEST.cfg → returns non-zero"
    fi
}

# =============================================================================
echo
if [[ "$FAIL" -gt 0 ]]; then
    echo "FAILED: ${FAIL} test(s)"
    exit 1
fi
echo "All draft_milestones_write_manifest tests passed."

#!/usr/bin/env bash
# Test: migrate_legacy_notes() edge case — notes file with no ## heading
# Verifies the fixed no-heading fallback path (the M40 blocker bug).
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# =============================================================================
# Section 1: Syntax / static analysis
# =============================================================================

if bash -n "${TEKHTON_HOME}/lib/notes_migrate.sh" 2>/dev/null; then
    pass "bash -n lib/notes_migrate.sh passes"
else
    fail "bash -n lib/notes_migrate.sh: syntax error"
fi

if command -v shellcheck &>/dev/null; then
    if shellcheck "${TEKHTON_HOME}/lib/notes_migrate.sh" 2>/dev/null; then
        pass "shellcheck lib/notes_migrate.sh passes"
    else
        fail "shellcheck lib/notes_migrate.sh: warnings or errors"
    fi
else
    echo "  SKIP: shellcheck not installed"
fi

# =============================================================================
# Section 2: migrate_legacy_notes() — no-heading path
#
# The blocker bug: when HUMAN_NOTES.md has no "# heading" line the function
# must prepend the v2 marker via a group redirect into tmpfile2.  The bug was
# writing to stdout (leaving tmpfile2 empty), so the notes file ended up empty
# after the mv.  This test verifies the fix is in place.
# =============================================================================

_run_migrate() {
    local proj_dir="$1"
    (
        cd "$proj_dir"
        mkdir -p "${TEKHTON_DIR:-.tekhton}"
        HUMAN_NOTES_FILE="${TEKHTON_DIR}/HUMAN_NOTES.md"
        export PROJECT_DIR="$proj_dir" HUMAN_NOTES_FILE
        log()     { :; }
        warn()    { :; }
        error()   { :; }
        success() { :; }
        header()  { :; }
        # shellcheck source=../lib/common.sh
        source "${TEKHTON_HOME}/lib/common.sh"
        log()     { :; }
        warn()    { :; }
        error()   { :; }
        success() { :; }
        header()  { :; }
        source "${TEKHTON_HOME}/lib/notes_core.sh"
        source "${TEKHTON_HOME}/lib/notes_cli.sh"
        source "${TEKHTON_HOME}/lib/notes_migrate.sh"
        migrate_legacy_notes
    )
}

# --- Test: no-heading file is non-empty after migration ----------------------
PROJ1="${TEST_TMPDIR}/proj_no_heading"
mkdir -p "${PROJ1}/.tekhton"
cat > "${PROJ1}/.tekhton/HUMAN_NOTES.md" << 'EOF'
- [ ] Fix the login bug
- [ ] Add export feature
EOF

_run_migrate "$PROJ1"
if [[ $? -eq 0 ]]; then
    # File must not be empty
    if [[ -s "${PROJ1}/.tekhton/HUMAN_NOTES.md" ]]; then
        pass "no-heading file: non-empty after migration"
    else
        fail "no-heading file: HUMAN_NOTES.md is empty after migration (data-loss regression)"
    fi
else
    fail "no-heading file: migrate_legacy_notes returned non-zero"
fi

# --- Test: v2 marker is present after migration of no-heading file -----------
if grep -qF "<!-- notes-format: v2 -->" "${PROJ1}/.tekhton/HUMAN_NOTES.md" 2>/dev/null; then
    pass "no-heading file: v2 format marker present after migration"
else
    fail "no-heading file: v2 format marker missing after migration"
fi

# --- Test: original notes are preserved after migration ----------------------
if grep -q "Fix the login bug" "${PROJ1}/.tekhton/HUMAN_NOTES.md" 2>/dev/null \
   && grep -q "Add export feature" "${PROJ1}/.tekhton/HUMAN_NOTES.md" 2>/dev/null; then
    pass "no-heading file: original note text preserved after migration"
else
    fail "no-heading file: original note text lost after migration"
fi

# --- Test: IDs assigned to notes in no-heading file --------------------------
if grep -q "<!-- note:n" "${PROJ1}/.tekhton/HUMAN_NOTES.md" 2>/dev/null; then
    pass "no-heading file: note IDs assigned after migration"
else
    fail "no-heading file: note IDs not assigned after migration"
fi

# --- Test: backup file created -----------------------------------------------
if [[ -f "${PROJ1}/.tekhton/HUMAN_NOTES.md.v1-backup" ]]; then
    pass "no-heading file: .v1-backup created"
else
    fail "no-heading file: .v1-backup not created"
fi

# --- Test: migration is idempotent (second call is a no-op) ------------------
checksum_before=$(md5sum "${PROJ1}/.tekhton/HUMAN_NOTES.md" 2>/dev/null || sha256sum "${PROJ1}/.tekhton/HUMAN_NOTES.md" | cut -d' ' -f1)
_run_migrate "$PROJ1"
checksum_after=$(md5sum "${PROJ1}/.tekhton/HUMAN_NOTES.md" 2>/dev/null || sha256sum "${PROJ1}/.tekhton/HUMAN_NOTES.md" | cut -d' ' -f1)
if [[ "$checksum_before" == "$checksum_after" ]]; then
    pass "idempotency: second migration call does not modify already-migrated file"
else
    fail "idempotency: file changed on second call (migration not idempotent)"
fi

# --- Test: file with heading gets marker AFTER the heading -------------------
PROJ2="${TEST_TMPDIR}/proj_with_heading"
mkdir -p "${PROJ2}/.tekhton"
cat > "${PROJ2}/.tekhton/HUMAN_NOTES.md" << 'EOF'
# Human Notes

- [ ] Fix button styling
- [ ] Refactor auth module
EOF

_run_migrate "$PROJ2"

# Marker must appear after the heading, not before
heading_line=$(grep -n "^# Human Notes" "${PROJ2}/.tekhton/HUMAN_NOTES.md" | cut -d: -f1 | head -1)
marker_line=$(grep -n "notes-format: v2" "${PROJ2}/.tekhton/HUMAN_NOTES.md" | cut -d: -f1 | head -1)
if [[ -n "$heading_line" ]] && [[ -n "$marker_line" ]] && [[ "$marker_line" -gt "$heading_line" ]]; then
    pass "with-heading file: marker appears after heading (not prepended)"
else
    fail "with-heading file: marker placement wrong (heading_line=${heading_line:-?} marker_line=${marker_line:-?})"
fi

# --- Test: absent HUMAN_NOTES.md → returns 0 without creating file -----------
PROJ3="${TEST_TMPDIR}/proj_absent"
mkdir -p "$PROJ3"
_run_migrate "$PROJ3"
if [[ $? -eq 0 ]]; then
    if [[ ! -f "${PROJ3}/.tekhton/HUMAN_NOTES.md" ]]; then
        pass "absent file: no file created, returns 0"
    else
        fail "absent file: unexpectedly created HUMAN_NOTES.md"
    fi
else
    fail "absent file: returned non-zero"
fi

# --- Test: file with no note lines (only text) → returns 0 unchanged ---------
PROJ4="${TEST_TMPDIR}/proj_no_notes"
mkdir -p "${PROJ4}/.tekhton"
cat > "${PROJ4}/.tekhton/HUMAN_NOTES.md" << 'EOF'
# Human Notes

Some descriptive text only.
No checkbox notes here.
EOF
_run_migrate "$PROJ4"
# Should detect no notes to migrate and skip
if grep -qF "<!-- notes-format: v2 -->" "${PROJ4}/.tekhton/HUMAN_NOTES.md" 2>/dev/null; then
    fail "no-notes file: v2 marker was written (should skip when no checkbox lines)"
else
    pass "no-notes file: migration skipped when no checkbox note lines"
fi

# =============================================================================
# Summary
# =============================================================================

echo
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

[[ "$FAIL" -eq 0 ]]

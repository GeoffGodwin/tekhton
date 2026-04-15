#!/usr/bin/env bash
# Test: drain_pending_inbox() in lib/inbox.sh — the pre-commit drain path (M40).
# drain_pending_inbox processes only note_*.md files; it does NOT touch
# milestone files, manifest appends, or task files.
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

if bash -n "${TEKHTON_HOME}/lib/inbox.sh" 2>/dev/null; then
    pass "bash -n lib/inbox.sh passes"
else
    fail "bash -n lib/inbox.sh: syntax error"
fi

# =============================================================================
# Helper: run drain_pending_inbox in an isolated subshell
# =============================================================================

_run_drain() {
    local proj_dir="$1"
    (
        cd "$proj_dir"
        TEKHTON_DIR=".tekhton"
        mkdir -p "${TEKHTON_DIR}"
        export PROJECT_DIR="$proj_dir"
        HUMAN_NOTES_FILE="${TEKHTON_DIR}/HUMAN_NOTES.md"
        export HUMAN_NOTES_FILE
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
        source "${TEKHTON_HOME}/lib/inbox.sh"
        drain_pending_inbox
    )
}

# =============================================================================
# Section 2: drain_pending_inbox() behavior tests
# =============================================================================

# --- Test: absent inbox directory → returns 0, no side effects ---------------
PROJ1="${TEST_TMPDIR}/proj_absent"
mkdir -p "$PROJ1"
_run_drain "$PROJ1"
if [[ $? -eq 0 ]]; then
    pass "absent inbox: returns 0 without error"
else
    fail "absent inbox: unexpected non-zero exit"
fi

# --- Test: empty inbox directory → returns 0 ---------------------------------
PROJ2="${TEST_TMPDIR}/proj_empty"
mkdir -p "${PROJ2}/.claude/watchtower_inbox"
_run_drain "$PROJ2"
if [[ $? -eq 0 ]]; then
    if [[ ! -f "${PROJ2}/.tekhton/HUMAN_NOTES.md" ]] || ! grep -q "^- \[ \]" "${PROJ2}/.tekhton/HUMAN_NOTES.md" 2>/dev/null; then
        pass "empty inbox: no notes created, returns 0"
    else
        fail "empty inbox: unexpected entries in HUMAN_NOTES.md"
    fi
else
    fail "empty inbox: unexpected non-zero exit"
fi

# --- Test: note file processed → appended to HUMAN_NOTES.md, moved to processed
PROJ3="${TEST_TMPDIR}/proj_note"
mkdir -p "${PROJ3}/.claude/watchtower_inbox"
cat > "${PROJ3}/.claude/watchtower_inbox/note_mid_run_BUG.md" << 'EOF'
<!-- watchtower-note -->
- [ ] [BUG] Mid-run bug discovered by watchtower
EOF
_run_drain "$PROJ3"
if [[ $? -eq 0 ]]; then
    if grep -q "Mid-run bug discovered by watchtower" "${PROJ3}/.tekhton/HUMAN_NOTES.md" 2>/dev/null; then
        pass "note file: title appended to HUMAN_NOTES.md"
    else
        fail "note file: title not found in HUMAN_NOTES.md"
    fi
else
    fail "note file: drain returned non-zero"
fi

if [[ -f "${PROJ3}/.claude/watchtower_inbox/processed/note_mid_run_BUG.md" ]]; then
    pass "note file: moved to processed/ after drain"
else
    fail "note file: not moved to processed/"
fi

if [[ ! -f "${PROJ3}/.claude/watchtower_inbox/note_mid_run_BUG.md" ]]; then
    pass "note file: removed from inbox after drain"
else
    fail "note file: still present in inbox after drain"
fi

# --- Test: task file in inbox → NOT touched by drain_pending_inbox -----------
PROJ4="${TEST_TMPDIR}/proj_task_skip"
mkdir -p "${PROJ4}/.claude/watchtower_inbox"
cat > "${PROJ4}/.claude/watchtower_inbox/task_9001.txt" << 'EOF'
Do something important
EOF
_run_drain "$PROJ4"
if [[ -f "${PROJ4}/.claude/watchtower_inbox/task_9001.txt" ]]; then
    pass "task file: not processed by drain (left in inbox)"
else
    fail "task file: wrongly consumed by drain_pending_inbox"
fi

# --- Test: milestone file in inbox → NOT touched by drain_pending_inbox ------
PROJ5="${TEST_TMPDIR}/proj_ms_skip"
mkdir -p "${PROJ5}/.claude/watchtower_inbox"
cat > "${PROJ5}/.claude/watchtower_inbox/milestone_m50.md" << 'EOF'
# Milestone m50
## Scope
Test milestone.
EOF
_run_drain "$PROJ5"
if [[ -f "${PROJ5}/.claude/watchtower_inbox/milestone_m50.md" ]]; then
    pass "milestone file: not processed by drain (left in inbox)"
else
    fail "milestone file: wrongly consumed by drain_pending_inbox"
fi

# --- Test: malformed note (no checkbox line) → left in inbox, no HUMAN_NOTES entry
PROJ6="${TEST_TMPDIR}/proj_bad_note"
mkdir -p "${PROJ6}/.claude/watchtower_inbox"
cat > "${PROJ6}/.claude/watchtower_inbox/note_bad.md" << 'EOF'
<!-- watchtower-note -->
No checkbox line here.
EOF
_run_drain "$PROJ6"
if [[ ! -f "${PROJ6}/.claude/watchtower_inbox/processed/note_bad.md" ]]; then
    pass "malformed note: not moved to processed/"
else
    fail "malformed note: wrongly moved to processed/"
fi
if [[ ! -f "${PROJ6}/.tekhton/HUMAN_NOTES.md" ]] || ! grep -q "^- \[ \]" "${PROJ6}/.tekhton/HUMAN_NOTES.md" 2>/dev/null; then
    pass "malformed note: no entry in HUMAN_NOTES.md"
else
    fail "malformed note: unexpected entry in HUMAN_NOTES.md"
fi

# --- Test: multiple note files processed in a single drain call --------------
PROJ7="${TEST_TMPDIR}/proj_multi"
mkdir -p "${PROJ7}/.claude/watchtower_inbox"
cat > "${PROJ7}/.claude/watchtower_inbox/note_a_BUG.md" << 'EOF'
<!-- watchtower-note -->
- [ ] [BUG] First mid-run note
EOF
cat > "${PROJ7}/.claude/watchtower_inbox/note_b_FEAT.md" << 'EOF'
<!-- watchtower-note -->
- [ ] [FEAT] Second mid-run note
EOF
_run_drain "$PROJ7"
note_count=$(grep -c "^- \[ \]" "${PROJ7}/.tekhton/HUMAN_NOTES.md" 2>/dev/null || echo 0)
if [[ "$note_count" -ge 2 ]]; then
    pass "multiple notes: both appended to HUMAN_NOTES.md (${note_count} entries)"
else
    fail "multiple notes: expected >=2 entries, got ${note_count}"
fi
processed_count=$(ls "${PROJ7}/.claude/watchtower_inbox/processed/"note_*.md 2>/dev/null | wc -l | tr -d '[:space:]')
if [[ "$processed_count" -eq 2 ]]; then
    pass "multiple notes: both moved to processed/"
else
    fail "multiple notes: expected 2 in processed/, got ${processed_count}"
fi

# --- Test: FEAT note lands in HUMAN_NOTES.md with FEAT tag -------------------
PROJ8="${TEST_TMPDIR}/proj_feat"
mkdir -p "${PROJ8}/.claude/watchtower_inbox"
cat > "${PROJ8}/.claude/watchtower_inbox/note_feat.md" << 'EOF'
<!-- watchtower-note -->
- [ ] [FEAT] Enable dark mode
EOF
_run_drain "$PROJ8"
if grep -q "\[FEAT\].*Enable dark mode" "${PROJ8}/.tekhton/HUMAN_NOTES.md" 2>/dev/null; then
    pass "FEAT note: tag preserved in HUMAN_NOTES.md"
else
    fail "FEAT note: tag or text missing from HUMAN_NOTES.md"
fi

# =============================================================================
# Summary
# =============================================================================

echo
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

[[ "$FAIL" -eq 0 ]]

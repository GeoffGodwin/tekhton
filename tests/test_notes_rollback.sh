#!/usr/bin/env bash
# Test: snapshot_note_states() and restore_note_states() in lib/notes_core.sh.
# These functions provide rollback protection for the claim/resolve cycle.
set -euo pipefail

export TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# =============================================================================
# Section 1: Syntax / static analysis
# =============================================================================

if bash -n "${TEKHTON_HOME}/lib/notes_core.sh" 2>/dev/null; then
    pass "bash -n lib/notes_core.sh passes"
else
    fail "bash -n lib/notes_core.sh: syntax error"
fi

if command -v shellcheck &>/dev/null; then
    if shellcheck "${TEKHTON_HOME}/lib/notes_core.sh" 2>/dev/null; then
        pass "shellcheck lib/notes_core.sh passes"
    else
        fail "shellcheck lib/notes_core.sh: warnings or errors"
    fi
else
    echo "  SKIP: shellcheck not installed"
fi

# =============================================================================
# Helper: run a test function in an isolated subshell with notes sourced
# =============================================================================

_run_in_proj() {
    local proj_dir="$1"
    shift
    (
        cd "$proj_dir"
        export PROJECT_DIR="$proj_dir"
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
        source "${TEKHTON_HOME}/lib/notes_rollback.sh"
        source "${TEKHTON_HOME}/lib/notes_cli.sh"
        # Now execute the provided inline function
        "$@"
    )
}

# =============================================================================
# Section 2: snapshot_note_states()
# =============================================================================

# --- Test: absent notes file → outputs "{}" ----------------------------------
PROJ1="${TEST_TMPDIR}/proj_absent"
mkdir -p "$PROJ1/.tekhton"
result=$(_run_in_proj "$PROJ1" bash -c '
    source "${TEKHTON_HOME}/lib/common.sh"
    log() { :; }; warn() { :; }; error() { :; }; success() { :; }; header() { :; }
    source "${TEKHTON_HOME}/lib/notes_core.sh"
    source "${TEKHTON_HOME}/lib/notes_rollback.sh"
    source "${TEKHTON_HOME}/lib/notes_cli.sh"
    snapshot_note_states
' 2>/dev/null)
if [[ "$result" == "{}" ]]; then
    pass "snapshot: absent notes file returns {}"
else
    fail "snapshot: absent notes file returned '${result}' (expected {})"
fi

# --- Test: snapshot captures all three states [ ], [~], [x] ------------------
PROJ2="${TEST_TMPDIR}/proj_states"
mkdir -p "$PROJ2/.tekhton"
cat > "${PROJ2}/.tekhton/HUMAN_NOTES.md" << 'EOF'
# Human Notes
<!-- notes-format: v2 -->

- [ ] [BUG] Unchecked note <!-- note:n01 created:2026-01-01 priority:high source:cli -->
- [~] [FEAT] Claimed note <!-- note:n02 created:2026-01-01 priority:medium source:cli -->
- [x] [POLISH] Done note <!-- note:n03 created:2026-01-01 priority:low source:cli -->
EOF

snapshot=$(_run_in_proj "$PROJ2" bash -c '
    source "${TEKHTON_HOME}/lib/common.sh"
    log() { :; }; warn() { :; }; error() { :; }; success() { :; }; header() { :; }
    source "${TEKHTON_HOME}/lib/notes_core.sh"
    source "${TEKHTON_HOME}/lib/notes_rollback.sh"
    source "${TEKHTON_HOME}/lib/notes_cli.sh"
    export _NOTES_FILE="${TEKHTON_DIR}/HUMAN_NOTES.md"
    snapshot_note_states
' 2>/dev/null)

if echo "$snapshot" | grep -q '"n01":" "' 2>/dev/null; then
    pass "snapshot: n01 (unchecked) recorded as space"
else
    fail "snapshot: n01 state missing or wrong in '${snapshot}'"
fi
if echo "$snapshot" | grep -q '"n02":"~"' 2>/dev/null; then
    pass "snapshot: n02 (claimed) recorded as ~"
else
    fail "snapshot: n02 state missing or wrong in '${snapshot}'"
fi
if echo "$snapshot" | grep -q '"n03":"x"' 2>/dev/null; then
    pass "snapshot: n03 (done) recorded as x"
else
    fail "snapshot: n03 state missing or wrong in '${snapshot}'"
fi

# --- Test: notes without IDs are not included in snapshot --------------------
PROJ3="${TEST_TMPDIR}/proj_no_ids"
mkdir -p "$PROJ3/.tekhton"
cat > "${PROJ3}/.tekhton/HUMAN_NOTES.md" << 'EOF'
# Human Notes

- [ ] [BUG] Note with no ID at all
- [x] [FEAT] Another note with no ID
EOF
snap=$(_run_in_proj "$PROJ3" bash -c '
    source "${TEKHTON_HOME}/lib/common.sh"
    log() { :; }; warn() { :; }; error() { :; }; success() { :; }; header() { :; }
    source "${TEKHTON_HOME}/lib/notes_core.sh"
    source "${TEKHTON_HOME}/lib/notes_rollback.sh"
    source "${TEKHTON_HOME}/lib/notes_cli.sh"
    export _NOTES_FILE="${TEKHTON_DIR}/HUMAN_NOTES.md"
    snapshot_note_states
' 2>/dev/null)
if [[ "$snap" == "{}" ]]; then
    pass "snapshot: notes without IDs produce empty snapshot {}"
else
    fail "snapshot: notes without IDs produced non-empty snapshot '${snap}'"
fi

# =============================================================================
# Section 3: restore_note_states()
# =============================================================================

# --- Test: [~] note that was [ ] in snapshot → reset to [ ] ------------------
PROJ4="${TEST_TMPDIR}/proj_restore_basic"
mkdir -p "$PROJ4/.tekhton"
cat > "${PROJ4}/.tekhton/HUMAN_NOTES.md" << 'EOF'
# Human Notes
<!-- notes-format: v2 -->

- [~] [BUG] A claimed note <!-- note:n01 created:2026-01-01 priority:high source:cli -->
- [x] [FEAT] A completed note <!-- note:n02 created:2026-01-01 priority:medium source:cli -->
EOF
# Snapshot shows n01 was [ ] and n02 was [x] before the run
snapshot='{"n01":" ","n02":"x"}'

(
    cd "$PROJ4"
    export PROJECT_DIR="$PROJ4"
    log() { :; }; warn() { :; }; error() { :; }; success() { :; }; header() { :; }
    source "${TEKHTON_HOME}/lib/common.sh"
    log() { :; }; warn() { :; }; error() { :; }; success() { :; }; header() { :; }
    source "${TEKHTON_HOME}/lib/notes_core.sh"
    source "${TEKHTON_HOME}/lib/notes_rollback.sh"
    source "${TEKHTON_HOME}/lib/notes_cli.sh"
    export _NOTES_FILE="${TEKHTON_DIR}/HUMAN_NOTES.md"
    restore_note_states "$snapshot"
)
if grep -q "^- \[ \] \[BUG\] A claimed note" "${PROJ4}/.tekhton/HUMAN_NOTES.md" 2>/dev/null; then
    pass "restore: [~] note that was [ ] in snapshot reset to [ ]"
else
    fail "restore: [~] note not reset to [ ] (file: $(cat "${PROJ4}/.tekhton/HUMAN_NOTES.md" 2>/dev/null))"
fi

# --- Test: [x] note that was [x] in snapshot → stays [x] --------------------
if grep -q "^- \[x\] \[FEAT\] A completed note" "${PROJ4}/.tekhton/HUMAN_NOTES.md" 2>/dev/null; then
    pass "restore: [x] note that was [x] in snapshot stays [x]"
else
    fail "restore: [x] note was modified unexpectedly"
fi

# --- Test: [~] note not in snapshot (added mid-run) → left untouched ---------
PROJ5="${TEST_TMPDIR}/proj_mid_run_note"
mkdir -p "$PROJ5/.tekhton"
cat > "${PROJ5}/.tekhton/HUMAN_NOTES.md" << 'EOF'
# Human Notes
<!-- notes-format: v2 -->

- [~] [BUG] Pre-run note <!-- note:n01 created:2026-01-01 priority:high source:cli -->
- [~] [FEAT] Mid-run note (new) <!-- note:n02 created:2026-01-01 priority:medium source:watchtower -->
EOF
# Snapshot only has n01 (n02 was added mid-run, not in snapshot)
snapshot='{"n01":" "}'

(
    cd "$PROJ5"
    export PROJECT_DIR="$PROJ5"
    log() { :; }; warn() { :; }; error() { :; }; success() { :; }; header() { :; }
    source "${TEKHTON_HOME}/lib/common.sh"
    log() { :; }; warn() { :; }; error() { :; }; success() { :; }; header() { :; }
    source "${TEKHTON_HOME}/lib/notes_core.sh"
    source "${TEKHTON_HOME}/lib/notes_rollback.sh"
    source "${TEKHTON_HOME}/lib/notes_cli.sh"
    export _NOTES_FILE="${TEKHTON_DIR}/HUMAN_NOTES.md"
    restore_note_states "$snapshot"
)
# n01 should be reset
if grep -q "^- \[ \] \[BUG\] Pre-run note" "${PROJ5}/.tekhton/HUMAN_NOTES.md" 2>/dev/null; then
    pass "restore: n01 (pre-run) reset to [ ]"
else
    fail "restore: n01 not reset"
fi
# n02 (mid-run, not in snapshot) must stay [~]
if grep -q "^- \[~\] \[FEAT\] Mid-run note" "${PROJ5}/.tekhton/HUMAN_NOTES.md" 2>/dev/null; then
    pass "restore: n02 (mid-run, absent from snapshot) left as [~]"
else
    fail "restore: n02 was modified (should be left untouched)"
fi

# --- Test: restore with "{}" snapshot → no changes ---------------------------
PROJ6="${TEST_TMPDIR}/proj_empty_snap"
mkdir -p "$PROJ6/.tekhton"
cat > "${PROJ6}/.tekhton/HUMAN_NOTES.md" << 'EOF'
# Human Notes
<!-- notes-format: v2 -->

- [~] [BUG] A claimed note <!-- note:n01 created:2026-01-01 priority:high source:cli -->
EOF
cp "${PROJ6}/.tekhton/HUMAN_NOTES.md" "${PROJ6}/.tekhton/HUMAN_NOTES.md.before"

(
    cd "$PROJ6"
    export PROJECT_DIR="$PROJ6"
    log() { :; }; warn() { :; }; error() { :; }; success() { :; }; header() { :; }
    source "${TEKHTON_HOME}/lib/common.sh"
    log() { :; }; warn() { :; }; error() { :; }; success() { :; }; header() { :; }
    source "${TEKHTON_HOME}/lib/notes_core.sh"
    source "${TEKHTON_HOME}/lib/notes_rollback.sh"
    source "${TEKHTON_HOME}/lib/notes_cli.sh"
    export _NOTES_FILE="${TEKHTON_DIR}/HUMAN_NOTES.md"
    restore_note_states "{}"
)
if diff -q "${PROJ6}/.tekhton/HUMAN_NOTES.md.before" "${PROJ6}/.tekhton/HUMAN_NOTES.md" >/dev/null 2>&1; then
    pass "restore: empty snapshot ({}) leaves file unchanged"
else
    fail "restore: empty snapshot modified the file"
fi

# --- Test: snapshot/restore roundtrip — [ ] and [x] notes are stable ---------
PROJ7="${TEST_TMPDIR}/proj_roundtrip"
mkdir -p "$PROJ7/.tekhton"
cat > "${PROJ7}/.tekhton/HUMAN_NOTES.md" << 'EOF'
# Human Notes
<!-- notes-format: v2 -->

- [ ] [BUG] Unchecked <!-- note:n01 created:2026-01-01 priority:high source:cli -->
- [x] [FEAT] Done <!-- note:n02 created:2026-01-01 priority:medium source:cli -->
EOF

# Take snapshot → simulate a claim run → restore → verify original states
snap=$(_run_in_proj "$PROJ7" bash -c '
    source "${TEKHTON_HOME}/lib/common.sh"
    log() { :; }; warn() { :; }; error() { :; }; success() { :; }; header() { :; }
    source "${TEKHTON_HOME}/lib/notes_core.sh"
    source "${TEKHTON_HOME}/lib/notes_rollback.sh"
    source "${TEKHTON_HOME}/lib/notes_cli.sh"
    export _NOTES_FILE="${TEKHTON_DIR}/HUMAN_NOTES.md"
    snapshot_note_states
' 2>/dev/null)

# Simulate pipeline: claim n01 ([ ] → [~])
(
    cd "$PROJ7"
    export PROJECT_DIR="$PROJ7"
    log() { :; }; warn() { :; }; error() { :; }; success() { :; }; header() { :; }
    source "${TEKHTON_HOME}/lib/common.sh"
    log() { :; }; warn() { :; }; error() { :; }; success() { :; }; header() { :; }
    source "${TEKHTON_HOME}/lib/notes_core.sh"
    source "${TEKHTON_HOME}/lib/notes_rollback.sh"
    source "${TEKHTON_HOME}/lib/notes_cli.sh"
    export _NOTES_FILE="${TEKHTON_DIR}/HUMAN_NOTES.md"
    claim_note "n01"
)

# Now restore
(
    cd "$PROJ7"
    export PROJECT_DIR="$PROJ7"
    log() { :; }; warn() { :; }; error() { :; }; success() { :; }; header() { :; }
    source "${TEKHTON_HOME}/lib/common.sh"
    log() { :; }; warn() { :; }; error() { :; }; success() { :; }; header() { :; }
    source "${TEKHTON_HOME}/lib/notes_core.sh"
    source "${TEKHTON_HOME}/lib/notes_rollback.sh"
    source "${TEKHTON_HOME}/lib/notes_cli.sh"
    export _NOTES_FILE="${TEKHTON_DIR}/HUMAN_NOTES.md"
    restore_note_states "$snap"
)

if grep -q "^- \[ \] \[BUG\] Unchecked" "${PROJ7}/.tekhton/HUMAN_NOTES.md" 2>/dev/null; then
    pass "roundtrip: n01 restored to [ ] after claim + restore"
else
    fail "roundtrip: n01 not restored (file: $(cat "${PROJ7}/.tekhton/HUMAN_NOTES.md" 2>/dev/null))"
fi
if grep -q "^- \[x\] \[FEAT\] Done" "${PROJ7}/.tekhton/HUMAN_NOTES.md" 2>/dev/null; then
    pass "roundtrip: n02 (done) unaffected by restore"
else
    fail "roundtrip: n02 was modified by restore"
fi

# =============================================================================
# Summary
# =============================================================================

echo
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

[[ "$FAIL" -eq 0 ]]

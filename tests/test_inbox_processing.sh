#!/usr/bin/env bash
# Test: lib/inbox.sh syntax/shellcheck, watchtower_server.py smoke test, and
#       process_watchtower_inbox() integration with fixture inbox items.
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

TEKHTON_DIR=".tekhton"
HUMAN_NOTES_FILE="${TEKHTON_DIR}/HUMAN_NOTES.md"
export TEKHTON_DIR HUMAN_NOTES_FILE

# =============================================================================
# Section 1: Syntax and static analysis gates
# =============================================================================

# --- bash -n syntax check ---
if bash -n "${TEKHTON_HOME}/lib/inbox.sh" 2>/dev/null; then
    pass "bash -n lib/inbox.sh passes"
else
    fail "bash -n lib/inbox.sh: syntax error"
fi

# --- shellcheck ---
if command -v shellcheck &>/dev/null; then
    if shellcheck "${TEKHTON_HOME}/lib/inbox.sh" 2>/dev/null; then
        pass "shellcheck lib/inbox.sh passes"
    else
        fail "shellcheck lib/inbox.sh: warnings or errors reported"
    fi
else
    echo "  SKIP: shellcheck not installed"
fi

# =============================================================================
# Section 2: watchtower_server.py smoke tests
# =============================================================================

if ! command -v python3 &>/dev/null; then
    echo "  SKIP: python3 not available — skipping server smoke tests"
else
    # --- --help exits cleanly ---
    if python3 "${TEKHTON_HOME}/tools/watchtower_server.py" --help >/dev/null 2>&1; then
        pass "watchtower_server.py --help exits 0"
    else
        fail "watchtower_server.py --help failed"
    fi

    # --- /api/ping returns {"ok": true} ---
    DASH_DIR="${TEST_TMPDIR}/dashboard"
    INBOX_DIR="${TEST_TMPDIR}/inbox"
    mkdir -p "$DASH_DIR" "$INBOX_DIR"
    # Pick a port unlikely to be in use
    PING_PORT=18271
    python3 "${TEKHTON_HOME}/tools/watchtower_server.py" \
        --port "$PING_PORT" \
        --dashboard-dir "$DASH_DIR" \
        --inbox-dir "$INBOX_DIR" \
        >/dev/null 2>&1 &
    SERVER_PID=$!
    # Wait up to 3s for server to be ready
    ready=0
    for _i in 1 2 3 4 5 6; do
        sleep 0.5
        if kill -0 "$SERVER_PID" 2>/dev/null && \
           curl -sf "http://127.0.0.1:${PING_PORT}/api/ping" >/dev/null 2>&1; then
            ready=1
            break
        fi
    done
    if [[ "$ready" -eq 1 ]]; then
        PING_RESPONSE=$(curl -sf "http://127.0.0.1:${PING_PORT}/api/ping" 2>/dev/null || true)
        if [[ "$PING_RESPONSE" == '{"ok": true}' ]]; then
            pass "/api/ping returns {\"ok\": true}"
        else
            fail "/api/ping returned unexpected: ${PING_RESPONSE}"
        fi
    else
        fail "Server did not start within timeout on port ${PING_PORT}"
    fi
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
fi

# =============================================================================
# Section 3: process_watchtower_inbox() unit tests
#
# Each test runs in an isolated subshell with its own PROJECT_DIR, cwd, and
# sourced libraries.  Subshells are used so _NOTES_FILE (relative path) resolves
# correctly and state does not bleed between cases.
# =============================================================================

# --- Test: note file → appended to HUMAN_NOTES.md with correct format ---
PROJ_NOTE="${TEST_TMPDIR}/proj_note"
mkdir -p "${PROJ_NOTE}/.claude/watchtower_inbox"
cat > "${PROJ_NOTE}/.claude/watchtower_inbox/note_1234_BUG.md" << 'EOF'
<!-- watchtower-note -->
- [ ] [BUG] Login page crashes on empty password
EOF

(
    cd "$PROJ_NOTE"
    export PROJECT_DIR="$PROJ_NOTE"
    mkdir -p .tekhton
    log() { :; }; success() { :; }; warn() { :; }; error() { :; }; header() { :; }
    # shellcheck source=../lib/common.sh
    source "${TEKHTON_HOME}/lib/common.sh"
    log() { :; }; success() { :; }; warn() { :; }; error() { :; }; header() { :; }
    source "${TEKHTON_HOME}/lib/notes_core.sh"
    source "${TEKHTON_HOME}/lib/notes_cli.sh"
    source "${TEKHTON_HOME}/lib/inbox.sh"
    process_watchtower_inbox
    [[ ! -f ".claude/watchtower_inbox/note_1234_BUG.md" ]] || { echo "original not moved" >&2; exit 1; }
    [[ -f ".claude/watchtower_inbox/processed/note_1234_BUG.md" ]] || { echo "processed file missing" >&2; exit 1; }
    grep -q "^- \[ \] \[BUG\] Login page crashes on empty password" .tekhton/HUMAN_NOTES.md || { echo "entry not in HUMAN_NOTES" >&2; exit 1; }
)
if [[ $? -eq 0 ]]; then
    pass "note file: title appended to HUMAN_NOTES.md as unchecked BUG entry, file moved to processed"
else
    fail "note file processing: unexpected result"
fi

# --- Test: FEAT-tagged note lands in correct section ---
PROJ_FEAT="${TEST_TMPDIR}/proj_feat"
mkdir -p "${PROJ_FEAT}/.claude/watchtower_inbox"
cat > "${PROJ_FEAT}/.claude/watchtower_inbox/note_5678_FEAT.md" << 'EOF'
<!-- watchtower-note -->
- [ ] [FEAT] Add dark mode toggle
EOF

(
    cd "$PROJ_FEAT"
    export PROJECT_DIR="$PROJ_FEAT"
    mkdir -p .tekhton
    log() { :; }; success() { :; }; warn() { :; }; error() { :; }; header() { :; }
    source "${TEKHTON_HOME}/lib/common.sh"
    log() { :; }; success() { :; }; warn() { :; }; error() { :; }; header() { :; }
    source "${TEKHTON_HOME}/lib/notes_core.sh"
    source "${TEKHTON_HOME}/lib/notes_cli.sh"
    source "${TEKHTON_HOME}/lib/inbox.sh"
    process_watchtower_inbox
    grep -q "^- \[ \] \[FEAT\] Add dark mode toggle" .tekhton/HUMAN_NOTES.md || { echo "FEAT entry missing" >&2; exit 1; }
)
if [[ $? -eq 0 ]]; then
    pass "FEAT-tagged note appended with correct checkbox format"
else
    fail "FEAT-tagged note: unexpected result"
fi

# --- Test: malformed note (no checkbox line) is skipped, not moved ---
PROJ_MALFORMED="${TEST_TMPDIR}/proj_malformed"
mkdir -p "${PROJ_MALFORMED}/.claude/watchtower_inbox"
cat > "${PROJ_MALFORMED}/.claude/watchtower_inbox/note_bad.md" << 'EOF'
<!-- watchtower-note -->
This file has no checkbox line at all.
EOF

(
    cd "$PROJ_MALFORMED"
    export PROJECT_DIR="$PROJ_MALFORMED"
    mkdir -p .tekhton
    log() { :; }; success() { :; }; warn() { :; }; error() { :; }; header() { :; }
    source "${TEKHTON_HOME}/lib/common.sh"
    log() { :; }; success() { :; }; warn() { :; }; error() { :; }; header() { :; }
    source "${TEKHTON_HOME}/lib/notes_core.sh"
    source "${TEKHTON_HOME}/lib/notes_cli.sh"
    source "${TEKHTON_HOME}/lib/inbox.sh"
    process_watchtower_inbox
    # Malformed note must stay in inbox (failed processing, not moved)
    [[ ! -f ".claude/watchtower_inbox/processed/note_bad.md" ]] || { echo "malformed note wrongly moved to processed" >&2; exit 1; }
    # No checkbox entries should have been added
    if [[ -f ".tekhton/HUMAN_NOTES.md" ]]; then
        if grep -q "^- \[ \]" .tekhton/HUMAN_NOTES.md 2>/dev/null; then
            echo "malformed note text appeared in HUMAN_NOTES.md" >&2; exit 1
        fi
    fi
)
if [[ $? -eq 0 ]]; then
    pass "malformed note skipped: not moved to processed, not added to HUMAN_NOTES"
else
    fail "malformed note handling: unexpected result"
fi

# --- Test: task file → INBOX_TASK_DESCRIPTIONS populated, file moved ---
PROJ_TASK="${TEST_TMPDIR}/proj_task"
mkdir -p "${PROJ_TASK}/.claude/watchtower_inbox"
cat > "${PROJ_TASK}/.claude/watchtower_inbox/task_9999.txt" << 'EOF'
Refactor the authentication module to use JWT
EOF

(
    cd "$PROJ_TASK"
    export PROJECT_DIR="$PROJ_TASK"
    mkdir -p .tekhton
    log() { :; }; success() { :; }; warn() { :; }; error() { :; }; header() { :; }
    source "${TEKHTON_HOME}/lib/common.sh"
    log() { :; }; success() { :; }; warn() { :; }; error() { :; }; header() { :; }
    source "${TEKHTON_HOME}/lib/notes_core.sh"
    source "${TEKHTON_HOME}/lib/notes_cli.sh"
    source "${TEKHTON_HOME}/lib/inbox.sh"
    process_watchtower_inbox
    [[ ! -f ".claude/watchtower_inbox/task_9999.txt" ]] || { echo "task file not moved" >&2; exit 1; }
    [[ -f ".claude/watchtower_inbox/processed/task_9999.txt" ]] || { echo "processed task missing" >&2; exit 1; }
    [[ -n "$INBOX_TASK_DESCRIPTIONS" ]] || { echo "INBOX_TASK_DESCRIPTIONS empty" >&2; exit 1; }
    [[ "$INBOX_TASK_DESCRIPTIONS" == *"Refactor the authentication module"* ]] || { echo "task text not in descriptions: ${INBOX_TASK_DESCRIPTIONS}" >&2; exit 1; }
)
if [[ $? -eq 0 ]]; then
    pass "task file: moved to processed, description captured in INBOX_TASK_DESCRIPTIONS"
else
    fail "task file handling: unexpected result"
fi

# --- Test: empty inbox directory → no side effects ---
PROJ_EMPTY="${TEST_TMPDIR}/proj_empty"
mkdir -p "${PROJ_EMPTY}/.claude/watchtower_inbox"

(
    cd "$PROJ_EMPTY"
    export PROJECT_DIR="$PROJ_EMPTY"
    mkdir -p .tekhton
    log() { :; }; success() { :; }; warn() { :; }; error() { :; }; header() { :; }
    source "${TEKHTON_HOME}/lib/common.sh"
    log() { :; }; success() { :; }; warn() { :; }; error() { :; }; header() { :; }
    source "${TEKHTON_HOME}/lib/notes_core.sh"
    source "${TEKHTON_HOME}/lib/notes_cli.sh"
    source "${TEKHTON_HOME}/lib/inbox.sh"
    process_watchtower_inbox
    if [[ -f ".tekhton/HUMAN_NOTES.md" ]]; then
        if grep -q "^- \[ \]" .tekhton/HUMAN_NOTES.md 2>/dev/null; then
            echo "HUMAN_NOTES.md has unexpected entries" >&2; exit 1
        fi
    fi
)
if [[ $? -eq 0 ]]; then
    pass "empty inbox: no HUMAN_NOTES entries created, exits cleanly"
else
    fail "empty inbox: unexpected side effect"
fi

# --- Test: absent inbox directory → no-op ---
PROJ_ABSENT="${TEST_TMPDIR}/proj_absent"
mkdir -p "$PROJ_ABSENT"

(
    cd "$PROJ_ABSENT"
    export PROJECT_DIR="$PROJ_ABSENT"
    mkdir -p .tekhton
    log() { :; }; success() { :; }; warn() { :; }; error() { :; }; header() { :; }
    source "${TEKHTON_HOME}/lib/common.sh"
    log() { :; }; success() { :; }; warn() { :; }; error() { :; }; header() { :; }
    source "${TEKHTON_HOME}/lib/notes_core.sh"
    source "${TEKHTON_HOME}/lib/notes_cli.sh"
    source "${TEKHTON_HOME}/lib/inbox.sh"
    process_watchtower_inbox
)
if [[ $? -eq 0 ]]; then
    pass "absent inbox directory: returns 0 without error"
else
    fail "absent inbox directory: unexpected failure"
fi

# --- Test: milestone file → moved to MILESTONE_DIR ---
PROJ_MS="${TEST_TMPDIR}/proj_milestone"
MS_DIR="${PROJ_MS}/.claude/milestones"
mkdir -p "${PROJ_MS}/.claude/watchtower_inbox" "$MS_DIR"
cat > "${PROJ_MS}/.claude/watchtower_inbox/milestone_m99.md" << 'EOF'
# Milestone m99: Test Milestone
## Scope
Add test milestone for inbox processing.
## Acceptance Criteria
- The milestone file is processed correctly.
EOF

(
    cd "$PROJ_MS"
    export PROJECT_DIR="$PROJ_MS"
    export MILESTONE_DIR="$MS_DIR"
    mkdir -p .tekhton
    log() { :; }; success() { :; }; warn() { :; }; error() { :; }; header() { :; }
    source "${TEKHTON_HOME}/lib/common.sh"
    log() { :; }; success() { :; }; warn() { :; }; error() { :; }; header() { :; }
    source "${TEKHTON_HOME}/lib/notes_core.sh"
    source "${TEKHTON_HOME}/lib/notes_cli.sh"
    source "${TEKHTON_HOME}/lib/inbox.sh"
    process_watchtower_inbox
    [[ -f "${MS_DIR}/milestone_m99.md" ]] || { echo "milestone not in MILESTONE_DIR" >&2; exit 1; }
    [[ ! -f ".claude/watchtower_inbox/milestone_m99.md" ]] || { echo "original still in inbox" >&2; exit 1; }
)
if [[ $? -eq 0 ]]; then
    pass "milestone file moved to MILESTONE_DIR"
else
    fail "milestone file handling: unexpected result"
fi

# --- Test: manifest_append → appended to MANIFEST.cfg, file moved ---
PROJ_MANIFEST="${TEST_TMPDIR}/proj_manifest"
MS_DIR2="${PROJ_MANIFEST}/.claude/milestones"
mkdir -p "${PROJ_MANIFEST}/.claude/watchtower_inbox" "$MS_DIR2"
cat > "${MS_DIR2}/MANIFEST.cfg" << 'EOF'
m01|Foundation|done||m01-foundation.md|foundation
EOF
cat > "${PROJ_MANIFEST}/.claude/watchtower_inbox/manifest_append_m99.cfg" << 'EOF'
m99|New Feature|pending|m01|m99-new-feature.md|features
EOF

(
    cd "$PROJ_MANIFEST"
    export PROJECT_DIR="$PROJ_MANIFEST"
    export MILESTONE_DIR="$MS_DIR2"
    export MILESTONE_MANIFEST="MANIFEST.cfg"
    mkdir -p .tekhton
    log() { :; }; success() { :; }; warn() { :; }; error() { :; }; header() { :; }
    source "${TEKHTON_HOME}/lib/common.sh"
    log() { :; }; success() { :; }; warn() { :; }; error() { :; }; header() { :; }
    source "${TEKHTON_HOME}/lib/notes_core.sh"
    source "${TEKHTON_HOME}/lib/notes_cli.sh"
    source "${TEKHTON_HOME}/lib/inbox.sh"
    process_watchtower_inbox
    [[ ! -f ".claude/watchtower_inbox/manifest_append_m99.cfg" ]] || { echo "cfg not moved from inbox" >&2; exit 1; }
    [[ -f ".claude/watchtower_inbox/processed/manifest_append_m99.cfg" ]] || { echo "cfg missing from processed" >&2; exit 1; }
    grep -q "^m99|" "${MS_DIR2}/MANIFEST.cfg" || { echo "m99 not in MANIFEST.cfg" >&2; exit 1; }
)
if [[ $? -eq 0 ]]; then
    pass "manifest_append appended to MANIFEST.cfg and moved to processed"
else
    fail "manifest_append processing: unexpected result"
fi

# --- Test: manifest_append with duplicate ID → rejected ---
PROJ_COLLISION="${TEST_TMPDIR}/proj_collision"
MS_DIR3="${PROJ_COLLISION}/.claude/milestones"
mkdir -p "${PROJ_COLLISION}/.claude/watchtower_inbox" "$MS_DIR3"
cat > "${MS_DIR3}/MANIFEST.cfg" << 'EOF'
m01|Foundation|done||m01-foundation.md|foundation
EOF
cat > "${PROJ_COLLISION}/.claude/watchtower_inbox/manifest_append_m01.cfg" << 'EOF'
m01|Duplicate Foundation|pending||m01-dup.md|foundation
EOF

(
    cd "$PROJ_COLLISION"
    export PROJECT_DIR="$PROJ_COLLISION"
    export MILESTONE_DIR="$MS_DIR3"
    export MILESTONE_MANIFEST="MANIFEST.cfg"
    mkdir -p .tekhton
    log() { :; }; success() { :; }; warn() { :; }; error() { :; }; header() { :; }
    source "${TEKHTON_HOME}/lib/common.sh"
    log() { :; }; success() { :; }; warn() { :; }; error() { :; }; header() { :; }
    source "${TEKHTON_HOME}/lib/notes_core.sh"
    source "${TEKHTON_HOME}/lib/notes_cli.sh"
    source "${TEKHTON_HOME}/lib/inbox.sh"
    process_watchtower_inbox
    # Rejected: must NOT appear in processed/
    [[ ! -f ".claude/watchtower_inbox/processed/manifest_append_m01.cfg" ]] || { echo "colliding manifest wrongly moved to processed" >&2; exit 1; }
    # MANIFEST.cfg must have exactly one m01 entry
    count=$(grep -c "^m01|" "${MS_DIR3}/MANIFEST.cfg" || true)
    [[ "$count" -eq 1 ]] || { echo "MANIFEST.cfg has ${count} m01 entries (expected 1)" >&2; exit 1; }
)
if [[ $? -eq 0 ]]; then
    pass "manifest_append with duplicate ID rejected, MANIFEST.cfg unchanged"
else
    fail "manifest_append collision detection: unexpected result"
fi

# --- Test: manifest_append with missing dependency → rejected ---
PROJ_MISSDEP="${TEST_TMPDIR}/proj_missdep"
MS_DIR4="${PROJ_MISSDEP}/.claude/milestones"
mkdir -p "${PROJ_MISSDEP}/.claude/watchtower_inbox" "$MS_DIR4"
cat > "${MS_DIR4}/MANIFEST.cfg" << 'EOF'
m01|Foundation|done||m01-foundation.md|foundation
EOF
cat > "${PROJ_MISSDEP}/.claude/watchtower_inbox/manifest_append_m02.cfg" << 'EOF'
m02|Depends On Missing|pending|m99|m02-depends.md|features
EOF

(
    cd "$PROJ_MISSDEP"
    export PROJECT_DIR="$PROJ_MISSDEP"
    export MILESTONE_DIR="$MS_DIR4"
    export MILESTONE_MANIFEST="MANIFEST.cfg"
    mkdir -p .tekhton
    log() { :; }; success() { :; }; warn() { :; }; error() { :; }; header() { :; }
    source "${TEKHTON_HOME}/lib/common.sh"
    log() { :; }; success() { :; }; warn() { :; }; error() { :; }; header() { :; }
    source "${TEKHTON_HOME}/lib/notes_core.sh"
    source "${TEKHTON_HOME}/lib/notes_cli.sh"
    source "${TEKHTON_HOME}/lib/inbox.sh"
    process_watchtower_inbox
    [[ ! -f ".claude/watchtower_inbox/processed/manifest_append_m02.cfg" ]] || { echo "bad-dep manifest wrongly accepted" >&2; exit 1; }
    ! grep -q "^m02|" "${MS_DIR4}/MANIFEST.cfg" || { echo "m02 incorrectly added to MANIFEST.cfg" >&2; exit 1; }
)
if [[ $? -eq 0 ]]; then
    pass "manifest_append with missing dependency rejected"
else
    fail "manifest_append missing dep check: unexpected result"
fi

# =============================================================================
# Summary
# =============================================================================

echo
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

[[ "$FAIL" -eq 0 ]]

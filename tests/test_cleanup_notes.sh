#!/usr/bin/env bash
# Test: count_unresolved_notes — absent-file and DEFERRED-exclusion cases
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_DIR="$TMPDIR"
TEKHTON_SESSION_DIR="$TMPDIR"
NON_BLOCKING_LOG_FILE="NON_BLOCKING_LOG.md"
NOTES_FILTER=""
LOG_DIR="$TMPDIR"
TIMESTAMP="test"
TASK="test task"

source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/drift.sh"
source "${TEKHTON_HOME}/lib/notes.sh"
source "${TEKHTON_HOME}/lib/notes_cleanup.sh"

FAIL=0

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" != "$actual" ]; then
        echo "FAIL: $name — expected '$expected', got '$actual'"
        FAIL=1
    fi
}

NB_FILE="${PROJECT_DIR}/${NON_BLOCKING_LOG_FILE}"

# =============================================================================
# Test 1: absent NON_BLOCKING_LOG.md returns 0
# =============================================================================

rm -f "$NB_FILE"
COUNT=$(count_unresolved_notes)
assert_eq "absent file returns 0" "0" "$COUNT"

# =============================================================================
# Test 2: empty Open section returns 0
# =============================================================================

cat > "$NB_FILE" << 'EOF'
## Open

## Resolved

EOF

COUNT=$(count_unresolved_notes)
assert_eq "empty Open section returns 0" "0" "$COUNT"

# =============================================================================
# Test 3: open items are counted
# =============================================================================

cat > "$NB_FILE" << 'EOF'
## Open
- [ ] `lib/foo.sh:10` — missing null check
- [ ] `lib/bar.sh:20` — unused variable

## Resolved
- [x] `lib/baz.sh:5` — fixed typo
EOF

COUNT=$(count_unresolved_notes)
assert_eq "two open items counted" "2" "$COUNT"

# =============================================================================
# Test 4: [DEFERRED] items are NOT counted as unresolved
# =============================================================================

cat > "$NB_FILE" << 'EOF'
## Open
- [ ] `lib/foo.sh:10` — missing null check
- [DEFERRED] `lib/bar.sh:20` — requires architectural change
- [ ] `lib/baz.sh:30` — add docstring

## Resolved
- [x] `lib/qux.sh:5` — already fixed
EOF

COUNT=$(count_unresolved_notes)
assert_eq "DEFERRED not counted" "2" "$COUNT"

# =============================================================================
# Test 5: [x] resolved items are NOT counted as unresolved
# =============================================================================

cat > "$NB_FILE" << 'EOF'
## Open
- [x] `lib/foo.sh:10` — was open, now resolved
- [ ] `lib/bar.sh:20` — still open

## Resolved
EOF

COUNT=$(count_unresolved_notes)
assert_eq "resolved [x] not counted" "1" "$COUNT"

# =============================================================================
# Test 6: all items deferred — returns 0
# =============================================================================

cat > "$NB_FILE" << 'EOF'
## Open
- [DEFERRED] `lib/foo.sh:10` — requires architectural change
- [DEFERRED] `lib/bar.sh:20` — out of scope

## Resolved
EOF

COUNT=$(count_unresolved_notes)
assert_eq "all deferred returns 0" "0" "$COUNT"

# =============================================================================
# Test 7: mark_note_resolved marks an open item [x]
# =============================================================================

cat > "$NB_FILE" << 'EOF'
## Open
- [ ] `lib/foo.sh:10` — missing null check
- [ ] `lib/bar.sh:20` — unused variable

## Resolved
EOF

mark_note_resolved "missing null check"
COUNT=$(count_unresolved_notes)
assert_eq "one resolved, one remaining" "1" "$COUNT"

if ! grep -q "^\- \[x\].*missing null check" "$NB_FILE" 2>/dev/null; then
    echo "FAIL: mark_note_resolved — item not marked [x]"
    FAIL=1
fi

# =============================================================================
# Test 8: mark_note_deferred marks an open item [DEFERRED]
# =============================================================================

cat > "$NB_FILE" << 'EOF'
## Open
- [ ] `lib/foo.sh:10` — needs refactor
- [ ] `lib/bar.sh:20` — unused variable

## Resolved
EOF

mark_note_deferred "needs refactor"
COUNT=$(count_unresolved_notes)
assert_eq "deferred excluded from count" "1" "$COUNT"

if ! grep -q "^\- \[DEFERRED\].*needs refactor" "$NB_FILE" 2>/dev/null; then
    echo "FAIL: mark_note_deferred — item not marked [DEFERRED]"
    FAIL=1
fi

# =============================================================================
# Test 9: mark_note_resolved on absent file returns 1
# =============================================================================

rm -f "$NB_FILE"
if mark_note_resolved "anything" 2>/dev/null; then
    echo "FAIL: mark_note_resolved absent file — expected return 1"
    FAIL=1
fi

# =============================================================================
# Test 10: mark_note_deferred on absent file returns 1
# =============================================================================

if mark_note_deferred "anything" 2>/dev/null; then
    echo "FAIL: mark_note_deferred absent file — expected return 1"
    FAIL=1
fi

# =============================================================================

if [ "$FAIL" -ne 0 ]; then
    exit 1
fi

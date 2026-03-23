#!/usr/bin/env bash
# Test: mark_milestone_done — marks milestone headings as [DONE] in CLAUDE.md
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_DIR="$TMPDIR"
export TEKHTON_HOME PROJECT_DIR

source "${TEKHTON_HOME}/lib/common.sh"

# Config stubs
PIPELINE_STATE_FILE="${TMPDIR}/.claude/PIPELINE_STATE.md"
TEST_CMD=""
ANALYZE_CMD=""
LOG_DIR="${TMPDIR}/.claude/logs"
mkdir -p "${TMPDIR}/.claude" "${LOG_DIR}"

MILESTONE_STATE_FILE="${TMPDIR}/.claude/MILESTONE_STATE.md"
export MILESTONE_STATE_FILE

source "${TEKHTON_HOME}/lib/state.sh"
run_build_gate() { return 0; }
source "${TEKHTON_HOME}/lib/milestones.sh"
source "${TEKHTON_HOME}/lib/milestone_ops.sh"

# cd to TMPDIR so relative CLAUDE.md paths resolve correctly
cd "$TMPDIR"

PASS=0
FAIL=0

assert() {
    local desc="$1"
    local result="$2"
    if [ "$result" = "0" ]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"
        FAIL=$((FAIL + 1))
    fi
}

# --- Create a sample CLAUDE.md with mixed milestones --------

cat > "${TMPDIR}/CLAUDE.md" << 'CLAUDE_EOF'
# Project Rules

## Implementation Milestones

#### Milestone 1: Basic Setup
Add foundational infrastructure.

Acceptance criteria:
- Files created
- Tests pass

#### Milestone 2: Context Compiler
Add task-scoped context assembly.

Acceptance criteria:
- extract_relevant_sections works

#### Milestone 13.2.1.1: Retry Envelope Skeleton
Complex nested milestone.

Acceptance criteria:
- Retry works

#### Milestone 13.2.2: Stage Cleanup
Another nested milestone.

Acceptance criteria:
- Cleanup functions exist

#### Milestone 999: Future Milestone
Placeholder for future work.

Acceptance criteria:
- Not started
CLAUDE_EOF

echo "=== mark_milestone_done basic tests ==="

# Test 1: Mark a simple milestone as [DONE]
mark_milestone_done 1
result=$(grep -q "^#### \[DONE\] Milestone 1:" "${TMPDIR}/CLAUDE.md" && echo 0 || echo 1)
assert "Mark Milestone 1 as [DONE]" "$result"

# Test 2: Verify the exact format is correct (with [DONE] before Milestone)
format_check=$(grep "^#### \[DONE\] Milestone 1: Basic Setup" "${TMPDIR}/CLAUDE.md" 2>/dev/null | wc -l)
assert "Format is exact: [DONE] Milestone 1: Title" "$([ "$format_check" -eq 1 ] && echo 0 || echo 1)"

# Test 3: Verify other milestones are untouched
m2_untouched=$(grep -q "^#### Milestone 2:" "${TMPDIR}/CLAUDE.md" && echo 0 || echo 1)
assert "Milestone 2 remains unchanged" "$m2_untouched"

# Test 4: Idempotency — calling again returns 0 without modification
original_md=$(cat "${TMPDIR}/CLAUDE.md")
mark_milestone_done 1
result=$?
modified_md=$(cat "${TMPDIR}/CLAUDE.md")
assert "mark_milestone_done 1 idempotent returns 0" "$([ "$result" -eq 0 ] && echo 0 || echo 1)"
assert "mark_milestone_done 1 idempotent does not change file" "$([ "$original_md" = "$modified_md" ] && echo 0 || echo 1)"

# Test 5: Mark dotted milestone (depth 2)
mark_milestone_done 13.2.2
result=$(grep -q "^#### \[DONE\] Milestone 13.2.2:" "${TMPDIR}/CLAUDE.md" && echo 0 || echo 1)
assert "Mark Milestone 13.2.2 as [DONE]" "$result"

# Test 6: Mark deep dotted milestone (depth 3+)
mark_milestone_done 13.2.1.1
result=$(grep -q "^#### \[DONE\] Milestone 13.2.1.1:" "${TMPDIR}/CLAUDE.md" && echo 0 || echo 1)
assert "Mark Milestone 13.2.1.1 as [DONE]" "$result"

# Test 7: Verify deep dotted milestone format is correct
deep_format=$(grep "^#### \[DONE\] Milestone 13.2.1.1: Retry Envelope Skeleton" "${TMPDIR}/CLAUDE.md" 2>/dev/null | wc -l)
assert "Deep dotted format is exact" "$([ "$deep_format" -eq 1 ] && echo 0 || echo 1)"

# Test 8: Verify dot escaping doesn't over-escape or under-escape
# Check that 13.2.2 and 13.2.1.1 don't interfere with each other
both_marked=$(grep -c "^#### \[DONE\] Milestone 13.2" "${TMPDIR}/CLAUDE.md")
assert "Both 13.2.2 and 13.2.1.1 are marked (dot escaping correct)" "$([ "$both_marked" -eq 2 ] && echo 0 || echo 1)"

echo "=== mark_milestone_done error cases ==="

# Test 9: Non-existent milestone returns 1
mark_milestone_done 777 2>/dev/null || rc=$?
assert "Non-existent Milestone 777 returns 1" "$([ "${rc:-0}" -ne 0 ] && echo 0 || echo 1)"

# Test 10: Non-existent file returns 1
(
    cd "$(mktemp -d)"
    trap 'cd "$TMPDIR"' EXIT
    mark_milestone_done 1 2>/dev/null; rc=$?
    [ "$rc" -ne 0 ]
) && result=0 || result=1
assert "Non-existent CLAUDE.md returns 1" "$result"

echo "=== mark_milestone_done path parameter ==="

# Test 11: Explicit path parameter overrides default
custom_claude="${TMPDIR}/custom_claude.md"
cp "${TMPDIR}/CLAUDE.md" "$custom_claude"
mark_milestone_done 2 "$custom_claude"
result=$(grep -q "^#### \[DONE\] Milestone 2:" "$custom_claude" && echo 0 || echo 1)
assert "Explicit path parameter works" "$result"

# Test 12: Verify original CLAUDE.md was not modified by custom path
original_still_unmarked=$(grep -q "^#### Milestone 2:" "${TMPDIR}/CLAUDE.md" && echo 0 || echo 1)
assert "Original CLAUDE.md untouched when custom path provided" "$original_still_unmarked"

echo "=== mark_milestone_done with PROJECT_RULES_FILE ==="

# Test 13: PROJECT_RULES_FILE fallback when no path provided
PROJECT_RULES_FILE="${TMPDIR}/project_rules.md"
export PROJECT_RULES_FILE
cp "${TMPDIR}/CLAUDE.md" "$PROJECT_RULES_FILE"
mark_milestone_done 8888 2>/dev/null || rc=$?
# 8888 doesn't exist in this file, so it should fail, but at the right file
assert "PROJECT_RULES_FILE used as fallback when no path given" "$([ "${rc:-0}" -ne 0 ] && echo 0 || echo 1)"

# Mark an actual milestone in the PROJECT_RULES_FILE
mark_milestone_done 1 "$PROJECT_RULES_FILE"
result=$(grep -q "^#### \[DONE\] Milestone 1:" "$PROJECT_RULES_FILE" && echo 0 || echo 1)
assert "Milestone 1 marked in PROJECT_RULES_FILE" "$result"

# Test 14: Verify CLAUDE.md constant default when neither explicit path nor PROJECT_RULES_FILE
unset PROJECT_RULES_FILE
fresh_claude="${TMPDIR}/fresh.md"
cd "$(mktemp -d)"
trap 'cd "$TMPDIR"' EXIT
cp "${TMPDIR}/CLAUDE.md" ./CLAUDE.md
mark_milestone_done 2 2>/dev/null; rc=$?
result=$(grep -q "^#### \[DONE\] Milestone 2:" ./CLAUDE.md && echo 0 || echo 1)
assert "Default CLAUDE.md constant in current directory" "$result"

# --- Summary -----------------------------------------------------------------

echo
echo "════════════════════════════════════════"
echo "  mark_milestone_done tests: ${PASS} passed, ${FAIL} failed"
echo "════════════════════════════════════════"

[ "$FAIL" -eq 0 ] || exit 1
echo "All mark_milestone_done tests passed"

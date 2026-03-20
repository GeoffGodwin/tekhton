#!/usr/bin/env bash
# =============================================================================
# test_human_orchestration_bounds.sh — Milestone 15.4.2 coverage gap tests
#
# Covers reviewer-identified gaps:
# 1. MAX_PIPELINE_ATTEMPTS count-out in _run_human_complete_loop
# 2. Flag validation via subprocess invocation (actual exit 1 paths)
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

FAIL=0

source "${TEKHTON_HOME}/lib/common.sh" 2>/dev/null || true
source "${TEKHTON_HOME}/lib/notes.sh"
source "${TEKHTON_HOME}/lib/notes_single.sh"

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$expected" = "$actual" ]]; then
        echo "PASS: $name"
    else
        echo "FAIL: $name — expected '$expected', got '$actual'"
        FAIL=1
    fi
}

# Create a HUMAN_NOTES.md with more notes than MAX_PIPELINE_ATTEMPTS
setup_large_notes() {
    cd "$TMPDIR"
    cat > HUMAN_NOTES.md << 'EOF'
# Human Notes — TestProject

## Bugs
- [ ] [BUG] Note 1
- [ ] [BUG] Note 2
- [ ] [BUG] Note 3
- [ ] [BUG] Note 4
- [ ] [BUG] Note 5
- [ ] [BUG] Note 6
- [ ] [BUG] Note 7
- [ ] [BUG] Note 8

## Features

## Polish
EOF
}

# Helper: set up a minimal valid project for subprocess invocation
setup_minimal_project() {
    local proj_dir="$1"
    mkdir -p "${proj_dir}/.claude/agents"
    mkdir -p "${proj_dir}/.claude/logs/archive"
    cat > "${proj_dir}/.claude/pipeline.conf" << 'EOF'
PROJECT_NAME="TestProject"
CLAUDE_STANDARD_MODEL="claude-sonnet-4-6"
ANALYZE_CMD="echo ok"
EOF
    for role in coder reviewer tester jr-coder; do
        echo "# ${role}" > "${proj_dir}/.claude/agents/${role}.md"
    done
    echo "# Rules" > "${proj_dir}/CLAUDE.md"
}

# =============================================================================
# Test 1: MAX_PIPELINE_ATTEMPTS count-out — loop terminates after N attempts
#
# Simulates the loop counter logic from _run_human_complete_loop. With
# MAX_PIPELINE_ATTEMPTS=3 and 8 notes, the loop should process exactly 3
# notes and leave 5 unchecked.
# =============================================================================

setup_large_notes
LOG_DIR="${TMPDIR}/logs"
TIMESTAMP="20260319_000000"
mkdir -p "$LOG_DIR"

# Reproduce the termination logic from _run_human_complete_loop
# (identical counter pattern: increment first, check second)
max_attempts=3
human_attempt=0
notes_processed=0

while true; do
    human_attempt=$((human_attempt + 1))
    if [[ "$human_attempt" -gt "$max_attempts" ]]; then
        break
    fi
    CURRENT_NOTE_LINE=$(pick_next_note "")
    if [[ -z "$CURRENT_NOTE_LINE" ]]; then
        break
    fi
    claim_single_note "$CURRENT_NOTE_LINE"
    TIMESTAMP="2026031900000${human_attempt}"
    resolve_single_note "$CURRENT_NOTE_LINE" 0
    notes_processed=$((notes_processed + 1))
done

assert_eq "1.1 MAX_PIPELINE_ATTEMPTS=3 stops after 3 notes" "3" "$notes_processed"

remaining=$(count_unchecked_notes "")
assert_eq "1.2 5 notes remain unchecked after 3-attempt limit" "5" "$remaining"

# =============================================================================
# Test 2: MAX_PIPELINE_ATTEMPTS=1 — only the first note is processed
# =============================================================================

setup_large_notes
LOG_DIR="${TMPDIR}/logs"
TIMESTAMP="20260319_000001"

max_attempts=1
human_attempt=0
notes_processed=0

while true; do
    human_attempt=$((human_attempt + 1))
    if [[ "$human_attempt" -gt "$max_attempts" ]]; then
        break
    fi
    CURRENT_NOTE_LINE=$(pick_next_note "")
    if [[ -z "$CURRENT_NOTE_LINE" ]]; then
        break
    fi
    claim_single_note "$CURRENT_NOTE_LINE"
    TIMESTAMP="2026031900010${human_attempt}"
    resolve_single_note "$CURRENT_NOTE_LINE" 0
    notes_processed=$((notes_processed + 1))
done

assert_eq "2.1 MAX_PIPELINE_ATTEMPTS=1 processes exactly 1 note" "1" "$notes_processed"

remaining=$(count_unchecked_notes "")
assert_eq "2.2 7 notes remain after 1-attempt limit" "7" "$remaining"

# =============================================================================
# Test 3: Loop exhausts all notes without hitting MAX_PIPELINE_ATTEMPTS
#
# With 8 notes and MAX_PIPELINE_ATTEMPTS=10, all 8 should be processed.
# =============================================================================

setup_large_notes
LOG_DIR="${TMPDIR}/logs"
TIMESTAMP="20260319_000002"

max_attempts=10
human_attempt=0
notes_processed=0

while true; do
    human_attempt=$((human_attempt + 1))
    if [[ "$human_attempt" -gt "$max_attempts" ]]; then
        break
    fi
    CURRENT_NOTE_LINE=$(pick_next_note "")
    if [[ -z "$CURRENT_NOTE_LINE" ]]; then
        break
    fi
    claim_single_note "$CURRENT_NOTE_LINE"
    TIMESTAMP="2026031900020${human_attempt}"
    resolve_single_note "$CURRENT_NOTE_LINE" 0
    notes_processed=$((notes_processed + 1))
done

assert_eq "3.1 all 8 notes processed when under MAX_PIPELINE_ATTEMPTS=10" "8" "$notes_processed"

remaining=$(count_unchecked_notes "")
assert_eq "3.2 0 notes remain after all processed" "0" "$remaining"

# =============================================================================
# Test 4: Flag validation via subprocess — --human --milestone exits 1
#
# Invokes tekhton.sh directly. The validation block at tekhton.sh:580-584
# should fire and exit 1 before the pipeline runs.
# =============================================================================

proj_dir=$(mktemp -d)
# shellcheck disable=SC2064
trap "rm -rf '$proj_dir'" EXIT
setup_minimal_project "$proj_dir"

# Run from the project dir so tekhton.sh resolves pipeline.conf via PROJECT_DIR=$(pwd)
rc=0
output=""
output=$(cd "$proj_dir" && bash "${TEKHTON_HOME}/tekhton.sh" --human --milestone 2>&1) || rc=$?

assert_eq "4.1 --human --milestone exits with code 1" "1" "$rc"

if echo "$output" | grep -q "Cannot combine --human with --milestone"; then
    echo "PASS: 4.2 --human --milestone error message correct"
else
    echo "FAIL: 4.2 error message missing 'Cannot combine --human with --milestone'"
    FAIL=1
fi

# =============================================================================
# Test 5: Flag validation via subprocess — --human "explicit task" exits 1
#
# Passes a positional task argument after --human. Validation at
# tekhton.sh:595-599 should fire and exit 1.
# =============================================================================

rc=0
output=""
output=$(cd "$proj_dir" && bash "${TEKHTON_HOME}/tekhton.sh" --human "explicit task string" 2>&1) || rc=$?

assert_eq "5.1 --human 'task' exits with code 1" "1" "$rc"

if echo "$output" | grep -q "Cannot combine --human with an explicit task"; then
    echo "PASS: 5.2 --human 'task' error message correct"
else
    echo "FAIL: 5.2 error message missing 'Cannot combine --human with an explicit task'"
    FAIL=1
fi

# =============================================================================

if [ "$FAIL" -ne 0 ]; then
    echo
    echo "SOME TESTS FAILED"
    exit 1
fi
echo
echo "All tests passed."

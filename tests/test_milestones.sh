#!/usr/bin/env bash
# Test: Milestone state machine — parsing, state, acceptance, and advance
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_DIR="$TMPDIR"
export TEKHTON_HOME PROJECT_DIR

source "${TEKHTON_HOME}/lib/common.sh"

# Provide stubs for config values needed by milestones.sh
PIPELINE_STATE_FILE="${TMPDIR}/.claude/PIPELINE_STATE.md"
TEST_CMD=""
ANALYZE_CMD=""
LOG_DIR="${TMPDIR}/.claude/logs"
mkdir -p "${TMPDIR}/.claude" "${LOG_DIR}"

# Override MILESTONE_STATE_FILE before sourcing
MILESTONE_STATE_FILE="${TMPDIR}/.claude/MILESTONE_STATE.md"

source "${TEKHTON_HOME}/lib/state.sh"

# Stub run_build_gate so we don't need the full gates.sh
run_build_gate() { return 0; }

source "${TEKHTON_HOME}/lib/milestones.sh"
source "${TEKHTON_HOME}/lib/milestone_ops.sh"

# cd to TMPDIR so relative CLAUDE.md paths resolve correctly (matches production behavior)
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

# --- Create a sample CLAUDE.md with milestones --------------------------------

cat > "${TMPDIR}/CLAUDE.md" << 'CLAUDE_EOF'
# Project Rules

## Implementation Milestones

#### Milestone 1: Token And Context Accounting
Add measurement infrastructure.

Acceptance criteria:
- `measure_context_size "hello world"` returns character count and estimated tokens
- `log_context_report` writes a structured breakdown
- All existing tests pass
- `bash -n lib/context.sh` passes

#### [DONE] Milestone 2: Context Compiler
Add task-scoped context assembly.

Acceptance criteria:
- `extract_relevant_sections` given a markdown file and keywords returns sections
- Feature is off by default

#### Milestone 3: Milestone State Machine And Auto-Advance
Add milestone tracking.

Acceptance criteria:
- `parse_milestones` extracts milestone list from CLAUDE.md
- `check_milestone_acceptance` runs automatable criteria
- Without `--auto-advance`, behavior is identical to 1.0
- All existing tests pass

#### Milestone 4: Mid-Run Clarification
Add structured protocol for questions.

Acceptance criteria:
- `detect_clarifications` parses items
- Blocking clarifications pause the pipeline
CLAUDE_EOF

# --- Test: parse_milestones extracts correct number of milestones -------------

echo "=== parse_milestones ==="

milestone_count=$(parse_milestones "${TMPDIR}/CLAUDE.md" | wc -l)
assert "parse_milestones finds 4 milestones" "$([ "$milestone_count" -eq 4 ] && echo 0 || echo 1)"

# Test individual milestone parsing
m1_title=$(parse_milestones "${TMPDIR}/CLAUDE.md" | awk -F'|' '$1 == 1 {print $2}')
assert "Milestone 1 title is correct" "$([ "$m1_title" = "Token And Context Accounting" ] && echo 0 || echo 1)"

m3_title=$(parse_milestones "${TMPDIR}/CLAUDE.md" | awk -F'|' '$1 == 3 {print $2}')
assert "Milestone 3 title is correct" "$([ "$m3_title" = "Milestone State Machine And Auto-Advance" ] && echo 0 || echo 1)"

# Test acceptance criteria extraction
m1_criteria=$(parse_milestones "${TMPDIR}/CLAUDE.md" | awk -F'|' '$1 == 1 {print $3}')
assert "Milestone 1 has acceptance criteria" "$([ -n "$m1_criteria" ] && echo 0 || echo 1)"
assert "Milestone 1 criteria contain test reference" "$(echo "$m1_criteria" | grep -q "tests pass" && echo 0 || echo 1)"

# --- Test: get_milestone_count ------------------------------------------------

echo "=== get_milestone_count ==="

count=$(get_milestone_count "${TMPDIR}/CLAUDE.md")
assert "get_milestone_count returns 4" "$([ "$count" -eq 4 ] && echo 0 || echo 1)"

# --- Test: get_milestone_title ------------------------------------------------

echo "=== get_milestone_title ==="

title=$(get_milestone_title 4 "${TMPDIR}/CLAUDE.md")
assert "get_milestone_title 4 returns correct title" "$([ "$title" = "Mid-Run Clarification" ] && echo 0 || echo 1)"

# --- Test: is_milestone_done --------------------------------------------------

echo "=== is_milestone_done ==="

assert "Milestone 2 is marked done" "$(is_milestone_done 2 "${TMPDIR}/CLAUDE.md" && echo 0 || echo 1)"
assert "Milestone 1 is not done" "$(! is_milestone_done 1 "${TMPDIR}/CLAUDE.md" && echo 0 || echo 1)"
assert "Milestone 3 is not done" "$(! is_milestone_done 3 "${TMPDIR}/CLAUDE.md" && echo 0 || echo 1)"

# --- Test: init_milestone_state -----------------------------------------------

echo "=== init_milestone_state ==="

init_milestone_state 3 4
assert "State file created" "$([ -f "$MILESTONE_STATE_FILE" ] && echo 0 || echo 1)"

current=$(get_current_milestone)
assert "Current milestone is 3" "$([ "$current" = "3" ] && echo 0 || echo 1)"

disposition=$(get_milestone_disposition)
assert "Initial disposition is NONE" "$([ "$disposition" = "NONE" ] && echo 0 || echo 1)"

completed=$(get_milestones_completed_this_session)
assert "Initial session count is 0" "$([ "$completed" = "0" ] && echo 0 || echo 1)"

# --- Test: write_milestone_disposition ----------------------------------------

echo "=== write_milestone_disposition ==="

write_milestone_disposition "COMPLETE_AND_CONTINUE"
disposition=$(get_milestone_disposition)
assert "Disposition updated to COMPLETE_AND_CONTINUE" "$([ "$disposition" = "COMPLETE_AND_CONTINUE" ] && echo 0 || echo 1)"

write_milestone_disposition "INCOMPLETE_REWORK"
disposition=$(get_milestone_disposition)
assert "Disposition updated to INCOMPLETE_REWORK" "$([ "$disposition" = "INCOMPLETE_REWORK" ] && echo 0 || echo 1)"

# Test invalid disposition
invalid_result=0
write_milestone_disposition "INVALID_THING" 2>/dev/null || invalid_result=$?
assert "Invalid disposition rejected" "$([ "$invalid_result" -ne 0 ] && echo 0 || echo 1)"

# --- Test: advance_milestone --------------------------------------------------

echo "=== advance_milestone ==="

init_milestone_state 1 4
write_milestone_disposition "COMPLETE_AND_CONTINUE"
advance_milestone 1 2

current=$(get_current_milestone)
assert "Current milestone advanced to 2" "$([ "$current" = "2" ] && echo 0 || echo 1)"

completed=$(get_milestones_completed_this_session)
assert "Session count incremented to 1" "$([ "$completed" = "1" ] && echo 0 || echo 1)"

# Advance again
write_milestone_disposition "COMPLETE_AND_CONTINUE"
advance_milestone 2 3

completed=$(get_milestones_completed_this_session)
assert "Session count incremented to 2" "$([ "$completed" = "2" ] && echo 0 || echo 1)"

# --- Test: find_next_milestone ------------------------------------------------

echo "=== find_next_milestone ==="

# Milestone 2 is [DONE], so next after 1 should be 3
next=$(find_next_milestone 1 "${TMPDIR}/CLAUDE.md")
assert "Next milestone after 1 skips done M2, returns 3" "$([ "$next" = "3" ] && echo 0 || echo 1)"

next=$(find_next_milestone 3 "${TMPDIR}/CLAUDE.md")
assert "Next milestone after 3 is 4" "$([ "$next" = "4" ] && echo 0 || echo 1)"

next=$(find_next_milestone 4 "${TMPDIR}/CLAUDE.md")
assert "No milestone after 4 (last)" "$([ -z "$next" ] && echo 0 || echo 1)"

# --- Test: find_next_milestone with decimal milestones (regression) -----------

echo "=== find_next_milestone decimal regression ==="

cat > "${TMPDIR}/decimal.md" << 'DECIMAL_EOF'
# Project Rules

## Current Initiative: Adaptive Pipeline 2.0

#### [DONE] Milestone 0: Security Hardening
Phase 1 complete.

Acceptance criteria:
- Config injection eliminated

#### [DONE] Milestone 0.5: Agent Output Monitoring And Null-Run Detection
Phase 2 complete.

Acceptance criteria:
- JSON output mode does not trigger false null-run

#### Milestone 1: Token And Context Accounting
Measurement infrastructure.

Acceptance criteria:
- measure_context_size returns character count

#### Milestone 2: Context Compiler
Task-scoped context assembly.

Acceptance criteria:
- extract_relevant_sections returns matching sections
DECIMAL_EOF

# Primary regression: advancing from 0.5 → next undone milestone is 1
next=$(find_next_milestone "0.5" "${TMPDIR}/decimal.md")
assert "find_next_milestone 0.5 → 1 (decimal advance path)" "$([ "$next" = "1" ] && echo 0 || echo 1)"

# Verify milestone 0 and 0.5 are correctly identified as done
assert "Milestone 0 is_milestone_done" "$(is_milestone_done 0 "${TMPDIR}/decimal.md" && echo 0 || echo 1)"
assert "Milestone 0.5 is_milestone_done" "$(is_milestone_done 0.5 "${TMPDIR}/decimal.md" && echo 0 || echo 1)"
assert "Milestone 1 is NOT done" "$(! is_milestone_done 1 "${TMPDIR}/decimal.md" && echo 0 || echo 1)"

# Verify parse_milestones captures 0.5 as its own milestone number (not 0)
m05_title=$(parse_milestones "${TMPDIR}/decimal.md" | awk -F'|' '$1 == "0.5" {print $2}')
assert "parse_milestones captures 0.5 as a distinct milestone number" "$([ -n "$m05_title" ] && echo 0 || echo 1)"

# Verify 0 is not misidentified as 0.5
m0_title=$(parse_milestones "${TMPDIR}/decimal.md" | awk -F'|' '$1 == "0" {print $2}')
m05_title_distinct=$(parse_milestones "${TMPDIR}/decimal.md" | awk -F'|' '$1 == "0.5" {print $2}')
assert "Milestone 0 and 0.5 are parsed as distinct entries" "$([ "$m0_title" != "$m05_title_distinct" ] && echo 0 || echo 1)"

# Advance path: from 0 should find 1 (skipping done 0.5)
next=$(find_next_milestone "0" "${TMPDIR}/decimal.md")
assert "find_next_milestone 0 → 1 (skips done 0.5)" "$([ "$next" = "1" ] && echo 0 || echo 1)"

# Advance path: from 1 → 2
next=$(find_next_milestone "1" "${TMPDIR}/decimal.md")
assert "find_next_milestone 1 → 2" "$([ "$next" = "2" ] && echo 0 || echo 1)"

# No milestone after 2
next=$(find_next_milestone "2" "${TMPDIR}/decimal.md")
assert "find_next_milestone 2 → empty (no more milestones)" "$([ -z "$next" ] && echo 0 || echo 1)"

# --- Test: should_auto_advance ------------------------------------------------

echo "=== should_auto_advance ==="

AUTO_ADVANCE_ENABLED=false
AUTO_ADVANCE_LIMIT=3
assert "Auto-advance disabled returns false" "$(! should_auto_advance && echo 0 || echo 1)"

AUTO_ADVANCE_ENABLED=true
init_milestone_state 1 4
write_milestone_disposition "COMPLETE_AND_CONTINUE"
should_auto_advance > /dev/null 2>&1; _sa_rc=$?
assert "Auto-advance with COMPLETE_AND_CONTINUE returns true" "$_sa_rc"

write_milestone_disposition "INCOMPLETE_REWORK"
should_auto_advance > /dev/null 2>&1 && _sa_rc=0 || _sa_rc=$?
assert "Auto-advance with INCOMPLETE_REWORK returns false" "$([ "$_sa_rc" -ne 0 ] && echo 0 || echo 1)"

# Test limit enforcement
AUTO_ADVANCE_LIMIT=2
init_milestone_state 1 4
write_milestone_disposition "COMPLETE_AND_CONTINUE"
advance_milestone 1 2
write_milestone_disposition "COMPLETE_AND_CONTINUE"
advance_milestone 2 3
write_milestone_disposition "COMPLETE_AND_CONTINUE"
should_auto_advance > /dev/null 2>&1 && _sa_rc=0 || _sa_rc=$?
assert "Auto-advance at limit returns false" "$([ "$_sa_rc" -ne 0 ] && echo 0 || echo 1)"

# --- Test: clear_milestone_state ----------------------------------------------

echo "=== clear_milestone_state ==="

init_milestone_state 1 4
assert "State file exists before clear" "$([ -f "$MILESTONE_STATE_FILE" ] && echo 0 || echo 1)"
clear_milestone_state
assert "State file removed after clear" "$([ ! -f "$MILESTONE_STATE_FILE" ] && echo 0 || echo 1)"

# --- Test: state.sh milestone field -------------------------------------------

echo "=== state.sh milestone field ==="

write_pipeline_state "coder" "interrupted" "--auto-advance" "Implement Milestone 3" "auto-advance" "3"
assert "Pipeline state includes milestone field" "$(grep -q '## Milestone' "$PIPELINE_STATE_FILE" && echo 0 || echo 1)"
saved_milestone=$(awk '/^## Milestone$/{getline; gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print; exit}' "$PIPELINE_STATE_FILE")
assert "Pipeline state milestone is 3" "$([ "$saved_milestone" = "3" ] && echo 0 || echo 1)"

# --- Test: parse varied heading formats ---------------------------------------

echo "=== parse varied heading formats ==="

cat > "${TMPDIR}/varied.md" << 'VARIED_EOF'
# Project

#### Milestone 1: Basic Setup
Setup stuff.

Acceptance criteria:
- Files created
- Tests pass

### Milestone 2 — Advanced Features
Advanced stuff.

Acceptance criteria:
- Feature works

#### Milestone 3. Final Polish
Polish stuff.

Acceptance criteria:
- Looks good
VARIED_EOF

varied_count=$(parse_milestones "${TMPDIR}/varied.md" | wc -l)
assert "Parses varied heading formats (colon, dash, period)" "$([ "$varied_count" -eq 3 ] && echo 0 || echo 1)"

# --- Test: get_milestone_commit_prefix ----------------------------------------

echo "=== get_milestone_commit_prefix ==="

prefix=$(get_milestone_commit_prefix "5" "COMPLETE_AND_CONTINUE")
assert "Complete+continue prefix has checkmark" "$([ "$prefix" = "[MILESTONE 5 ✓]" ] && echo 0 || echo 1)"

prefix=$(get_milestone_commit_prefix "3" "COMPLETE_AND_WAIT")
assert "Complete+wait prefix has checkmark" "$([ "$prefix" = "[MILESTONE 3 ✓]" ] && echo 0 || echo 1)"

prefix=$(get_milestone_commit_prefix "7" "INCOMPLETE_REWORK")
assert "Incomplete prefix says partial" "$(echo "$prefix" | grep -q "partial" && echo 0 || echo 1)"

prefix=$(get_milestone_commit_prefix "2" "REPLAN_REQUIRED")
assert "Replan prefix says partial" "$(echo "$prefix" | grep -q "partial" && echo 0 || echo 1)"

prefix=$(get_milestone_commit_prefix "1" "NONE")
assert "NONE disposition says partial" "$(echo "$prefix" | grep -q "partial" && echo 0 || echo 1)"

prefix=$(get_milestone_commit_prefix "" "COMPLETE_AND_WAIT")
assert "Empty milestone returns empty prefix" "$([ -z "$prefix" ] && echo 0 || echo 1)"

# --- Test: get_milestone_commit_body ------------------------------------------

echo "=== get_milestone_commit_body ==="

body=$(get_milestone_commit_body "1" "COMPLETE_AND_CONTINUE" "${TMPDIR}/CLAUDE.md")
assert "Complete body says COMPLETE" "$(echo "$body" | grep -q "COMPLETE" && echo 0 || echo 1)"
assert "Complete body includes milestone title" "$(echo "$body" | grep -q "Token And Context Accounting" && echo 0 || echo 1)"

body=$(get_milestone_commit_body "3" "INCOMPLETE_REWORK" "${TMPDIR}/CLAUDE.md")
assert "Rework body says PARTIAL" "$(echo "$body" | grep -q "PARTIAL" && echo 0 || echo 1)"

body=$(get_milestone_commit_body "" "COMPLETE_AND_WAIT")
assert "Empty milestone returns empty body" "$([ -z "$body" ] && echo 0 || echo 1)"

# --- Test: tag_milestone_complete (without git) --------------------------------

echo "=== tag_milestone_complete ==="

# Test that tagging is skipped when disabled (default)
MILESTONE_TAG_ON_COMPLETE=false
tag_result=0
tag_milestone_complete 1 || tag_result=$?
assert "Tagging skipped when MILESTONE_TAG_ON_COMPLETE=false" "$([ "$tag_result" -eq 0 ] && echo 0 || echo 1)"

# --- Test: tag_milestone_complete (with git repo fixture) ----------------------

echo "=== tag_milestone_complete (with git) ==="

GIT_REPO_DIR=$(mktemp -d)
trap 'rm -rf "$GIT_REPO_DIR"' EXIT

# Initialize a minimal git repo with one commit so tagging works
git -C "$GIT_REPO_DIR" init -q
git -C "$GIT_REPO_DIR" config user.email "test@example.com"
git -C "$GIT_REPO_DIR" config user.name "Test"
touch "$GIT_REPO_DIR/dummy.txt"
git -C "$GIT_REPO_DIR" add dummy.txt
git -C "$GIT_REPO_DIR" commit -q -m "init"

# Run tag_milestone_complete from inside the git repo so git tag works
(
    cd "$GIT_REPO_DIR"
    MILESTONE_TAG_ON_COMPLETE=true
    source "${TEKHTON_HOME}/lib/common.sh"
    source "${TEKHTON_HOME}/lib/milestones.sh" 2>/dev/null || true
    source "${TEKHTON_HOME}/lib/milestone_ops.sh" 2>/dev/null || true
    tag_milestone_complete 7
)
tag_exists=$(git -C "$GIT_REPO_DIR" tag -l "milestone-7-complete")
assert "tag_milestone_complete creates tag when enabled" "$([ "$tag_exists" = "milestone-7-complete" ] && echo 0 || echo 1)"

# Test idempotent: calling again with an existing tag warns but does not fail
(
    cd "$GIT_REPO_DIR"
    MILESTONE_TAG_ON_COMPLETE=true
    source "${TEKHTON_HOME}/lib/common.sh"
    source "${TEKHTON_HOME}/lib/milestones.sh" 2>/dev/null || true
    source "${TEKHTON_HOME}/lib/milestone_ops.sh" 2>/dev/null || true
    tag_milestone_complete 7
) 2>/dev/null
assert "tag_milestone_complete handles duplicate tag gracefully (no error)" "$([ $? -eq 0 ] && echo 0 || echo 1)"

# --- Test: generate_commit_message with milestone info -------------------------

echo "=== generate_commit_message with milestone ==="

# Source hooks.sh for commit message generation
source "${TEKHTON_HOME}/lib/hooks.sh"

# Create a minimal CODER_SUMMARY.md
cat > "${TMPDIR}/CODER_SUMMARY.md" << 'SUMMARY_EOF'
# Coder Summary
## Status: COMPLETE
## What Was Implemented
Added milestone commit signatures
## Files Modified
- lib/hooks.sh
- lib/milestones.sh
SUMMARY_EOF

cd "$TMPDIR"

msg=$(generate_commit_message "Implement Milestone 5: Widget System" "5" "COMPLETE_AND_CONTINUE")
assert "Milestone-complete commit has checkmark prefix" "$(echo "$msg" | head -1 | grep -q '\[MILESTONE 5 ✓\]' && echo 0 || echo 1)"
assert "Milestone-complete commit has COMPLETE in body" "$(echo "$msg" | grep -q "COMPLETE" && echo 0 || echo 1)"

msg=$(generate_commit_message "Implement Milestone 3: Foo" "3" "INCOMPLETE_REWORK")
assert "Partial commit has partial prefix" "$(echo "$msg" | head -1 | grep -q 'partial' && echo 0 || echo 1)"

msg=$(generate_commit_message "Fix: some bug" "" "")
first_line=$(echo "$msg" | head -1)
assert "Non-milestone commit has no prefix" "$(echo "$first_line" | grep -qv 'MILESTONE' && echo 0 || echo 1)"

# --- Test: Deep dot-notation milestone parsing (depth 3+) --------------------

echo "=== deep milestone parsing ==="

cat > "${TMPDIR}/deep.md" << 'DEEP_EOF'
# Project Rules

## Current Initiative: V2

#### [DONE] Milestone 13.1: Config Defaults
Done.

Acceptance criteria:
- Config loads

#### [DONE] Milestone 13.2.1.1: Retry Envelope Skeleton
Skeleton done.

Acceptance criteria:
- Skeleton works

#### [DONE] Milestone 13.2.1.2: Transient Retry Loop
Loop done.

Acceptance criteria:
- Loop works

#### Milestone 13.2.2: Stage Cleanup and Metrics
Next milestone.

Acceptance criteria:
- Tester OOM retry removed
- retry_count in metrics

#### Milestone 14: Turn Exhaustion Continuation
Future milestone.

Acceptance criteria:
- Continuation works
DEEP_EOF

# Depth-3 milestones are correctly parsed as distinct entries
m_13_2_1_1=$(parse_milestones "${TMPDIR}/deep.md" | awk -F'|' '$1 == "13.2.1.1" {print $2}')
assert "parse_milestones captures 13.2.1.1" "$([ "$m_13_2_1_1" = "Retry Envelope Skeleton" ] && echo 0 || echo 1)"

m_13_2_1_2=$(parse_milestones "${TMPDIR}/deep.md" | awk -F'|' '$1 == "13.2.1.2" {print $2}')
assert "parse_milestones captures 13.2.1.2" "$([ "$m_13_2_1_2" = "Transient Retry Loop" ] && echo 0 || echo 1)"

m_13_2_2=$(parse_milestones "${TMPDIR}/deep.md" | awk -F'|' '$1 == "13.2.2" {print $2}')
assert "parse_milestones captures 13.2.2" "$([ "$m_13_2_2" = "Stage Cleanup and Metrics" ] && echo 0 || echo 1)"

# Titles are NOT contaminated with leftover number segments
assert "13.2.1.1 title does not start with number remnant" "$(echo "$m_13_2_1_1" | grep -qvE '^[0-9]' && echo 0 || echo 1)"

# get_milestone_title works for depth-3+
title=$(get_milestone_title "13.2.1.1" "${TMPDIR}/deep.md")
assert "get_milestone_title returns correct title for 13.2.1.1" "$([ "$title" = "Retry Envelope Skeleton" ] && echo 0 || echo 1)"

# is_milestone_done works for depth-3+
assert "13.2.1.1 is_milestone_done" "$(is_milestone_done "13.2.1.1" "${TMPDIR}/deep.md" && echo 0 || echo 1)"
assert "13.2.2 is NOT done" "$(! is_milestone_done "13.2.2" "${TMPDIR}/deep.md" && echo 0 || echo 1)"

# find_next_milestone works for depth-3+
next=$(find_next_milestone "13.2.1.2" "${TMPDIR}/deep.md")
assert "find_next after 13.2.1.2 is 13.2.2" "$([ "$next" = "13.2.2" ] && echo 0 || echo 1)"

next=$(find_next_milestone "13.2.2" "${TMPDIR}/deep.md")
assert "find_next after 13.2.2 is 14" "$([ "$next" = "14" ] && echo 0 || echo 1)"

# Commit prefix uses full deep number
init_milestone_state "13.2.1.1" 4
write_milestone_disposition "COMPLETE_AND_CONTINUE"
prefix=$(get_milestone_commit_prefix "13.2.1.1" "COMPLETE_AND_CONTINUE")
assert "Commit prefix uses full deep number" "$(echo "$prefix" | grep -q '13.2.1.1' && echo 0 || echo 1)"

# Commit body uses full deep number and correct title
body=$(get_milestone_commit_body "13.2.1.1" "COMPLETE_AND_CONTINUE" "${TMPDIR}/deep.md")
assert "Commit body has 13.2.1.1" "$(echo "$body" | grep -q '13.2.1.1' && echo 0 || echo 1)"
assert "Commit body has correct title" "$(echo "$body" | grep -q 'Retry Envelope Skeleton' && echo 0 || echo 1)"

# --- Summary ------------------------------------------------------------------

echo
echo "════════════════════════════════════════"
echo "  Milestone tests: ${PASS} passed, ${FAIL} failed"
echo "════════════════════════════════════════"

[ "$FAIL" -eq 0 ] || exit 1
echo "All milestone tests passed"

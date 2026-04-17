#!/usr/bin/env bash
# =============================================================================
# test_coder_scout_tools_integration.sh — Integration test for M45 scout tool
# reduction via run_stage_coder() (closes reviewer coverage gap)
#
# Tests:
# - run_stage_coder() passes "Read Glob Grep Write" to run_agent Scout when
#   repo map is available and SCOUT_REPO_MAP_TOOLS_ONLY=true
# - run_stage_coder() passes full AGENT_TOOLS_SCOUT when
#   SCOUT_REPO_MAP_TOOLS_ONLY=false
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

cd "$TMPDIR"
mkdir -p "${TEKHTON_DIR:-.tekhton}"

# --- Set up a minimal git repo so git commands inside coder.sh don't fail ----
git init -q .
git config user.email "test@test.com"
git config user.name "Test"
git commit -q -m "init" --allow-empty

mkdir -p "$TMPDIR/logs" "$TMPDIR/.claude"

# --- Pipeline globals ---------------------------------------------------------
export PROJECT_DIR="$TMPDIR"
export TEKHTON_HOME
export LOG_FILE="$TMPDIR/test.log"
export LOG_DIR="$TMPDIR/logs"
export TIMESTAMP="20260101_120000"
export TASK="Test scout tool reduction"
export PROJECT_NAME="test-project"
export PIPELINE_STATE_FILE="$TMPDIR/.claude/PIPELINE_STATE.md"
export TEKHTON_SESSION_DIR="$TMPDIR/.claude"

# Model/turn globals
export CLAUDE_SCOUT_MODEL="claude-sonnet-4-6"
export CLAUDE_CODER_MODEL="claude-sonnet-4-6"
export SCOUT_MAX_TURNS=10
export CODER_MAX_TURNS=50
export ADJUSTED_CODER_TURNS=50
export JR_CODER_MAX_TURNS=40

# Role files
export CODER_ROLE_FILE=".claude/agents/coder.md"
export JR_CODER_ROLE_FILE=".claude/agents/jr-coder.md"
export PROJECT_RULES_FILE=".claude/CLAUDE.md"

# Tool globals
export AGENT_TOOLS_SCOUT="Read Glob Grep Bash(find:*) Bash(head:*) Bash(wc:*) Bash(cat:*) Bash(ls:*) Write"
export AGENT_TOOLS_CODER="Read Write Edit Glob Grep Bash"
export AGENT_TOOLS_BUILD_FIX="Read Write Edit Glob Grep"

# Feature flags
export DYNAMIC_TURNS_ENABLED=true
export SCOUT_CACHED=false
export MILESTONE_MODE=false
export HUMAN_NOTE_COUNT=0
export HUMAN_MODE=false
export PIPELINE_ORDER=standard
export CONTINUATION_ENABLED=false
export FIX_NONBLOCKERS_MODE=false
export NOTES_FILTER=""
export START_AT="fresh"
export ARCHITECTURE_FILE=""
export GLOSSARY_FILE=""
export CLARIFICATIONS_CONTENT=""
export TESTER_PREFLIGHT_CONTENT=""

# Agent state cleared
export AGENT_ERROR_CATEGORY=""
export AGENT_ERROR_SUBCATEGORY=""
export AGENT_ERROR_MESSAGE=""
export LAST_AGENT_TURNS=10
export LAST_AGENT_EXIT_CODE=0
export BUILD_GATE_RETRY=0

# Disable M92 pre-coder sweep — this test targets scout tool reduction, not
# baseline enforcement, and the run_agent mock only captures the Scout call.
export PRE_RUN_CLEAN_ENABLED=false

touch "$LOG_FILE"

# --- Source common.sh for log/warn/header ------------------------------------
source "${TEKHTON_HOME}/lib/common.sh"

# =============================================================================
# Mock all functions that run_stage_coder() calls
# (defined before sourcing coder.sh so they override any sourced versions)
# =============================================================================

# Agent invocation — captures tools arg for Scout call
declare -g _captured_scout_tools=""
declare -g _run_agent_call_count=0

run_agent() {
    local _name="$1"
    local _tools="${6:-}"
    _run_agent_call_count=$(( _run_agent_call_count + 1 ))

    case "$_name" in
        Scout*)
            _captured_scout_tools="$_tools"
            ;;
        Coder*)
            # Create CODER_SUMMARY.md so downstream checks pass
            cat > "$TMPDIR/CODER_SUMMARY.md" <<'EOF'
## Status: COMPLETE

## Summary
Mock coder completed the task.

## Files Modified
- lib/example.sh
EOF
            ;;
    esac
    return 0
}

# Repo map — populates REPO_MAP_CONTENT (simulates indexer output)
run_repo_map() {
    REPO_MAP_CONTENT="## src/main.sh
  run_stage_coder()
  _switch_to_sub_milestone()"
    return 0
}

# All other mocked functions (no-op or safe defaults)
render_prompt()                  { echo "# mock prompt for $1"; }
apply_scout_turn_limits()        { :; }
print_run_summary()              { :; }
was_null_run()                   { return 1; }
is_substantive_work()            { return 0; }
run_completion_gate()            { return 0; }
run_build_gate()                 { return 0; }
should_claim_notes()             { return 1; }
extract_human_notes()            { echo ""; }
claim_human_notes()              { :; }
resolve_human_notes()            { :; }
archive_human_notes()            { :; }
triage_bulk_warn()               { :; }
detect_clarifications()          { return 1; }
handle_clarifications()          { return 0; }
load_clarifications_content()    { CLARIFICATIONS_CONTENT=""; }
build_context_packet()           { :; }
_add_context_component()         { :; }
log_context_report()             { :; }
count_open_nonblocking_notes()   { echo "0"; }
get_open_nonblocking_notes()     { echo ""; }
emit_dashboard_run_state()       { :; }
emit_event()                     { :; }
log_decision()                   { :; }
progress_status()                { :; }
stage_header()                   { :; }
log_verbose()                    { :; }
_safe_read_file()                { echo ""; }
_wrap_file_content()             { echo ""; }
_phase_start()                   { :; }
_phase_end()                     { :; }
# Source context cache (M47 — needed by coder.sh)
# shellcheck disable=SC1091
source "${TEKHTON_HOME}/lib/context_cache.sh"
has_milestone_manifest()         { return 1; }
build_milestone_window()         { :; }
has_test_baseline()              { return 1; }
_test_baseline_json()            { echo "{}"; }
_build_resume_flag()             { echo "--start-at coder"; }
write_pipeline_state()           { :; }
check_milestone_size()           { return 0; }
split_milestone()                { return 1; }
handle_null_run_split()          { return 1; }
get_split_depth()                { echo "1"; }
get_milestone_title()            { echo "Test Milestone"; }
get_milestone_count()            { echo "1"; }
init_milestone_state()           { :; }
get_repo_map_slice()             { return 1; }
extract_files_from_coder_summary() { echo ""; }
record_task_file_association()   { :; }

# Source the stage under test
# shellcheck disable=SC1091
source "${TEKHTON_HOME}/stages/coder.sh"

# --- Test helpers -------------------------------------------------------------
PASS=0
FAIL=0

pass() {
    echo "  PASS: $1"
    PASS=$((PASS + 1))
}

fail() {
    echo "  FAIL: $1"
    FAIL=$((FAIL + 1))
}

# =============================================================================
# Test Suite 1: Tool reduction when SCOUT_REPO_MAP_TOOLS_ONLY=true
# =============================================================================
echo "=== Test Suite 1: Scout tools reduced when repo map available ==="

INDEXER_AVAILABLE=true
SCOUT_REPO_MAP_TOOLS_ONLY=true
REPO_MAP_CONTENT=""  # will be populated by mock run_repo_map
_captured_scout_tools=""
_run_agent_call_count=0

# Run the full coder stage
run_stage_coder 2>/dev/null

if [[ "$_captured_scout_tools" = "Read Glob Grep Write" ]]; then
    pass "1.1 run_agent Scout received reduced tool set 'Read Glob Grep Write'"
else
    fail "1.1 run_agent Scout received reduced tool set — got: '${_captured_scout_tools}'"
fi

# Verify the scout was actually called (not a no-op path)
if [[ "$_run_agent_call_count" -ge 1 ]]; then
    pass "1.2 run_agent was called at least once (scout ran)"
else
    fail "1.2 run_agent was called at least once (got 0 calls)"
fi

# Clean up CODER_SUMMARY.md before next test
rm -f "$TMPDIR/CODER_SUMMARY.md"

# =============================================================================
# Test Suite 2: Tools unchanged when SCOUT_REPO_MAP_TOOLS_ONLY=false
# =============================================================================
echo "=== Test Suite 2: Scout tools unchanged when flag is false ==="

INDEXER_AVAILABLE=true
SCOUT_REPO_MAP_TOOLS_ONLY=false
REPO_MAP_CONTENT=""
_captured_scout_tools=""
_run_agent_call_count=0

run_stage_coder 2>/dev/null

if [[ "$_captured_scout_tools" = "$AGENT_TOOLS_SCOUT" ]]; then
    pass "2.1 run_agent Scout received full AGENT_TOOLS_SCOUT when flag is false"
else
    fail "2.1 run_agent Scout received full AGENT_TOOLS_SCOUT — got: '${_captured_scout_tools}'"
fi

rm -f "$TMPDIR/CODER_SUMMARY.md"

# =============================================================================
# Test Suite 3: Tools unchanged when INDEXER_AVAILABLE=false (no repo map)
# =============================================================================
echo "=== Test Suite 3: Scout tools unchanged when indexer unavailable ==="

INDEXER_AVAILABLE=false
SCOUT_REPO_MAP_TOOLS_ONLY=true
REPO_MAP_CONTENT=""
_captured_scout_tools=""
_run_agent_call_count=0

run_stage_coder 2>/dev/null

if [[ "$_captured_scout_tools" = "$AGENT_TOOLS_SCOUT" ]]; then
    pass "3.1 run_agent Scout received full AGENT_TOOLS_SCOUT when indexer unavailable"
else
    fail "3.1 run_agent Scout received full AGENT_TOOLS_SCOUT — got: '${_captured_scout_tools}'"
fi

rm -f "$TMPDIR/CODER_SUMMARY.md"

# =============================================================================
# Summary
# =============================================================================
echo
echo "════════════════════════════════════════"
echo "  coder scout tools integration: ${PASS} passed, ${FAIL} failed"
echo "════════════════════════════════════════"

[[ "$FAIL" -eq 0 ]] || exit 1
echo "All coder scout tools integration tests passed"

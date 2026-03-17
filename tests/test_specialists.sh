#!/usr/bin/env bash
# test_specialists.sh — Tests for lib/specialists.sh (Milestone 7)
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

PROJECT_DIR="$TMPDIR_TEST"
TEKHTON_SESSION_DIR=$(mktemp -d "$TMPDIR_TEST/session_XXXXXXXX")
export TEKHTON_HOME PROJECT_DIR TEKHTON_SESSION_DIR

# Initialize git repo for agent.sh functions
(cd "$PROJECT_DIR" && git init -q && git commit --allow-empty -m "init" -q)

# cd into PROJECT_DIR since agents and specialists write files relative to cwd
cd "$PROJECT_DIR"

# --- Source required libraries ---
source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/prompts.sh"

# Stub functions that specialists.sh depends on
run_agent() { :; }
was_null_run() { return 1; }
render_prompt() { echo "stub prompt"; }
_ensure_nonblocking_log() {
    local nb_file="${PROJECT_DIR}/${NON_BLOCKING_LOG_FILE}"
    if [ ! -f "$nb_file" ]; then
        cat > "$nb_file" << 'EOF'
# Non-Blocking Notes Log

## Open

## Resolved
EOF
    fi
}
print_run_summary() { :; }
run_build_gate() { return 0; }
write_pipeline_state() { :; }
has_specialist_blockers() { [ -n "${SPECIALIST_BLOCKERS:-}" ]; }

# Set required globals
TASK="test task"
TIMESTAMP="20260317_120000"
LOG_DIR="${PROJECT_DIR}/.claude/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/test.log"
NON_BLOCKING_LOG_FILE="NON_BLOCKING_LOG.md"
CLAUDE_STANDARD_MODEL="claude-sonnet-4-6"
AGENT_TOOLS_REVIEWER="Read Glob Grep Write"
BOLD=""
NC=""

# --- Source specialists.sh ---
source "${TEKHTON_HOME}/lib/specialists.sh"

PASS=0
FAIL=0

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo -e "\033[0;32mPASS\033[0m $label"
        PASS=$((PASS + 1))
    else
        echo -e "\033[0;31mFAIL\033[0m $label — expected='$expected', got='$actual'"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local label="$1" expected="$2" actual="$3"
    if echo "$actual" | grep -qF "$expected"; then
        echo -e "\033[0;32mPASS\033[0m $label"
        PASS=$((PASS + 1))
    else
        echo -e "\033[0;31mFAIL\033[0m $label — expected to contain '$expected'"
        FAIL=$((FAIL + 1))
    fi
}

# =============================================================================
# Test 1: No specialists enabled → returns 0
# =============================================================================
SPECIALIST_SECURITY_ENABLED=false
SPECIALIST_PERFORMANCE_ENABLED=false
SPECIALIST_API_ENABLED=false
result=0
run_specialist_reviews || result=$?
assert_eq "No specialists enabled returns 0" "0" "$result"

# =============================================================================
# Test 2: Config defaults populated by config.sh defaults
# =============================================================================
assert_eq "Security model defaults to standard" "$CLAUDE_STANDARD_MODEL" "${SPECIALIST_SECURITY_MODEL:-$CLAUDE_STANDARD_MODEL}"
assert_eq "Performance max turns defaults to 8" "8" "${SPECIALIST_PERFORMANCE_MAX_TURNS:-8}"
assert_eq "API enabled defaults to false" "false" "${SPECIALIST_API_ENABLED:-false}"

# =============================================================================
# Test 3: _resolve_specialist_config for built-in specialist
# =============================================================================
SPECIALIST_SECURITY_MODEL="claude-opus-4-6"
SPECIALIST_SECURITY_MAX_TURNS=12

_resolve_specialist_config "security" _t_model _t_turns _t_prompt
assert_eq "Built-in model resolved" "claude-opus-4-6" "$_t_model"
assert_eq "Built-in turns resolved" "12" "$_t_turns"
assert_eq "Built-in prompt resolved" "specialist_security" "$_t_prompt"

# Reset
SPECIALIST_SECURITY_MODEL="$CLAUDE_STANDARD_MODEL"
SPECIALIST_SECURITY_MAX_TURNS=8

# =============================================================================
# Test 4: _resolve_specialist_config for custom specialist
# =============================================================================
export SPECIALIST_CUSTOM_MYCHECK_PROMPT="specialist_mycheck"
export SPECIALIST_CUSTOM_MYCHECK_MODEL="claude-haiku-4-5"
export SPECIALIST_CUSTOM_MYCHECK_MAX_TURNS=6

_resolve_specialist_config "mycheck" _t_model _t_turns _t_prompt
assert_eq "Custom model resolved" "claude-haiku-4-5" "$_t_model"
assert_eq "Custom turns resolved" "6" "$_t_turns"
assert_eq "Custom prompt resolved" "specialist_mycheck" "$_t_prompt"

unset SPECIALIST_CUSTOM_MYCHECK_PROMPT SPECIALIST_CUSTOM_MYCHECK_MODEL SPECIALIST_CUSTOM_MYCHECK_MAX_TURNS

# =============================================================================
# Test 5: _collect_custom_specialists finds enabled custom specialists
# =============================================================================
export SPECIALIST_CUSTOM_FOO_ENABLED=true
export SPECIALIST_CUSTOM_FOO_PROMPT="specialist_foo"
export SPECIALIST_CUSTOM_BAR_ENABLED=false
export SPECIALIST_CUSTOM_BAR_PROMPT="specialist_bar"

declare -a custom_specs=()
_collect_custom_specialists custom_specs

# Should have foo but not bar
found_foo=false
found_bar=false
for s in "${custom_specs[@]}"; do
    [ "$s" = "foo" ] && found_foo=true
    [ "$s" = "bar" ] && found_bar=true
done
assert_eq "Custom foo collected" "true" "$found_foo"
assert_eq "Custom bar NOT collected" "false" "$found_bar"

unset SPECIALIST_CUSTOM_FOO_ENABLED SPECIALIST_CUSTOM_FOO_PROMPT
unset SPECIALIST_CUSTOM_BAR_ENABLED SPECIALIST_CUSTOM_BAR_PROMPT

# =============================================================================
# Test 6: _extract_specialist_blockers reads [BLOCKER] items
# =============================================================================
cat > "${PROJECT_DIR}/SPECIALIST_SECURITY_FINDINGS.md" << 'EOF'
# Security Review Findings

## Blockers
- [BLOCKER] lib/config.sh:42 — Command injection via unescaped variable

## Notes
- [NOTE] lib/agent.sh:10 — Consider adding rate limiting
EOF

blockers=$(_extract_specialist_blockers "security")
assert_contains "Blocker extracted" "[BLOCKER]" "$blockers"
assert_contains "Blocker has file ref" "lib/config.sh:42" "$blockers"

rm -f "${PROJECT_DIR}/SPECIALIST_SECURITY_FINDINGS.md"

# =============================================================================
# Test 7: _extract_specialist_blockers returns empty when no blockers
# =============================================================================
cat > "${PROJECT_DIR}/SPECIALIST_PERFORMANCE_FINDINGS.md" << 'EOF'
# Performance Review Findings

## Blockers
None

## Notes
- [NOTE] lib/agent.sh:10 — Consider caching
EOF

blockers=$(_extract_specialist_blockers "performance")
assert_eq "No blockers returns empty" "" "$blockers"

rm -f "${PROJECT_DIR}/SPECIALIST_PERFORMANCE_FINDINGS.md"

# =============================================================================
# Test 8: _append_specialist_notes adds [NOTE] items to NON_BLOCKING_LOG.md
# =============================================================================
cat > "${PROJECT_DIR}/SPECIALIST_API_FINDINGS.md" << 'EOF'
# API Contract Review Findings

## Notes
- [NOTE] lib/agent.sh:10 — Missing validation on public interface

## Summary
Clean
EOF

_append_specialist_notes "api"

nb_file="${PROJECT_DIR}/${NON_BLOCKING_LOG_FILE}"
assert_eq "Non-blocking log exists" "true" "$([ -f "$nb_file" ] && echo true || echo false)"

nb_content=$(cat "$nb_file")
assert_contains "Note appended to log" "specialist:api" "$nb_content"
assert_contains "Note text in log" "Missing validation" "$nb_content"

rm -f "${PROJECT_DIR}/SPECIALIST_API_FINDINGS.md"

# =============================================================================
# Test 9: Specialist reviews with security enabled runs the specialist
# =============================================================================
SPECIALIST_SECURITY_ENABLED=true
_specialist_ran=false

# Override run_agent to detect the call and create findings
run_agent() {
    local label="$1"
    if [[ "$label" == *"Specialist"* ]]; then
        _specialist_ran=true
        # Create empty findings (no blockers)
        cat > "${PROJECT_DIR}/SPECIALIST_SECURITY_FINDINGS.md" << 'SEOF'
# Security Review Findings

## Blockers
None

## Notes
None
SEOF
    fi
}

result=0
run_specialist_reviews || result=$?
assert_eq "Specialist ran when enabled" "true" "$_specialist_ran"
assert_eq "No blockers returns 0" "0" "$result"

# Reset
SPECIALIST_SECURITY_ENABLED=false
rm -f "${PROJECT_DIR}/SPECIALIST_SECURITY_FINDINGS.md" "${PROJECT_DIR}/SPECIALIST_REPORT.md"

# Restore original stub
run_agent() { :; }

# =============================================================================
# Test 10: run_specialist_reviews() returns 1 when specialist finds a [BLOCKER]
# =============================================================================
SPECIALIST_SECURITY_ENABLED=true
_specialist_ran_t10=false

run_agent() {
    local label="$1"
    if [[ "$label" == *"Specialist"* ]]; then
        _specialist_ran_t10=true
        # Create findings with a [BLOCKER] item
        cat > "${PROJECT_DIR}/SPECIALIST_SECURITY_FINDINGS.md" << 'SEOF'
# Security Review Findings

## Blockers
- [BLOCKER] lib/config.sh:42 — Command injection via unescaped variable

## Notes
None
SEOF
    fi
}

SPECIALIST_BLOCKERS=""
result_t10=0
run_specialist_reviews || result_t10=$?

assert_eq "Blocker path: specialist ran" "true" "$_specialist_ran_t10"
assert_eq "Blocker path: returns 1" "1" "$result_t10"
assert_contains "Blocker path: SPECIALIST_BLOCKERS populated" "[BLOCKER]" "${SPECIALIST_BLOCKERS}"

# Reset
SPECIALIST_SECURITY_ENABLED=false
SPECIALIST_BLOCKERS=""
rm -f "${PROJECT_DIR}/SPECIALIST_SECURITY_FINDINGS.md" "${PROJECT_DIR}/SPECIALIST_REPORT.md"

# Restore original stub
run_agent() { :; }

# =============================================================================
# Test 11: AGENT_TOOLS_SPECIALIST resolves at call time, not source time
# Verifies the fix: variable is set inside run_specialist_reviews() so changes
# to AGENT_TOOLS_REVIEWER after sourcing are picked up.
# =============================================================================
SPECIALIST_SECURITY_ENABLED=true
_captured_tools=""

run_agent() {
    local label="$1"
    if [[ "$label" == *"Specialist"* ]]; then
        # Capture the AGENT_TOOLS_SPECIALIST that was set by run_specialist_reviews
        _captured_tools="$AGENT_TOOLS_SPECIALIST"
        cat > "${PROJECT_DIR}/SPECIALIST_SECURITY_FINDINGS.md" << 'SEOF'
# Security Review Findings
## Blockers
None
## Notes
None
SEOF
    fi
}

# Change AGENT_TOOLS_REVIEWER AFTER sourcing specialists.sh
# The old source-time freeze would still return the original value;
# the call-time fix must pick up this new value.
AGENT_TOOLS_REVIEWER="Read Glob Grep Write Edit"

result_t11=0
run_specialist_reviews || result_t11=$?
assert_eq "Call-time resolution: no blockers" "0" "$result_t11"
assert_eq "Call-time resolution: picks up updated AGENT_TOOLS_REVIEWER" \
    "Read Glob Grep Write Edit" "$_captured_tools"

# Reset
SPECIALIST_SECURITY_ENABLED=false
AGENT_TOOLS_REVIEWER="Read Glob Grep Write"
rm -f "${PROJECT_DIR}/SPECIALIST_SECURITY_FINDINGS.md" "${PROJECT_DIR}/SPECIALIST_REPORT.md"

# Restore original stub
run_agent() { :; }

# =============================================================================
# Test 12: _append_specialist_notes — backslash sequences are not interpreted
# Regression test for the awk fix: sed -i would corrupt \n, \t in note text.
# =============================================================================
cat > "${PROJECT_DIR}/SPECIALIST_SECURITY_FINDINGS.md" << 'EOF'
# Security Review Findings

## Notes
- [NOTE] lib/agent.sh:42 — Use \n instead of \\n for newlines; path is C:\Users\foo
EOF

# Remove any existing log so we start fresh
rm -f "${PROJECT_DIR}/${NON_BLOCKING_LOG_FILE}"

_append_specialist_notes "security"

nb_content=$(cat "${PROJECT_DIR}/${NON_BLOCKING_LOG_FILE}")
# The literal backslash sequences must survive unchanged
assert_contains "Backslash-n literal preserved" 'Use \n instead of' "$nb_content"
assert_contains "Windows path backslashes preserved" 'C:\Users\foo' "$nb_content"

rm -f "${PROJECT_DIR}/SPECIALIST_SECURITY_FINDINGS.md"

# =============================================================================
# Test 13: _append_specialist_notes — note text with special chars (brackets, pipes)
# =============================================================================
cat > "${PROJECT_DIR}/SPECIALIST_SECURITY_FINDINGS.md" << 'EOF'
# Security Review Findings

## Notes
- [NOTE] lib/agent.sh:10 — Check input [user|admin] values & escape pipes
EOF

rm -f "${PROJECT_DIR}/${NON_BLOCKING_LOG_FILE}"

_append_specialist_notes "security"

nb_content=$(cat "${PROJECT_DIR}/${NON_BLOCKING_LOG_FILE}")
assert_contains "Brackets preserved" '[user|admin]' "$nb_content"
assert_contains "Ampersand preserved" '& escape pipes' "$nb_content"

rm -f "${PROJECT_DIR}/SPECIALIST_SECURITY_FINDINGS.md"

# =============================================================================
# Results
# =============================================================================
echo
echo "────────────────────────────────────────"
echo "  Passed: $PASS  Failed: $FAIL"
echo "────────────────────────────────────────"

[ "$FAIL" -eq 0 ] || exit 1

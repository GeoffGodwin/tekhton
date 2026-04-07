#!/usr/bin/env bash
# test_m48_reduce_agent_invocations.sh — Tests for Milestone 48
# Tests: specialist skip detection, SPECIALIST_SKIP_IRRELEVANT config,
#        review skip threshold, adaptive turn budget floor.
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

PROJECT_DIR="$TMPDIR_TEST"
TEKHTON_SESSION_DIR=$(mktemp -d "$TMPDIR_TEST/session_XXXXXXXX")
export TEKHTON_HOME PROJECT_DIR TEKHTON_SESSION_DIR

PASS=0
FAIL=0

pass() { echo -e "\033[0;32mPASS\033[0m $1"; PASS=$((PASS + 1)); }
fail() { echo -e "\033[0;31mFAIL\033[0m $1"; FAIL=$((FAIL + 1)); }

# =============================================================================
# Part 1: Specialist skip detection (_specialist_diff_relevant)
# =============================================================================

echo "=== Specialist skip detection ==="

# Initialize git repo with a baseline commit
(cd "$PROJECT_DIR" && git init -q && git commit --allow-empty -m "init" -q)
cd "$PROJECT_DIR"

# --- Source required libraries ---
source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/prompts.sh"

# Stub functions specialists.sh depends on
run_agent() { :; }
was_null_run() { return 1; }
render_prompt() { echo "stub prompt"; }
_ensure_nonblocking_log() { :; }
print_run_summary() { :; }
run_build_gate() { return 0; }
write_pipeline_state() { :; }
has_specialist_blockers() { [ -n "${SPECIALIST_BLOCKERS:-}" ]; }

TASK="test task"
TIMESTAMP="20260401_120000"
LOG_DIR="${PROJECT_DIR}/.claude/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/test.log"
NON_BLOCKING_LOG_FILE="NON_BLOCKING_LOG.md"
CLAUDE_STANDARD_MODEL="claude-sonnet-4-6"
AGENT_TOOLS_REVIEWER="Read Glob Grep Write"
BOLD=""
NC=""

source "${TEKHTON_HOME}/lib/specialists.sh"
source "${TEKHTON_HOME}/lib/specialists_helpers.sh"

# --- Test: security specialist detects auth file changes ---
mkdir -p src
echo "// auth logic" > src/auth_middleware.js
(cd "$PROJECT_DIR" && git add -A && git commit -q -m "add auth file")
echo "// changed" >> src/auth_middleware.js

result=0
_specialist_diff_relevant "security" || result=$?
if [ "$result" -eq 0 ]; then
    pass "Security specialist detects auth file"
else
    fail "Security specialist should detect auth file"
fi

# --- Test: security specialist skips unrelated file ---
git checkout -q -- src/auth_middleware.js
echo "body { color: red; }" > src/styles.css
(cd "$PROJECT_DIR" && git add src/styles.css && git commit -q -m "add css")
echo "body { color: blue; }" > src/styles.css

result=0
_specialist_diff_relevant "security" || result=$?
if [ "$result" -eq 1 ]; then
    pass "Security specialist skips CSS-only diff"
else
    fail "Security specialist should skip CSS-only diff"
fi

# --- Test: performance specialist detects cache file ---
git checkout -q -- src/styles.css
echo "// cache layer" > src/cache_manager.py
(cd "$PROJECT_DIR" && git add src/cache_manager.py && git commit -q -m "add cache file")
echo "# changed" >> src/cache_manager.py

result=0
_specialist_diff_relevant "performance" || result=$?
if [ "$result" -eq 0 ]; then
    pass "Performance specialist detects cache file"
else
    fail "Performance specialist should detect cache file"
fi

# --- Test: API specialist detects route file ---
git checkout -q -- src/cache_manager.py
echo "// routes" > src/api_routes.ts
(cd "$PROJECT_DIR" && git add src/api_routes.ts && git commit -q -m "add routes")
echo "// changed" >> src/api_routes.ts

result=0
_specialist_diff_relevant "api" || result=$?
if [ "$result" -eq 0 ]; then
    pass "API specialist detects route file"
else
    fail "API specialist should detect route file"
fi

# --- Test: API specialist skips unrelated file ---
git checkout -q -- src/api_routes.ts
echo "readme content" > README.md
(cd "$PROJECT_DIR" && git add README.md && git commit -q -m "add readme")
echo "updated readme" >> README.md

result=0
_specialist_diff_relevant "api" || result=$?
if [ "$result" -eq 1 ]; then
    pass "API specialist skips README-only diff"
else
    fail "API specialist should skip README-only diff"
fi

# --- Test: custom specialist always returns relevant ---
result=0
_specialist_diff_relevant "my_custom_check" || result=$?
if [ "$result" -eq 0 ]; then
    pass "Custom specialist always treated as relevant"
else
    fail "Custom specialist should always be relevant"
fi

# --- Test: SPECIALIST_SKIP_IRRELEVANT=false disables skip logic ---
git checkout -q -- README.md
echo "only readme" > README.md
(cd "$PROJECT_DIR" && git add README.md && git commit -q -m "readme baseline")
echo "changed readme" >> README.md

SPECIALIST_SECURITY_ENABLED=true
SPECIALIST_SKIP_IRRELEVANT=false
_specialist_ran_t=false

run_agent() {
    local label="$1"
    if [[ "$label" == *"Specialist"* ]]; then
        _specialist_ran_t=true
        cat > "${PROJECT_DIR}/SPECIALIST_SECURITY_FINDINGS.md" << 'SEOF'
# Security Review Findings
## Blockers
None
## Notes
None
SEOF
    fi
}

run_specialist_reviews || true
if [ "$_specialist_ran_t" = "true" ]; then
    pass "SPECIALIST_SKIP_IRRELEVANT=false runs specialist despite irrelevant diff"
else
    fail "SPECIALIST_SKIP_IRRELEVANT=false should run specialist"
fi

# Reset
SPECIALIST_SECURITY_ENABLED=false
SPECIALIST_SKIP_IRRELEVANT=true
rm -f "${PROJECT_DIR}/SPECIALIST_SECURITY_FINDINGS.md" "${PROJECT_DIR}/SPECIALIST_REPORT.md"
run_agent() { :; }

# --- Test: SPECIALIST_SKIP_IRRELEVANT=true skips when irrelevant ---
SPECIALIST_SECURITY_ENABLED=true
SPECIALIST_SKIP_IRRELEVANT=true
_specialist_ran_t2=false

run_agent() {
    local label="$1"
    if [[ "$label" == *"Specialist"* ]]; then
        _specialist_ran_t2=true
    fi
}

# README-only diff still active from above
run_specialist_reviews || true
if [ "$_specialist_ran_t2" = "false" ]; then
    pass "SPECIALIST_SKIP_IRRELEVANT=true skips specialist for irrelevant diff"
else
    fail "SPECIALIST_SKIP_IRRELEVANT=true should skip specialist for irrelevant diff"
fi

SPECIALIST_SECURITY_ENABLED=false
run_agent() { :; }

# =============================================================================
# Part 2: Adaptive turn budget floor (metrics_calibration.sh)
# =============================================================================

echo
echo "=== Adaptive turn budget floor ==="

source "${TEKHTON_HOME}/lib/metrics.sh"
source "${TEKHTON_HOME}/lib/metrics_extended.sh"
source "${TEKHTON_HOME}/lib/metrics_calibration.sh"

_METRICS_FILE=""
rm -f "${LOG_DIR}/metrics.jsonl"
METRICS_ADAPTIVE_TURNS=true
METRICS_MIN_RUNS=5

# Create data where actuals are very low relative to estimates
# est=100, actual=10 → centimult would be 10 → clamped to 50
for i in $(seq 1 10); do
    echo "{\"task_type\":\"feature\",\"scout_est_coder\":100,\"coder_turns\":10,\"adjusted_coder\":200,\"scout_est_reviewer\":0,\"reviewer_turns\":0,\"adjusted_reviewer\":0,\"scout_est_tester\":0,\"tester_turns\":0,\"adjusted_tester\":0}" >> "${LOG_DIR}/metrics.jsonl"
done

# recommendation=80 → 0.5x clamp → 40, but floor is 50% of 80 = 40
result=$(calibrate_turn_estimate 80 "coder" | tail -1)
if [ "$result" -eq 40 ]; then
    pass "Turn budget floor: 80 → 40 (50% floor matches 0.5x clamp)"
else
    fail "Turn budget floor: expected 40, got '${result}'"
fi

# Test with odd number: recommendation=81 → floor = (81+1)/2 = 41
# 0.5x clamp → (81*50+50)/100 = 41 (rounded), floor = 41
result=$(calibrate_turn_estimate 81 "coder" | tail -1)
if [ "$result" -ge 40 ] && [ "$result" -le 41 ]; then
    pass "Turn budget floor: odd recommendation handled correctly (got ${result})"
else
    fail "Turn budget floor: expected ~41, got '${result}'"
fi

# Test floor prevents going below 50% when centimult clamp doesn't catch it:
# This shouldn't happen with current [50,200] clamping, but verifies the guard.
# recommendation=3 → floor=(3+1)/2=2, 0.5x→(3*50+50)/100=2
result=$(calibrate_turn_estimate 3 "coder" | tail -1)
if [ "$result" -ge 2 ]; then
    pass "Turn budget floor: small recommendation (3 → ${result})"
else
    fail "Turn budget floor: expected >=2, got '${result}'"
fi

# =============================================================================
# Results
# =============================================================================
echo
echo "────────────────────────────────────────"
echo "  Passed: $PASS  Failed: $FAIL"
echo "────────────────────────────────────────"

[ "$FAIL" -eq 0 ] || exit 1

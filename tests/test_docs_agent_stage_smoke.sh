#!/usr/bin/env bash
# Test: run_stage_docs() function signature, non-blocking behavior, and flag
# gating. Validates that the stage returns 0 on agent failure, respects
# DOCS_AGENT_ENABLED and SKIP_DOCS flags, and calls run_agent correctly.
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# Create a temporary project dir with a git repo
TEST_TMPDIR=$(mktemp -d)
export PROJECT_DIR="$TEST_TMPDIR"
export TEKHTON_DIR="${TEST_TMPDIR}/.tekhton"
mkdir -p "$TEKHTON_DIR"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

cd "$TEST_TMPDIR"
git init -q
git config user.email "test@test.com"
git config user.name "Test"

# Create baseline content so git diff has something to show
echo "# README" > README.md
git add README.md
git commit -q -m "baseline"
echo "# Updated README" > README.md

# Stub logging functions
log()     { :; }
success() { :; }
warn()    { :; }
error()   { :; }
header()  { :; }
print_run_summary() { :; }
emit_event() { echo "evt_000"; }
emit_dashboard_run_state() { :; }
emit_dashboard_reports() { :; }
progress_status() { :; }
progress_outcome() { :; }
stage_header() { :; }
log_verbose() { :; }
render_prompt() { echo "rendered prompt for $1"; }
_safe_read_file() { cat "$1" 2>/dev/null || true; }

# Track run_agent calls
AGENT_CALLS=()
AGENT_FAIL=false
export LAST_AGENT_TURNS=0

run_agent() {
    AGENT_CALLS+=("$1|$2|$3")
    if [[ "$AGENT_FAIL" == "true" ]]; then
        return 1
    fi
    return 0
}

# Config defaults — exported for sourced functions
export DOCS_AGENT_ENABLED=false
export DOCS_AGENT_MODEL="claude-haiku-4-5-20251001"
export DOCS_AGENT_MAX_TURNS=10
export DOCS_AGENT_REPORT_FILE="${TEKHTON_DIR}/DOCS_AGENT_REPORT.md"
export DOCS_README_FILE="README.md"
export DOCS_DIRS="docs/"
export SKIP_DOCS=false
export PIPELINE_STAGE_COUNT=5
export PIPELINE_STAGE_POS=2
export LOG_FILE="/dev/null"
export CODER_SUMMARY_FILE="${TEKHTON_DIR}/CODER_SUMMARY.md"
export PROJECT_RULES_FILE="${TEST_TMPDIR}/CLAUDE.md"
export AGENT_TOOLS_CODER="Read Write Edit Glob Grep Bash"

# Create CLAUDE.md with Documentation Responsibilities
cat > "$PROJECT_RULES_FILE" << 'EOF'
# TestProject
## Documentation Responsibilities
- README.md is the primary doc
- docs/ directory for guides
- Public surface: CLI flags, config keys
EOF

# Source the files under test
# shellcheck source=../lib/docs_agent.sh
source "${TEKHTON_HOME}/lib/docs_agent.sh"
# shellcheck source=../stages/docs.sh
source "${TEKHTON_HOME}/stages/docs.sh"

# --- Test 1: Disabled → skip, no agent call ---
echo "=== Test 1: disabled → skip ==="
DOCS_AGENT_ENABLED=false
AGENT_CALLS=()
run_stage_docs
rc=$?
if [[ "$rc" -eq 0 ]] && [[ ${#AGENT_CALLS[@]} -eq 0 ]]; then
    pass "returns 0 with no agent call when disabled"
else
    fail "expected 0 exit and 0 agent calls, got rc=${rc} calls=${#AGENT_CALLS[@]}"
fi

# --- Test 2: SKIP_DOCS=true → skip, no agent call ---
echo "=== Test 2: --skip-docs → skip ==="
DOCS_AGENT_ENABLED=true
SKIP_DOCS=true
AGENT_CALLS=()
run_stage_docs
rc=$?
if [[ "$rc" -eq 0 ]] && [[ ${#AGENT_CALLS[@]} -eq 0 ]]; then
    pass "returns 0 with no agent call when SKIP_DOCS=true"
else
    fail "expected 0 exit and 0 agent calls, got rc=${rc} calls=${#AGENT_CALLS[@]}"
fi

# --- Test 3: Enabled, public surface changed → calls agent ---
echo "=== Test 3: enabled + public surface change → agent called ==="
DOCS_AGENT_ENABLED=true
SKIP_DOCS=false
AGENT_CALLS=()
run_stage_docs
rc=$?
if [[ "$rc" -eq 0 ]] && [[ ${#AGENT_CALLS[@]} -eq 1 ]]; then
    # Verify agent was called with correct model and turns
    call="${AGENT_CALLS[0]}"
    if [[ "$call" == *"claude-haiku-4-5-20251001"* ]] && [[ "$call" == *"|10" ]]; then
        pass "agent called with model=haiku, turns=10"
    else
        fail "agent called with unexpected args: ${call}"
    fi
else
    fail "expected 1 agent call, got ${#AGENT_CALLS[@]} (rc=${rc})"
fi

# --- Test 4: Agent failure → stage still returns 0 (non-blocking) ---
echo "=== Test 4: agent failure → non-blocking ==="
AGENT_FAIL=true
AGENT_CALLS=()
run_stage_docs
rc=$?
if [[ "$rc" -eq 0 ]]; then
    pass "returns 0 even when agent fails (non-blocking)"
else
    fail "expected 0 exit on agent failure, got ${rc}"
fi
AGENT_FAIL=false

# --- Test 5: Custom model and turns from config ---
echo "=== Test 5: custom model/turns ==="
DOCS_AGENT_MODEL="claude-sonnet-4-6"
DOCS_AGENT_MAX_TURNS=20
AGENT_CALLS=()
run_stage_docs
rc=$?
if [[ ${#AGENT_CALLS[@]} -eq 1 ]]; then
    call="${AGENT_CALLS[0]}"
    if [[ "$call" == *"claude-sonnet-4-6"* ]] && [[ "$call" == *"|20" ]]; then
        pass "agent called with custom model and turns"
    else
        fail "expected custom model/turns, got: ${call}"
    fi
else
    fail "expected 1 agent call, got ${#AGENT_CALLS[@]}"
fi

# --- Summary ---
echo
echo "Results: ${PASS} passed, ${FAIL} failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi

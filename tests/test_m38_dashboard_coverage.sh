#!/usr/bin/env bash
# =============================================================================
# test_m38_dashboard_coverage.sh — Coverage gaps from M38 reviewer report
#
# Gap 1: _extract_milestone_summary() — positive path (## Overview found),
#         negative path (no Overview section), missing-file path.
# Gap 2: emit_dashboard_run_state() emit-time "pending"→"active" override
#         when CURRENT_STAGE is set but _STAGE_STATUS was never updated.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

export PROJECT_DIR="$TMPDIR"
export TEKHTON_HOME

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Minimal stubs required to source dashboard_parsers.sh + dashboard_emitters.sh
# without the full pipeline environment.
# ---------------------------------------------------------------------------
log()     { :; }
warn()    { :; }
error()   { :; }
success() { :; }
header()  { :; }

is_dashboard_enabled() { return 0; }

_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s' "$s"
}

# Source the parsers (provides _write_js_file, _to_js_timestamp, _to_js_string)
# shellcheck source=../lib/dashboard_parsers.sh
source "${TEKHTON_HOME}/lib/dashboard_parsers.sh"

# Source the emitters (provides _extract_milestone_summary, emit_dashboard_milestones, etc.)
# shellcheck source=../lib/dashboard_emitters.sh
source "${TEKHTON_HOME}/lib/dashboard_emitters.sh"

# Source dashboard.sh for emit_dashboard_run_state (it re-sources parsers+emitters, harmless)
# shellcheck source=../lib/dashboard.sh
source "${TEKHTON_HOME}/lib/dashboard.sh"

# =============================================================================
# Test Suite 1: _extract_milestone_summary()
# =============================================================================
echo "=== Test Suite 1: _extract_milestone_summary() ==="

# --- 1.1: Positive path — file has ## Overview, returns first paragraph ------
cat > "$TMPDIR/ms_with_overview.md" << 'EOF'
# Milestone 1 — DAG Infrastructure

## Overview
This milestone implements the core DAG parser and manifest loader.
It enables dependency-aware milestone ordering for the pipeline.

## Acceptance Criteria
- load_manifest() parses MANIFEST.cfg correctly
EOF

result=$(_extract_milestone_summary "$TMPDIR/ms_with_overview.md")

# The function collects all consecutive non-blank lines after ## Overview as one paragraph,
# joining with spaces. Both lines above the blank separator should appear.
expected="This milestone implements the core DAG parser and manifest loader. It enables dependency-aware milestone ordering for the pipeline."
if [[ "$result" = "$expected" ]]; then
    pass "1.1 _extract_milestone_summary returns full first paragraph joined with spaces (stops at blank line)"
else
    fail "1.1 expected: '$expected', got: '$result'"
fi

# --- 1.2: Positive path — multi-line paragraph before blank line -------------
cat > "$TMPDIR/ms_multiline.md" << 'EOF'
# Milestone 2

## Overview
First line of overview.
Second line of overview.

Third paragraph (should not be included).

## Acceptance Criteria
- something
EOF

result=$(_extract_milestone_summary "$TMPDIR/ms_multiline.md")

if echo "$result" | grep -q "First line of overview." && \
   echo "$result" | grep -q "Second line of overview." && \
   ! echo "$result" | grep -q "Third paragraph"; then
    pass "1.2 _extract_milestone_summary captures multi-line first paragraph, stops at blank line"
else
    fail "1.2 multi-line paragraph: got: '$result'"
fi

# --- 1.3: Positive path — long content is capped at 300 chars with ellipsis -
long_line=$(python3 -c "print('x' * 350)" 2>/dev/null || printf '%0.s-' {1..350})
cat > "$TMPDIR/ms_long.md" << EOF
## Overview
${long_line}

## Other Section
ignored
EOF

result=$(_extract_milestone_summary "$TMPDIR/ms_long.md")

if [[ ${#result} -le 300 ]]; then
    pass "1.3 _extract_milestone_summary caps output at 300 chars"
else
    fail "1.3 output length ${#result} exceeds 300 chars"
fi

if [[ "$result" = *"..." ]]; then
    pass "1.3b capped output ends with ellipsis"
else
    fail "1.3b capped output missing ellipsis: '${result: -10}'"
fi

# --- 1.4: Negative path — no ## Overview section in file --------------------
cat > "$TMPDIR/ms_no_overview.md" << 'EOF'
# Milestone with no overview

## Acceptance Criteria
- Something must work

## Watch For
- Edge cases
EOF

result=$(_extract_milestone_summary "$TMPDIR/ms_no_overview.md")

if [[ -z "$result" ]]; then
    pass "1.4 _extract_milestone_summary returns empty string when no ## Overview section"
else
    fail "1.4 expected empty string for missing Overview, got: '$result'"
fi

# --- 1.5: Negative path — file does not exist --------------------------------
result=$(_extract_milestone_summary "$TMPDIR/nonexistent_milestone.md")

if [[ -z "$result" ]]; then
    pass "1.5 _extract_milestone_summary returns empty string for missing file"
else
    fail "1.5 expected empty string for missing file, got: '$result'"
fi

# --- 1.6: ## Overview immediately followed by another heading (no content) --
cat > "$TMPDIR/ms_empty_overview.md" << 'EOF'
# Milestone 3

## Overview

## Acceptance Criteria
- Something
EOF

result=$(_extract_milestone_summary "$TMPDIR/ms_empty_overview.md")

if [[ -z "$result" ]]; then
    pass "1.6 _extract_milestone_summary returns empty string for blank Overview section"
else
    fail "1.6 expected empty string for blank Overview, got: '$result'"
fi

# =============================================================================
# Test Suite 2: emit_dashboard_run_state() pending→active override
# =============================================================================
echo "=== Test Suite 2: emit_dashboard_run_state() pending→active override ==="

# Set up a minimal dashboard data directory
mkdir -p "$TMPDIR/.claude/dashboard/data"
export DASHBOARD_DIR=".claude/dashboard"

# Declare the required stage arrays (empty — simulating a fresh state where
# no stage has been explicitly set to "active" yet)
declare -gA _STAGE_STATUS=()
declare -gA _STAGE_TURNS=()
declare -gA _STAGE_BUDGET=()
declare -gA _STAGE_DURATION=()
declare -gA _STAGE_START_TS=()

# --- 2.1: CURRENT_STAGE=coder, _STAGE_STATUS[coder] never set → emits "active" ---
export CURRENT_STAGE="coder"
export PIPELINE_STATUS="running"
unset _CURRENT_MILESTONE 2>/dev/null || true
unset START_AT_TS 2>/dev/null || true
unset WAITING_FOR 2>/dev/null || true

emit_dashboard_run_state

run_state_file="$TMPDIR/.claude/dashboard/data/run_state.js"
if [[ ! -f "$run_state_file" ]]; then
    fail "2.1 emit_dashboard_run_state did not create run_state.js"
else
    content=$(cat "$run_state_file")

    # Verify coder status is "active" (the emit-time override)
    if echo "$content" | grep -q '"coder":{"status":"active"'; then
        pass "2.1 emit-time override: coder status is 'active' when CURRENT_STAGE=coder and _STAGE_STATUS[coder] unset"
    else
        fail "2.1 coder status not 'active' in run_state.js — content: $content"
    fi

    # Verify other stages remain "pending"
    if echo "$content" | grep -q '"intake":{"status":"pending"'; then
        pass "2.2 non-current stages remain 'pending' (intake not overridden)"
    else
        fail "2.2 intake stage not 'pending' — content: $content"
    fi

    if echo "$content" | grep -q '"reviewer":{"status":"pending"'; then
        pass "2.3 non-current stages remain 'pending' (reviewer not overridden)"
    else
        fail "2.3 reviewer stage not 'pending' — content: $content"
    fi
fi

# --- 2.4: Verify override doesn't mutate global _STAGE_STATUS ----------------
# After emit, _STAGE_STATUS[coder] should still be unset (empty)
actual_status="${_STAGE_STATUS[coder]:-unset}"
if [[ "$actual_status" = "unset" ]]; then
    pass "2.4 emit-time override does not mutate _STAGE_STATUS[coder] global"
else
    fail "2.4 _STAGE_STATUS[coder] was mutated to '$actual_status' (expected unset)"
fi

# --- 2.5: When _STAGE_STATUS[coder]="pending" explicitly set, same override applies ---
_STAGE_STATUS[coder]="pending"
export CURRENT_STAGE="coder"

emit_dashboard_run_state

content=$(cat "$run_state_file")
if echo "$content" | grep -q '"coder":{"status":"active"'; then
    pass "2.5 override applies when _STAGE_STATUS[coder] explicitly set to 'pending'"
else
    fail "2.5 override did not fire for explicit pending status — content: $content"
fi

# Verify global still "pending" after emit
if [[ "${_STAGE_STATUS[coder]}" = "pending" ]]; then
    pass "2.6 global _STAGE_STATUS[coder] still 'pending' after override emit"
else
    fail "2.6 global _STAGE_STATUS[coder] mutated to '${_STAGE_STATUS[coder]}'"
fi

# --- 2.7: When stage is already "active" in globals, override is a no-op -----
_STAGE_STATUS[coder]="active"
_STAGE_START_TS[coder]="$SECONDS"

emit_dashboard_run_state

content=$(cat "$run_state_file")
if echo "$content" | grep -q '"coder":{"status":"active"'; then
    pass "2.7 already-active stage emits 'active' (no regression)"
else
    fail "2.7 unexpected status for already-active stage — content: $content"
fi

# --- 2.8: Override only fires for CURRENT_STAGE, not other pending stages ----
_STAGE_STATUS=()
export CURRENT_STAGE="reviewer"

emit_dashboard_run_state

content=$(cat "$run_state_file")

# coder should remain "pending" (not overridden because it's not CURRENT_STAGE)
if echo "$content" | grep -q '"coder":{"status":"pending"'; then
    pass "2.8 override is scoped to CURRENT_STAGE only (coder stays pending)"
else
    fail "2.8 coder should be pending when CURRENT_STAGE=reviewer — content: $content"
fi

# reviewer should be "active" (the current stage)
if echo "$content" | grep -q '"reviewer":{"status":"active"'; then
    pass "2.9 override fires for reviewer when CURRENT_STAGE=reviewer"
else
    fail "2.9 reviewer not overridden to active — content: $content"
fi

# =============================================================================
# Summary
# =============================================================================
echo
echo "════════════════════════════════════════"
echo "  M38 dashboard coverage: ${PASS} passed, ${FAIL} failed"
echo "════════════════════════════════════════"

[[ "$FAIL" -eq 0 ]] || exit 1
echo "All M38 dashboard coverage tests passed"

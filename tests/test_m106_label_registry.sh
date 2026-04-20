#!/usr/bin/env bash
# =============================================================================
# test_m106_label_registry.sh — M106 — verify get_stage_display_label mappings
#
# Primary behavior: get_stage_display_label is the single authoritative mapping
# from internal pipeline stage name to TUI display label.
#
# AC-1: test_verify  → "tester"
# AC-2: test_write   → "tester-write"
# AC-3: wrap_up and wrap-up both → "wrap-up"
# AC-4: unknown_stage → "unknown-stage" (fallback: replace _ with -)
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# Stubs required by pipeline_order.sh (warn is called in validate_pipeline_order)
log()         { :; }
warn()        { :; }
error()       { :; }
success()     { :; }
header()      { :; }
log_verbose() { :; }

# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/pipeline_order.sh"

PASS=0; FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL+1)); }

assert_label() {
    local input="$1" expected="$2" description="$3"
    local actual
    actual=$(get_stage_display_label "$input")
    if [[ "$actual" == "$expected" ]]; then
        pass "$description"
    else
        fail "$description" "expected '$expected', got '$actual'"
    fi
}

# =============================================================================
echo "=== AC-1: test_verify → tester ==="
assert_label "test_verify" "tester" "get_stage_display_label test_verify → tester"

# =============================================================================
echo "=== AC-2: test_write → tester-write ==="
assert_label "test_write" "tester-write" "get_stage_display_label test_write → tester-write"

# =============================================================================
echo "=== AC-3a: wrap_up → wrap-up ==="
assert_label "wrap_up" "wrap-up" "get_stage_display_label wrap_up → wrap-up"

echo "=== AC-3b: wrap-up → wrap-up ==="
assert_label "wrap-up" "wrap-up" "get_stage_display_label wrap-up → wrap-up"

# =============================================================================
echo "=== AC-4: unknown_stage → unknown-stage (fallback: _ replaced by -) ==="
assert_label "unknown_stage" "unknown-stage" "get_stage_display_label unknown_stage → unknown-stage (fallback)"

# =============================================================================
echo "=== Canonical mappings: all explicitly registered stage names ==="
assert_label "intake"   "intake"   "get_stage_display_label intake → intake"
assert_label "scout"    "scout"    "get_stage_display_label scout → scout"
assert_label "coder"    "coder"    "get_stage_display_label coder → coder"
assert_label "security" "security" "get_stage_display_label security → security"
assert_label "review"   "review"   "get_stage_display_label review → review"
assert_label "docs"     "docs"     "get_stage_display_label docs → docs"
assert_label "rework"   "rework"   "get_stage_display_label rework → rework"

# =============================================================================
echo "=== Edge: empty input → empty string ==="
actual=$(get_stage_display_label "" 2>/dev/null || true)
if [[ -z "$actual" ]]; then
    pass "get_stage_display_label '' → empty string"
else
    fail "get_stage_display_label empty input" "expected empty, got '$actual'"
fi

echo ""
echo "=== Summary: ${PASS} passed, ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]]

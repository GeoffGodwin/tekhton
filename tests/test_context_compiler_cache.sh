#!/usr/bin/env bash
# Test: lib/context_compiler.sh — keyword extraction caching (Milestone 47)
# Tests: _extract_keywords output, _CACHED_KEYWORDS_KEY/_CACHED_KEYWORDS cache
#        population, cache hit reuse, cache miss bust, disabled mode
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# Dependencies
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/common.sh"

# Stubs for context.sh functions required by context_budget.sh
_add_context_component() { :; }
_get_model_window() { echo "200000"; }
check_context_budget() { return 0; }  # Always under budget — suppresses compression

# Source context_compiler.sh (auto-sources context_budget.sh which needs count_lines)
# count_lines is provided by common.sh (sourced above)
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/context_compiler.sh"

TEST_TMPDIR=$(mktemp -d)
# shellcheck disable=SC2064
trap "rm -rf '${TEST_TMPDIR}'" EXIT

cd "$TEST_TMPDIR"

# =============================================================================
# Test 1: _extract_keywords extracts significant words from task
# =============================================================================
echo "=== _extract_keywords: task word extraction ==="

result=$(_extract_keywords "build cache logic system" "")

if echo "$result" | grep -q "^cache$"; then
    pass "_extract_keywords extracts 'cache' from task"
else
    fail "_extract_keywords missing 'cache' — got: ${result}"
fi

if echo "$result" | grep -q "^logic$"; then
    pass "_extract_keywords extracts 'logic' from task"
else
    fail "_extract_keywords missing 'logic' — got: ${result}"
fi

if echo "$result" | grep -q "^system$"; then
    pass "_extract_keywords extracts 'system' from task"
else
    fail "_extract_keywords missing 'system' — got: ${result}"
fi

# Short words (< 4 chars) should be excluded
if echo "$result" | grep -q "^is$\|^of$\|^in$"; then
    fail "_extract_keywords should exclude words shorter than 4 chars"
else
    pass "_extract_keywords excludes short words"
fi

# 'implement' and 'milestone' are explicit stop words
stop_task_result=$(_extract_keywords "implement milestone tracking" "")
if echo "$stop_task_result" | grep -qw "implement"; then
    fail "_extract_keywords should filter stop word 'implement'"
else
    pass "_extract_keywords filters stop word 'implement'"
fi

if echo "$stop_task_result" | grep -qw "milestone"; then
    fail "_extract_keywords should filter stop word 'milestone'"
else
    pass "_extract_keywords filters stop word 'milestone'"
fi

# =============================================================================
# Test 2: _extract_keywords augments with basenames from reference file
# =============================================================================
echo "=== _extract_keywords: reference file augmentation ==="

REF_FILE="${TEST_TMPDIR}/scout_report.md"
cat > "$REF_FILE" <<'EOF'
## Files to examine
- lib/context_cache.sh
- stages/coder.sh
- lib/milestone_window.sh
EOF

result=$(_extract_keywords "test task query" "$REF_FILE")

if echo "$result" | grep -q "context_cache"; then
    pass "_extract_keywords extracts 'context_cache' basename from reference file"
else
    fail "_extract_keywords missing 'context_cache' — got: ${result}"
fi

if echo "$result" | grep -q "coder"; then
    pass "_extract_keywords extracts 'coder' basename from reference file"
else
    fail "_extract_keywords missing 'coder' — got: ${result}"
fi

if echo "$result" | grep -q "milestone_window"; then
    pass "_extract_keywords extracts 'milestone_window' basename from reference file"
else
    fail "_extract_keywords missing 'milestone_window' — got: ${result}"
fi

# Missing ref file should not cause an error
result_no_ref=$(_extract_keywords "build cache logic" "${TEST_TMPDIR}/nonexistent.md")
if echo "$result_no_ref" | grep -q "cache"; then
    pass "_extract_keywords works without reference file (missing path)"
else
    fail "_extract_keywords failed with missing reference file — got: ${result_no_ref}"
fi

# =============================================================================
# Test 3: build_context_packet populates _CACHED_KEYWORDS_KEY and _CACHED_KEYWORDS
# =============================================================================
echo "=== build_context_packet: cache population ==="

unset _CACHED_KEYWORDS_KEY 2>/dev/null || true
unset _CACHED_KEYWORDS 2>/dev/null || true

CONTEXT_COMPILER_ENABLED="true"

build_context_packet "coder" "build cache logic system" "sonnet"

if [[ -n "${_CACHED_KEYWORDS_KEY:-}" ]]; then
    pass "build_context_packet sets _CACHED_KEYWORDS_KEY after first call"
else
    fail "build_context_packet did not set _CACHED_KEYWORDS_KEY"
fi

if [[ -n "${_CACHED_KEYWORDS:-}" ]]; then
    pass "build_context_packet sets _CACHED_KEYWORDS after first call"
else
    fail "build_context_packet did not set _CACHED_KEYWORDS"
fi

# Key format is "task::ref_file" — no ref files exist in tmpdir so it ends with "::"
if echo "${_CACHED_KEYWORDS_KEY:-}" | grep -q "build cache logic"; then
    pass "_CACHED_KEYWORDS_KEY contains task string"
else
    fail "_CACHED_KEYWORDS_KEY does not contain task — got: ${_CACHED_KEYWORDS_KEY:-}"
fi

# =============================================================================
# Test 4: build_context_packet cache hit — same key reuses cached keywords
# =============================================================================
echo "=== build_context_packet: cache hit ==="

# Inject a sentinel that _extract_keywords would never naturally produce
_CACHED_KEYWORDS_KEY="sentinel_hit_task::"
_CACHED_KEYWORDS="sentinel_unique_keyword_xyzzy"
export _CACHED_KEYWORDS_KEY _CACHED_KEYWORDS

CONTEXT_COMPILER_ENABLED="true"

build_context_packet "coder" "sentinel_hit_task" "sonnet"

if [[ "${_CACHED_KEYWORDS:-}" == "sentinel_unique_keyword_xyzzy" ]]; then
    pass "build_context_packet uses cached keywords on cache hit (sentinel preserved)"
else
    fail "build_context_packet recomputed keywords on cache hit — got: ${_CACHED_KEYWORDS:-}"
fi

# =============================================================================
# Test 5: build_context_packet cache miss — different task busts cache
# =============================================================================
echo "=== build_context_packet: cache miss ==="

_CACHED_KEYWORDS_KEY="old_previous_task::"
_CACHED_KEYWORDS="old_stale_keywords_zyxw"
export _CACHED_KEYWORDS_KEY _CACHED_KEYWORDS

CONTEXT_COMPILER_ENABLED="true"

build_context_packet "coder" "totally different query text" "sonnet"

if [[ "${_CACHED_KEYWORDS:-}" != "old_stale_keywords_zyxw" ]]; then
    pass "build_context_packet recomputes keywords on cache miss (different task)"
else
    fail "build_context_packet used stale keywords for different task"
fi

if echo "${_CACHED_KEYWORDS_KEY:-}" | grep -q "totally different"; then
    pass "_CACHED_KEYWORDS_KEY updated with new task on cache miss"
else
    fail "_CACHED_KEYWORDS_KEY not updated — got: ${_CACHED_KEYWORDS_KEY:-}"
fi

# =============================================================================
# Test 6: build_context_packet skips caching when CONTEXT_COMPILER_ENABLED=false
# =============================================================================
echo "=== build_context_packet: disabled mode ==="

unset _CACHED_KEYWORDS_KEY 2>/dev/null || true
unset _CACHED_KEYWORDS 2>/dev/null || true

CONTEXT_COMPILER_ENABLED="false"

build_context_packet "coder" "some task string" "sonnet"

if [[ -z "${_CACHED_KEYWORDS_KEY:-}" ]]; then
    pass "build_context_packet does not cache when CONTEXT_COMPILER_ENABLED=false"
else
    fail "build_context_packet should not set cache when disabled — key: ${_CACHED_KEYWORDS_KEY:-}"
fi

if [[ -z "${_CACHED_KEYWORDS:-}" ]]; then
    pass "build_context_packet does not set _CACHED_KEYWORDS when disabled"
else
    fail "build_context_packet should not set _CACHED_KEYWORDS when disabled"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi

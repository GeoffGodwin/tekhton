#!/usr/bin/env bash
# Test: lib/context_cache.sh — Extended tests (prompt consistency + milestone block)
# Split from test_context_cache.sh to stay under 300-line ceiling.
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# Stubs for dependencies
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/common.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/prompts.sh"

# Stub _phase_start / _phase_end if not available
if ! declare -f _phase_start &>/dev/null; then
    _phase_start() { :; }
    _phase_end() { :; }
fi

# Stub _add_context_component / _get_model_window / check_context_budget
_add_context_component() { :; }
_get_model_window() { echo "200000"; }
check_context_budget() { return 0; }

# Source context cache under test
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/context_cache.sh"

# Create temp directory for test fixtures
TEST_TMPDIR=$(mktemp -d)
# shellcheck disable=SC2064
trap "rm -rf '${TEST_TMPDIR}'" EXIT

cd "$TEST_TMPDIR"

# =============================================================================
# Test 1: Prompt output byte-identical with and without caching
# =============================================================================
echo "=== Prompt output consistency ==="

# Create a minimal prompt template
mkdir -p "${TEST_TMPDIR}/prompts"
cat > "${TEST_TMPDIR}/prompts/cache_test.prompt.md" <<'PROMPT_EOF'
# Test Prompt
Architecture: {{ARCHITECTURE_CONTENT}}
PROMPT_EOF

# Set up for render_prompt
export PROMPTS_DIR="${TEST_TMPDIR}/prompts"
export ARCHITECTURE_FILE="${TEST_TMPDIR}/ARCHITECTURE.md"
echo "# Test Architecture Content" > "$ARCHITECTURE_FILE"

# Render WITHOUT cache (direct file read)
_CONTEXT_CACHE_LOADED="false"
export ARCHITECTURE_CONTENT
ARCHITECTURE_CONTENT=$(_wrap_file_content "ARCHITECTURE" "$(_safe_read_file "$ARCHITECTURE_FILE" "ARCHITECTURE_FILE")")
output_no_cache=$(render_prompt "cache_test")

# Render WITH cache
_CONTEXT_CACHE_LOADED="false"
export DRIFT_LOG_FILE="${TEST_TMPDIR}/drift.md"
export CLARIFICATIONS_FILE="${TEST_TMPDIR}/clarify.md"
export ARCHITECTURE_LOG_FILE="${TEST_TMPDIR}/adl.md"
export MILESTONE_MODE=false
preload_context_cache
ARCHITECTURE_CONTENT=$(_get_cached_architecture_content)
output_with_cache=$(render_prompt "cache_test")

if [[ "$output_no_cache" == "$output_with_cache" ]]; then
    pass "Prompt output byte-identical with and without caching"
else
    fail "Prompt output differs between cached and uncached"
    echo "    NO CACHE: $(echo "$output_no_cache" | head -3)"
    echo "    CACHED:   $(echo "$output_with_cache" | head -3)"
fi

# =============================================================================
# Test 2: _get_cached_milestone_block — cache hit returns cached block
# =============================================================================
echo "=== _get_cached_milestone_block: cache hit ==="

_CONTEXT_CACHE_LOADED="true"
_CACHED_MILESTONE_BLOCK="cached milestone window content"
export _CONTEXT_CACHE_LOADED _CACHED_MILESTONE_BLOCK

MILESTONE_BLOCK=""
if _get_cached_milestone_block; then
    if [[ "$MILESTONE_BLOCK" == "cached milestone window content" ]]; then
        pass "_get_cached_milestone_block sets MILESTONE_BLOCK from cache"
    else
        fail "_get_cached_milestone_block wrong MILESTONE_BLOCK — got: ${MILESTONE_BLOCK}"
    fi
else
    fail "_get_cached_milestone_block returned non-zero on cache hit"
fi

# =============================================================================
# Test 3: _get_cached_milestone_block — cache miss calls build_milestone_window
# =============================================================================
echo "=== _get_cached_milestone_block: cache miss fallback ==="

# Simulate state after invalidate_milestone_cache: loaded=true but block is empty
_CONTEXT_CACHE_LOADED="true"
_CACHED_MILESTONE_BLOCK=""
export _CONTEXT_CACHE_LOADED _CACHED_MILESTONE_BLOCK

MILESTONE_DAG_ENABLED="true"
export MILESTONE_DAG_ENABLED

# Stub build_milestone_window and has_milestone_manifest
build_milestone_window() {
    MILESTONE_BLOCK="computed by stub build_milestone_window"
    export MILESTONE_BLOCK
    return 0
}
has_milestone_manifest() { return 0; }

MILESTONE_BLOCK=""
if _get_cached_milestone_block; then
    if [[ "$MILESTONE_BLOCK" == "computed by stub build_milestone_window" ]]; then
        pass "_get_cached_milestone_block calls build_milestone_window on cache miss"
    else
        fail "_get_cached_milestone_block wrong MILESTONE_BLOCK on miss — got: ${MILESTONE_BLOCK}"
    fi
else
    fail "_get_cached_milestone_block returned non-zero when build_milestone_window succeeded"
fi

# =============================================================================
# Test 4: _get_cached_milestone_block — returns non-zero when DAG disabled
# =============================================================================
echo "=== _get_cached_milestone_block: DAG disabled ==="

_CONTEXT_CACHE_LOADED="true"
_CACHED_MILESTONE_BLOCK=""
MILESTONE_DAG_ENABLED="false"
export _CONTEXT_CACHE_LOADED _CACHED_MILESTONE_BLOCK MILESTONE_DAG_ENABLED

if _get_cached_milestone_block 2>/dev/null; then
    fail "_get_cached_milestone_block should return non-zero when DAG disabled and cache empty"
else
    pass "_get_cached_milestone_block returns non-zero when DAG disabled and cache empty"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi

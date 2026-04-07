#!/usr/bin/env bash
# Test: lib/context_cache.sh — Intra-run context cache (Milestone 47)
# Tests: preload_context_cache, invalidation, _get_cached_* accessors
# Extended tests (prompt consistency, milestone block) in test_context_cache_extended.sh
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
# Test 1: Cache populated when files exist
# =============================================================================
echo "=== preload_context_cache: files exist ==="

ARCHITECTURE_FILE="${TEST_TMPDIR}/ARCHITECTURE.md"
echo "# Architecture Doc" > "$ARCHITECTURE_FILE"

DRIFT_LOG_FILE="${TEST_TMPDIR}/DRIFT_LOG.md"
echo "## Drift Observations" > "$DRIFT_LOG_FILE"

CLARIFICATIONS_FILE="${TEST_TMPDIR}/CLARIFICATIONS.md"
echo "## Q: How?" > "$CLARIFICATIONS_FILE"
echo "**A:** Like this." >> "$CLARIFICATIONS_FILE"

ARCHITECTURE_LOG_FILE="${TEST_TMPDIR}/ARCHITECTURE_LOG.md"
echo "## ADL-001" > "$ARCHITECTURE_LOG_FILE"

# Disable milestone mode for this test
MILESTONE_MODE=false

preload_context_cache

if [[ "$_CONTEXT_CACHE_LOADED" == "true" ]]; then
    pass "Cache loaded flag set to true"
else
    fail "Cache loaded flag not set — got: ${_CONTEXT_CACHE_LOADED}"
fi

if [[ -n "$_CACHED_ARCHITECTURE_CONTENT" ]]; then
    pass "Architecture content cached"
else
    fail "Architecture content not cached"
fi

if echo "$_CACHED_ARCHITECTURE_CONTENT" | grep -q "BEGIN FILE CONTENT"; then
    pass "Architecture content wrapped in delimiters"
else
    fail "Architecture content missing delimiters"
fi

if [[ -n "$_CACHED_ARCHITECTURE_RAW" ]]; then
    pass "Architecture raw content cached"
else
    fail "Architecture raw content not cached"
fi

if echo "$_CACHED_ARCHITECTURE_RAW" | grep -q "# Architecture Doc"; then
    pass "Architecture raw content is unwrapped"
else
    fail "Architecture raw content should be unwrapped"
fi

if [[ -n "$_CACHED_DRIFT_LOG_CONTENT" ]]; then
    pass "Drift log content cached"
else
    fail "Drift log content not cached"
fi

if [[ -n "$_CACHED_CLARIFICATIONS_CONTENT" ]]; then
    pass "Clarifications content cached"
else
    fail "Clarifications content not cached"
fi

if [[ -n "$_CACHED_ARCHITECTURE_LOG_CONTENT" ]]; then
    pass "Architecture log content cached"
else
    fail "Architecture log content not cached"
fi

# =============================================================================
# Test 2: Cache empty when files don't exist (graceful)
# =============================================================================
echo "=== preload_context_cache: files missing ==="

_CONTEXT_CACHE_LOADED="false"
ARCHITECTURE_FILE="${TEST_TMPDIR}/nonexistent_arch.md"
DRIFT_LOG_FILE="${TEST_TMPDIR}/nonexistent_drift.md"
CLARIFICATIONS_FILE="${TEST_TMPDIR}/nonexistent_clarify.md"
ARCHITECTURE_LOG_FILE="${TEST_TMPDIR}/nonexistent_adl.md"

preload_context_cache

if [[ "$_CONTEXT_CACHE_LOADED" == "true" ]]; then
    pass "Cache loaded flag set even when files missing"
else
    fail "Cache loaded flag not set when files missing"
fi

if [[ -z "$_CACHED_ARCHITECTURE_CONTENT" ]]; then
    pass "Architecture content empty when file missing"
else
    fail "Architecture content should be empty — got: ${#_CACHED_ARCHITECTURE_CONTENT} chars"
fi

if [[ -z "$_CACHED_DRIFT_LOG_CONTENT" ]]; then
    pass "Drift log content empty when file missing"
else
    fail "Drift log content should be empty"
fi

if [[ -z "$_CACHED_CLARIFICATIONS_CONTENT" ]]; then
    pass "Clarifications content empty when file missing"
else
    fail "Clarifications content should be empty"
fi

if [[ -z "$_CACHED_ARCHITECTURE_LOG_CONTENT" ]]; then
    pass "Architecture log content empty when file missing"
else
    fail "Architecture log content should be empty"
fi

# =============================================================================
# Test 3: _get_cached_* accessors return cached values
# =============================================================================
echo "=== _get_cached_* accessors ==="

# Re-populate cache with known content
ARCHITECTURE_FILE="${TEST_TMPDIR}/ARCHITECTURE.md"
echo "# Arch for accessor test" > "$ARCHITECTURE_FILE"
DRIFT_LOG_FILE="${TEST_TMPDIR}/DRIFT_LOG.md"
echo "## Drift for accessor test" > "$DRIFT_LOG_FILE"
CLARIFICATIONS_FILE="${TEST_TMPDIR}/CLARIFICATIONS.md"
echo "Clarify accessor test" > "$CLARIFICATIONS_FILE"
ARCHITECTURE_LOG_FILE="${TEST_TMPDIR}/ARCHITECTURE_LOG.md"
echo "ADL accessor test" > "$ARCHITECTURE_LOG_FILE"
_CONTEXT_CACHE_LOADED="false"

preload_context_cache

result=$(_get_cached_architecture_content)
if echo "$result" | grep -q "Arch for accessor test"; then
    pass "_get_cached_architecture_content returns cached value"
else
    fail "_get_cached_architecture_content wrong value"
fi

result=$(_get_cached_architecture_raw)
if [[ "$result" == "# Arch for accessor test" ]]; then
    pass "_get_cached_architecture_raw returns unwrapped value"
else
    fail "_get_cached_architecture_raw wrong value — got: ${result}"
fi

result=$(_get_cached_drift_log_content)
if echo "$result" | grep -q "Drift for accessor test"; then
    pass "_get_cached_drift_log_content returns cached value"
else
    fail "_get_cached_drift_log_content wrong value"
fi

result=$(_get_cached_clarifications_content)
if echo "$result" | grep -q "Clarify accessor test"; then
    pass "_get_cached_clarifications_content returns cached value"
else
    fail "_get_cached_clarifications_content wrong value"
fi

result=$(_get_cached_architecture_log_content)
if echo "$result" | grep -q "ADL accessor test"; then
    pass "_get_cached_architecture_log_content returns cached value"
else
    fail "_get_cached_architecture_log_content wrong value"
fi

# =============================================================================
# Test 4: _get_cached_* accessors fall back to disk when cache not loaded
# =============================================================================
echo "=== _get_cached_* fallback to disk ==="

_CONTEXT_CACHE_LOADED="false"
echo "# Disk fallback arch" > "$ARCHITECTURE_FILE"

result=$(_get_cached_architecture_content)
if echo "$result" | grep -q "Disk fallback arch"; then
    pass "_get_cached_architecture_content falls back to disk read"
else
    fail "_get_cached_architecture_content disk fallback failed"
fi

result=$(_get_cached_architecture_raw)
if echo "$result" | grep -q "Disk fallback arch"; then
    pass "_get_cached_architecture_raw falls back to disk read"
else
    fail "_get_cached_architecture_raw disk fallback failed"
fi

# =============================================================================
# Test 5: invalidate_drift_cache clears cached drift log
# =============================================================================
echo "=== invalidate_drift_cache ==="

_CONTEXT_CACHE_LOADED="true"
_CACHED_DRIFT_LOG_CONTENT="some drift content"

invalidate_drift_cache

if [[ -z "$_CACHED_DRIFT_LOG_CONTENT" ]]; then
    pass "Drift cache invalidated"
else
    fail "Drift cache not cleared after invalidation"
fi

# =============================================================================
# Test 6: invalidate_milestone_cache clears cached milestone block
# =============================================================================
echo "=== invalidate_milestone_cache ==="

_CACHED_MILESTONE_BLOCK="some milestone content"

invalidate_milestone_cache

if [[ -z "$_CACHED_MILESTONE_BLOCK" ]]; then
    pass "Milestone cache invalidated"
else
    fail "Milestone cache not cleared after invalidation"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi

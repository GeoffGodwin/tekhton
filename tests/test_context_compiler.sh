#!/usr/bin/env bash
# Test: lib/context.sh — Context compiler functions (Milestone 2)
# Tests: _extract_keywords, extract_relevant_sections, compress_context,
#        build_context_packet, _filter_block
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# Source the library under test
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/common.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/context.sh"

# Create a temp directory for test fixtures
TEST_TMPDIR=$(mktemp -d)
# shellcheck disable=SC2064
trap "rm -rf '${TEST_TMPDIR}'" EXIT

# =============================================================================
# _extract_keywords
# =============================================================================

echo "=== _extract_keywords ==="

# Keywords from task string (words 4+ chars, no stop words)
kw_output=$(_extract_keywords "Implement the context compiler for token budgeting" "")
if echo "$kw_output" | grep -q "context"; then
    pass "_extract_keywords extracts 'context' from task"
else
    fail "_extract_keywords missing 'context' — output: ${kw_output}"
fi

if echo "$kw_output" | grep -q "compiler"; then
    pass "_extract_keywords extracts 'compiler' from task"
else
    fail "_extract_keywords missing 'compiler' — output: ${kw_output}"
fi

if echo "$kw_output" | grep -q "token"; then
    pass "_extract_keywords extracts 'token' from task"
else
    fail "_extract_keywords missing 'token' — output: ${kw_output}"
fi

# Stop words are excluded
if echo "$kw_output" | grep -q "^this$"; then
    fail "_extract_keywords should exclude stop word 'this'"
else
    pass "_extract_keywords excludes stop word 'this'"
fi

# Short words (< 4 chars) excluded
if echo "$kw_output" | grep -q "^the$"; then
    fail "_extract_keywords should exclude short word 'the'"
else
    pass "_extract_keywords excludes short word 'the'"
fi

# File paths extracted from reference file
cat > "${TEST_TMPDIR}/scout.md" <<'EOF'
## Relevant Files
- `lib/context.sh` — token accounting
- `stages/coder.sh` — integration point
- `lib/config.sh` — defaults
EOF

kw_from_file=$(_extract_keywords "fix the build" "${TEST_TMPDIR}/scout.md")
if echo "$kw_from_file" | grep -q "context"; then
    pass "_extract_keywords extracts file stems from reference file"
else
    fail "_extract_keywords missing file stem 'context' from scout — output: ${kw_from_file}"
fi

if echo "$kw_from_file" | grep -q "coder"; then
    pass "_extract_keywords extracts 'coder' file stem"
else
    fail "_extract_keywords missing 'coder' from scout — output: ${kw_from_file}"
fi

# Empty task produces no keywords (or only file-based ones)
kw_empty=$(_extract_keywords "" "")
if [ -z "$kw_empty" ]; then
    pass "_extract_keywords with empty task and no file returns empty"
else
    fail "_extract_keywords should return empty for empty inputs — got: ${kw_empty}"
fi

# =============================================================================
# extract_relevant_sections
# =============================================================================

echo
echo "=== extract_relevant_sections ==="

# Create test markdown content
TEST_MD="# Architecture

Overview of the system.

## Database Layer
The database layer handles persistence and queries.
Uses PostgreSQL with connection pooling.

## API Layer
REST endpoints for the frontend.
Handles authentication and rate limiting.

## Frontend Components
React components with TypeScript.
Uses Redux for state management.

## Testing Strategy
Unit tests with Jest. Integration tests with Cypress."

# Filter for database-related keywords
db_filtered=$(extract_relevant_sections "$TEST_MD" "database
persistence")
if echo "$db_filtered" | grep -q "Database Layer"; then
    pass "extract_relevant_sections includes matching section 'Database Layer'"
else
    fail "extract_relevant_sections missing 'Database Layer' — output: ${db_filtered}"
fi

if echo "$db_filtered" | grep -q "Frontend Components"; then
    fail "extract_relevant_sections should not include non-matching 'Frontend Components'"
else
    pass "extract_relevant_sections excludes non-matching 'Frontend Components'"
fi

# Preamble (content before first ##) is always included
if echo "$db_filtered" | grep -q "Overview of the system"; then
    pass "extract_relevant_sections includes preamble content"
else
    fail "extract_relevant_sections missing preamble — output: ${db_filtered}"
fi

# Zero keyword matches returns empty filtered content (caller handles fallback)
no_match=$(extract_relevant_sections "$TEST_MD" "zzzznonexistent")
# Should not contain any ## sections
section_count=$(echo "$no_match" | grep -c "^## " || true)
if [ "$section_count" -eq 0 ]; then
    pass "extract_relevant_sections with no matches returns no sections"
else
    fail "extract_relevant_sections with no matches returned ${section_count} sections"
fi

# Empty content returns empty
empty_result=$(extract_relevant_sections "" "database")
if [ -z "$empty_result" ]; then
    pass "extract_relevant_sections with empty content returns empty"
else
    fail "extract_relevant_sections should return empty for empty content"
fi

# Empty keywords returns full content
full_result=$(extract_relevant_sections "$TEST_MD" "")
if echo "$full_result" | grep -q "Database Layer"; then
    pass "extract_relevant_sections with empty keywords returns full content"
else
    fail "extract_relevant_sections with empty keywords should return full content"
fi

# Multiple keywords match multiple sections
multi_filtered=$(extract_relevant_sections "$TEST_MD" "database
react")
if echo "$multi_filtered" | grep -q "Database Layer" && echo "$multi_filtered" | grep -q "Frontend Components"; then
    pass "extract_relevant_sections matches multiple sections from multiple keywords"
else
    fail "extract_relevant_sections should match both Database and Frontend sections"
fi

# Case insensitive matching
case_filtered=$(extract_relevant_sections "$TEST_MD" "POSTGRESQL")
if echo "$case_filtered" | grep -q "Database Layer"; then
    pass "extract_relevant_sections matches case-insensitively"
else
    fail "extract_relevant_sections should match case-insensitively — output: ${case_filtered}"
fi

# =============================================================================
# compress_context
# =============================================================================

echo
echo "=== compress_context ==="

# Generate a 100-line block
LONG_CONTENT=""
for i in $(seq 1 100); do
    LONG_CONTENT="${LONG_CONTENT}Line ${i}: some content here
"
done

# Truncate strategy — reduces to max_lines
truncated=$(compress_context "$LONG_CONTENT" "truncate" 20)
trunc_lines=$(echo "$truncated" | wc -l | tr -d '[:space:]')
if [ "$trunc_lines" -le 22 ]; then  # 20 lines + truncation note + possible trailing
    pass "compress_context truncate reduces 100 lines to ~20"
else
    fail "compress_context truncate: expected ~20 lines, got ${trunc_lines}"
fi

if echo "$truncated" | grep -q "truncated from"; then
    pass "compress_context truncate adds truncation note"
else
    fail "compress_context truncate missing truncation note"
fi

# Truncate with content shorter than max — returns as-is
SHORT_CONTENT="line 1
line 2
line 3"
short_truncated=$(compress_context "$SHORT_CONTENT" "truncate" 50)
if [ "$short_truncated" = "$SHORT_CONTENT" ]; then
    pass "compress_context truncate returns short content unchanged"
else
    fail "compress_context truncate should not modify short content"
fi

# Summarize headings strategy
HEADED_CONTENT="## Section One
Some content under section one.
More details here.

### Sub-Section A
Sub-section details.

## Section Two
Content for section two.

### Sub-Section B
More sub-section content."

heading_summary=$(compress_context "$HEADED_CONTENT" "summarize_headings")
heading_count=$(echo "$heading_summary" | grep -c "^#" || true)
if [ "$heading_count" -eq 4 ]; then
    pass "compress_context summarize_headings extracts 4 headings"
else
    fail "compress_context summarize_headings: expected 4 headings, got ${heading_count}"
fi

# Non-heading content is excluded
if echo "$heading_summary" | grep -q "Some content"; then
    fail "compress_context summarize_headings should exclude body text"
else
    pass "compress_context summarize_headings excludes body text"
fi

# Omit strategy returns empty
omitted=$(compress_context "$LONG_CONTENT" "omit")
if [ -z "$omitted" ]; then
    pass "compress_context omit returns empty string"
else
    fail "compress_context omit should return empty — got ${#omitted} chars"
fi

# Unknown strategy returns content as-is
unknown_result=$(compress_context "hello world" "unknown_strategy")
if [ "$unknown_result" = "hello world" ]; then
    pass "compress_context unknown strategy returns content unchanged"
else
    fail "compress_context unknown strategy should return as-is"
fi

# =============================================================================
# _filter_block — filters exported variable by keywords
# =============================================================================

echo
echo "=== _filter_block ==="

# Set up an exported variable with markdown sections
export TEST_BLOCK="## Authentication
Handles user login and sessions.

## Database
PostgreSQL connection pooling.

## Caching
Redis caching layer."

_filter_block "TEST_BLOCK" "database
postgresql"

if echo "$TEST_BLOCK" | grep -q "Database"; then
    pass "_filter_block keeps matching section"
else
    fail "_filter_block should keep 'Database' section"
fi

# Caching should be filtered out (doesn't match keywords)
if echo "$TEST_BLOCK" | grep -q "Redis caching"; then
    fail "_filter_block should remove non-matching 'Caching' section"
else
    pass "_filter_block removes non-matching section"
fi

# Empty variable — no-op
export EMPTY_BLOCK=""
_filter_block "EMPTY_BLOCK" "database"
if [ -z "$EMPTY_BLOCK" ]; then
    pass "_filter_block no-ops on empty variable"
else
    fail "_filter_block should no-op on empty variable"
fi

# No keyword matches — falls back to original (no change)
export FULL_BLOCK="## Only Section
Content here."
original_full="$FULL_BLOCK"
_filter_block "FULL_BLOCK" "zzzznonexistent"
if [ "$FULL_BLOCK" = "$original_full" ]; then
    pass "_filter_block keeps original when no keywords match"
else
    fail "_filter_block should keep original on zero matches"
fi

# Preamble + sections but no section matches — must keep original (not just preamble)
export PREAMBLE_BLOCK="# Architecture Overview
This is the project architecture.

## Database Layer
Tables and schemas for storage.

## API Layer
REST endpoints and handlers."
original_preamble="$PREAMBLE_BLOCK"
_filter_block "PREAMBLE_BLOCK" "zzzznonexistent"
if [ "$PREAMBLE_BLOCK" = "$original_preamble" ]; then
    pass "_filter_block keeps original when preamble exists but no sections match"
else
    fail "_filter_block should not reduce to preamble-only on zero section matches"
fi

# =============================================================================
# build_context_packet — integration test
# =============================================================================

echo
echo "=== build_context_packet ==="

# When disabled (default), no-op
export CONTEXT_COMPILER_ENABLED=false
export ARCHITECTURE_BLOCK="## Full Architecture Content
This is the full architecture."
original_arch="$ARCHITECTURE_BLOCK"
build_context_packet "coder" "implement database layer" "claude-sonnet" 2>/dev/null
if [ "$ARCHITECTURE_BLOCK" = "$original_arch" ]; then
    pass "build_context_packet no-ops when CONTEXT_COMPILER_ENABLED=false"
else
    fail "build_context_packet should no-op when disabled"
fi

# When enabled, coder stage keeps architecture full
export CONTEXT_COMPILER_ENABLED=true
export ARCHITECTURE_BLOCK="## Database
DB content.

## Frontend
UI content.

## API
API content."
original_arch="$ARCHITECTURE_BLOCK"

export PRIOR_TESTER_CONTEXT="## Database Tests
Test the DB layer.

## Frontend Tests
Test the UI layer."

build_context_packet "coder" "fix database connection pooling" "claude-sonnet" 2>/dev/null

if [ "$ARCHITECTURE_BLOCK" = "$original_arch" ]; then
    pass "build_context_packet coder stage keeps architecture FULL"
else
    fail "build_context_packet should keep architecture full for coder"
fi

# Review stage filters architecture
export CONTEXT_COMPILER_ENABLED=true
export ARCHITECTURE_CONTENT="## Database
DB content.

## Frontend
UI content.

## API
API content."

# Create a coder summary to extract keywords from
cat > "CODER_SUMMARY.md" <<'CSEOF'
# Coder Summary
## Status: COMPLETE
## Files Modified
- lib/database.sh
CSEOF

build_context_packet "review" "fix database connection" "claude-sonnet" 2>/dev/null

if echo "$ARCHITECTURE_CONTENT" | grep -q "Database"; then
    pass "build_context_packet review stage keeps matching architecture sections"
else
    fail "build_context_packet review should keep 'Database' section"
fi

# Clean up test file
rm -f "CODER_SUMMARY.md"

# =============================================================================
# CONTEXT_COMPILER_ENABLED config default
# =============================================================================

echo
echo "=== Config default ==="

compiler_enabled=$(
    unset CONTEXT_COMPILER_ENABLED 2>/dev/null || true
    # shellcheck source=/dev/null
    source "${TEKHTON_HOME}/lib/common.sh"
    PROJECT_DIR="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '${PROJECT_DIR}'" EXIT
    mkdir -p "${PROJECT_DIR}/.claude"
    printf 'PROJECT_NAME=test\nCLAUDE_STANDARD_MODEL=claude-sonnet\nANALYZE_CMD=true\n' \
        > "${PROJECT_DIR}/.claude/pipeline.conf"
    # shellcheck source=/dev/null
    source "${TEKHTON_HOME}/lib/config.sh"
    load_config
    echo "$CONTEXT_COMPILER_ENABLED"
)
if [ "$compiler_enabled" = "false" ]; then
    pass "default CONTEXT_COMPILER_ENABLED is false"
else
    fail "expected CONTEXT_COMPILER_ENABLED=false, got '${compiler_enabled}'"
fi

# =============================================================================
# _compress_if_over_budget — over-budget path, priority ordering, note injection
# =============================================================================

echo
echo "=== _compress_if_over_budget ==="

# Helper: generate N lines of content (~50 chars each)
_gen_lines() {
    local n="$1"
    local i out=""
    for i in $(seq 1 "$n"); do
        out="${out}Line ${i}: context data here some extra filler content here
"
    done
    printf '%s' "$out"
}

# --- Under budget: no compression applied ---
# Budget: 50% of 200k = 100k tokens (well above any test content)
CONTEXT_BUDGET_PCT=50
CHARS_PER_TOKEN=4
CONTEXT_BUDGET_ENABLED=true
export ARCHITECTURE_BLOCK="" GLOSSARY_BLOCK="" MILESTONE_BLOCK=""
export HUMAN_NOTES_BLOCK="" PRIOR_REVIEWER_CONTEXT="" BUG_SCOUT_CONTEXT=""
export PRIOR_TESTER_CONTEXT="small tester context"
export NON_BLOCKING_CONTEXT=""
export PRIOR_PROGRESS_CONTEXT=""

orig_tester="$PRIOR_TESTER_CONTEXT"
_compress_if_over_budget "coder" "claude-sonnet" 2>/dev/null
if [ "$PRIOR_TESTER_CONTEXT" = "$orig_tester" ]; then
    pass "_compress_if_over_budget: no-op when under budget"
else
    fail "_compress_if_over_budget: unexpectedly compressed when under budget"
fi

# --- Over budget: PRIOR_TESTER_CONTEXT compressed first with note injected ---
# Budget: 1% of 200k = 2000 tokens; CHARS_PER_TOKEN=1 so tokens = chars
# Large content: 100 lines × ~55 chars = ~5500 chars > 2000 budget
CONTEXT_BUDGET_PCT=1
CHARS_PER_TOKEN=1
CONTEXT_BUDGET_ENABLED=true
large_content=$(_gen_lines 100)
export ARCHITECTURE_BLOCK="" GLOSSARY_BLOCK="" MILESTONE_BLOCK=""
export HUMAN_NOTES_BLOCK="" PRIOR_REVIEWER_CONTEXT="" BUG_SCOUT_CONTEXT=""
export PRIOR_TESTER_CONTEXT="$large_content"
export NON_BLOCKING_CONTEXT=""
export PRIOR_PROGRESS_CONTEXT=""

_compress_if_over_budget "coder" "claude-sonnet" 2>/dev/null
if echo "$PRIOR_TESTER_CONTEXT" | grep -q "\[Context compressed: PRIOR_TESTER_CONTEXT reduced from"; then
    pass "_compress_if_over_budget: injects [Context compressed:] note into PRIOR_TESTER_CONTEXT"
else
    fail "_compress_if_over_budget: missing [Context compressed:] note — got: ${PRIOR_TESTER_CONTEXT:0:120}"
fi

# Compressed content is shorter than original
if [ "${#PRIOR_TESTER_CONTEXT}" -lt "${#large_content}" ]; then
    pass "_compress_if_over_budget: compressed PRIOR_TESTER_CONTEXT is shorter than original"
else
    fail "_compress_if_over_budget: compressed content not shorter (orig=${#large_content}, got=${#PRIOR_TESTER_CONTEXT})"
fi

# Note format includes 'reduced from N to M lines'
if echo "$PRIOR_TESTER_CONTEXT" | grep -qE "\[Context compressed: PRIOR_TESTER_CONTEXT reduced from [0-9]+ to [0-9]+ lines\]"; then
    pass "_compress_if_over_budget: note format includes 'reduced from N to M lines'"
else
    fail "_compress_if_over_budget: note format incorrect — got: $(echo "$PRIOR_TESTER_CONTEXT" | head -1)"
fi

# NON_BLOCKING_CONTEXT untouched (first priority sufficed to reach budget)
if [ -z "$NON_BLOCKING_CONTEXT" ]; then
    pass "_compress_if_over_budget: NON_BLOCKING_CONTEXT not touched when first priority suffices"
else
    fail "_compress_if_over_budget: NON_BLOCKING_CONTEXT should be empty after first-priority compression"
fi

# --- Priority ordering: empty PRIOR_TESTER_CONTEXT → NON_BLOCKING_CONTEXT compressed ---
CONTEXT_BUDGET_PCT=1
CHARS_PER_TOKEN=1
CONTEXT_BUDGET_ENABLED=true
large_content=$(_gen_lines 100)
export ARCHITECTURE_BLOCK="" GLOSSARY_BLOCK="" MILESTONE_BLOCK=""
export HUMAN_NOTES_BLOCK="" PRIOR_REVIEWER_CONTEXT="" BUG_SCOUT_CONTEXT=""
export PRIOR_TESTER_CONTEXT=""          # empty — skipped by priority loop
export NON_BLOCKING_CONTEXT="$large_content"
export PRIOR_PROGRESS_CONTEXT=""

_compress_if_over_budget "coder" "claude-sonnet" 2>/dev/null
if echo "$NON_BLOCKING_CONTEXT" | grep -q "\[Context compressed: NON_BLOCKING_CONTEXT reduced from"; then
    pass "_compress_if_over_budget: compresses NON_BLOCKING_CONTEXT when PRIOR_TESTER_CONTEXT is empty"
else
    fail "_compress_if_over_budget: should compress NON_BLOCKING_CONTEXT as second priority"
fi

if [ -z "$PRIOR_TESTER_CONTEXT" ]; then
    pass "_compress_if_over_budget: PRIOR_TESTER_CONTEXT stays empty (not second-guessed)"
else
    fail "_compress_if_over_budget: PRIOR_TESTER_CONTEXT should remain empty"
fi

# --- Priority ordering: empty PRIOR_TESTER_CONTEXT + NON_BLOCKING_CONTEXT → PRIOR_PROGRESS_CONTEXT compressed ---
CONTEXT_BUDGET_PCT=1
CHARS_PER_TOKEN=1
CONTEXT_BUDGET_ENABLED=true
large_content=$(_gen_lines 100)
export ARCHITECTURE_BLOCK="" GLOSSARY_BLOCK="" MILESTONE_BLOCK=""
export HUMAN_NOTES_BLOCK="" PRIOR_REVIEWER_CONTEXT="" BUG_SCOUT_CONTEXT=""
export PRIOR_TESTER_CONTEXT=""          # empty — skipped
export NON_BLOCKING_CONTEXT=""          # empty — skipped
export PRIOR_PROGRESS_CONTEXT="$large_content"

_compress_if_over_budget "coder" "claude-sonnet" 2>/dev/null
if echo "$PRIOR_PROGRESS_CONTEXT" | grep -q "\[Context compressed: PRIOR_PROGRESS_CONTEXT reduced from"; then
    pass "_compress_if_over_budget: compresses PRIOR_PROGRESS_CONTEXT as third priority"
else
    fail "_compress_if_over_budget: should compress PRIOR_PROGRESS_CONTEXT as third priority"
fi

# =============================================================================
# Summary
# =============================================================================

echo
echo "=== Summary ==="
echo "  Passed: ${PASS}  Failed: ${FAIL}"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi

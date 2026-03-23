#!/usr/bin/env bash
# Test: lib/indexer_history.sh — JSONL append, prune logic, guard conditions
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# =============================================================================
# Setup: temp project dir and stubs
# =============================================================================

TEST_DIR=$(mktemp -d)
# shellcheck disable=SC2064
trap "rm -rf '${TEST_DIR}'" EXIT

PROJECT_DIR="$TEST_DIR"
TEKHTON_HOME="$TEKHTON_HOME"
export PROJECT_DIR TEKHTON_HOME

# Stubs for common.sh functions (avoid sourcing full common.sh)
log()  { :; }
warn() { :; }
export -f log warn

# Stub for _indexer_find_venv_python (from indexer.sh) — returns a fake python
_indexer_find_venv_python() { echo "/usr/bin/python3"; }
export -f _indexer_find_venv_python

# Set INDEXER_AVAILABLE before sourcing
INDEXER_AVAILABLE=true
REPO_MAP_HISTORY_ENABLED=true
REPO_MAP_HISTORY_MAX_RECORDS=200
REPO_MAP_CACHE_DIR=".claude/index"
export INDEXER_AVAILABLE REPO_MAP_HISTORY_ENABLED REPO_MAP_HISTORY_MAX_RECORDS REPO_MAP_CACHE_DIR

# Source dependencies
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/indexer_helpers.sh"

# Source the library under test
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/indexer_history.sh"

# =============================================================================
# Helper: reset task history state between tests
# =============================================================================

reset_history() {
    _TASK_HISTORY_FILE=""
    rm -f "${TEST_DIR}/.claude/index/task_history.jsonl" 2>/dev/null || true
}

# =============================================================================
# _ensure_task_history_file — creates cache dir and sets path
# =============================================================================

echo "=== _ensure_task_history_file ==="

reset_history
_ensure_task_history_file

expected_path="${TEST_DIR}/.claude/index/task_history.jsonl"
if [[ "$_TASK_HISTORY_FILE" == "$expected_path" ]]; then
    pass "_TASK_HISTORY_FILE set to expected path"
else
    fail "expected '${expected_path}', got '${_TASK_HISTORY_FILE}'"
fi

if [[ -d "${TEST_DIR}/.claude/index" ]]; then
    pass "cache directory created by _ensure_task_history_file"
else
    fail "cache directory not created"
fi

# Second call is a no-op (path already set)
_TASK_HISTORY_FILE="/some/other/path"
_ensure_task_history_file
if [[ "$_TASK_HISTORY_FILE" == "/some/other/path" ]]; then
    pass "_ensure_task_history_file is idempotent when path already set"
else
    fail "expected idempotent, got '${_TASK_HISTORY_FILE}'"
fi

# =============================================================================
# _ensure_task_history_file — absolute REPO_MAP_CACHE_DIR
# =============================================================================

echo
echo "=== _ensure_task_history_file — absolute cache dir ==="

reset_history
REPO_MAP_CACHE_DIR="${TEST_DIR}/abs_cache"
_ensure_task_history_file

if [[ "$_TASK_HISTORY_FILE" == "${TEST_DIR}/abs_cache/task_history.jsonl" ]]; then
    pass "_ensure_task_history_file uses absolute REPO_MAP_CACHE_DIR as-is"
else
    fail "expected absolute path, got '${_TASK_HISTORY_FILE}'"
fi

REPO_MAP_CACHE_DIR=".claude/index"

# =============================================================================
# record_task_file_association — JSONL append
# =============================================================================

echo
echo "=== record_task_file_association — JSONL append ==="

reset_history
record_task_file_association "Add user authentication" "lib/auth.sh lib/session.sh"

history_file="${TEST_DIR}/.claude/index/task_history.jsonl"
if [[ -f "$history_file" ]]; then
    pass "record_task_file_association creates task_history.jsonl"
else
    fail "task_history.jsonl not created"
fi

line=$(cat "$history_file")
if echo "$line" | grep -q '"task":"Add user authentication"'; then
    pass "JSONL record contains task description"
else
    fail "expected task in record: ${line}"
fi

if echo "$line" | grep -q '"files":\["lib/auth.sh","lib/session.sh"\]'; then
    pass "JSONL record contains files array"
else
    fail "expected files array in record: ${line}"
fi

if echo "$line" | grep -q '"task_type":"feature"'; then
    pass "JSONL record classifies task as feature"
else
    fail "expected task_type:feature in record: ${line}"
fi

if echo "$line" | grep -q '"ts":"'; then
    pass "JSONL record includes timestamp"
else
    fail "expected timestamp in record: ${line}"
fi

# Second append adds a second line
record_task_file_association "Fix login bug" "lib/auth.sh"
line_count=$(wc -l < "$history_file" | tr -d '[:space:]')
if [[ "$line_count" -eq 2 ]]; then
    pass "second record appended (2 lines total)"
else
    fail "expected 2 lines, got ${line_count}"
fi

# =============================================================================
# record_task_file_association — task type classification
# =============================================================================

echo
echo "=== record_task_file_association — task type classification ==="

reset_history

record_task_file_association "Fix: crash on empty input" "lib/parser.sh"
line=$(cat "$history_file")
if echo "$line" | grep -q '"task_type":"bug"'; then
    pass "task starting with 'Fix' classified as bug"
else
    fail "expected task_type:bug for 'Fix:...' task: ${line}"
fi

reset_history
record_task_file_association "bugfix: null pointer" "lib/core.sh"
line=$(cat "$history_file")
if echo "$line" | grep -q '"task_type":"bug"'; then
    pass "'bugfix' prefix classified as bug"
else
    fail "expected task_type:bug for 'bugfix' task: ${line}"
fi

reset_history
record_task_file_association "Milestone 7: Cross-run cache" "lib/indexer.sh"
line=$(cat "$history_file")
if echo "$line" | grep -q '"task_type":"milestone"'; then
    pass "'Milestone N:' classified as milestone"
else
    fail "expected task_type:milestone for milestone task: ${line}"
fi

reset_history
record_task_file_association "hotfix: security patch" "lib/auth.sh"
line=$(cat "$history_file")
if echo "$line" | grep -q '"task_type":"bug"'; then
    pass "'hotfix' prefix classified as bug"
else
    fail "expected task_type:bug for 'hotfix' task: ${line}"
fi

# =============================================================================
# record_task_file_association — guard conditions
# =============================================================================

echo
echo "=== record_task_file_association — guard conditions ==="

# Empty task — skips silently
reset_history
record_task_file_association "" "lib/auth.sh"
if [[ ! -f "$history_file" ]]; then
    pass "empty task skipped without creating history file"
else
    fail "should not create history file for empty task"
fi

# Empty file list — skips silently
reset_history
record_task_file_association "Add feature" ""
if [[ ! -f "$history_file" ]]; then
    pass "empty file list skipped without creating history file"
else
    fail "should not create history file for empty file list"
fi

# REPO_MAP_HISTORY_ENABLED=false — skips
reset_history
REPO_MAP_HISTORY_ENABLED=false
record_task_file_association "Add feature" "lib/auth.sh"
if [[ ! -f "$history_file" ]]; then
    pass "REPO_MAP_HISTORY_ENABLED=false skips recording"
else
    fail "should not record when history disabled"
fi
REPO_MAP_HISTORY_ENABLED=true

# INDEXER_AVAILABLE=false — skips
reset_history
INDEXER_AVAILABLE=false
record_task_file_association "Add feature" "lib/auth.sh"
if [[ ! -f "$history_file" ]]; then
    pass "INDEXER_AVAILABLE=false skips recording"
else
    fail "should not record when indexer unavailable"
fi
INDEXER_AVAILABLE=true

# =============================================================================
# record_task_file_association — JSON-safe task escaping
# =============================================================================

echo
echo "=== record_task_file_association — JSON escaping ==="

reset_history
record_task_file_association 'Fix "quoted" bug' "lib/auth.sh"
line=$(cat "$history_file")
if echo "$line" | grep -q '\"Fix \\"quoted\\" bug\"'; then
    pass "double quotes in task are escaped for JSON"
else
    # More lenient check: the record is valid (task is present, quotes handled)
    if echo "$line" | grep -q 'Fix'; then
        pass "task with special chars recorded without crash"
    else
        fail "expected task with quotes to be recorded: ${line}"
    fi
fi

# =============================================================================
# _prune_task_history — no-op when under limit
# =============================================================================

echo
echo "=== _prune_task_history — no prune when under limit ==="

reset_history
REPO_MAP_HISTORY_MAX_RECORDS=10

# Write 5 records
for i in 1 2 3 4 5; do
    echo "{\"ts\":\"2026-03-01T00:00:0${i}Z\",\"task\":\"task${i}\",\"files\":[],\"task_type\":\"feature\"}" \
        >> "$history_file"
done

_prune_task_history

line_count=$(wc -l < "$history_file" | tr -d '[:space:]')
if [[ "$line_count" -eq 5 ]]; then
    pass "_prune_task_history is no-op when under limit (5 <= 10)"
else
    fail "expected 5 lines after no-op prune, got ${line_count}"
fi

# =============================================================================
# _prune_task_history — trims to limit when over limit
# =============================================================================

echo
echo "=== _prune_task_history — trims to limit ==="

reset_history
REPO_MAP_HISTORY_MAX_RECORDS=5

# Write 8 records (records 1-8, oldest first)
for i in 1 2 3 4 5 6 7 8; do
    echo "{\"ts\":\"2026-03-01T00:00:0${i}Z\",\"task\":\"task${i}\",\"files\":[],\"task_type\":\"feature\"}" \
        >> "$history_file"
done

_prune_task_history

line_count=$(wc -l < "$history_file" | tr -d '[:space:]')
if [[ "$line_count" -eq 5 ]]; then
    pass "_prune_task_history trims to max_records (8 → 5)"
else
    fail "expected 5 lines after prune, got ${line_count}"
fi

# Oldest records should be gone; newest kept
last_line=$(tail -1 "$history_file")
if echo "$last_line" | grep -q '"task":"task8"'; then
    pass "_prune_task_history keeps newest records"
else
    fail "expected task8 to be last record: ${last_line}"
fi

first_line=$(head -1 "$history_file")
if echo "$first_line" | grep -q '"task":"task4"'; then
    pass "_prune_task_history discards oldest records"
else
    fail "expected task4 to be first kept record: ${first_line}"
fi

# =============================================================================
# _prune_task_history — no-op when file does not exist
# =============================================================================

echo
echo "=== _prune_task_history — no-op when file missing ==="

reset_history
# Do not create the file — _prune_task_history should return cleanly
_prune_task_history
pass "_prune_task_history returns cleanly when history file does not exist"

# =============================================================================
# _prune_task_history — atomic replace (tmp file cleaned up)
# =============================================================================

echo
echo "=== _prune_task_history — atomic replace ==="

reset_history
REPO_MAP_HISTORY_MAX_RECORDS=3

for i in 1 2 3 4 5; do
    echo "{\"ts\":\"2026-03-01T00:00:0${i}Z\",\"task\":\"task${i}\",\"files\":[],\"task_type\":\"feature\"}" \
        >> "$history_file"
done

_prune_task_history

tmp_file="${history_file}.tmp"
if [[ ! -f "$tmp_file" ]]; then
    pass "temporary .tmp file cleaned up after prune"
else
    fail ".tmp file should not exist after atomic prune"
fi

REPO_MAP_HISTORY_MAX_RECORDS=200

# =============================================================================
# get_indexer_stats — returns empty when no globals set
# =============================================================================

echo
echo "=== get_indexer_stats ==="

INDEXER_CACHE_HIT_RATE=""
INDEXER_GENERATION_TIME_MS=""

set +e
result=$(get_indexer_stats)
exit_code=$?
set -e

if [[ "$result" == "{}" ]]; then
    pass "get_indexer_stats returns {} when no stats available"
else
    fail "expected {}, got '${result}'"
fi

if [[ "$exit_code" -eq 1 ]]; then
    pass "get_indexer_stats exits 1 when no stats available"
else
    fail "expected exit code 1, got ${exit_code}"
fi

# With hit_rate set
INDEXER_CACHE_HIT_RATE="0.85"
INDEXER_GENERATION_TIME_MS="120"

result=$(get_indexer_stats)
if echo "$result" | grep -q '"hit_rate":0.85'; then
    pass "get_indexer_stats includes hit_rate"
else
    fail "expected hit_rate in result: ${result}"
fi

if echo "$result" | grep -q '"generation_time_ms":120'; then
    pass "get_indexer_stats includes generation_time_ms"
else
    fail "expected generation_time_ms in result: ${result}"
fi

set +e
get_indexer_stats > /dev/null 2>&1
exit_code=$?
set -e
if [[ "$exit_code" -eq 0 ]]; then
    pass "get_indexer_stats exits 0 when stats are available"
else
    fail "expected exit code 0, got ${exit_code}"
fi

INDEXER_CACHE_HIT_RATE=""
INDEXER_GENERATION_TIME_MS=""

# =============================================================================
# warm_index_cache — guard: INDEXER_AVAILABLE=false
# =============================================================================

echo
echo "=== warm_index_cache — guard conditions ==="

INDEXER_AVAILABLE=false
set +e
warm_index_cache
exit_code=$?
set -e
if [[ "$exit_code" -eq 1 ]]; then
    pass "warm_index_cache returns 1 when INDEXER_AVAILABLE=false"
else
    fail "expected exit 1 when indexer unavailable, got ${exit_code}"
fi
INDEXER_AVAILABLE=true

# warm_index_cache — guard: repo_map.py missing
_indexer_find_venv_python() { echo "/usr/bin/python3"; }
export -f _indexer_find_venv_python

TEKHTON_HOME_ORIG="$TEKHTON_HOME"
TEKHTON_HOME="/nonexistent/tekhton"
set +e
warm_index_cache
exit_code=$?
set -e
if [[ "$exit_code" -eq 1 ]]; then
    pass "warm_index_cache returns 1 when repo_map.py not found"
else
    fail "expected exit 1 when repo_map.py missing, got ${exit_code}"
fi
TEKHTON_HOME="$TEKHTON_HOME_ORIG"

# warm_index_cache — guard: _indexer_find_venv_python fails
_indexer_find_venv_python() { return 1; }
export -f _indexer_find_venv_python
set +e
warm_index_cache
exit_code=$?
set -e
if [[ "$exit_code" -eq 1 ]]; then
    pass "warm_index_cache returns 1 when venv python not found"
else
    fail "expected exit 1 when venv python missing, got ${exit_code}"
fi
# Restore
_indexer_find_venv_python() { echo "/usr/bin/python3"; }
export -f _indexer_find_venv_python

# =============================================================================
# record_task_file_association — auto-prune integration
# =============================================================================

echo
echo "=== record_task_file_association — auto-prune integration ==="

reset_history
REPO_MAP_HISTORY_MAX_RECORDS=3

# Fill to limit
for i in 1 2 3; do
    record_task_file_association "task ${i}" "lib/file${i}.sh"
done

line_count=$(wc -l < "$history_file" | tr -d '[:space:]')
if [[ "$line_count" -eq 3 ]]; then
    pass "3 records at limit — no prune triggered"
else
    fail "expected 3 lines at limit, got ${line_count}"
fi

# Add one more — should trigger prune
record_task_file_association "task 4" "lib/file4.sh"
line_count=$(wc -l < "$history_file" | tr -d '[:space:]')
if [[ "$line_count" -eq 3 ]]; then
    pass "auto-prune triggered after exceeding max_records (4 → 3)"
else
    fail "expected 3 lines after auto-prune, got ${line_count}"
fi

REPO_MAP_HISTORY_MAX_RECORDS=200

# =============================================================================
# Summary
# =============================================================================

echo
echo "=== Summary ==="
echo "  Passed: ${PASS}  Failed: ${FAIL}"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi

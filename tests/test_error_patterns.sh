#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# test_error_patterns.sh — Unit tests for lib/error_patterns.sh
#
# Tests:
#   load_error_patterns: registry loading, pattern count
#   classify_build_error: per-category classification, fallback behavior
#   classify_build_errors_all: multi-line mixed-output classification
#   get_pattern_count: returns >= 30
#   Edge cases: empty input, unknown errors default to code
#
# Milestone 53: Error Pattern Registry & Build Gate Classification
# =============================================================================

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TEKHTON_HOME

# Source dependencies
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/common.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/error_patterns.sh"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# Helper: extract field from pipe-delimited classification
get_field() {
    local record="$1" idx="$2"
    echo "$record" | cut -d'|' -f"$idx"
}

check_field() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        pass
    else
        fail "${label}: expected '${expected}', got '${actual}'"
    fi
}

# =============================================================================
# load_error_patterns & get_pattern_count
# =============================================================================

echo "=== Pattern loading ==="

# Pattern count must be >= 30
load_error_patterns
count=$(get_pattern_count)
if [[ "$count" -ge 30 ]]; then
    pass
else
    fail "Pattern count should be >= 30, got ${count}"
fi

# Second call should be idempotent (cached)
load_error_patterns
count2=$(get_pattern_count)
check_field "Idempotent load" "$count" "$count2"

# =============================================================================
# classify_build_error — env_setup category
# =============================================================================

echo "=== classify_build_error: env_setup ==="

record=$(classify_build_error "Please run: npx playwright install")
check_field "playwright cat" "env_setup" "$(get_field "$record" 1)"
check_field "playwright safety" "safe" "$(get_field "$record" 2)"
check_field "playwright remed" "npx playwright install" "$(get_field "$record" 3)"

record=$(classify_build_error "npx cypress install is needed")
check_field "cypress cat" "env_setup" "$(get_field "$record" 1)"
check_field "cypress safety" "safe" "$(get_field "$record" 2)"

record=$(classify_build_error "Executable doesn't exist at /opt/chromium")
check_field "chromium cat" "env_setup" "$(get_field "$record" 1)"

record=$(classify_build_error "docker: command not found")
check_field "docker notfound cat" "env_setup" "$(get_field "$record" 1)"

record=$(classify_build_error "venv directory not found")
check_field "venv cat" "env_setup" "$(get_field "$record" 1)"

record=$(classify_build_error "WebDriverError: session creation failed")
check_field "webdriver cat" "env_setup" "$(get_field "$record" 1)"

record=$(classify_build_error "PLAYWRIGHT_BROWSERS_PATH is not set")
check_field "pw_path cat" "env_setup" "$(get_field "$record" 1)"

record=$(classify_build_error "bash: protoc: command not found")
check_field "protoc cat" "env_setup" "$(get_field "$record" 1)"

# =============================================================================
# classify_build_error — service_dep category
# =============================================================================

echo "=== classify_build_error: service_dep ==="

record=$(classify_build_error "Error: connect ECONNREFUSED 127.0.0.1:5432")
check_field "postgres cat" "service_dep" "$(get_field "$record" 1)"
check_field "postgres safety" "manual" "$(get_field "$record" 2)"
check_field "postgres diag" "PostgreSQL not running (port 5432)" "$(get_field "$record" 4)"

record=$(classify_build_error "ECONNREFUSED 127.0.0.1:3306")
check_field "mysql cat" "service_dep" "$(get_field "$record" 1)"

record=$(classify_build_error "ECONNREFUSED 127.0.0.1:27017")
check_field "mongo cat" "service_dep" "$(get_field "$record" 1)"

record=$(classify_build_error "ECONNREFUSED 127.0.0.1:6379")
check_field "redis cat" "service_dep" "$(get_field "$record" 1)"

record=$(classify_build_error "Cannot connect to the Docker daemon")
check_field "docker_daemon cat" "service_dep" "$(get_field "$record" 1)"

record=$(classify_build_error "Error: connection refused to database server")
check_field "db_generic cat" "service_dep" "$(get_field "$record" 1)"

record=$(classify_build_error "Connection refused on localhost:8080")
check_field "localhost_conn cat" "service_dep" "$(get_field "$record" 1)"

# =============================================================================
# classify_build_error — toolchain category
# =============================================================================

echo "=== classify_build_error: toolchain ==="

record=$(classify_build_error "Cannot find module 'express'")
check_field "npm_module cat" "toolchain" "$(get_field "$record" 1)"
check_field "npm_module safety" "safe" "$(get_field "$record" 2)"
check_field "npm_module remed" "npm install" "$(get_field "$record" 3)"

record=$(classify_build_error "ModuleNotFoundError: No module named 'flask'")
check_field "python_module cat" "toolchain" "$(get_field "$record" 1)"

record=$(classify_build_error "ImportError: No module named 'requests'")
check_field "python_import cat" "toolchain" "$(get_field "$record" 1)"

record=$(classify_build_error "No module named 'django'")
check_field "python_nomod cat" "toolchain" "$(get_field "$record" 1)"

record=$(classify_build_error "missing go.sum entry for module")
check_field "go_sum cat" "toolchain" "$(get_field "$record" 1)"

record=$(classify_build_error "npm ERR! Missing: react@18.0.0")
check_field "npm_missing cat" "toolchain" "$(get_field "$record" 1)"

record=$(classify_build_error "ERR_MODULE_NOT_FOUND: Cannot find package")
check_field "esm_notfound cat" "toolchain" "$(get_field "$record" 1)"

record=$(classify_build_error "@prisma/client did not initialize, run prisma generate")
check_field "prisma_client cat" "toolchain" "$(get_field "$record" 1)"

record=$(classify_build_error "please run prisma generate")
check_field "prisma_gen cat" "toolchain" "$(get_field "$record" 1)"

record=$(classify_build_error "npm ERR! ERESOLVE could not resolve")
check_field "npm_eresolve cat" "toolchain" "$(get_field "$record" 1)"

# =============================================================================
# classify_build_error — resource category
# =============================================================================

echo "=== classify_build_error: resource ==="

record=$(classify_build_error "Error: listen EADDRINUSE :::3000")
check_field "port_inuse cat" "resource" "$(get_field "$record" 1)"
check_field "port_inuse safety" "manual" "$(get_field "$record" 2)"

record=$(classify_build_error "FATAL ERROR: ENOMEM not enough memory")
check_field "enomem cat" "resource" "$(get_field "$record" 1)"

record=$(classify_build_error "FATAL ERROR: Reached heap out of memory")
check_field "heap_oom cat" "resource" "$(get_field "$record" 1)"

record=$(classify_build_error "Error: ENOSPC: no space left on device")
check_field "enospc cat" "resource" "$(get_field "$record" 1)"

record=$(classify_build_error "Error: EACCES: permission denied /usr/local")
check_field "eacces cat" "resource" "$(get_field "$record" 1)"

# =============================================================================
# classify_build_error — test_infra category
# =============================================================================

echo "=== classify_build_error: test_infra ==="

record=$(classify_build_error "Snapshot Summary: 3 snapshots obsolete")
check_field "snapshot_obsolete cat" "test_infra" "$(get_field "$record" 1)"
check_field "snapshot_obsolete safety" "prompt" "$(get_field "$record" 2)"

record=$(classify_build_error "snapshot does not match the stored snapshot — mismatch")
check_field "snapshot_mismatch cat" "test_infra" "$(get_field "$record" 1)"

record=$(classify_build_error "TIMEOUT: test exceeded 30s limit")
check_field "timeout cat" "test_infra" "$(get_field "$record" 1)"

record=$(classify_build_error "Error: test fixture data/sample.json not found")
check_field "fixture cat" "test_infra" "$(get_field "$record" 1)"

# =============================================================================
# classify_build_error — code category
# =============================================================================

echo "=== classify_build_error: code ==="

record=$(classify_build_error "error TS2304: Cannot find name 'foo'")
check_field "typescript cat" "code" "$(get_field "$record" 1)"
check_field "typescript safety" "code" "$(get_field "$record" 2)"

record=$(classify_build_error "could not compile \`mylib\`")
check_field "rust_compile cat" "code" "$(get_field "$record" 1)"

record=$(classify_build_error "error[E0412]: unresolved import \`foo::bar\`")
check_field "rust_import cat" "code" "$(get_field "$record" 1)"

record=$(classify_build_error "java.lang.ClassNotFoundException: com.example.Foo")
check_field "java_classnotfound cat" "code" "$(get_field "$record" 1)"

record=$(classify_build_error "SyntaxError: Unexpected token '}'")
check_field "syntax cat" "code" "$(get_field "$record" 1)"

record=$(classify_build_error "ReferenceError: foo is not defined")
check_field "reference cat" "code" "$(get_field "$record" 1)"

record=$(classify_build_error "TypeError: Cannot read properties of undefined")
check_field "type cat" "code" "$(get_field "$record" 1)"

record=$(classify_build_error "BUILD FAILED in 5s")
check_field "build_failed cat" "code" "$(get_field "$record" 1)"

# =============================================================================
# classify_build_error — edge cases
# =============================================================================

echo "=== classify_build_error: edge cases ==="

# Empty input
record=$(classify_build_error "")
check_field "empty cat" "code" "$(get_field "$record" 1)"
check_field "empty diag" "Empty error input" "$(get_field "$record" 4)"

# Unrecognized error defaults to code
record=$(classify_build_error "some completely unknown error message xyz123")
check_field "unknown cat" "code" "$(get_field "$record" 1)"
check_field "unknown safety" "code" "$(get_field "$record" 2)"
check_field "unknown diag" "Unclassified build error" "$(get_field "$record" 4)"

# =============================================================================
# classify_build_errors_all — mixed output
# =============================================================================

echo "=== classify_build_errors_all: mixed output ==="

mixed_output="error TS2304: Cannot find name 'bar'
Error: connect ECONNREFUSED 127.0.0.1:5432
npx playwright install
some random text that is unclassified"

results=$(classify_build_errors_all "$mixed_output")
result_count=$(echo "$results" | wc -l | tr -d '[:space:]')

# Should have at least 3 distinct classifications (code, service_dep, env_setup + unclassified)
if [[ "$result_count" -ge 3 ]]; then
    pass
else
    fail "Mixed output should produce >= 3 classifications, got ${result_count}: ${results}"
fi

# Check specific categories are present
if echo "$results" | grep -q "^code|"; then
    pass
else
    fail "Mixed output missing code classification"
fi

if echo "$results" | grep -q "^service_dep|"; then
    pass
else
    fail "Mixed output missing service_dep classification"
fi

if echo "$results" | grep -q "^env_setup|"; then
    pass
else
    fail "Mixed output missing env_setup classification"
fi

# =============================================================================
# classify_build_errors_all — deduplication
# =============================================================================

echo "=== classify_build_errors_all: deduplication ==="

duped_output="error TS2304: Cannot find name 'foo'
error TS2304: Cannot find name 'bar'
error TS2304: Cannot find name 'baz'"

results=$(classify_build_errors_all "$duped_output")
# All three are TypeScript errors — same category+diagnosis → deduplicated
ts_count=$(echo "$results" | grep -c "^code|" || true)
if [[ "$ts_count" -eq 1 ]]; then
    pass
else
    fail "Deduplication: expected 1 code classification, got ${ts_count}"
fi

# =============================================================================
# classify_build_errors_all — empty input
# =============================================================================

echo "=== classify_build_errors_all: empty input ==="

results=$(classify_build_errors_all "")
if [[ -z "$results" ]]; then
    pass
else
    fail "Empty input should return empty output, got: ${results}"
fi

# =============================================================================
# has_only_noncode_errors
# =============================================================================

echo "=== has_only_noncode_errors ==="

# All non-code
if has_only_noncode_errors "ECONNREFUSED 127.0.0.1:5432"; then
    pass
else
    fail "All service_dep should be non-code"
fi

# Has code error
if ! has_only_noncode_errors "error TS2304: Cannot find name 'foo'"; then
    pass
else
    fail "TypeScript error should NOT be non-code only"
fi

# Mixed — has code
if ! has_only_noncode_errors "ECONNREFUSED 127.0.0.1:5432
error TS2304: Cannot find name 'foo'"; then
    pass
else
    fail "Mixed output with code error should NOT be non-code only"
fi

# Empty input returns 1 (not non-code only)
if ! has_only_noncode_errors ""; then
    pass
else
    fail "Empty input should return 1"
fi

# =============================================================================
# filter_code_errors
# =============================================================================

echo "=== filter_code_errors ==="

mixed_input="error TS2304: Cannot find name 'foo'
ECONNREFUSED 127.0.0.1:5432
SyntaxError: Unexpected token"

filtered=$(filter_code_errors "$mixed_input")

# Should contain "Code Errors to Fix" section
if echo "$filtered" | grep -q "Code Errors to Fix"; then
    pass
else
    fail "Filtered output missing 'Code Errors to Fix' header"
fi

# Should contain "Already Handled" section
if echo "$filtered" | grep -q "Already Handled"; then
    pass
else
    fail "Filtered output missing 'Already Handled' header"
fi

# Should contain the TypeScript error
if echo "$filtered" | grep -q "TS2304"; then
    pass
else
    fail "Filtered output missing TypeScript code error"
fi

# Empty input returns nothing
filtered_empty=$(filter_code_errors "")
if [[ -z "$filtered_empty" ]]; then
    pass
else
    fail "Empty input to filter_code_errors should return empty"
fi

# All-code input: only code errors, no non-code errors present
echo "=== filter_code_errors: all-code input ==="

all_code_input="error TS2304: Cannot find name 'foo'
SyntaxError: Unexpected token '}'
ReferenceError: bar is not defined"

filtered_all_code=$(filter_code_errors "$all_code_input")

# Should contain Code Errors to Fix section
if echo "$filtered_all_code" | grep -q "Code Errors to Fix"; then
    pass
else
    fail "All-code input: missing 'Code Errors to Fix' section"
fi

# Should NOT contain Already Handled section (no non-code errors)
if ! echo "$filtered_all_code" | grep -q "Already Handled"; then
    pass
else
    fail "All-code input: should not contain 'Already Handled' section"
fi

# Should contain all three error lines
if echo "$filtered_all_code" | grep -q "TS2304"; then
    pass
else
    fail "All-code input: missing TypeScript error line"
fi

if echo "$filtered_all_code" | grep -q "SyntaxError"; then
    pass
else
    fail "All-code input: missing SyntaxError line"
fi

# All-noncode input: only env/service errors, no code errors
echo "=== filter_code_errors: all-noncode input ==="

all_noncode_input="ECONNREFUSED 127.0.0.1:5432
npx playwright install
Cannot find module 'react'"

filtered_all_noncode=$(filter_code_errors "$all_noncode_input")

# Should contain Already Handled section
if echo "$filtered_all_noncode" | grep -q "Already Handled"; then
    pass
else
    fail "All-noncode input: missing 'Already Handled' section"
fi

# Should NOT contain Code Errors to Fix section (no code errors)
if ! echo "$filtered_all_noncode" | grep -q "Code Errors to Fix"; then
    pass
else
    fail "All-noncode input: should not contain 'Code Errors to Fix' section"
fi

# =============================================================================
# annotate_build_errors
# =============================================================================

echo "=== annotate_build_errors ==="

annotated=$(annotate_build_errors "error TS2304: Cannot find name 'foo'" "post-coder")

# Should have stage label
if echo "$annotated" | grep -q "post-coder"; then
    pass
else
    fail "Annotated output missing stage label"
fi

# Should have Error Classification section
if echo "$annotated" | grep -q "Error Classification"; then
    pass
else
    fail "Annotated output missing Error Classification section"
fi

# Non-code branch: env_setup error with remediation should produce Auto-fix line
echo "=== annotate_build_errors: non-code env_setup branch ==="

annotated_env=$(annotate_build_errors "npx playwright install" "ui-tests")

# Should have stage label
if echo "$annotated_env" | grep -q "ui-tests"; then
    pass
else
    fail "env_setup annotated output missing stage label"
fi

# Should have Error Classification section
if echo "$annotated_env" | grep -q "Error Classification"; then
    pass
else
    fail "env_setup annotated output missing Error Classification section"
fi

# Should have Auto-fix line (env_setup with remediation)
if echo "$annotated_env" | grep -q "Auto-fix:"; then
    pass
else
    fail "env_setup annotated output missing Auto-fix remediation line"
fi

# Should have environment/setup section header
if echo "$annotated_env" | grep -q "Environment/Setup"; then
    pass
else
    fail "env_setup annotated output missing 'Environment/Setup' header"
fi

# Should NOT have code error header (no code errors in input)
if ! echo "$annotated_env" | grep -q "Classified as Code Error"; then
    pass
else
    fail "env_setup annotated output should not contain 'Classified as Code Error'"
fi

# =============================================================================
# M54: Auto-Remediation Engine tests
# =============================================================================

# Source remediation engine
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/error_patterns_remediation.sh"

# Stub log/warn for remediation output
log() { :; }
warn() { :; }

# Stub append_human_action to capture calls
_HUMAN_ACTION_CALLS=()
append_human_action() {
    _HUMAN_ACTION_CALLS+=("$1|$2")
}

# Stub emit_event to capture calls
_EMIT_EVENT_CALLS=()
emit_event() {
    _EMIT_EVENT_CALLS+=("$1|$2|$3")
    echo "evt-${#_EMIT_EVENT_CALLS[@]}"
}

# Set PROJECT_DIR to a temp dir for safe command execution
_TEST_TMPDIR=$(mktemp -d)
PROJECT_DIR="$_TEST_TMPDIR"

echo "=== attempt_remediation: safe command executes ==="

reset_remediation_state

# Create a classifications string with a safe remediation (touch a file)
classifications="env_setup|safe|touch ${_TEST_TMPDIR}/remed_test_marker|Test env fix"

if attempt_remediation "$classifications" "test_phase"; then
    pass
else
    fail "attempt_remediation should return 0 on successful safe command"
fi

# Verify the command actually ran
if [[ -f "${_TEST_TMPDIR}/remed_test_marker" ]]; then
    pass
else
    fail "Safe remediation command did not execute (marker file missing)"
fi

# Verify remediation log has an entry
remed_log=$(get_remediation_log)
if echo "$remed_log" | grep -q '"action":"attempted"'; then
    pass
else
    fail "Remediation log missing 'attempted' entry: ${remed_log}"
fi

if echo "$remed_log" | grep -q '"exit_code":0'; then
    pass
else
    fail "Remediation log should show exit_code 0: ${remed_log}"
fi

echo "=== attempt_remediation: manual command NOT executed ==="

reset_remediation_state
_HUMAN_ACTION_CALLS=()

classifications="service_dep|manual||PostgreSQL not running"

if ! attempt_remediation "$classifications" "test_phase"; then
    pass
else
    fail "attempt_remediation should return 1 when no safe commands exist"
fi

# Verify human action was routed
if [[ ${#_HUMAN_ACTION_CALLS[@]} -gt 0 ]]; then
    pass
else
    fail "Manual error should route to human action"
fi

# Verify human action content mentions the diagnosis
if echo "${_HUMAN_ACTION_CALLS[0]}" | grep -q "PostgreSQL"; then
    pass
else
    fail "Human action should contain diagnosis: ${_HUMAN_ACTION_CALLS[0]}"
fi

echo "=== attempt_remediation: prompt command routed to human action ==="

reset_remediation_state
_HUMAN_ACTION_CALLS=()

classifications="test_infra|prompt|npm test -- -u|Snapshots obsolete"

if ! attempt_remediation "$classifications" "test_phase"; then
    pass
else
    fail "attempt_remediation should return 1 for prompt-only (no safe execution)"
fi

if [[ ${#_HUMAN_ACTION_CALLS[@]} -gt 0 ]]; then
    pass
else
    fail "Prompt error should route to human action"
fi

echo "=== attempt_remediation: blocklisted command rejected ==="

reset_remediation_state

classifications="env_setup|safe|rm -rf /tmp/badstuff|Dangerous cleanup"

if ! attempt_remediation "$classifications" "test_phase"; then
    pass
else
    fail "attempt_remediation should return 1 when command is blocklisted"
fi

# Verify log shows blocked
remed_log=$(get_remediation_log)
if echo "$remed_log" | grep -q '"action":"blocked"'; then
    pass
else
    fail "Remediation log should show 'blocked' for blocklisted command: ${remed_log}"
fi

echo "=== attempt_remediation: max 2 attempts enforced ==="

reset_remediation_state

# Three safe commands — only first 2 should execute
classifications="env_setup|safe|touch ${_TEST_TMPDIR}/remed_a|Fix A
env_setup|safe|touch ${_TEST_TMPDIR}/remed_b|Fix B
env_setup|safe|touch ${_TEST_TMPDIR}/remed_c|Fix C"

attempt_remediation "$classifications" "test_phase" || true

if [[ -f "${_TEST_TMPDIR}/remed_a" ]]; then
    pass
else
    fail "First remediation should execute"
fi

if [[ -f "${_TEST_TMPDIR}/remed_b" ]]; then
    pass
else
    fail "Second remediation should execute"
fi

if [[ ! -f "${_TEST_TMPDIR}/remed_c" ]]; then
    pass
else
    fail "Third remediation should NOT execute (max 2 attempts)"
fi

# Verify skipped entry in log
remed_log=$(get_remediation_log)
if echo "$remed_log" | grep -q '"action":"skipped"'; then
    pass
else
    fail "Remediation log should show 'skipped' for third command: ${remed_log}"
fi

echo "=== attempt_remediation: duplicate command not re-run ==="

reset_remediation_state

# Same command twice — should only execute once
classifications="env_setup|safe|touch ${_TEST_TMPDIR}/remed_dup|Fix dup
env_setup|safe|touch ${_TEST_TMPDIR}/remed_dup|Fix dup again"

attempt_remediation "$classifications" "test_phase" || true

# Should have only 1 attempt (not 2)
if [[ "$_REMEDIATION_ATTEMPT_COUNT" -eq 1 ]]; then
    pass
else
    fail "Duplicate command should not be re-run, got ${_REMEDIATION_ATTEMPT_COUNT} attempts"
fi

echo "=== attempt_remediation: code errors skipped ==="

reset_remediation_state

classifications="code|code||TypeScript error"

if ! attempt_remediation "$classifications" "test_phase"; then
    pass
else
    fail "Code errors should not trigger remediation"
fi

echo "=== _is_blocklisted_command ==="

if _is_blocklisted_command "rm -rf /tmp/foo"; then
    pass
else
    fail "rm -rf should be blocklisted"
fi

if _is_blocklisted_command "git reset --hard HEAD"; then
    pass
else
    fail "reset --hard should be blocklisted"
fi

if _is_blocklisted_command "npm install --force"; then
    pass
else
    fail "--force should be blocklisted"
fi

if ! _is_blocklisted_command "npm install"; then
    pass
else
    fail "npm install should NOT be blocklisted"
fi

if ! _is_blocklisted_command "npx playwright install"; then
    pass
else
    fail "npx playwright install should NOT be blocklisted"
fi

echo "=== _run_safe_remediation: timeout enforcement ==="

# Override timeout to 1s for testing
_REMEDIATION_TIMEOUT=1
output=$(_run_safe_remediation "sleep 10" 2>&1) || exit_code=$?
_REMEDIATION_TIMEOUT=60

if echo "$output" | grep -q "TIMEOUT"; then
    pass
else
    fail "Timed-out command should report TIMEOUT: ${output}"
fi

echo "=== causal event emission ==="

reset_remediation_state
_EMIT_EVENT_CALLS=()

classifications="env_setup|safe|touch ${_TEST_TMPDIR}/remed_evt|Env fix"
attempt_remediation "$classifications" "test_phase" || true

# Check that remediation_attempted event was emitted
local_found=false
for call in "${_EMIT_EVENT_CALLS[@]}"; do
    if echo "$call" | grep -q "remediation_attempted"; then
        local_found=true
        break
    fi
done
if [[ "$local_found" = true ]]; then
    pass
else
    fail "remediation_attempted event should be emitted"
fi

# Check manual error emits human_action_required
_EMIT_EVENT_CALLS=()
reset_remediation_state
classifications="service_dep|manual||DB down"
attempt_remediation "$classifications" "test_phase" || true

local_found=false
for call in "${_EMIT_EVENT_CALLS[@]}"; do
    if echo "$call" | grep -q "human_action_required"; then
        local_found=true
        break
    fi
done
if [[ "$local_found" = true ]]; then
    pass
else
    fail "human_action_required event should be emitted for manual errors"
fi

echo "=== get_remediation_log: empty state ==="

reset_remediation_state
remed_log=$(get_remediation_log)
if [[ "$remed_log" == "[]" ]]; then
    pass
else
    fail "Empty remediation log should return []: ${remed_log}"
fi

echo "=== get_remediation_log: JSON structure ==="

reset_remediation_state
classifications="env_setup|safe|touch ${_TEST_TMPDIR}/remed_json|JSON test"
attempt_remediation "$classifications" "test_phase" || true
remed_log=$(get_remediation_log)

# Must start with [ and end with ]
if [[ "$remed_log" == "["* ]] && [[ "$remed_log" == *"]" ]]; then
    pass
else
    fail "Remediation log should be a JSON array: ${remed_log}"
fi

# Must contain required fields
for field in action category command exit_code duration_s diagnosis; do
    if echo "$remed_log" | grep -q "\"${field}\""; then
        pass
    else
        fail "Remediation log entry missing '${field}' field: ${remed_log}"
    fi
done

# Cleanup temp dir
rm -rf "$_TEST_TMPDIR"

# =============================================================================
# Summary
# =============================================================================

echo
echo "--------------------------------------"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "--------------------------------------"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
echo "error_patterns.sh unit tests passed"

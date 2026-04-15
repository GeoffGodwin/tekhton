#!/usr/bin/env bash
# Test: Config source annotations (Milestone 83)
# Tests that _emit_command_line() and _emit_verified_line() emit
# detection source annotations in generated config output.
# shellcheck disable=SC2034
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# Stub logging functions
log()     { :; }
success() { :; }
warn()    { :; }
error()   { :; }
header()  { :; }

# Set up minimal globals
TEKHTON_VERSION="3.83.0"
export TEKHTON_VERSION
TEKHTON_DIR=".tekhton"
DRIFT_LOG_FILE="${TEKHTON_DIR}/DRIFT_LOG.md"
ARCHITECTURE_LOG_FILE="${TEKHTON_DIR}/ARCHITECTURE_LOG.md"
HUMAN_ACTION_FILE="${TEKHTON_DIR}/HUMAN_ACTION_REQUIRED.md"
NON_BLOCKING_LOG_FILE="${TEKHTON_DIR}/NON_BLOCKING_LOG.md"
_INIT_WORKSPACES=""
_INIT_SERVICES=""
_INIT_WORKSPACE_SCOPE=""

# Source the config emitter files
# shellcheck source=../lib/init_config_emitters.sh
source "${TEKHTON_HOME}/lib/init_config_emitters.sh"
# shellcheck source=../lib/init_config_sections.sh
source "${TEKHTON_HOME}/lib/init_config_sections.sh"

echo "=== _emit_command_line: source annotation emitted when source is set ==="

output=$(_emit_command_line "TEST_CMD" "npm test" "high" "package.json scripts.test")
if echo "$output" | grep -q "# Detected from: package.json scripts.test (confidence: high)"; then
    pass "_emit_command_line emits source annotation"
else
    fail "_emit_command_line did not emit source annotation: $output"
fi
if echo "$output" | grep -q 'TEST_CMD="npm test"'; then
    pass "_emit_command_line emits key=value"
else
    fail "_emit_command_line did not emit key=value: $output"
fi

echo ""
echo "=== _emit_command_line: no annotation when source is empty ==="

output=$(_emit_command_line "TEST_CMD" "npm test" "high" "")
if echo "$output" | grep -q "# Detected from:"; then
    fail "_emit_command_line emitted annotation when source was empty"
else
    pass "_emit_command_line no annotation when source is empty"
fi

echo ""
echo "=== _emit_command_line: medium conf with source omits VERIFY marker ==="

output=$(_emit_command_line "ANALYZE_CMD" "npx eslint ." "medium" ".eslintrc.json")
if echo "$output" | grep -q "# Detected from: .eslintrc.json"; then
    pass "Medium conf with source has source annotation"
else
    fail "Medium conf with source missing source annotation"
fi
if echo "$output" | grep -q "# VERIFY:"; then
    fail "Medium conf with source should not have VERIFY marker"
else
    pass "Medium conf with source omits VERIFY marker"
fi

echo ""
echo "=== _emit_command_line: medium conf without source shows VERIFY ==="

output=$(_emit_command_line "ANALYZE_CMD" "npx eslint ." "medium" "")
if echo "$output" | grep -q "# VERIFY:"; then
    pass "Medium conf without source shows VERIFY marker"
else
    fail "Medium conf without source missing VERIFY marker"
fi

echo ""
echo "=== _emit_command_line: low confidence shows SUGGESTION regardless ==="

output=$(_emit_command_line "BUILD_CMD" "make build" "low" "Makefile")
if echo "$output" | grep -q "# Detected from: Makefile (confidence: low)"; then
    pass "Low conf with source has source annotation"
else
    fail "Low conf with source missing source annotation"
fi
if echo "$output" | grep -q "# SUGGESTION:"; then
    pass "Low conf shows SUGGESTION marker"
else
    fail "Low conf missing SUGGESTION marker"
fi

echo ""
echo "=== _emit_verified_line: source annotation emitted ==="

output=$(_emit_verified_line "TEST_CMD" "pytest" "high" "pyproject.toml scripts.test")
if echo "$output" | grep -q "# Detected from: pyproject.toml scripts.test"; then
    pass "_emit_verified_line emits source annotation"
else
    fail "_emit_verified_line did not emit source annotation"
fi

echo ""
echo "=== generate_sectioned_config: source annotations in full config ==="

output=$(generate_sectioned_config \
    "my-project" \
    "npm test" "high" "npx eslint ." "medium" "npm run build" "low" \
    "claude-sonnet-4-6" \
    35 15 10 30 20 \
    "claude git node npm" \
    "" \
    "package.json scripts.test" ".eslintrc.json + package.json" "package.json scripts.build")

if echo "$output" | grep -q "# Detected from: package.json scripts.test (confidence: high)"; then
    pass "Full config has test source annotation"
else
    fail "Full config missing test source annotation"
fi
if echo "$output" | grep -q "# Detected from: .eslintrc.json + package.json (confidence: medium)"; then
    pass "Full config has analyze source annotation"
else
    fail "Full config missing analyze source annotation"
fi
if echo "$output" | grep -q "# Detected from: package.json scripts.build (confidence: low)"; then
    pass "Full config has build source annotation"
else
    fail "Full config missing build source annotation"
fi
if echo "$output" | grep -q "# Not auto-detected"; then
    pass "Full config has 'Not auto-detected' for PROJECT_DESCRIPTION"
else
    fail "Full config missing 'Not auto-detected' marker"
fi

echo ""
echo "=== generate_sectioned_config: no annotations when sources empty ==="

output=$(generate_sectioned_config \
    "my-project" \
    "npm test" "high" "npx eslint ." "high" "" "" \
    "claude-sonnet-4-6" \
    35 15 10 30 20 \
    "claude git" \
    "" \
    "" "" "")

detect_count=$(echo "$output" | grep -c "# Detected from:" || true)
if [[ "$detect_count" -eq 0 ]]; then
    pass "No source annotations when sources are empty"
else
    fail "Found $detect_count unexpected source annotations"
fi

echo ""
echo "=== _best_source helper returns detection source ==="

# Source init_config.sh for _best_source
# shellcheck source=../lib/init_config.sh
source "${TEKHTON_HOME}/lib/init_config.sh"

commands="test|npm test|package.json scripts.test|high
analyze|npx eslint .|.eslintrc.json|medium
build|npm run build|package.json scripts.build|low"

src=$(_best_source "$commands" "test")
if [[ "$src" == "package.json scripts.test" ]]; then
    pass "_best_source returns test source"
else
    fail "_best_source returned '$src' (expected 'package.json scripts.test')"
fi

src=$(_best_source "$commands" "analyze")
if [[ "$src" == ".eslintrc.json" ]]; then
    pass "_best_source returns analyze source"
else
    fail "_best_source returned '$src' (expected '.eslintrc.json')"
fi

src=$(_best_source "" "test")
if [[ -z "$src" ]]; then
    pass "_best_source returns empty for empty commands"
else
    fail "_best_source returned '$src' for empty commands"
fi

echo ""
echo "════════════════════════════════════════"
echo "  Results: ${PASS} passed, ${FAIL} failed"
echo "════════════════════════════════════════"
exit "$FAIL"

#!/usr/bin/env bash
# Test: _generate_smart_config() and _detect_required_tools() — Milestone 19
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEKHTON_VERSION="${TEKHTON_VERSION:-0.0.0}"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# Stub logging functions used by init_config.sh
log()     { :; }
warn()    { :; }
error()   { :; }
success() { :; }
header()  { :; }

# Source the library under test
# shellcheck source=../lib/init_config.sh
source "${TEKHTON_HOME}/lib/init_config.sh"

# =============================================================================
# Helper: run _generate_smart_config and return the output conf file path
# =============================================================================
make_conf() {
    local proj_dir="$1"
    local languages="$2"
    local frameworks="$3"
    local commands="$4"
    local file_count="$5"
    local conf_file="${proj_dir}/.claude/pipeline.conf"
    mkdir -p "${proj_dir}/.claude"
    _generate_smart_config "$proj_dir" "$conf_file" \
        "$languages" "$frameworks" "$commands" "$file_count"
    echo "$conf_file"
}

# =============================================================================
# Node.js / TypeScript scenario (Acceptance criterion 1)
# =============================================================================
echo "=== Node.js scenario ==="

NODE_DIR=$(mktemp -d -p "$TEST_TMPDIR")
NODE_LANGS="typescript|high|package.json"
NODE_FWKS=""
# Format: CMD_TYPE|COMMAND|SOURCE|CONFIDENCE
NODE_CMDS="$(printf 'test|npm test|package.json|high\nanalyze|npx eslint .|package.json|high')"
NODE_CONF=$(make_conf "$NODE_DIR" "$NODE_LANGS" "$NODE_FWKS" "$NODE_CMDS" 10)

test_cmd=$(grep "^TEST_CMD=" "$NODE_CONF" | cut -d= -f2 | tr -d '"')
if [[ "$test_cmd" = "npm test" ]]; then
    pass "Node.js: TEST_CMD=npm test"
else
    fail "Node.js: TEST_CMD expected 'npm test', got '$test_cmd'"
fi

analyze_cmd=$(grep "^ANALYZE_CMD=" "$NODE_CONF" | cut -d= -f2 | tr -d '"')
if [[ "$analyze_cmd" = "npx eslint ." ]]; then
    pass "Node.js: ANALYZE_CMD=npx eslint ."
else
    fail "Node.js: ANALYZE_CMD expected 'npx eslint .', got '$analyze_cmd'"
fi

required_tools=$(grep "^REQUIRED_TOOLS=" "$NODE_CONF" | cut -d= -f2 | tr -d '"')
if echo "$required_tools" | grep -q "node" && echo "$required_tools" | grep -q "npm"; then
    pass "Node.js: REQUIRED_TOOLS contains node and npm"
else
    fail "Node.js: REQUIRED_TOOLS expected 'node npm', got '$required_tools'"
fi

if echo "$required_tools" | grep -q "claude" && echo "$required_tools" | grep -q "git"; then
    pass "Node.js: REQUIRED_TOOLS contains claude and git"
else
    fail "Node.js: REQUIRED_TOOLS missing claude or git: '$required_tools'"
fi

# =============================================================================
# Rust scenario (Acceptance criterion 2)
# =============================================================================
echo "=== Rust scenario ==="

RUST_DIR=$(mktemp -d -p "$TEST_TMPDIR")
RUST_LANGS="rust|high|Cargo.toml"
RUST_FWKS=""
RUST_CMDS="$(printf 'test|cargo test|Cargo.toml|high\nanalyze|cargo clippy|Cargo.toml|high')"
RUST_CONF=$(make_conf "$RUST_DIR" "$RUST_LANGS" "$RUST_FWKS" "$RUST_CMDS" 15)

test_cmd=$(grep "^TEST_CMD=" "$RUST_CONF" | cut -d= -f2 | tr -d '"')
if [[ "$test_cmd" = "cargo test" ]]; then
    pass "Rust: TEST_CMD=cargo test"
else
    fail "Rust: TEST_CMD expected 'cargo test', got '$test_cmd'"
fi

analyze_cmd=$(grep "^ANALYZE_CMD=" "$RUST_CONF" | cut -d= -f2 | tr -d '"')
if [[ "$analyze_cmd" = "cargo clippy" ]]; then
    pass "Rust: ANALYZE_CMD=cargo clippy"
else
    fail "Rust: ANALYZE_CMD expected 'cargo clippy', got '$analyze_cmd'"
fi

required_tools=$(grep "^REQUIRED_TOOLS=" "$RUST_CONF" | cut -d= -f2 | tr -d '"')
if echo "$required_tools" | grep -q "cargo"; then
    pass "Rust: REQUIRED_TOOLS contains cargo"
else
    fail "Rust: REQUIRED_TOOLS expected 'cargo', got '$required_tools'"
fi

if echo "$required_tools" | grep -q "claude" && echo "$required_tools" | grep -q "git"; then
    pass "Rust: REQUIRED_TOOLS contains claude and git"
else
    fail "Rust: REQUIRED_TOOLS missing claude or git: '$required_tools'"
fi

# =============================================================================
# Python scenario (Acceptance criterion 3)
# =============================================================================
echo "=== Python scenario ==="

PY_DIR=$(mktemp -d -p "$TEST_TMPDIR")
PY_LANGS="python|high|pyproject.toml"
PY_FWKS=""
PY_CMDS="$(printf 'test|pytest|pyproject.toml|high\nanalyze|ruff check .|pyproject.toml|high')"
PY_CONF=$(make_conf "$PY_DIR" "$PY_LANGS" "$PY_FWKS" "$PY_CMDS" 20)

test_cmd=$(grep "^TEST_CMD=" "$PY_CONF" | cut -d= -f2 | tr -d '"')
if [[ "$test_cmd" = "pytest" ]]; then
    pass "Python: TEST_CMD=pytest"
else
    fail "Python: TEST_CMD expected 'pytest', got '$test_cmd'"
fi

analyze_cmd=$(grep "^ANALYZE_CMD=" "$PY_CONF" | cut -d= -f2 | tr -d '"')
if [[ "$analyze_cmd" = "ruff check ." ]]; then
    pass "Python: ANALYZE_CMD=ruff check ."
else
    fail "Python: ANALYZE_CMD expected 'ruff check .', got '$analyze_cmd'"
fi

required_tools=$(grep "^REQUIRED_TOOLS=" "$PY_CONF" | cut -d= -f2 | tr -d '"')
if echo "$required_tools" | grep -q "python"; then
    pass "Python: REQUIRED_TOOLS contains python"
else
    fail "Python: REQUIRED_TOOLS expected 'python', got '$required_tools'"
fi

# =============================================================================
# Confidence annotations — medium confidence
# M83 behavior: with source → emits "# Detected from:" (no VERIFY marker)
#               without source → emits "# VERIFY:"
# =============================================================================
echo "=== Confidence annotation: medium ==="

MED_DIR=$(mktemp -d -p "$TEST_TMPDIR")
MED_LANGS="python|medium|requirements.txt"
MED_CMDS="$(printf 'test|pytest|requirements.txt|medium')"
MED_CONF=$(make_conf "$MED_DIR" "$MED_LANGS" "" "$MED_CMDS" 5)

# M83: when detection source is known, the source annotation replaces VERIFY
if grep -q "# Detected from: requirements.txt (confidence: medium)" "$MED_CONF"; then
    pass "Medium confidence with source produces # Detected from: annotation"
else
    fail "Medium confidence with source should produce # Detected from: annotation — not found"
fi

# VERIFY should NOT appear when source is known (source annotation suffices)
if ! grep -q "# VERIFY:" "$MED_CONF"; then
    pass "Medium confidence with source omits # VERIFY: (redundant when source known)"
else
    fail "Medium confidence with source should not emit # VERIFY: when source is known"
fi

test_cmd=$(grep "^TEST_CMD=" "$MED_CONF" | cut -d= -f2 | tr -d '"')
if [[ "$test_cmd" = "pytest" ]]; then
    pass "Medium confidence: command still set (not commented out)"
else
    fail "Medium confidence: TEST_CMD expected 'pytest', got '$test_cmd'"
fi

# =============================================================================
# Confidence annotations — low confidence → # SUGGESTION: + command disabled
# =============================================================================
echo "=== Confidence annotation: low ==="

LOW_DIR=$(mktemp -d -p "$TEST_TMPDIR")
LOW_LANGS="python|low|setup.py"
LOW_CMDS="$(printf 'test|python -m pytest|setup.py|low')"
LOW_CONF=$(make_conf "$LOW_DIR" "$LOW_LANGS" "" "$LOW_CMDS" 3)

if grep -q "# SUGGESTION:" "$LOW_CONF"; then
    pass "Low confidence produces # SUGGESTION: comment in config"
else
    fail "Low confidence should produce # SUGGESTION: comment — not found"
fi

# Low confidence: command should be commented out, TEST_CMD="true" set instead
test_cmd=$(grep "^TEST_CMD=" "$LOW_CONF" | cut -d= -f2 | tr -d '"')
if [[ "$test_cmd" = "true" ]]; then
    pass "Low confidence: TEST_CMD defaults to 'true' (actual command commented)"
else
    fail "Low confidence: TEST_CMD expected 'true', got '$test_cmd'"
fi

if grep -q "# TEST_CMD=" "$LOW_CONF"; then
    pass "Low confidence: actual command appears commented out"
else
    fail "Low confidence: actual command should be commented out"
fi

# =============================================================================
# Model scaling — large project (>200 files) → opus
# =============================================================================
echo "=== Model scaling: large project ==="

LARGE_DIR=$(mktemp -d -p "$TEST_TMPDIR")
LARGE_CONF=$(make_conf "$LARGE_DIR" "" "" "" 201)

coder_model=$(grep "^CLAUDE_CODER_MODEL=" "$LARGE_CONF" | cut -d= -f2 | tr -d '"')
if [[ "$coder_model" = "claude-opus-4-6" ]]; then
    pass "Large project (>200 files): CLAUDE_CODER_MODEL=claude-opus-4-6"
else
    fail "Large project: CLAUDE_CODER_MODEL expected 'claude-opus-4-6', got '$coder_model'"
fi

coder_turns=$(grep "^CODER_MAX_TURNS=" "$LARGE_CONF" | cut -d= -f2)
if [[ "$coder_turns" -ge 50 ]]; then
    pass "Large project: CODER_MAX_TURNS scaled up (>= 50)"
else
    fail "Large project: CODER_MAX_TURNS expected >= 50, got '$coder_turns'"
fi

# =============================================================================
# Model scaling — small project (<50 files) → sonnet
# =============================================================================
echo "=== Model scaling: small project ==="

SMALL_DIR=$(mktemp -d -p "$TEST_TMPDIR")
SMALL_CONF=$(make_conf "$SMALL_DIR" "" "" "" 10)

coder_model=$(grep "^CLAUDE_CODER_MODEL=" "$SMALL_CONF" | cut -d= -f2 | tr -d '"')
if [[ "$coder_model" = "claude-sonnet-4-6" ]]; then
    pass "Small project (<50 files): CLAUDE_CODER_MODEL=claude-sonnet-4-6"
else
    fail "Small project: CLAUDE_CODER_MODEL expected 'claude-sonnet-4-6', got '$coder_model'"
fi

# =============================================================================
# _detect_required_tools — deduplication
# =============================================================================
echo "=== _detect_required_tools: deduplication ==="

# Two languages that both add the same tool should not duplicate it
DEDUP_LANGS="$(printf 'typescript|high|package.json\njavascript|medium|package.json')"
dedup_tools=$(_detect_required_tools "$DEDUP_LANGS")

node_count=$(echo "$dedup_tools" | tr ' ' '\n' | grep -c "^node$" || true)
if [[ "$node_count" -eq 1 ]]; then
    pass "_detect_required_tools: node not duplicated for typescript+javascript"
else
    fail "_detect_required_tools: node appears $node_count times (expected 1)"
fi

# =============================================================================
# _detect_required_tools — empty languages
# =============================================================================
echo "=== _detect_required_tools: empty input ==="

empty_tools=$(_detect_required_tools "")
if echo "$empty_tools" | grep -q "claude" && echo "$empty_tools" | grep -q "git"; then
    pass "_detect_required_tools: empty input still returns claude git"
else
    fail "_detect_required_tools: empty input should return 'claude git', got '$empty_tools'"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi

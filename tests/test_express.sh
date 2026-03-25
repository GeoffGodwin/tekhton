#!/usr/bin/env bash
# =============================================================================
# test_express.sh — Unit tests for lib/express.sh
#
# Tests:
# - _detect_express_project_name: package.json, pyproject.toml, Cargo.toml,
#   go.mod, and basename fallback
# - detect_express_config: sets _EXPRESS_PROJECT_NAME/_EXPRESS_LANGUAGES/_EXPRESS_COMMANDS
# - generate_express_config: command extraction from pipe-delimited detection output,
#   fallbacks when no command detected, path absolutization
# - persist_express_config: never overwrites existing pipeline.conf, template
#   variable substitution, atomic write, inline fallback when template missing
# - resolve_role_file: project file exists / fallback to template / last resort
# - apply_role_file_fallbacks: updates all role file globals for missing files
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_ROOT=$(mktemp -d)
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

# --- Test infrastructure -------------------------------------------------------

PASS=0
FAIL=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc — expected '$expected', got '$actual'"
        FAIL=$((FAIL + 1))
    fi
}

assert() {
    local desc="$1" result="$2"
    if [ "$result" = "0" ]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc — '$needle' not found in output"
        FAIL=$((FAIL + 1))
    fi
}

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        echo "  FAIL: $desc — '$needle' found but should not be present"
        FAIL=$((FAIL + 1))
    else
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    fi
}

# --- Minimal globals required by common.sh and express.sh --------------------

PROJECT_DIR="$TMPDIR_ROOT/project"
mkdir -p "$PROJECT_DIR"
export PROJECT_DIR

# Source common.sh (provides log, warn, etc.)
source "${TEKHTON_HOME}/lib/common.sh"

# Mock detect_languages and detect_commands — express.sh calls these at runtime
detect_languages() {
    echo "${_MOCK_LANGUAGES:-}"
}
detect_commands() {
    echo "${_MOCK_COMMANDS:-}"
}

# Mock _clamp_config_value — defined in config.sh, called by config_defaults.sh
# which is sourced inside generate_express_config. Clamps a var to a max value.
_clamp_config_value() {
    local var="$1" max="$2"
    local val="${!var:-0}"
    if [[ "$val" =~ ^[0-9]+$ ]] && (( val > max )); then
        printf -v "$var" '%s' "$max"
    fi
}

# Mock _clamp_config_float — defined in config.sh, called by config_defaults.sh.
# Clamps a floating-point config value to [min, max].
_clamp_config_float() {
    local key="$1" min="$2" max="$3"
    local val="${!key:-0}"
    if ! [[ "$val" =~ ^[0-9]+\.?[0-9]*$ ]]; then
        return
    fi
    local clamped
    clamped=$(awk "BEGIN { v=$val; if (v < $min) v=$min; if (v > $max) v=$max; printf \"%.1f\", v }")
    if [[ "$clamped" != "$val" ]]; then
        declare -gx "$key=$clamped"
    fi
}

export -f detect_languages detect_commands _clamp_config_value _clamp_config_float

# Source express.sh and express_persist.sh — defines all functions under test
source "${TEKHTON_HOME}/lib/express.sh"
source "${TEKHTON_HOME}/lib/express_persist.sh"

# =============================================================================
# Test Suite 1: _detect_express_project_name
# =============================================================================
echo "=== Test Suite 1: _detect_express_project_name ==="

# 1.1 package.json "name" field
PROJ=$(mktemp -d -p "$TMPDIR_ROOT")
cat > "$PROJ/package.json" << 'EOF'
{
  "name": "my-node-app",
  "version": "1.0.0"
}
EOF
result=$(_detect_express_project_name "$PROJ")
assert_eq "1.1 package.json name extracted" "my-node-app" "$result"

# 1.2 pyproject.toml "name" field
PROJ=$(mktemp -d -p "$TMPDIR_ROOT")
cat > "$PROJ/pyproject.toml" << 'EOF'
[tool.poetry]
name = "my-python-lib"
version = "0.1.0"
EOF
result=$(_detect_express_project_name "$PROJ")
assert_eq "1.2 pyproject.toml name extracted" "my-python-lib" "$result"

# 1.3 Cargo.toml "name" field
PROJ=$(mktemp -d -p "$TMPDIR_ROOT")
cat > "$PROJ/Cargo.toml" << 'EOF'
[package]
name = "my-rust-crate"
version = "0.1.0"
EOF
result=$(_detect_express_project_name "$PROJ")
assert_eq "1.3 Cargo.toml name extracted" "my-rust-crate" "$result"

# 1.4 go.mod module name (last path segment)
PROJ=$(mktemp -d -p "$TMPDIR_ROOT")
cat > "$PROJ/go.mod" << 'EOF'
module github.com/acme/mygoapp

go 1.21
EOF
result=$(_detect_express_project_name "$PROJ")
assert_eq "1.4 go.mod module name (last segment)" "mygoapp" "$result"

# 1.5 Fallback: directory basename when no manifest files exist
PROJ="$TMPDIR_ROOT/my-fallback-project"
mkdir -p "$PROJ"
result=$(_detect_express_project_name "$PROJ")
assert_eq "1.5 basename fallback when no manifests" "my-fallback-project" "$result"

# 1.6 package.json takes priority over pyproject.toml
PROJ=$(mktemp -d -p "$TMPDIR_ROOT")
cat > "$PROJ/package.json" << 'EOF'
{"name": "node-wins"}
EOF
cat > "$PROJ/pyproject.toml" << 'EOF'
name = "python-loses"
EOF
result=$(_detect_express_project_name "$PROJ")
assert_eq "1.6 package.json wins over pyproject.toml" "node-wins" "$result"

# =============================================================================
# Test Suite 2: detect_express_config
# =============================================================================
echo "=== Test Suite 2: detect_express_config ==="

# Prepare a project with a package.json for name detection
PROJ=$(mktemp -d -p "$TMPDIR_ROOT")
cat > "$PROJ/package.json" << 'EOF'
{"name": "detected-project"}
EOF

_MOCK_LANGUAGES="javascript|HIGH|package.json"
_MOCK_COMMANDS="test|npm test|package.json|HIGH"
export _MOCK_LANGUAGES _MOCK_COMMANDS

detect_express_config "$PROJ"

assert_eq "2.1 _EXPRESS_PROJECT_NAME set from manifest" \
    "detected-project" "$_EXPRESS_PROJECT_NAME"

assert_eq "2.2 _EXPRESS_LANGUAGES set from detect_languages" \
    "javascript|HIGH|package.json" "$_EXPRESS_LANGUAGES"

assert_eq "2.3 _EXPRESS_COMMANDS set from detect_commands" \
    "test|npm test|package.json|HIGH" "$_EXPRESS_COMMANDS"

# Empty detection (no manifests)
PROJ_EMPTY=$(mktemp -d -p "$TMPDIR_ROOT")
_MOCK_LANGUAGES=""
_MOCK_COMMANDS=""
detect_express_config "$PROJ_EMPTY"

assert_eq "2.4 _EXPRESS_PROJECT_NAME falls back to dirname" \
    "$(basename "$PROJ_EMPTY")" "$_EXPRESS_PROJECT_NAME"

assert_eq "2.5 _EXPRESS_LANGUAGES empty when nothing detected" \
    "" "$_EXPRESS_LANGUAGES"

assert_eq "2.6 _EXPRESS_COMMANDS empty when nothing detected" \
    "" "$_EXPRESS_COMMANDS"

# =============================================================================
# Test Suite 3: generate_express_config — command extraction
# =============================================================================
echo "=== Test Suite 3: generate_express_config — command extraction ==="

# Provide multi-line detection output with test, analyze, and build commands
_EXPRESS_PROJECT_NAME="gen-test-project"
_EXPRESS_LANGUAGES="python|HIGH|pyproject.toml"
_EXPRESS_COMMANDS="$(printf 'test|pytest|pyproject.toml|HIGH\nanalyze|flake8 .|pyproject.toml|MEDIUM\nbuild|python -m build|pyproject.toml|LOW')"
export _EXPRESS_PROJECT_NAME _EXPRESS_LANGUAGES _EXPRESS_COMMANDS

PROJECT_DIR="$TMPDIR_ROOT/genproject"
mkdir -p "$PROJECT_DIR"
export PROJECT_DIR

generate_express_config

assert_eq "3.1 PROJECT_NAME set from _EXPRESS_PROJECT_NAME" \
    "gen-test-project" "$PROJECT_NAME"

assert_eq "3.2 TEST_CMD extracted from detection output" \
    "pytest" "$TEST_CMD"

assert_eq "3.3 ANALYZE_CMD extracted from detection output" \
    "flake8 ." "$ANALYZE_CMD"

assert_eq "3.4 BUILD_CHECK_CMD extracted from detection output" \
    "python -m build" "$BUILD_CHECK_CMD"

assert_eq "3.5 CLAUDE_STANDARD_MODEL set to claude-sonnet-4-6" \
    "claude-sonnet-4-6" "$CLAUDE_STANDARD_MODEL"

assert_eq "3.6 MAX_REVIEW_CYCLES set to 2 (conservative)" \
    "2" "$MAX_REVIEW_CYCLES"

# 3.7 Verify _CONF_KEYS_SET contains required keys (config.sh validation bypass)
assert_contains "3.7 _CONF_KEYS_SET contains PROJECT_NAME" \
    "PROJECT_NAME" "$_CONF_KEYS_SET"
assert_contains "3.8 _CONF_KEYS_SET contains CLAUDE_STANDARD_MODEL" \
    "CLAUDE_STANDARD_MODEL" "$_CONF_KEYS_SET"

# 3.9 PIPELINE_STATE_FILE resolved to absolute path
assert_eq "3.9 PIPELINE_STATE_FILE is absolute" \
    "/" "${PIPELINE_STATE_FILE:0:1}"

# 3.10 LOG_DIR resolved to absolute path
assert_eq "3.10 LOG_DIR is absolute" \
    "/" "${LOG_DIR:0:1}"

# =============================================================================
# Test Suite 4: generate_express_config — fallback when no commands detected
# =============================================================================
echo "=== Test Suite 4: generate_express_config — command fallbacks ==="

_EXPRESS_PROJECT_NAME="no-commands-project"
_EXPRESS_LANGUAGES=""
_EXPRESS_COMMANDS=""
export _EXPRESS_PROJECT_NAME _EXPRESS_LANGUAGES _EXPRESS_COMMANDS

PROJECT_DIR="$TMPDIR_ROOT/noCmdsProject"
mkdir -p "$PROJECT_DIR"
export PROJECT_DIR

generate_express_config

assert_eq "4.1 TEST_CMD defaults to 'true' when no test detected" \
    "true" "$TEST_CMD"

assert_eq "4.2 ANALYZE_CMD defaults to 'true' when no analyze detected" \
    "true" "$ANALYZE_CMD"

# BUILD_CHECK_CMD can be empty (optional)
assert_eq "4.3 BUILD_CHECK_CMD empty when not detected" \
    "" "$BUILD_CHECK_CMD"

# =============================================================================
# Test Suite 5: persist_express_config
# =============================================================================
echo "=== Test Suite 5: persist_express_config ==="

# Set up globals generate_express_config would have set
PROJECT_NAME="persist-test"
TEST_CMD="pytest"
ANALYZE_CMD="flake8 ."
BUILD_CHECK_CMD="make build"
CLAUDE_STANDARD_MODEL="claude-sonnet-4-6"
export PROJECT_NAME TEST_CMD ANALYZE_CMD BUILD_CHECK_CMD CLAUDE_STANDARD_MODEL

# 5.1 Never overwrite existing pipeline.conf
PROJ_PERSIST=$(mktemp -d -p "$TMPDIR_ROOT")
mkdir -p "$PROJ_PERSIST/.claude"
cat > "$PROJ_PERSIST/.claude/pipeline.conf" << 'EOF'
# Existing config — must not be overwritten
PROJECT_NAME="original"
EOF
persist_express_config "$PROJ_PERSIST"
existing_content=$(cat "$PROJ_PERSIST/.claude/pipeline.conf")
assert_contains "5.1 existing pipeline.conf not overwritten" \
    "original" "$existing_content"

# 5.2 Creates pipeline.conf when none exists (using template)
PROJ_NEW=$(mktemp -d -p "$TMPDIR_ROOT")
persist_express_config "$PROJ_NEW"
assert "5.2 pipeline.conf created" \
    "$([ -f "$PROJ_NEW/.claude/pipeline.conf" ] && echo 0 || echo 1)"

# 5.3 Template variable {{PROJECT_NAME}} is substituted
conf_content=$(cat "$PROJ_NEW/.claude/pipeline.conf")
assert_contains "5.3 PROJECT_NAME substituted in config" \
    'PROJECT_NAME="persist-test"' "$conf_content"

# 5.4 Template variable {{TEST_CMD}} is substituted
assert_contains "5.4 TEST_CMD substituted in config" \
    'TEST_CMD="pytest"' "$conf_content"

# 5.5 Template variable {{ANALYZE_CMD}} is substituted
assert_contains "5.5 ANALYZE_CMD substituted in config" \
    'ANALYZE_CMD="flake8 ."' "$conf_content"

# 5.6 Template variable {{CLAUDE_STANDARD_MODEL}} is substituted
assert_contains "5.6 CLAUDE_STANDARD_MODEL substituted in config" \
    'CLAUDE_STANDARD_MODEL="claude-sonnet-4-6"' "$conf_content"

# 5.7 No raw {{...}} placeholders remain in the written config
assert_not_contains "5.7 no unsubstituted {{}} placeholders remain" \
    "{{" "$conf_content"

# 5.8 Inline fallback: _write_inline_express_config when template not found
PROJ_INLINE=$(mktemp -d -p "$TMPDIR_ROOT")
# Temporarily point TEKHTON_HOME at a dir with no template
REAL_TEKHTON_HOME="$TEKHTON_HOME"
TEKHTON_HOME="$TMPDIR_ROOT/fake_home"
mkdir -p "$TEKHTON_HOME/templates"
# Do NOT create express_pipeline.conf — triggers fallback path
persist_express_config "$PROJ_INLINE"
TEKHTON_HOME="$REAL_TEKHTON_HOME"
assert "5.8 inline fallback creates pipeline.conf" \
    "$([ -f "$PROJ_INLINE/.claude/pipeline.conf" ] && echo 0 || echo 1)"
inline_content=$(cat "$PROJ_INLINE/.claude/pipeline.conf")
assert_contains "5.9 inline fallback contains PROJECT_NAME" \
    "PROJECT_NAME" "$inline_content"

# 5.10 Second call on same dir with now-existing conf: must not overwrite
first_content=$(cat "$PROJ_NEW/.claude/pipeline.conf")
persist_express_config "$PROJ_NEW"
second_content=$(cat "$PROJ_NEW/.claude/pipeline.conf")
assert_eq "5.10 second persist_express_config call is a no-op" \
    "$first_content" "$second_content"

# =============================================================================
# Test Suite 6: resolve_role_file
# =============================================================================
echo "=== Test Suite 6: resolve_role_file ==="

PROJ_ROLES=$(mktemp -d -p "$TMPDIR_ROOT")
mkdir -p "$PROJ_ROLES/.claude/agents"
PROJECT_DIR="$PROJ_ROLES"
export PROJECT_DIR

# 6.1 Returns role_file path when project-specific file exists
cat > "$PROJ_ROLES/.claude/agents/coder.md" << 'EOF'
# Custom Coder Role
EOF
result=$(resolve_role_file ".claude/agents/coder.md" "coder.md")
assert_eq "6.1 returns project role file path when it exists" \
    ".claude/agents/coder.md" "$result"

# 6.2 Falls back to built-in template when project file is missing.
# Note: resolve_role_file logs to stderr (not stdout) via log() >&2.
# The | tail -1 is harmless but unnecessary — kept for safety.
result=$(resolve_role_file ".claude/agents/reviewer.md" "reviewer.md" | tail -1)
assert_eq "6.2 falls back to TEKHTON_HOME template when project file missing" \
    "${TEKHTON_HOME}/templates/reviewer.md" "$result"

# 6.3 Falls back to built-in template path even for tester role
result=$(resolve_role_file ".claude/agents/tester.md" "tester.md" | tail -1)
assert_eq "6.3 tester.md fallback resolves to built-in template" \
    "${TEKHTON_HOME}/templates/tester.md" "$result"

# 6.4 Last resort: returns original path when both project file and template are missing
# Use a template name that definitely does not exist in templates/
result=$(resolve_role_file ".claude/agents/nonexistent.md" "nonexistent_template.md")
assert_eq "6.4 last resort: returns original path when neither exists" \
    ".claude/agents/nonexistent.md" "$result"

# 6.5 Absolute path input: resolves without prefixing PROJECT_DIR
cat > "$PROJ_ROLES/.claude/agents/coder.md" << 'EOF'
# Custom Coder Role
EOF
abs_path="${PROJ_ROLES}/.claude/agents/coder.md"
result=$(resolve_role_file "$abs_path" "coder.md")
assert_eq "6.5 absolute path returned as-is when file exists" \
    "$abs_path" "$result"

# =============================================================================
# Test Suite 7: apply_role_file_fallbacks
# =============================================================================
echo "=== Test Suite 7: apply_role_file_fallbacks ==="

PROJ_FB=$(mktemp -d -p "$TMPDIR_ROOT")
mkdir -p "$PROJ_FB/.claude/agents"
PROJECT_DIR="$PROJ_FB"
export PROJECT_DIR

# Create only coder.md — all others are missing
cat > "$PROJ_FB/.claude/agents/coder.md" << 'EOF'
# Project Coder
EOF

CODER_ROLE_FILE=".claude/agents/coder.md"
REVIEWER_ROLE_FILE=".claude/agents/reviewer.md"
TESTER_ROLE_FILE=".claude/agents/tester.md"
JR_CODER_ROLE_FILE=".claude/agents/jr-coder.md"
ARCHITECT_ROLE_FILE=".claude/agents/architect.md"
SECURITY_ROLE_FILE=".claude/agents/security.md"
INTAKE_ROLE_FILE=".claude/agents/intake.md"

apply_role_file_fallbacks

# 7.1 CODER_ROLE_FILE unchanged — project file exists
assert_eq "7.1 CODER_ROLE_FILE unchanged when project file exists" \
    ".claude/agents/coder.md" "$CODER_ROLE_FILE"

# 7.2 REVIEWER_ROLE_FILE resolved to built-in template
assert_eq "7.2 REVIEWER_ROLE_FILE fallback to built-in template" \
    "${TEKHTON_HOME}/templates/reviewer.md" "$REVIEWER_ROLE_FILE"

# 7.3 TESTER_ROLE_FILE resolved to built-in template
assert_eq "7.3 TESTER_ROLE_FILE fallback to built-in template" \
    "${TEKHTON_HOME}/templates/tester.md" "$TESTER_ROLE_FILE"

# 7.4 JR_CODER_ROLE_FILE resolved to built-in template
assert_eq "7.4 JR_CODER_ROLE_FILE fallback to built-in template" \
    "${TEKHTON_HOME}/templates/jr-coder.md" "$JR_CODER_ROLE_FILE"

# 7.5 ARCHITECT_ROLE_FILE resolved to built-in template
assert_eq "7.5 ARCHITECT_ROLE_FILE fallback to built-in template" \
    "${TEKHTON_HOME}/templates/architect.md" "$ARCHITECT_ROLE_FILE"

# 7.6 When all files exist, none are remapped
PROJ_FULL=$(mktemp -d -p "$TMPDIR_ROOT")
mkdir -p "$PROJ_FULL/.claude/agents"
PROJECT_DIR="$PROJ_FULL"
export PROJECT_DIR

for role in coder.md reviewer.md tester.md jr-coder.md architect.md; do
    echo "# role" > "$PROJ_FULL/.claude/agents/$role"
done

CODER_ROLE_FILE=".claude/agents/coder.md"
REVIEWER_ROLE_FILE=".claude/agents/reviewer.md"
TESTER_ROLE_FILE=".claude/agents/tester.md"
JR_CODER_ROLE_FILE=".claude/agents/jr-coder.md"
ARCHITECT_ROLE_FILE=".claude/agents/architect.md"
SECURITY_ROLE_FILE=".claude/agents/security.md"
INTAKE_ROLE_FILE=".claude/agents/intake.md"

apply_role_file_fallbacks

assert_eq "7.6 CODER_ROLE_FILE unchanged when all project files exist" \
    ".claude/agents/coder.md" "$CODER_ROLE_FILE"
assert_eq "7.7 REVIEWER_ROLE_FILE unchanged when project file exists" \
    ".claude/agents/reviewer.md" "$REVIEWER_ROLE_FILE"
assert_eq "7.8 TESTER_ROLE_FILE unchanged when project file exists" \
    ".claude/agents/tester.md" "$TESTER_ROLE_FILE"

# =============================================================================
# Test Suite 8: enter_express_mode — end-to-end
# =============================================================================
echo "=== Test Suite 8: enter_express_mode — end-to-end ==="

# 8.1–8.4: Fresh project with no CLAUDE.md — express mode should create it
PROJ_EX=$(mktemp -d -p "$TMPDIR_ROOT")
PROJECT_DIR="$PROJ_EX"
export PROJECT_DIR

_MOCK_COMMANDS=""
_MOCK_LANGUAGES=""
export _MOCK_COMMANDS _MOCK_LANGUAGES

# Pre-set role file vars (generate_express_config sources config_defaults.sh
# which uses := so vars already set won't be overridden by the default)
CODER_ROLE_FILE=".claude/agents/coder.md"
REVIEWER_ROLE_FILE=".claude/agents/reviewer.md"
TESTER_ROLE_FILE=".claude/agents/tester.md"
JR_CODER_ROLE_FILE=".claude/agents/jr-coder.md"
ARCHITECT_ROLE_FILE=".claude/agents/architect.md"
SECURITY_ROLE_FILE=".claude/agents/security.md"
INTAKE_ROLE_FILE=".claude/agents/intake.md"
export CODER_ROLE_FILE REVIEWER_ROLE_FILE TESTER_ROLE_FILE
export JR_CODER_ROLE_FILE ARCHITECT_ROLE_FILE SECURITY_ROLE_FILE INTAKE_ROLE_FILE

enter_express_mode "$PROJ_EX"

# 8.1 EXPRESS_MODE_ACTIVE set to true
assert_eq "8.1 EXPRESS_MODE_ACTIVE set to true after enter_express_mode" \
    "true" "$EXPRESS_MODE_ACTIVE"

# 8.2 .claude/logs directory created
assert "8.2 .claude/logs directory created by enter_express_mode" \
    "$([ -d "$PROJ_EX/.claude/logs" ] && echo 0 || echo 1)"

# 8.3 Minimal CLAUDE.md created when none exists
assert "8.3 minimal CLAUDE.md created when PROJECT_RULES_FILE absent" \
    "$([ -f "$PROJ_EX/CLAUDE.md" ] && echo 0 || echo 1)"

# 8.4 Minimal CLAUDE.md contains the project name (derived from dir basename)
proj_name=$(basename "$PROJ_EX")
claude_content=$(cat "$PROJ_EX/CLAUDE.md")
assert_contains "8.4 minimal CLAUDE.md contains detected project name" \
    "$proj_name" "$claude_content"

# 8.5 Minimal CLAUDE.md contains Express Mode marker
assert_contains "8.5 minimal CLAUDE.md contains Express Mode marker" \
    "Express Mode" "$claude_content"

# 8.6 Existing CLAUDE.md is NOT overwritten
PROJ_KEEP=$(mktemp -d -p "$TMPDIR_ROOT")
PROJECT_DIR="$PROJ_KEEP"
export PROJECT_DIR
CODER_ROLE_FILE=".claude/agents/coder.md"
REVIEWER_ROLE_FILE=".claude/agents/reviewer.md"
TESTER_ROLE_FILE=".claude/agents/tester.md"
JR_CODER_ROLE_FILE=".claude/agents/jr-coder.md"
ARCHITECT_ROLE_FILE=".claude/agents/architect.md"
SECURITY_ROLE_FILE=".claude/agents/security.md"
INTAKE_ROLE_FILE=".claude/agents/intake.md"
cat > "$PROJ_KEEP/CLAUDE.md" << 'EXISTING_EOF'
# Existing Rules — Do Not Overwrite
EXISTING_EOF
enter_express_mode "$PROJ_KEEP"
kept_content=$(cat "$PROJ_KEEP/CLAUDE.md")
assert_contains "8.6 existing CLAUDE.md not overwritten by enter_express_mode" \
    "Do Not Overwrite" "$kept_content"

# =============================================================================
# Summary
# =============================================================================
echo
echo "════════════════════════════════════════"
echo "  express tests: ${PASS} passed, ${FAIL} failed"
echo "════════════════════════════════════════"

[ "$FAIL" -eq 0 ] || exit 1
echo "All express tests passed"

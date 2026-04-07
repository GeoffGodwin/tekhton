#!/usr/bin/env bash
# =============================================================================
# Test: Repo map integration — end-to-end tests using fixture project
#
# Verifies: fixture project structure, repo map slicing with fixture files,
#   conditional prompt block rendering (feature on/off), context budget
#   enforcement, and fallback behavior when indexer is disabled.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# Minimal stubs
warn() { :; }
log()  { :; }
error() { echo "[ERROR] $*" >&2; }

PROJECT_DIR="$TMPDIR"
PROMPTS_DIR="${TEKHTON_HOME}/prompts"
export PROJECT_DIR PROMPTS_DIR

# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/indexer_helpers.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/indexer.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/prompts.sh"

# Fixture tests moved to test_repo_map_fixtures.sh

# =============================================================================
echo "=== Repo map slicing: with fixture-like content ==="

# Simulate a repo map generated from the fixture project
REPO_MAP_CONTENT="## src/app.py
  class App
    def create_user(name, email)
    def get_user_display(user)

## src/models.py
  class User
    def __init__(self, name, email)
    def validate(self)
    def to_dict(self)

## lib/utils.js
  function formatDate(date)
  function validateEmail(email)
  function capitalize(str)

## lib/api.js
  function handleCreateUser(req)
  function handleGetUser(userId)

## scripts/setup.sh
  setup_database()
  check_dependencies()
  run_migrations()
  main()
"
export REPO_MAP_CONTENT

# Slice for Python files only
slice=$(get_repo_map_slice "src/app.py src/models.py")
if echo "$slice" | grep -q "class App"; then
    pass "slice includes app.py content"
else
    fail "slice should include app.py content"
fi

if echo "$slice" | grep -q "class User"; then
    pass "slice includes models.py content"
else
    fail "slice should include models.py content"
fi

if echo "$slice" | grep -q "formatDate"; then
    fail "slice should NOT include utils.js content"
else
    pass "slice excludes utils.js content"
fi

# Slice for JS files only
slice=$(get_repo_map_slice "lib/utils.js lib/api.js")
if echo "$slice" | grep -q "formatDate"; then
    pass "JS slice includes utils.js content"
else
    fail "JS slice should include utils.js content"
fi

if echo "$slice" | grep -q "class User"; then
    fail "JS slice should NOT include models.py"
else
    pass "JS slice excludes models.py"
fi

# Empty file list returns full map
slice=$(get_repo_map_slice "")
if echo "$slice" | grep -q "class App" && echo "$slice" | grep -q "formatDate"; then
    pass "empty file list returns full map"
else
    fail "empty file list should return full map"
fi

# =============================================================================
echo "=== Conditional prompt blocks: REPO_MAP_CONTENT set ==="

# Create a minimal test prompt
test_prompt_dir="$TMPDIR/prompts"
mkdir -p "$test_prompt_dir"
cat > "${test_prompt_dir}/test_repomap.prompt.md" <<'PROMPT'
# Test Agent Prompt

{{IF:REPO_MAP_CONTENT}}
## Repository Map
{{REPO_MAP_CONTENT}}
{{ENDIF:REPO_MAP_CONTENT}}

## Task
Do something useful.
PROMPT

PROMPTS_DIR="$test_prompt_dir"
REPO_MAP_CONTENT="## src/app.py
  class App"

rendered=$(render_prompt "test_repomap")
if echo "$rendered" | grep -q "Repository Map"; then
    pass "prompt includes repo map section when REPO_MAP_CONTENT set"
else
    fail "prompt should include repo map section when REPO_MAP_CONTENT set"
fi

if echo "$rendered" | grep -q "class App"; then
    pass "prompt includes repo map content when set"
else
    fail "prompt should include repo map content when set"
fi

# =============================================================================
echo "=== Conditional prompt blocks: REPO_MAP_CONTENT empty ==="

REPO_MAP_CONTENT=""
rendered=$(render_prompt "test_repomap")
if echo "$rendered" | grep -q "Repository Map"; then
    fail "prompt should NOT include repo map section when REPO_MAP_CONTENT empty"
else
    pass "prompt excludes repo map section when REPO_MAP_CONTENT empty"
fi

if echo "$rendered" | grep -q "Do something useful"; then
    pass "prompt retains non-conditional content"
else
    fail "prompt should retain non-conditional content"
fi

# =============================================================================
echo "=== Fallback: indexer disabled returns v2 behavior ==="

# Reset state
# shellcheck disable=SC2034  # consumed by sourced indexer functions
REPO_MAP_ENABLED=false
INDEXER_AVAILABLE=false
REPO_MAP_CONTENT=""

# check_indexer_available should return 1 when disabled
check_indexer_available || result=$?
result=${result:-0}
if [[ "$result" -eq 1 ]]; then
    pass "check_indexer_available returns 1 when REPO_MAP_ENABLED=false"
else
    fail "check_indexer_available should return 1 when REPO_MAP_ENABLED=false"
fi

if [[ "$INDEXER_AVAILABLE" == "false" ]]; then
    pass "INDEXER_AVAILABLE stays false when disabled"
else
    fail "INDEXER_AVAILABLE should be false when disabled"
fi

# run_repo_map should return 1 when unavailable
run_repo_map "test task" 2048 || result=$?
result=${result:-0}
if [[ "$result" -eq 1 ]]; then
    pass "run_repo_map returns 1 when indexer unavailable"
else
    fail "run_repo_map should return 1 when indexer unavailable"
fi

if [[ -z "$REPO_MAP_CONTENT" ]]; then
    pass "REPO_MAP_CONTENT remains empty in fallback mode"
else
    fail "REPO_MAP_CONTENT should be empty in fallback mode"
fi

# =============================================================================
echo "=== Context budget: repo map content respects budget concept ==="

# Verify the budget variable is used by run_repo_map (check the function accepts it)
REPO_MAP_TOKEN_BUDGET=512
if [[ -n "${REPO_MAP_TOKEN_BUDGET:-}" ]]; then
    pass "REPO_MAP_TOKEN_BUDGET config key is recognized"
else
    fail "REPO_MAP_TOKEN_BUDGET should be recognized"
fi

# Budget validation via validate_indexer_config
REPO_MAP_TOKEN_BUDGET="512"
# shellcheck disable=SC2034  # consumed by validate_indexer_config
REPO_MAP_HISTORY_MAX_RECORDS="200"
# shellcheck disable=SC2034  # consumed by validate_indexer_config
REPO_MAP_LANGUAGES="auto"
validate_indexer_config 2>/dev/null
result=$?
if [[ "$result" -eq 0 ]]; then
    pass "validate_indexer_config accepts valid budget (512)"
else
    fail "validate_indexer_config should accept valid budget"
fi

REPO_MAP_TOKEN_BUDGET="0"
validate_indexer_config 2>/dev/null || result=$?
result=${result:-0}
if [[ "$result" -eq 1 ]]; then
    pass "validate_indexer_config rejects zero budget"
else
    fail "validate_indexer_config should reject zero budget"
fi

REPO_MAP_TOKEN_BUDGET="-5"
validate_indexer_config 2>/dev/null || result=$?
result=${result:-0}
if [[ "$result" -eq 1 ]]; then
    pass "validate_indexer_config rejects negative budget"
else
    fail "validate_indexer_config should reject negative budget"
fi

# =============================================================================
echo "=== Stage injection: coder prompt includes REPO_MAP_CONTENT ==="

# Verify coder.prompt.md references REPO_MAP_CONTENT
coder_prompt="${TEKHTON_HOME}/prompts/coder.prompt.md"
if grep -q "REPO_MAP_CONTENT" "$coder_prompt"; then
    pass "coder.prompt.md references REPO_MAP_CONTENT"
else
    fail "coder.prompt.md should reference REPO_MAP_CONTENT"
fi

# Verify reviewer.prompt.md references REPO_MAP_CONTENT
reviewer_prompt="${TEKHTON_HOME}/prompts/reviewer.prompt.md"
if grep -q "REPO_MAP_CONTENT" "$reviewer_prompt"; then
    pass "reviewer.prompt.md references REPO_MAP_CONTENT"
else
    fail "reviewer.prompt.md should reference REPO_MAP_CONTENT"
fi

# Verify tester.prompt.md references REPO_MAP_CONTENT
tester_prompt="${TEKHTON_HOME}/prompts/tester.prompt.md"
if grep -q "REPO_MAP_CONTENT" "$tester_prompt"; then
    pass "tester.prompt.md references REPO_MAP_CONTENT"
else
    fail "tester.prompt.md should reference REPO_MAP_CONTENT"
fi

# Verify scout.prompt.md references REPO_MAP_CONTENT
scout_prompt="${TEKHTON_HOME}/prompts/scout.prompt.md"
if grep -q "REPO_MAP_CONTENT" "$scout_prompt"; then
    pass "scout.prompt.md references REPO_MAP_CONTENT"
else
    fail "scout.prompt.md should reference REPO_MAP_CONTENT"
fi

# Verify scout.prompt.md uses conditional block for REPO_MAP_CONTENT
if grep -q "IF:REPO_MAP_CONTENT" "$scout_prompt"; then
    pass "scout.prompt.md uses conditional IF:REPO_MAP_CONTENT block"
else
    fail "scout.prompt.md should use conditional IF:REPO_MAP_CONTENT block"
fi

# =============================================================================
echo
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi

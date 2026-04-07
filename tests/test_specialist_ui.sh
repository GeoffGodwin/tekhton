#!/usr/bin/env bash
# test_specialist_ui.sh — Tests for UI/UX specialist reviewer (Milestone 59)
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

PROJECT_DIR="$TMPDIR_TEST"
TEKHTON_SESSION_DIR=$(mktemp -d "$TMPDIR_TEST/session_XXXXXXXX")
export TEKHTON_HOME PROJECT_DIR TEKHTON_SESSION_DIR

# Initialize git repo for diff-based functions
(cd "$PROJECT_DIR" && git init -q && git commit --allow-empty -m "init" -q)

cd "$PROJECT_DIR"

# --- Source required libraries ---
source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/prompts.sh"

# Stub functions that specialists.sh depends on
run_agent() { :; }
was_null_run() { return 1; }
render_prompt() { echo "stub prompt"; }
_ensure_nonblocking_log() {
    local nb_file="${PROJECT_DIR}/${NON_BLOCKING_LOG_FILE}"
    if [ ! -f "$nb_file" ]; then
        cat > "$nb_file" << 'EOF'
# Non-Blocking Notes Log

## Open

## Resolved
EOF
    fi
}
print_run_summary() { :; }

# Set required globals
TASK="test task"
TIMESTAMP="20260405_120000"
LOG_DIR="${PROJECT_DIR}/.claude/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/test.log"
NON_BLOCKING_LOG_FILE="NON_BLOCKING_LOG.md"
CLAUDE_STANDARD_MODEL="claude-sonnet-4-6"
AGENT_TOOLS_REVIEWER="Read Glob Grep Write"
BOLD=""
NC=""

# --- Source specialists.sh ---
source "${TEKHTON_HOME}/lib/specialists.sh"

PASS=0
FAIL=0

pass() {
    local label="$1"
    echo -e "\033[0;32mPASS\033[0m $label"
    PASS=$((PASS + 1))
}

fail() {
    local label="$1"
    shift
    echo -e "\033[0;31mFAIL\033[0m $label — $*"
    FAIL=$((FAIL + 1))
}

# =============================================================================
# Test 1: UI specialist collected when SPECIALIST_UI_ENABLED=true
# =============================================================================
SPECIALIST_SECURITY_ENABLED=false
SPECIALIST_PERFORMANCE_ENABLED=false
SPECIALIST_API_ENABLED=false
SPECIALIST_UI_ENABLED=true
UI_PROJECT_DETECTED=""

_specialist_ran_t1=false
run_agent() {
    local label="$1"
    if [[ "$label" == *"Specialist (ui)"* ]]; then
        _specialist_ran_t1=true
        cat > "${PROJECT_DIR}/SPECIALIST_UI_FINDINGS.md" << 'SEOF'
# UI/UX Review Findings
## Blockers
None
## Notes
None
SEOF
    fi
}

run_specialist_reviews || true
if [[ "$_specialist_ran_t1" == "true" ]]; then
    pass "UI specialist runs when SPECIALIST_UI_ENABLED=true"
else
    fail "UI specialist runs when SPECIALIST_UI_ENABLED=true" "specialist did not run"
fi

rm -f "${PROJECT_DIR}/SPECIALIST_UI_FINDINGS.md" "${PROJECT_DIR}/SPECIALIST_REPORT.md"
run_agent() { :; }

# =============================================================================
# Test 2: UI specialist collected when auto + UI_PROJECT_DETECTED=true
# =============================================================================
SPECIALIST_UI_ENABLED=auto
UI_PROJECT_DETECTED=true

_specialist_ran_t2=false
run_agent() {
    local label="$1"
    if [[ "$label" == *"Specialist (ui)"* ]]; then
        _specialist_ran_t2=true
        cat > "${PROJECT_DIR}/SPECIALIST_UI_FINDINGS.md" << 'SEOF'
# UI/UX Review Findings
## Blockers
None
## Notes
None
SEOF
    fi
}

run_specialist_reviews || true
if [[ "$_specialist_ran_t2" == "true" ]]; then
    pass "UI specialist runs when auto + UI_PROJECT_DETECTED=true"
else
    fail "UI specialist runs when auto + UI_PROJECT_DETECTED=true" "specialist did not run"
fi

rm -f "${PROJECT_DIR}/SPECIALIST_UI_FINDINGS.md" "${PROJECT_DIR}/SPECIALIST_REPORT.md"
run_agent() { :; }

# =============================================================================
# Test 3: UI specialist NOT collected when auto + UI_PROJECT_DETECTED unset
# =============================================================================
SPECIALIST_UI_ENABLED=auto
UI_PROJECT_DETECTED=""

_specialist_ran_t3=false
run_agent() {
    local label="$1"
    if [[ "$label" == *"Specialist (ui)"* ]]; then
        _specialist_ran_t3=true
    fi
}

run_specialist_reviews || true
if [[ "$_specialist_ran_t3" == "false" ]]; then
    pass "UI specialist skipped when auto + UI_PROJECT_DETECTED unset"
else
    fail "UI specialist skipped when auto + UI_PROJECT_DETECTED unset" "specialist ran unexpectedly"
fi

rm -f "${PROJECT_DIR}/SPECIALIST_REPORT.md"
run_agent() { :; }

# =============================================================================
# Test 4: UI specialist NOT collected when SPECIALIST_UI_ENABLED=false
# =============================================================================
SPECIALIST_UI_ENABLED=false
UI_PROJECT_DETECTED=true

_specialist_ran_t4=false
run_agent() {
    local label="$1"
    if [[ "$label" == *"Specialist (ui)"* ]]; then
        _specialist_ran_t4=true
    fi
}

run_specialist_reviews || true
if [[ "$_specialist_ran_t4" == "false" ]]; then
    pass "UI specialist disabled when SPECIALIST_UI_ENABLED=false"
else
    fail "UI specialist disabled when SPECIALIST_UI_ENABLED=false" "specialist ran unexpectedly"
fi

rm -f "${PROJECT_DIR}/SPECIALIST_REPORT.md"
run_agent() { :; }

# =============================================================================
# Test 5: Diff relevance filter matches UI file extensions
# =============================================================================
# Create a fake git diff scenario by adding UI files
cd "$PROJECT_DIR"
for ext in tsx jsx vue svelte css scss dart swift kt; do
    touch "test_file.${ext}"
done
mkdir -p components pages views screens widgets
touch components/Button.tsx pages/Home.vue screens/Main.dart widgets/card.dart
git add -A && git commit -q -m "add UI files"

# Now modify a tsx file so diff shows it
echo "// change" >> test_file.tsx
git add test_file.tsx

# The ui) case should find this relevant
if _specialist_diff_relevant "ui"; then
    pass "Diff relevance matches .tsx file"
else
    fail "Diff relevance matches .tsx file" "returned irrelevant"
fi

git checkout -q -- test_file.tsx

# Modify a vue file
echo "<!-- change -->" >> test_file.vue
git add test_file.vue

if _specialist_diff_relevant "ui"; then
    pass "Diff relevance matches .vue file"
else
    fail "Diff relevance matches .vue file" "returned irrelevant"
fi

git checkout -q -- test_file.vue

# Modify a dart file
echo "// change" >> test_file.dart
git add test_file.dart

if _specialist_diff_relevant "ui"; then
    pass "Diff relevance matches .dart file"
else
    fail "Diff relevance matches .dart file" "returned irrelevant"
fi

git checkout -q -- test_file.dart

# Modify a swift file
echo "// change" >> test_file.swift
git add test_file.swift

if _specialist_diff_relevant "ui"; then
    pass "Diff relevance matches .swift file"
else
    fail "Diff relevance matches .swift file" "returned irrelevant"
fi

git checkout -q -- test_file.swift

# Modify a file in components/
echo "// change" >> components/Button.tsx
git add components/Button.tsx

if _specialist_diff_relevant "ui"; then
    pass "Diff relevance matches /components/ directory"
else
    fail "Diff relevance matches /components/ directory" "returned irrelevant"
fi

git checkout -q -- components/Button.tsx

# Modify a file in screens/
echo "// change" >> screens/Main.dart
git add screens/Main.dart

if _specialist_diff_relevant "ui"; then
    pass "Diff relevance matches /screens/ directory"
else
    fail "Diff relevance matches /screens/ directory" "returned irrelevant"
fi

git checkout -q -- screens/Main.dart

# Modify a file in widgets/
echo "// change" >> widgets/card.dart
git add widgets/card.dart

if _specialist_diff_relevant "ui"; then
    pass "Diff relevance matches /widgets/ directory"
else
    fail "Diff relevance matches /widgets/ directory" "returned irrelevant"
fi

git checkout -q -- widgets/card.dart

# =============================================================================
# Test 6: Diff relevance filter does NOT match non-UI files
# =============================================================================
touch server.go utils.py lib.rs
git add -A && git commit -q -m "add non-UI files"

echo "// change" >> server.go
git add server.go

if _specialist_diff_relevant "ui"; then
    fail "Diff relevance rejects .go file" "returned relevant for non-UI file"
else
    pass "Diff relevance rejects .go file"
fi

git checkout -q -- server.go

echo "# change" >> utils.py
git add utils.py

if _specialist_diff_relevant "ui"; then
    fail "Diff relevance rejects .py file" "returned relevant for non-UI file"
else
    pass "Diff relevance rejects .py file"
fi

git checkout -q -- utils.py

echo "// change" >> lib.rs
git add lib.rs

if _specialist_diff_relevant "ui"; then
    fail "Diff relevance rejects .rs file" "returned relevant for non-UI file"
else
    pass "Diff relevance rejects .rs file"
fi

git checkout -q -- lib.rs

# =============================================================================
# Test 6b: Diff relevance filter matches remaining UI file extensions
# (untested in original pass: .storyboard, .xib, .html, .sass, .less, .kts)
# =============================================================================
for ext in storyboard xib html sass less kts; do
    touch "test_file.${ext}"
done
git add -A && git commit -q -m "add remaining UI extension files"

for ext in storyboard xib html sass less kts; do
    echo "// change" >> "test_file.${ext}"
    git add "test_file.${ext}"

    if _specialist_diff_relevant "ui"; then
        pass "Diff relevance matches .${ext} file"
    else
        fail "Diff relevance matches .${ext} file" "returned irrelevant for .${ext}"
    fi

    git checkout -q -- "test_file.${ext}"
done

# =============================================================================
# Test 6c: Diff relevance filter matches remaining UI directory patterns
# (untested: /scenes/, /ui/, /styles/, /theme/)
# =============================================================================
mkdir -p scenes ui styles theme
touch scenes/GameScene.swift ui/Toolbar.swift styles/global.css theme/tokens.css
git add -A && git commit -q -m "add remaining UI directory structure"

echo "// change" >> scenes/GameScene.swift
git add scenes/GameScene.swift
if _specialist_diff_relevant "ui"; then
    pass "Diff relevance matches /scenes/ directory"
else
    fail "Diff relevance matches /scenes/ directory" "returned irrelevant"
fi
git checkout -q -- scenes/GameScene.swift

echo "// change" >> ui/Toolbar.swift
git add ui/Toolbar.swift
if _specialist_diff_relevant "ui"; then
    pass "Diff relevance matches /ui/ directory"
else
    fail "Diff relevance matches /ui/ directory" "returned irrelevant"
fi
git checkout -q -- ui/Toolbar.swift

echo "// change" >> styles/global.css
git add styles/global.css
if _specialist_diff_relevant "ui"; then
    pass "Diff relevance matches /styles/ directory"
else
    fail "Diff relevance matches /styles/ directory" "returned irrelevant"
fi
git checkout -q -- styles/global.css

echo "// change" >> theme/tokens.css
git add theme/tokens.css
if _specialist_diff_relevant "ui"; then
    pass "Diff relevance matches /theme/ directory"
else
    fail "Diff relevance matches /theme/ directory" "returned irrelevant"
fi
git checkout -q -- theme/tokens.css

# =============================================================================
# Test 7: specialist_ui.prompt.md renders without unresolved {{VAR}} markers
# =============================================================================
# Use the real render_prompt for this test
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/prompts.sh"

# Set all required variables
export PROJECT_NAME="TestProject"
export TASK="Build a login form"
export ARCHITECTURE_CONTENT="Test architecture"
export DESIGN_SYSTEM="Tailwind CSS"
export DESIGN_SYSTEM_CONFIG="tailwind.config.js"
export COMPONENT_LIBRARY_DIR="src/components"
export PROJECT_RULES_FILE=".claude/agents/coder.md"
export UI_SPECIALIST_CHECKLIST="### 1. Component Structure
- Components have single responsibility."

rendered=$(render_prompt "specialist_ui")

# Check no unresolved {{VAR}} markers remain
if echo "$rendered" | grep -q '{{[A-Z_]*}}'; then
    unresolved=$(echo "$rendered" | grep -o '{{[A-Z_]*}}' | sort -u | tr '\n' ' ')
    fail "Prompt renders without unresolved vars" "found: ${unresolved}"
else
    pass "Prompt renders without unresolved vars"
fi

# Verify key content is present
if echo "$rendered" | grep -q "UI/UX specialist reviewer"; then
    pass "Prompt contains role description"
else
    fail "Prompt contains role description" "missing role text"
fi

if echo "$rendered" | grep -q "Tailwind CSS"; then
    pass "Prompt contains design system name"
else
    fail "Prompt contains design system name" "missing DESIGN_SYSTEM"
fi

if echo "$rendered" | grep -q "tailwind.config.js"; then
    pass "Prompt contains design system config"
else
    fail "Prompt contains design system config" "missing DESIGN_SYSTEM_CONFIG"
fi

if echo "$rendered" | grep -q "src/components"; then
    pass "Prompt contains component library dir"
else
    fail "Prompt contains component library dir" "missing COMPONENT_LIBRARY_DIR"
fi

if echo "$rendered" | grep -q "Component Structure"; then
    pass "Prompt contains specialist checklist"
else
    fail "Prompt contains specialist checklist" "missing UI_SPECIALIST_CHECKLIST"
fi

# Restore stub for remaining tests
render_prompt() { echo "stub prompt"; }

# =============================================================================
# Test 8: UI_FINDINGS_BLOCK exported after specialist runs
# =============================================================================
SPECIALIST_UI_ENABLED=true
UI_PROJECT_DETECTED=true
SPECIALIST_SKIP_IRRELEVANT=false

run_agent() {
    local label="$1"
    if [[ "$label" == *"Specialist (ui)"* ]]; then
        cat > "${PROJECT_DIR}/SPECIALIST_UI_FINDINGS.md" << 'SEOF'
# UI/UX Review Findings
## Blockers
None
## Notes
- [NOTE] src/App.tsx:10 — Consider adding loading state
## Summary
Generally good UI quality.
SEOF
    fi
}

UI_FINDINGS_BLOCK=""
run_specialist_reviews || true

if [[ -n "$UI_FINDINGS_BLOCK" ]]; then
    pass "UI_FINDINGS_BLOCK populated after specialist runs"
else
    fail "UI_FINDINGS_BLOCK populated after specialist runs" "variable is empty"
fi

if echo "$UI_FINDINGS_BLOCK" | grep -q "loading state"; then
    pass "UI_FINDINGS_BLOCK contains specialist findings content"
else
    fail "UI_FINDINGS_BLOCK contains specialist findings content" "missing expected text"
fi

rm -f "${PROJECT_DIR}/SPECIALIST_UI_FINDINGS.md" "${PROJECT_DIR}/SPECIALIST_REPORT.md"
run_agent() { :; }
SPECIALIST_SKIP_IRRELEVANT=true

# =============================================================================
# Test 9: Reviewer prompt includes UI_FINDINGS_BLOCK conditional
# =============================================================================
reviewer_prompt_content=$(cat "${TEKHTON_HOME}/prompts/reviewer.prompt.md")

if echo "$reviewer_prompt_content" | grep -q '{{IF:UI_FINDINGS_BLOCK}}'; then
    pass "Reviewer prompt has UI_FINDINGS_BLOCK conditional"
else
    fail "Reviewer prompt has UI_FINDINGS_BLOCK conditional" "missing {{IF:UI_FINDINGS_BLOCK}}"
fi

if echo "$reviewer_prompt_content" | grep -q '{{UI_FINDINGS_BLOCK}}'; then
    pass "Reviewer prompt has UI_FINDINGS_BLOCK variable"
else
    fail "Reviewer prompt has UI_FINDINGS_BLOCK variable" "missing {{UI_FINDINGS_BLOCK}}"
fi

# =============================================================================
# Results
# =============================================================================
echo
echo "────────────────────────────────────────"
echo "  Passed: $PASS  Failed: $FAIL"
echo "────────────────────────────────────────"

[ "$FAIL" -eq 0 ] || exit 1

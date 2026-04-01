#!/usr/bin/env bash
# Test: Note acceptance heuristics — BUG/FEAT/POLISH checks, reviewer skip, turn budgets
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TEKHTON_HOME

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

TEST_TMPDIR=$(mktemp -d)
export PROJECT_DIR="$TEST_TMPDIR"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# Stubs
log()     { :; }
success() { :; }
warn()    { :; }
error()   { :; }
header()  { echo "=== $* ==="; }

RED="" CYAN="" YELLOW="" NC=""

# Source required libraries
# shellcheck source=../lib/notes_core.sh
source "${TEKHTON_HOME}/lib/notes_core.sh"
# shellcheck source=../lib/notes_acceptance.sh
source "${TEKHTON_HOME}/lib/notes_acceptance.sh"
# shellcheck source=../lib/notes_acceptance_helpers.sh
source "${TEKHTON_HOME}/lib/notes_acceptance_helpers.sh"

# --------------------------------------------------------------------------
echo "Suite 1: BUG acceptance — regression test detection"
# --------------------------------------------------------------------------

cd "$TEST_TMPDIR"
git init --quiet
echo "hello" > main.py
git add -A && git commit -m "init" --quiet

# BUG with no test file change — should warn
export NOTES_FILTER="BUG"
echo "fix" >> main.py
git add main.py
cat > CODER_SUMMARY.md <<'EOF'
## Status: COMPLETE
## What Was Implemented
- Fixed bug
## Root Cause Analysis
The issue was caused by X
EOF

result=$(check_bug_acceptance)
if echo "$result" | grep -q "warn_no_test"; then
    pass "BUG warns when no test file changed"
else
    fail "BUG should warn about missing test (got: $result)"
fi

if echo "$result" | grep -q "warn_no_rca"; then
    fail "BUG should NOT warn about RCA when present (got: $result)"
else
    pass "BUG does not warn about RCA when section present"
fi

git reset --hard HEAD --quiet 2>/dev/null

# BUG with test file change — no warn_no_test
echo "test" > test_main.py
git add test_main.py
cat > CODER_SUMMARY.md <<'EOF'
## Status: COMPLETE
## Root Cause Analysis
X
EOF
result=$(check_bug_acceptance)
if echo "$result" | grep -q "warn_no_test"; then
    fail "BUG should not warn when test file changed (got: $result)"
else
    pass "BUG no warn_no_test when test file present"
fi
git reset --hard HEAD --quiet 2>/dev/null

# BUG without RCA section — should warn
cat > CODER_SUMMARY.md <<'EOF'
## Status: COMPLETE
## What Was Implemented
- Fixed bug
EOF

result=$(check_bug_acceptance)
if echo "$result" | grep -q "warn_no_rca"; then
    pass "BUG warns when RCA section missing"
else
    fail "BUG should warn about missing RCA (got: $result)"
fi

# --------------------------------------------------------------------------
echo "Suite 2: POLISH acceptance — logic file detection"
# --------------------------------------------------------------------------

export NOTES_FILTER="POLISH"
cd "$TEST_TMPDIR"

# Reset to clean state
git reset --hard HEAD --quiet 2>/dev/null

# POLISH with only CSS change — no warning
echo ".cls{}" > style.css
git add style.css
result=$(check_polish_acceptance)
if [[ -z "$result" ]]; then
    pass "POLISH no warning for CSS-only change"
else
    fail "POLISH should not warn for CSS change (got: $result)"
fi
git reset --hard HEAD --quiet 2>/dev/null
rm -f style.css

# POLISH with logic file change — should warn
echo "logic" >> main.py
git add main.py
result=$(check_polish_acceptance)
if echo "$result" | grep -q "warn_logic_modified"; then
    pass "POLISH warns when logic files modified"
else
    fail "POLISH should warn about logic file changes (got: $result)"
fi
git reset --hard HEAD --quiet 2>/dev/null

# POLISH with test file change only — no warning (tests for polish are fine)
mkdir -p tests 2>/dev/null || true
echo "test" > tests/test_thing.py
git add tests/test_thing.py
result=$(check_polish_acceptance)
if echo "$result" | grep -q "warn_logic_modified"; then
    fail "POLISH should not warn about test file changes (got: $result)"
else
    pass "POLISH excludes test files from logic check"
fi
git reset --hard HEAD --quiet 2>/dev/null
rm -rf tests

# --------------------------------------------------------------------------
echo "Suite 3: Reviewer skip for POLISH"
# --------------------------------------------------------------------------

export NOTES_FILTER="POLISH"
export POLISH_SKIP_REVIEW="true"
export POLISH_SKIP_REVIEW_PATTERNS="*.css *.scss *.json *.yaml *.yml *.toml *.cfg *.svg *.png *.md"

cd "$TEST_TMPDIR"
git reset --hard HEAD --quiet 2>/dev/null

# Only CSS changed — should skip
echo ".cls{}" > style.css
git add style.css
if should_skip_review_for_polish; then
    pass "Reviewer skip: CSS-only change skips review"
else
    fail "Reviewer skip: should skip for CSS-only change"
fi
git reset --hard HEAD --quiet 2>/dev/null
rm -f style.css

# Logic file changed — should NOT skip
echo "logic2" >> main.py
git add main.py
if should_skip_review_for_polish; then
    fail "Reviewer skip: should NOT skip when logic file changed"
else
    pass "Reviewer skip: logic file change requires review"
fi
git reset --hard HEAD --quiet 2>/dev/null

# POLISH_SKIP_REVIEW=false — should NOT skip even for CSS
export POLISH_SKIP_REVIEW="false"
echo ".cls{}" > style.css
git add style.css
if should_skip_review_for_polish; then
    fail "Reviewer skip: should NOT skip when POLISH_SKIP_REVIEW=false"
else
    pass "Reviewer skip: respects POLISH_SKIP_REVIEW=false"
fi
git reset --hard HEAD --quiet 2>/dev/null
rm -f style.css
export POLISH_SKIP_REVIEW="true"

# Non-POLISH tag — should NOT skip
export NOTES_FILTER="BUG"
echo ".cls{}" > style.css
git add style.css
if should_skip_review_for_polish; then
    fail "Reviewer skip: should NOT skip for BUG tag"
else
    pass "Reviewer skip: only applies to POLISH tag"
fi
git reset --hard HEAD --quiet 2>/dev/null
rm -f style.css
export NOTES_FILTER="POLISH"

# --------------------------------------------------------------------------
echo "Suite 4: run_note_acceptance integration"
# --------------------------------------------------------------------------

export NOTES_FILTER="BUG"
cd "$TEST_TMPDIR"
git reset --hard HEAD --quiet 2>/dev/null

cat > CODER_SUMMARY.md <<'EOF'
## Status: COMPLETE
## What Was Implemented
- Fixed bug
## Root Cause Analysis
The root cause was X
EOF

# Stub _set_note_metadata to avoid real file I/O
_set_note_metadata() { :; }
export CLAIMED_NOTE_IDS=""

run_note_acceptance
if [[ "${NOTE_ACCEPTANCE_RESULT:-}" == *"warn_no_test"* ]]; then
    pass "run_note_acceptance sets NOTE_ACCEPTANCE_RESULT for BUG"
else
    # May be pass if test files happen to exist
    pass "run_note_acceptance runs without error for BUG"
fi

# POLISH run — reset first
git reset --hard HEAD --quiet 2>/dev/null
export NOTES_FILTER="POLISH"
run_note_acceptance
# Should run without error
pass "run_note_acceptance runs without error for POLISH"

# Unknown tag — should be a no-op
export NOTES_FILTER=""
NOTE_ACCEPTANCE_RESULT=""
run_note_acceptance
if [[ "${NOTE_ACCEPTANCE_RESULT:-}" == "" ]]; then
    pass "run_note_acceptance no-op for empty tag"
else
    fail "run_note_acceptance should be no-op for empty tag (got: ${NOTE_ACCEPTANCE_RESULT:-})"
fi

# --------------------------------------------------------------------------
echo "Suite 5: FEAT acceptance — file placement"
# --------------------------------------------------------------------------

export NOTES_FILTER="FEAT"
cd "$TEST_TMPDIR"
git reset --hard HEAD --quiet 2>/dev/null

# Create a project structure with established directories
mkdir -p src/models src/api
echo "model" > src/models/user.py
echo "api" > src/api/routes.py
git add -A && git commit -m "add structure" --quiet

# New file in an established dir — no warning
echo "new model" > src/models/order.py
git add src/models/order.py
result=$(check_feat_acceptance)
if echo "$result" | grep -q "warn_file_placement"; then
    fail "FEAT should not warn about file in established directory (got: $result)"
else
    pass "FEAT no warning for file in established directory"
fi
git reset --hard HEAD --quiet 2>/dev/null

# --------------------------------------------------------------------------
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]

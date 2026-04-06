#!/usr/bin/env bash
# =============================================================================
# test_m66_refresh_data_completeness.sh
#
# Regression guard: asserts that the dataFiles array in refreshData() (app.js)
# contains exactly the same set of data file names as the <script src="data/...">
# tags in index.html.
#
# If these two lists diverge, initial page load (index.html script tags) and
# incremental refresh (refreshData fetch loop) will disagree on what data exists.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() {
    echo "  PASS: $1"
    PASS=$((PASS + 1))
}

fail() {
    echo "  FAIL: $1"
    FAIL=$((FAIL + 1))
}

APP_JS="${TEKHTON_HOME}/templates/watchtower/app.js"
INDEX_HTML="${TEKHTON_HOME}/templates/watchtower/index.html"

# =============================================================================
# Test 1: app.js contains a dataFiles array in refreshData()
# =============================================================================
echo "=== Test 1: dataFiles array exists in refreshData() ==="

if grep -q "var dataFiles = \[" "$APP_JS"; then
    pass "dataFiles array declared in app.js"
else
    fail "dataFiles array not found in app.js"
fi

# =============================================================================
# Test 2: index.html contains data/*.js script tags
# =============================================================================
echo "=== Test 2: index.html has data/*.js script tags ==="

html_count=$(grep -c 'script src="data/' "$INDEX_HTML" || true)
if [ "$html_count" -gt 0 ]; then
    pass "index.html has $html_count data script tags"
else
    fail "index.html has no data/*.js script tags"
fi

# =============================================================================
# Test 3: extract and compare the two file lists
# =============================================================================
echo "=== Test 3: dataFiles in app.js matches script tags in index.html ==="

# Extract names from: var dataFiles = ['run_state', 'timeline', ...];
# Split on single-quotes, keep only pure lowercase+underscore tokens (the names).
js_files=$(grep "var dataFiles = \[" "$APP_JS" \
    | tr "'" '\n' \
    | grep -E '^[a-z_]+$' \
    | sort)

# Extract names from: <script src="data/run_state.js"></script>
html_files=$(grep 'script src="data/' "$INDEX_HTML" \
    | sed 's/.*data\/\([^.]*\)\.js.*/\1/' \
    | sort)

if [ -z "$js_files" ]; then
    fail "could not extract any names from dataFiles array in app.js"
elif [ -z "$html_files" ]; then
    fail "could not extract any names from index.html script tags"
elif [ "$js_files" = "$html_files" ]; then
    pass "dataFiles in app.js matches script tags in index.html (set-equal)"
else
    fail "dataFiles in app.js does NOT match script tags in index.html"
    echo "  app.js dataFiles: $(echo "$js_files" | tr '\n' ' ')"
    echo "  index.html tags:  $(echo "$html_files" | tr '\n' ' ')"
    # Show diff for diagnosis
    diff_out=$(diff <(echo "$js_files") <(echo "$html_files") || true)
    echo "  diff (app.js vs index.html):"
    echo "$diff_out" | sed 's/^/    /'
fi

# =============================================================================
# Test 4: neither list is empty — guard against extraction failures
# =============================================================================
echo "=== Test 4: both lists are non-empty ==="

js_count=$(echo "$js_files" | grep -c '[^[:space:]]' || true)
html_count2=$(echo "$html_files" | grep -c '[^[:space:]]' || true)

if [ "$js_count" -gt 0 ] && [ "$html_count2" -gt 0 ]; then
    pass "both lists extracted successfully ($js_count app.js, $html_count2 html)"
else
    fail "extraction produced an empty list (app.js=$js_count, html=$html_count2)"
fi

# =============================================================================
# Test 5: the set sizes are equal (count check independent of string compare)
# =============================================================================
echo "=== Test 5: dataFiles count matches script tag count ==="

if [ "$js_count" -eq "$html_count2" ]; then
    pass "file count matches: $js_count entries in both"
else
    fail "count mismatch: app.js has $js_count entries, index.html has $html_count2 script tags"
fi

# =============================================================================
# Summary
# =============================================================================
echo
echo "Results: Passed=$PASS  Failed=$FAIL"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0

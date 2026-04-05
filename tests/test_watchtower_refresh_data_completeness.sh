#!/usr/bin/env bash
# Test: Watchtower refreshData() array completeness
# Verifies that the dataFiles array in refreshData() matches all script tags in index.html

# Get absolute paths
TEKHTON_HOME="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
HTML_FILE="$TEKHTON_HOME/templates/watchtower/index.html"
APP_FILE="$TEKHTON_HOME/templates/watchtower/app.js"

PASS=0
FAIL=0

test_pass() {
  echo "✓ $1"
  ((PASS++))
}

test_fail() {
  echo "✗ $1"
  ((FAIL++))
}

echo "Testing Watchtower refresh data completeness..."
echo ""

# Verify files exist
if [[ ! -f "$HTML_FILE" ]]; then
  test_fail "index.html not found at $HTML_FILE"
  exit 1
fi

if [[ ! -f "$APP_FILE" ]]; then
  test_fail "app.js not found at $APP_FILE"
  exit 1
fi

test_pass "Source files found"

# Extract data file names from index.html script tags
# Look for: <script src="data/XXX.js"></script>
HTML_FILES=$(grep -oP 'src="data/\K[^.]+(?=\.js)' "$HTML_FILE" 2>/dev/null | sort)

if [[ -z "$HTML_FILES" ]]; then
  test_fail "Could not extract data files from index.html"
  exit 1
fi

test_pass "Extracted data files from index.html"

# Extract dataFiles array from app.js
# Look for: var dataFiles = ['file1', 'file2', ...]
APP_FILES=$(grep 'var dataFiles = ' "$APP_FILE" 2>/dev/null | grep -oP "'[^']+'" | tr -d "'" | sort)

if [[ -z "$APP_FILES" ]]; then
  test_fail "Could not extract dataFiles array from app.js"
  exit 1
fi

test_pass "Extracted dataFiles array from app.js"

echo ""
echo "=== Detailed Comparisons ==="
echo ""

# Convert to arrays
mapfile -t html_array < <(echo "$HTML_FILES")
mapfile -t app_array < <(echo "$APP_FILES")

echo "Files in index.html: ${#html_array[@]}"
echo "Files in app.js: ${#app_array[@]}"
echo ""

# Check that all HTML files are in app.js
echo "Checking: HTML files present in app.js..."
all_found=true
for file in "${html_array[@]}"; do
  if echo "$APP_FILES" | grep -q "^${file}$"; then
    test_pass "  ✓ '$file'"
  else
    test_fail "  ✗ '$file' MISSING from app.js"
    all_found=false
  fi
done

echo ""

# Check that all app.js files are in HTML
echo "Checking: app.js files loaded in index.html..."
no_stale=true
for file in "${app_array[@]}"; do
  if echo "$HTML_FILES" | grep -q "^${file}$"; then
    test_pass "  ✓ '$file'"
  else
    test_fail "  ✗ '$file' NOT in index.html (stale entry)"
    no_stale=false
  fi
done

echo ""

# Critical files check
echo "Checking: Critical bug-fix files..."
if echo "$APP_FILES" | grep -q "^action_items$"; then
  test_pass "action_items is in refreshData()"
else
  test_fail "action_items is MISSING from refreshData() (BUG NOT FIXED)"
fi

if echo "$APP_FILES" | grep -q "^notes$"; then
  test_pass "notes is in refreshData()"
else
  test_fail "notes is MISSING from refreshData() (BUG NOT FIXED)"
fi

echo ""
echo "=== Test Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
echo ""

if [[ $FAIL -eq 0 ]]; then
  echo "✓ All tests passed!"
  exit 0
else
  echo "✗ Some tests failed"
  exit 1
fi
